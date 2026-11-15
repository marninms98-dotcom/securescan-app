//
//  VoiceAndPackTests.swift
//  SecureScanTests
//
//  v1.1 pure logic: voice-note grouping and merging, timeline order, chunk
//  planning, WAV repair, job-pack file names, moisture lines, camera framing,
//  plan <-> world transform.
//

import XCTest
import simd

final class VoiceAndPackTests: XCTestCase {

    func seg(_ text: String, _ start: Double, _ duration: Double = 0.3) -> TimedSegment {
        TimedSegment(text: text, start: start, duration: duration)
    }

    // MARK: Grouping

    func testGroupingSplitsAtPauses() {
        let segs = [seg("skirting", 0.5), seg("here", 0.9), seg("is", 1.3), seg("wet.", 1.6),
                    // 3 s silence
                    seg("moving", 5.0), seg("to", 5.4), seg("the", 5.6), seg("laundry", 5.9, 0.5)]
        let notes = NoteGrouper.group(segs)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].text, "Skirting here is wet.")
        XCTAssertEqual(notes[0].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(notes[0].end, 1.9, accuracy: 1e-9)
        XCTAssertEqual(notes[1].text, "Moving to the laundry")
        XCTAssertEqual(notes[1].end, 6.4, accuracy: 1e-9)
    }

    func testGroupingJoinsPunctuationAndPhrases() {
        XCTAssertEqual(NoteGrouper.join([" reading", "38", "%", ",", " we'll", "cut", "it."]), "Reading 38%, we'll cut it.")
        // Unsorted input, empty pieces ignored.
        let notes = NoteGrouper.group([seg("b", 1.0), seg("", 0.2), seg("a", 0.5)])
        XCTAssertEqual(notes.map(\.text), ["A b"])
        XCTAssertTrue(NoteGrouper.group([]).isEmpty)
    }

    func testLongSpeechSplitsAtSentenceEndThenHardLimit() {
        // Continuous speech, a word every 0.5 s for 80 s; one sentence end at 35 s.
        var segs: [TimedSegment] = []
        for i in 0..<160 {
            let t = Double(i) * 0.5
            segs.append(seg(t == 35 ? "end." : "word", t, 0.4))
        }
        let notes = NoteGrouper.group(segs)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes[0].text.hasSuffix("end."))
        XCTAssertEqual(notes[1].start, 35.5, accuracy: 1e-9)
        for n in notes { XCTAssertLessThanOrEqual(n.end - n.start, 60.5) }
    }

    // MARK: Merging

    let start = ISOTime.date("2026-11-13T01:00:00Z")!

    func testMergeAddsNotesWithAbsoluteTimesInOrder() {
        let typed: [String: Any] = ["id": "t1", "t": "2026-11-13T01:00:05Z", "text": "typed", "source": "typed"]
        let notes = [GroupedNote(text: "First", start: 2.0, end: 4.0), GroupedNote(text: "Second", start: 12.4, end: 15)]
        let out = VoiceNoteMerger.merge(existing: [typed], audio: "audio/001.m4a", recordingStart: start, notes: notes)
        XCTAssertEqual(out.map { $0["id"] as? String }, ["v001-01", "t1", "v001-02"])
        XCTAssertEqual(out[0]["t"] as? String, "2026-11-13T01:00:02Z")
        XCTAssertEqual(out[0]["end"] as? String, "2026-11-13T01:00:04Z")
        XCTAssertEqual(out[2]["t"] as? String, "2026-11-13T01:00:12Z")
        XCTAssertEqual(PlanDocument.number(out[2]["audioOffset"]), 12.4)
        XCTAssertEqual(out[0]["source"] as? String, "voice")
        XCTAssertEqual(out[0]["audio"] as? String, "audio/001.m4a")
        XCTAssertEqual(out[0]["edited"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(out))
    }

    func testRegenerateKeepsEditsAndOtherRecordings() {
        let first = VoiceNoteMerger.merge(existing: [], audio: "audio/001.m4a", recordingStart: start,
                                          notes: [GroupedNote(text: "Skirting reads thirty eight", start: 1, end: 4),
                                                  GroupedNote(text: "Second", start: 10, end: 12)])
        var edited = first
        edited[0]["text"] = "Skirting reads 38%"
        edited[0]["edited"] = true
        let other = VoiceNoteMerger.merge(existing: edited, audio: "audio/002.m4a",
                                          recordingStart: start.addingTimeInterval(60),
                                          notes: [GroupedNote(text: "Other", start: 0, end: 2)])
        XCTAssertEqual(other.count, 3)

        // Transcribe 001 again: the edit survives, the overlapping new note is
        // dropped, the other note is replaced, 002 is untouched.
        let again = VoiceNoteMerger.merge(existing: other, audio: "audio/001.m4a", recordingStart: start,
                                          notes: [GroupedNote(text: "Skirting reads 30 8", start: 1.2, end: 3.8),
                                                  GroupedNote(text: "Second again", start: 10, end: 12)])
        XCTAssertEqual(again.count, 3)
        XCTAssertEqual(again[0]["text"] as? String, "Skirting reads 38%")
        XCTAssertEqual(again[0]["edited"] as? Bool, true)
        XCTAssertEqual(again[1]["text"] as? String, "Second again")
        XCTAssertEqual(again[2]["text"] as? String, "Other")
        XCTAssertEqual(Set(again.compactMap { $0["id"] as? String }).count, 3)
    }

    func testFailedTranscriptionAddsPlaceholderOnce() {
        let out = VoiceNoteMerger.merge(existing: [], audio: "audio/003.m4a", recordingStart: start, notes: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["id"] as? String, "v003-00")
        XCTAssertEqual(out[0]["text"] as? String, "")
        XCTAssertEqual(out[0]["transcribed"] as? Bool, false)
        XCTAssertEqual(out[0]["t"] as? String, "2026-11-13T01:00:00Z")
        // Failing again replaces it rather than adding another.
        XCTAssertEqual(VoiceNoteMerger.merge(existing: out, audio: "audio/003.m4a", recordingStart: start, notes: nil).count, 1)
        // A later success replaces the placeholder.
        let ok = VoiceNoteMerger.merge(existing: out, audio: "audio/003.m4a", recordingStart: start,
                                       notes: [GroupedNote(text: "Hello", start: 0, end: 1)])
        XCTAssertEqual(ok.map { $0["id"] as? String }, ["v003-01"])
        XCTAssertNil(ok[0]["transcribed"])
    }

    func testNextAudioFileName() {
        XCTAssertEqual(VoiceIndex.nextFile(existing: [], filesOnDisk: []), "audio/001.m4a")
        let r = VoiceRecording(file: "audio/002.m4a", startedAt: "", duration: nil, state: "saved")
        XCTAssertEqual(VoiceIndex.nextFile(existing: [r], filesOnDisk: ["audio/007.wav", "audio/part-003.m4a"]), "audio/008.m4a")
        XCTAssertEqual(r.wavFile, "audio/002.wav")
        XCTAssertEqual(r.number, "002")
    }

    // MARK: Timeline

    func testTimelineOrdersEverythingAndPutsItemsBeforeNotesAtEqualTimes() throws {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        var doc = PlanDocument.newDocument(id: "J", address: "A", jobRef: "", createdAt: Date(timeIntervalSince1970: 0),
                                           now: Date(timeIntervalSince1970: 0), geometry: g)
        var markup = doc["markup"] as! [String: Any]
        var notes = SimulatedScan.notes()
        notes.append(["id": "same", "t": ISOTime.string(SimulatedScan.startDate.addingTimeInterval(40)), "text": "same time"])
        markup["notes"] = notes
        doc["markup"] = markup
        let events = Timeline.events(plan: doc)
        XCTAssertEqual(events.count, SimulatedScan.expected.filter { $0.kind != "floorType" }.count + SimulatedScan.spokenNotes.count + 1)
        for (a, b) in zip(events, events.dropFirst()) { XCTAssertLessThanOrEqual(a.time, b.time) }
        XCTAssertEqual(events.first?.id, "demo-n1")
        let i = try XCTUnwrap(events.firstIndex { $0.id == "sim-01" })
        XCTAssertEqual(events[i + 1].id, "same")
        XCTAssertEqual(events.first { $0.kind == "source" }?.text, "Water source — Flexi hose")
        XCTAssertEqual(events[i].text, "Reading 1: 24.5%")
    }

    func testSortedByTimeIsStableAndHandlesFractionsAndMissing() {
        let items: [[String: Any]] = [["id": "c"], ["id": "b", "t": "2026-11-13T01:00:01.500Z"],
                                      ["id": "a", "t": "2026-11-13T01:00:01Z"], ["id": "d", "t": "2026-11-13T01:00:01Z"]]
        XCTAssertEqual(Timeline.sortedByTime(items, key: "t").map { $0["id"] as? String }, ["a", "d", "b", "c"])
    }

    // MARK: Chunks, WAV

    func testChunkSplitsAtQuietestMoment() {
        var rms = [Float](repeating: 0.5, count: 1200)       // 120 s of speech at 0.1 s frames
        rms[400] = 0.01                                      // quiet at 40.05 s
        rms[880] = 0.02                                      // quiet at 88.05 s
        let cuts = ChunkPlanner.splitPoints(frameRMS: rms, frameSeconds: 0.1, maxChunk: 50, minChunk: 30)
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[0], 40.05, accuracy: 1e-6)
        XCTAssertEqual(cuts[1], 88.05, accuracy: 1e-6)
        XCTAssertTrue(ChunkPlanner.splitPoints(frameRMS: [Float](repeating: 1, count: 400), frameSeconds: 0.1).isEmpty)
        // No quiet spot: still never longer than the limit.
        let flat = ChunkPlanner.splitPoints(frameRMS: [Float](repeating: 1, count: 2000), frameSeconds: 0.1)
        var last = 0.0
        for c in flat + [200] { XCTAssertLessThanOrEqual(c - last, 50.0001); last = c }
    }

    func wavHeader(dataSizeField: UInt32, withJunk: Bool) -> Data {
        var d = Data("RIFF".utf8) + WAVRepair.le(0) + Data("WAVE".utf8)
        d += Data("fmt ".utf8) + WAVRepair.le(16) + Data(count: 16)
        if withJunk { d += Data("FLLR".utf8) + WAVRepair.le(6) + Data(count: 6) }
        d += Data("data".utf8) + WAVRepair.le(dataSizeField)
        return d
    }

    func testWAVRepairComputesSizes() {
        let h = wavHeader(dataSizeField: 0, withJunk: false)              // 44 bytes
        let fix = WAVRepair.fix(header: h, fileLength: 44 + 32_001)
        XCTAssertEqual(fix, WAVRepair.Fix(riffSize: 36 + 32_000, dataSizeOffset: 40, dataSize: 32_000))
        let h2 = wavHeader(dataSizeField: 0xFFFF_FFFF, withJunk: true)    // 58 bytes
        let fix2 = WAVRepair.fix(header: h2, fileLength: 58 + 1000)
        XCTAssertEqual(fix2?.dataSizeOffset, 54)
        XCTAssertEqual(fix2?.dataSize, 1000)
        XCTAssertEqual(fix2?.riffSize, 50 + 1000)
        XCTAssertNil(WAVRepair.fix(header: Data("NOPE".utf8), fileLength: 100))
    }

    func testWAVRepairFileOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try (wavHeader(dataSizeField: 0, withJunk: true) + Data(count: 400)).write(to: url)
        XCTAssertTrue(WAVRepair.repairFile(at: url))
        let d = try Data(contentsOf: url)
        XCTAssertEqual(d.count, 458)
        XCTAssertEqual(d.subdata(in: 4..<8), WAVRepair.le(450))
        XCTAssertEqual(d.subdata(in: 54..<58), WAVRepair.le(400))
    }

    // MARK: Pack names

    func testPackPathsRejectTraversal() {
        XCTAssertEqual(PackNames.safeRelativePath("summary.md"), "summary.md")
        XCTAssertEqual(PackNames.safeRelativePath("photos/reading-3.jpg"), "photos/reading-3.jpg")
        XCTAssertEqual(PackNames.safeRelativePath("photos/P1: inspection?.jpg"), "photos/P1- inspection-.jpg")
        XCTAssertEqual(PackNames.safeRelativePath(".hidden"), "hidden")
        for bad in ["../plan.json", "photos/../../x", "/etc/passwd", "~/x", "a\\b", "", "a//b", "./a", "a/./b",
                    "a/b/c/d/e", String(repeating: "x", count: 300), "..", "photos/.."] {
            XCTAssertNil(PackNames.safeRelativePath(bad), bad)
        }
    }

    func testPackZipName() {
        XCTAssertEqual(PackNames.packBaseName(address: "30 Sample Cr, Testwood, WA"), "30 Sample Cr, Testwood, WA-job-pack")
        XCTAssertEqual(PackNames.packBaseName(address: "Unit 2/14  Smith St\nPerth"), "Unit 2-14 Smith St-Perth-job-pack")
        XCTAssertEqual(PackNames.packBaseName(address: "  "), "SecureScan-job-pack")
    }

    // MARK: 3D helpers

    func testMoistureLinesGroupPerWallInWallTOrder() {
        let marks = [MoistureLines.Mark(id: "a", wallId: "w2", wallT: 0.6),
                     MoistureLines.Mark(id: "b", wallId: "w3", wallT: 0.1),
                     MoistureLines.Mark(id: "c", wallId: "w2", wallT: 0.2),
                     MoistureLines.Mark(id: "d", wallId: nil, wallT: nil),
                     MoistureLines.Mark(id: "e", wallId: "w2", wallT: 0.9)]
        XCTAssertEqual(MoistureLines.lines(marks), [["c", "a", "e"]])
    }

    func testDemoMoistureLineHasFourPointsOnOneWall() {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        let marks = g.readings.filter { $0.kind == "boundary" }.map { MoistureLines.Mark(id: $0.id, wallId: $0.wallId, wallT: $0.wallT) }
        XCTAssertEqual(MoistureLines.lines(marks), [["sim-11", "sim-12", "sim-03", "sim-05"]])
    }

    func testCameraFitSeesEveryCorner() {
        let lo = SIMD3<Double>(0, 0, 0), hi = SIMD3<Double>(5.4, 2.4, 5.9)
        var corners: [SIMD3<Double>] = []
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] { corners.append(SIMD3(x, y, z)) } } }
        let centre = (lo + hi) / 2
        let dir = CameraFit.direction(azimuthDegrees: 30, elevationDegrees: 48)
        XCTAssertEqual(simd_length(dir), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(dir.y, 0.7)
        let tanH = tan(25 * Double.pi / 180)
        let d = CameraFit.distance(points: corners, target: centre, direction: dir, tanH: tanH, tanV: tanH / 0.62, margin: 0.86)
        let cam = centre + dir * d
        // Outside the model, and not absurdly far.
        XCTAssertGreaterThan(cam.y, hi.y + 2)
        XCTAssertGreaterThan(d, 5)
        XCTAssertLessThan(d, 25)
        // Tight: a bit closer and some corner leaves the view.
        let closer = CameraFit.distance(points: corners, target: centre, direction: dir, tanH: tanH, tanV: tanH / 0.62, margin: 1.0)
        XCTAssertLessThan(closer, d)
    }

    func testPlanTransformInverse() {
        let t = PlanTransform(angle: -0.5236, offset: PlanVec(3.1, -0.7))
        let w = WorldVec(2.3, -1.1, -1.7)
        let back = t.world(t.point(w), y: w.y)
        XCTAssertEqual(simd_distance(back, w), 0, accuracy: 1e-9)
    }
}

