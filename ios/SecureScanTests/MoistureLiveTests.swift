//
//  MoistureLiveTests.swift
//  SecureScanTests
//
//  The moisture model wired into the app (Core/MoistureLive.swift): the capture
//  world as a plan, a solve drawn by provenance, the runner's cache, the camera's
//  corrections, the words on the chips and the quote's totals; LabelLayout's
//  dense-room rule.
//

import XCTest
import CoreGraphics
import simd

final class MoistureLiveTests: XCTestCase {

    private var world: CaptureWorld { StudioScenes.world }
    private var marks: [OverlayMark] { StudioScenes.raw("model-wash").marks }

    func testCaptureWorldAsPlan() {
        let plan = MoistureLive.plan(world: world, marks: marks)
        XCTAssertEqual((plan["walls"] as? [Any])?.count, 4)
        XCTAssertEqual((plan["rooms"] as? [Any])?.count, 1)
        XCTAssertEqual((plan["openings"] as? [Any])?.count, 2)
        let input = MoisturePlan.input(plan: plan, options: MoistureLive.options(live: true))
        XCTAssertEqual(input.readings.filter { $0.kind == .reading }.count, 5)
        XCTAssertEqual(input.sources.count, 1)
        XCTAssertEqual(input.sources.first?.wallId, "w1")
        XCTAssertEqual(input.sources.first?.type, .pipe, "\"Burst pipe\" reads as a pipe")
        let r1 = input.readings.first { $0.id == "r1" }
        XCTAssertEqual(r1?.wallId, "w1")
        XCTAssertEqual(r1?.side, .a, "inside the room is side a of w1")
        XCTAssertEqual(r1?.height ?? 0, 0.3, accuracy: 1e-6)
        XCTAssertEqual(r1?.value, 31)
        let r3 = input.readings.first { $0.id == "r3" }
        XCTAssertNil(r3?.wallId, "a floor reading")
        XCTAssertEqual(r3?.material, "floor")
        XCTAssertEqual(input.options.cellSize, 0.2, accuracy: 1e-9)
    }

    func testFadedReadingsOnlyWhenNothingMeasuredThisVisit() {
        var old = StudioScenes.pin("o1", WorldVec(1.0, 0.3, 0), 30, 1, faded: true)
        old.wallId = "w1"; old.side = "a"
        let fresh = StudioScenes.pin("n1", WorldVec(2.0, 0.3, 0), 12, 2)
        let a = MoisturePlan.input(plan: MoistureLive.plan(world: world, marks: [old]))
        XCTAssertEqual(a.readings.map(\.id), ["o1"])
        let b = MoisturePlan.input(plan: MoistureLive.plan(world: world, marks: [old, fresh]))
        XCTAssertEqual(b.readings.map(\.id), ["n1"])
    }

    func testTideLinesAreSiteMarks() {
        var wash = OverlayMark(id: "m1", style: .moistureWash, points: [WorldVec(0.5, 0.4, 0), WorldVec(1.0, 0.45, 0), WorldVec(1.5, 0.38, 0)])
        wash.floorLevel = 0
        let input = MoisturePlan.input(plan: MoistureLive.plan(world: world, marks: [wash]))
        let marks = input.readings.filter { $0.kind == .boundary }
        XCTAssertEqual(marks.count, 3)
        XCTAssertTrue(marks.allSatisfy { $0.wallId == "w1" })
        XCTAssertEqual(marks[1].height ?? 0, 0.45, accuracy: 1e-6)
    }

    private func solve(_ marks: [OverlayMark], tweaks: [MoistTweak] = []) -> MoistureSolve {
        MoistureSolve.solve(plan: MoistureLive.plan(world: world, marks: marks, tweaks: tweaks), options: MoistureLive.options(live: true))
    }