// MARK: - v1.5 / v1.6

final class ReportAndEquipmentTests: XCTestCase {

    func testReportLinksParseAndConvertToPDFSpace() throws {
        let raw: [String: Any] = [
            "pages": 3, "pageSize": [595, 842],
            "links": [
                ["page": 2, "rect": [100, 200, 20, 10], "targetPage": 3, "targetY": 120],
                ["page": 1, "rect": [10, 10, 0, 10], "targetPage": 2, "targetY": 0],     // zero width: skipped
                ["page": 3, "rect": [1, 2, 3, 4], "targetPage": 9, "targetY": 0],        // target out of range
            ] as [[String: Any]],
        ]
        let links = try XCTUnwrap(ReportLinks.parse(raw))
        XCTAssertEqual(links.pages, 3)
        XCTAssertEqual(links.links.count, 2)
        XCTAssertEqual(links.valid(pageCount: 3).count, 1)
        XCTAssertTrue(links.valid(pageCount: 0).isEmpty)
        let box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let r = ReportLinks.pdfRect(links.links[0].rect, pageSize: links.pageSize, box: box)
        XCTAssertEqual(r, CGRect(x: 100, y: 842 - 200 - 10, width: 20, height: 10))
        XCTAssertEqual(ReportLinks.pdfDestination(targetY: 120, pageSize: links.pageSize, box: box), CGPoint(x: 0, y: 722))
        XCTAssertEqual(ReportLinks.pdfDestination(targetY: 0, pageSize: links.pageSize, box: box), CGPoint(x: 0, y: 842))
        // A page box rendered at a different size or origin is scaled.
        let big = CGRect(x: 10, y: 20, width: 1190, height: 1684)
        XCTAssertEqual(ReportLinks.pdfRect(CGRect(x: 0, y: 0, width: 595, height: 842), pageSize: links.pageSize, box: big), big)
        XCTAssertNil(ReportLinks.parse(["pages": 0]))
        XCTAssertNil(ReportLinks.parse("nope"))
    }