    func testDrawnByProvenance() {
        let s = solve(marks)
        let d = s.draw
        XCTAssertFalse(d.faces.isEmpty, "the wet wall face is drawn")
        let w1 = d.faces.first { $0.wallId == "w1" && $0.side == .a }
        XCTAssertNotNil(w1)
        let provs = Set(d.faces.flatMap { $0.areas.map(\.provenance) } + d.floors.flatMap { $0.areas.map(\.provenance) })
        XCTAssertTrue(provs.contains(.measured), "near the readings")
        XCTAssertTrue(provs.contains(.estimated), "physics only, further out")
        XCTAssertFalse(provs.contains(.scoper), "no corrections yet")
        // Face shapes stay on their face: along 0...length, 0...the modelled height.
        for f in d.faces {
            let len = world.wall(f.wallId)!.length
            for a in f.areas { for loop in a.loops { for p in loop {
                XCTAssertGreaterThanOrEqual(p.x, -1e-9); XCTAssertLessThanOrEqual(p.x, len + 1e-9)
                XCTAssertGreaterThanOrEqual(p.y, -1e-9); XCTAssertLessThanOrEqual(p.y, 1.2 + 1e-9)
            } } }
            // No edge along the floor junction.
            for e in f.edges { XCTAssertFalse(e.points.allSatisfy { $0.y < 0.03 }) }
        }
        XCTAssertFalse(d.floors.isEmpty, "the wet floor is drawn")
        // As world marks: faces carry their wall and side, so the camera's side rules apply.
        let ms = MoistureMarks.marks(d, world: world)
        XCTAssertTrue(ms.contains { if case .modelArea = $0.style { return $0.wallId == "w1" && $0.side == "a" } else { return false } })
        XCTAssertTrue(ms.contains { if case .modelEdge = $0.style { return true } else { return false } })
        // From the next room (behind w1) the face's wash is not drawn.
        let behind = WorldVec(1.5, 1.4, -2.0)
        let seen = ms.compactMap { Visibility.prepare($0, camera: behind, world: world) }
        XCTAssertFalse(seen.contains { $0.wallId == "w1" && $0.side == "a" })
    }

    func testScoperCorrectionDrawnAsScoper() {
        let t = LiveTweak(id: "adj-1", kind: .wet, onWall: false, points: [WorldVec(0.6, 0, 2.2), WorldVec(0.8, 0, 2.3)], floorY: 0,
                          from: PlanVec(1.5, 1.5), wallId: nil, radius: 0.3)
        let mt = t.tweak(walls: world.walls)!
        let s = solve(marks, tweaks: [mt])
        let provs = Set(s.draw.floors.flatMap { $0.areas.map(\.provenance) })
        XCTAssertTrue(provs.contains(.scoper))
    }

    func testRunnerCachesByInputsHash() {
        let runner = MoistureRunner(debounce: 0)
        let opts = MoistureLive.options(live: true)
        let a = runner.solveNow(plan: MoistureLive.plan(world: world, marks: marks), options: opts)
        let b = runner.solveNow(plan: MoistureLive.plan(world: world, marks: marks), options: opts)
        XCTAssertTrue(a === b)
        XCTAssertEqual(runner.solves, 1)
        var changed = marks
        changed[1].value = "40"
        _ = runner.solveNow(plan: MoistureLive.plan(world: world, marks: changed), options: opts)
        XCTAssertEqual(runner.solves, 2)
        // The signature the HUD watches changes with a value, not with anything else.
        XCTAssertNotEqual(MoistureLive.signature(world: world, marks: marks, tweaks: 0), MoistureLive.signature(world: world, marks: changed, tweaks: 0))
        var photo = marks
        photo.append(OverlayMark(id: "p1", style: .photo, points: [WorldVec(1, 1, 0)]))
        XCTAssertEqual(MoistureLive.signature(world: world, marks: marks, tweaks: 0), MoistureLive.signature(world: world, marks: photo, tweaks: 0))
    }

    func testRunnerScheduleDeliversNewestOnly() {
        let runner = MoistureRunner(debounce: 0.05)
        let opts = MoistureLive.options(live: true)
        var got: [String] = []
        let done = expectation(description: "solved")
        var changed = marks
        changed[1].value = "40"
        runner.schedule(plan: MoistureLive.plan(world: world, marks: marks), options: opts) { got.append($0.inputsHash) }
        runner.schedule(plan: MoistureLive.plan(world: world, marks: changed), options: opts) { got.append($0.inputsHash); done.fulfill() }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(got.count, 1, "the first request was replaced")
        XCTAssertEqual(runner.solves, 1)
    }