    func testReportFileNames() {
        XCTAssertEqual(PackNames.reportFileName(address: "30 Sample Cr, Testwood, WA"), "30 Sample Cr, Testwood, WA-assessment-report.pdf")
        XCTAssertEqual(PackNames.reportFileName(address: ""), "SecureScan-assessment-report.pdf")
        XCTAssertEqual(PackNames.packBaseName(address: "a/b"), "a-b-job-pack")
    }

    func testBrandIsRememberedAndInjected() {
        let brand: [String: Any] = ["name": "SecureWorks WA", "accent": "#1f4e79", "logo": "data:image/png;base64,AAAA"]
        let plan: [String: Any] = ["markup": ["brand": brand, "readings": [] as [Any]] as [String: Any]]
        let diff = AppSettings.changes(plan: plan, stored: [:])
        XCTAssertEqual((diff["brand"] as? [String: Any])?["accent"] as? String, "#1f4e79")
        XCTAssertTrue(AppSettings.changes(plan: plan, stored: ["brand": brand]).isEmpty)
        var other = brand; other["accent"] = "#2b3a55"
        XCTAssertNotNil(AppSettings.changes(plan: ["markup": ["brand": other]], stored: ["brand": brand])["brand"])
        // Injection only fills a missing brand, and only when one is stored.
        let bare: [String: Any] = ["address": "A", "markup": ["readings": [] as [Any]] as [String: Any]]
        let injected = AppSettings.injected(plan: bare, stored: ["brand": brand])
        XCTAssertEqual(((injected?["markup"] as? [String: Any])?["brand"] as? [String: Any])?["name"] as? String, "SecureWorks WA")
        XCTAssertEqual(injected?["address"] as? String, "A")
        XCTAssertNil(AppSettings.injected(plan: plan, stored: ["brand": other]))
        XCTAssertNil(AppSettings.injected(plan: bare, stored: [:]))
        // The rate-card hook works the same way once the editor writes markup.rateCard.
        let rc: [String: Any] = ["equipment:airMover": 45]
        XCTAssertNotNil(AppSettings.changes(plan: ["markup": ["rateCard": rc]], stored: [:])["rateCard"])
    }