    func testCameraCorrections() {
        let w1 = world.wall("w1")!
        // A brush on w1, from inside the room: side a, along / up the wall.
        let brush = LiveTweak(id: "adj-1", kind: .dry, onWall: true, points: [WorldVec(1.0, 0.5, 0), WorldVec(1.3, 0.55, 0)], floorY: 0,
                              from: PlanVec(1.5, 2.0), wallId: "w1")
        let t = brush.tweak(walls: world.walls)!
        XCTAssertEqual(t.kind, .brush)
        XCTAssertEqual(t.surface, .face)
        XCTAssertEqual(t.wallId, "w1")
        XCTAssertEqual(t.side, .a)
        XCTAssertEqual(t.state, .dry)
        XCTAssertEqual(t.points[0].x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.points[1].y, 0.55, accuracy: 1e-6)
        // From the other room: side b.
        var other = brush; other.from = PlanVec(1.5, -2.0)
        XCTAssertEqual(other.tweak(walls: world.walls)?.side, .b)
        // A tap on the tide line: a short level line either side.
        let tide = LiveTweak(id: "adj-2", kind: .tide, onWall: true, points: [WorldVec(2.0, 0.6, 0)], floorY: 0, from: PlanVec(1, 1), wallId: "w1")
        let tt = tide.tweak(walls: world.walls)!
        XCTAssertEqual(tt.kind, .tideLine)
        XCTAssertEqual(tt.points.count, 2)
        XCTAssertEqual(tt.points[0].y, 0.6, accuracy: 1e-6)
        XCTAssertEqual(tt.points[1].x - tt.points[0].x, 0.6, accuracy: 1e-6)
        // "No spread past here": two floor points, mapped into another frame.
        let bar = LiveTweak(id: "adj-3", kind: .barrier, onWall: false, points: [WorldVec(1, 0, 1), WorldVec(1.2, 0, 1.6), WorldVec(1, 0, 2.5)],
                            floorY: 0, from: PlanVec(2, 2), wallId: nil)
        let shifted = bar.tweak(walls: world.walls, toPlan: { $0 + PlanVec(10, 0) })!
        XCTAssertEqual(shifted.kind, .barrier)
        XCTAssertEqual(shifted.points.count, 2)
        XCTAssertEqual(shifted.points[0].x, 11, accuracy: 1e-9)
        XCTAssertEqual(shifted.points[1].y, 2.5, accuracy: 1e-9)
        // A tide line can't be on the floor; a tiny barrier is nothing.
        XCTAssertNil(LiveTweak(id: "x", kind: .tide, onWall: false, points: [WorldVec(1, 0, 1)], floorY: 0, from: .zero).tweak(walls: world.walls))
        XCTAssertNil(LiveTweak(id: "y", kind: .barrier, onWall: false, points: [WorldVec(1, 0, 1), WorldVec(1.02, 0, 1)], floorY: 0, from: .zero).tweak(walls: world.walls))
        // Written into a plan through the engine's API and read back.
        let plan = MoisturePlan.adding(t, to: MoistureLive.plan(world: world, marks: marks))
        XCTAssertEqual(MoisturePlan.input(plan: plan).tweaks.first?.id, "adj-1")
        _ = w1
    }

    func testWords() {
        let s = solve(marks)
        XCTAssertTrue(s.words.secondSource || s.words.text.hasPrefix("Model · 5 readings · "), s.words.text)
        XCTAssertEqual(s.words.secondSource, !s.result.hints.isEmpty)
        var sg = MoistSuggestion(kind: .stripLining, wallId: "w1", side: .a, from: 0.5, to: 2.5, cutHeightMm: 600)
        sg.length = 2.0
        sg.confidence = MoistConfidence(score: 0.8, level: .high, readings: 3)
        XCTAssertEqual(MoistureWords.suggestion(sg), "Likely: strip wall to 600 · 2.0 m")
        sg.confidence = MoistConfidence(score: 0.5, level: .medium, readings: 1)
        XCTAssertEqual(MoistureWords.suggestion(sg), "Possible: strip wall to 600 · 2.0 m")
        var floor = MoistSuggestion(kind: .liftFlooring, covering: .carpet)
        floor.area = 3.25
        XCTAssertEqual(MoistureWords.suggestion(floor), "Possible: lift carpet · 3.2 m²")
        XCTAssertNil(MoistureWords.suggestion(MoistSuggestion(kind: .inspectCavity)))
    }