    func testEquipmentStandsOnTheFloorAndGoesToMarkupEquipment() throws {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        let e = try XCTUnwrap(g.equipment.first { $0.id == "sim-e3" })
        XCTAssertEqual(e.pos.x, 3.2, accuracy: 0.03)
        XCTAssertEqual(e.pos.y, 3.4, accuracy: 0.03)
        XCTAssertEqual(e.height, 0)
        XCTAssertEqual(simd_distance(e.cam ?? PlanVec(-9, -9), PlanVec(2.2, 3.4)), 0, accuracy: 0.03)

        var doc = PlanDocument.newDocument(id: "J", address: "A", jobRef: "", createdAt: Date(timeIntervalSince1970: 0),
                                           now: Date(timeIntervalSince1970: 0), geometry: g)
        var markup = doc["markup"] as! [String: Any]
        let items = markup["equipment"] as! [[String: Any]]
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[2]["type"] as? String, "dehumidifier")
        XCTAssertEqual(items[2]["label"] as? String, "DH-01")
        XCTAssertEqual(items[2]["placed"] as? String, "v1")
        XCTAssertTrue(items[2]["removed"] is NSNull)
        XCTAssertNotNil(items[2]["placedAt"] as? String)
        XCTAssertNil(items[2]["wallId"])
        XCTAssertNotNil(items[2]["cam"])

        // Regenerate during visit 2: positions rebuilt, edits kept, a missing item comes back as visit 2.
        var edited = items
        edited[0]["label"] = "AM-07"
        edited[0]["pos"] = [9.0, 9.0]
        edited.remove(at: 1)
        markup["equipment"] = edited
        markup["currentVisit"] = "v2"
        doc["markup"] = markup
        let merged = (PlanDocument.merged(existing: doc, geometry: g)["markup"] as! [String: Any])["equipment"] as! [[String: Any]]
        XCTAssertEqual(merged.map { $0["id"] as? String }, ["sim-e1", "sim-e3", "sim-e2"])
        XCTAssertEqual(merged[0]["label"] as? String, "AM-07")
        XCTAssertEqual((merged[0]["pos"] as! [Double])[0], 4.4, accuracy: 0.03)
        XCTAssertEqual(merged[2]["placed"] as? String, "v2")
        XCTAssertEqual(PlanDocument.currentVisit(["visits": [["id": "v1"], ["id": "v3"]]]), "v3")
        XCTAssertEqual(PlanDocument.currentVisit([:]), "v1")
    }

    func testDemoPhotosBelongToDemoItems() {
        let ids = Set(SimulatedScan.expected.map(\.id))
        for p in SimulatedScan.demoPhotos { XCTAssertTrue(ids.contains(p.id), p.id) }
    }
}

final class StressDemoTests: XCTestCase {
    func testStressPhotosAreWallPhotosTakenFromInsideTheHouse() {
        let extra = SimulatedScan.stressPhotos(count: 20)
        XCTAssertEqual(Set(extra.map(\.id)).count, 20)
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings() + extra)
        let photos = g.readings.filter { $0.kind == "photo" }
        XCTAssertEqual(photos.count, 21)
        XCTAssertEqual(photos.last?.n, 21)
        for p in photos where p.id.hasPrefix("stress-") {
            XCTAssertNotNil(p.wallId, p.id)
            let cam = p.cam ?? PlanVec(-9, -9)
            XCTAssertTrue(SimulatedScan.truePolygons.contains { SimulatedScan.inside(cam, $0) }, "\(p.id) camera outside")
        }
    }
}