    func testTotalsForTheQuote() {
        let t = MoistTotals(wallLining: MoistSplit(measured: 1.2, estimated: 0.8, scoper: 0.3), floor: MoistSplit(measured: 2, estimated: 0, scoper: 0),
                            floorByCovering: [], skirting: MoistSplit(measured: 0, estimated: 1.5, scoper: 0), cavityLength: 0)
        let rows = MoistureWords.totals(t)
        XCTAssertEqual(rows.map(\.title), ["Wall lining", "Floor", "Skirting"])
        XCTAssertEqual(rows[0].measured, 1.5, accuracy: 1e-9, "the scoper's own count as measured")
        XCTAssertEqual(rows[0].value, "2.3 m²")
        XCTAssertEqual(rows[0].detail, "1.5 measured · 0.8 estimated")
        XCTAssertEqual(rows[1].detail, "measured")
        XCTAssertEqual(rows[2].detail, "estimated")
        XCTAssertEqual(rows[2].value, "1.5 lm")
        // The same from plan.json.
        let s = solve(marks)
        let json = MoisturePlan.modelJSON(s.result, report: s.report)
        let fromJSON = MoistureWords.totals(json: json["solved"] as? [String: Any])
        XCTAssertEqual(fromJSON?.map(\.title), ["Wall lining", "Floor", "Skirting"])
        XCTAssertEqual(fromJSON?[1].total ?? -1, MoistureWords.totals(s.report.totals)[1].total, accuracy: 0.02)
    }

    func testDenseLabelsDoNotStack() {
        // Five pins within a few points of each other: one label, not a column of five.
        let items = (0..<5).map { k in
            LabelLayout.Item(id: "r\(k)", anchor: CGPoint(x: 200 + CGFloat(k) * 4, y: 300 + CGFloat(k) * 3), size: CGSize(width: 90, height: 24), priority: 10 + k)
        }
        let out = LabelLayout.layout(items, in: CGRect(x: 0, y: 0, width: 400, height: 800), obstacles: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertNotNil(out["r4"], "the most important one")
        // A selected one always gets its label.
        var sel = items
        sel[0].priority = 110
        let out2 = LabelLayout.layout(sel, in: CGRect(x: 0, y: 0, width: 400, height: 800), obstacles: [])
        XCTAssertNotNil(out2["r0"])
        // Labels never climb above their pin by more than one row.
        for (id, f) in out2 {
            let a = items.first { $0.id == id }!.anchor
            XCTAssertGreaterThan(f.minY, a.y - 24 - LabelLayout.pinClear - LabelLayout.gap - 1)
        }
    }
}

/// The model's solve time on the 5-room house, logged for CI (run in Release: see the workflow).
final class MoisturePerfTests: XCTestCase {
    func testSolveTimeFiveRoomHouse() {
        var lines: [String] = []
        for cell in [0.10, 0.20] {
            var input = MoistFixtures.house()
            input.options.cellSize = cell
            input.options.fitCellSize = max(0.2, cell)
            _ = MoistModel.run(input)                     // warm up
            var times: [Double] = []
            var r: MoistResult?
            for _ in 0..<3 {
                let t0 = Date()
                r = MoistModel.run(input)
                _ = r?.report()
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            let best = times.min() ?? 0
            #if DEBUG
            let config = "Debug"
            #else
            let config = "Release"
            #endif
            lines.append(String(format: "MOISTURE-PERF %@ cell=%.2f m best=%.1f ms median=%.1f ms cells=%ld", config, cell, best,
                                times.sorted()[1], r?.grid.count ?? 0))
            XCTAssertGreaterThan(r?.grid.count ?? 0, 1000)
        }
        for l in lines { print(l) }
    }
}
