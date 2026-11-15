//
//  RevisitTests.swift
//  SecureScanTests
//
//  Round 3: removals by two taps, flooring sections, floor types, alignment
//  of a new AR session to the saved plan, and the return-visit document
//  functions - all through the same Core code the app uses, with synthetic
//  "session" data (rotated / offset / noisy) instead of a camera.
//

import XCTest
import simd

final class RemovalTests: XCTestCase {

    func room4() -> PBRoom {
        var r = PBRoom()
        let c: [PlanVec] = [[0, 0], [4, 0], [4, 3], [0, 3]]
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4], mid = (a + b) / 2
            r.walls.append(PBSurface(id: SimulatedScan.uuid(i + 1), parentId: nil,
                                     transform: SimulatedScan.surfaceTransform(centre: WorldVec(mid.x, 1.2, mid.y), dir: b - a),
                                     dimensions: SIMD3<Float>(Float(simd_length(b - a)), 2.4, 0)))
        }
        return r
    }

    /// A removal whose taps aim from `cam` (plan, 1.4 m high) at `target` (plan, at `h` m) and `end`.
    func removal(_ item: String, from cam: PlanVec, _ target: PlanVec, to cam2: PlanVec, _ end: PlanVec, h: Double = 0.4) -> PBReading {
        let c1 = WorldVec(cam.x, 1.4, cam.y), t1 = WorldVec(target.x, h, target.y)
        let c2 = WorldVec(cam2.x, 1.4, cam2.y), t2 = WorldVec(end.x, h, end.y)
        var r = PBReading(id: "x-\(item)", seq: 1, kind: "removal", value: nil, material: item, takenAt: "2026-11-13T01:00:00Z",
                          cameraPosition: c1, cameraForward: simd_normalize(t1 - c1), hit: t1)
        r.end = PBPose(cameraPosition: c2, cameraForward: simd_normalize(t2 - c2), hit: t2)
        r.heightMm = 600
        return r
    }

    func testRemovalOnOneWallIsOrdered() throws {
        // End tapped before start along the wall: t0 < t1 anyway.
        let r = removal("plasterboard", from: [3, 1.5], [3, 0], to: [1, 1.5], [1, 0])
        let g = PlanBuilder.build(rooms: [room4()], readings: [r])
        let x = try XCTUnwrap(g.removals.first)
        XCTAssertEqual(x.wallId, "w1")
        XCTAssertEqual(x.t0 ?? -1, 0.25, accuracy: 0.01)
        XCTAssertEqual(x.t1 ?? -1, 0.75, accuracy: 0.01)
        XCTAssertTrue(g.readings.isEmpty)
    }

    func testEndOnAdjoiningWallNearTheCornerIsSnappedToTheStartWall() throws {
        // Start on w1 (y = 0); end aimed 0.25 m along w2 (x = 4) next to the shared corner.
        let r = removal("skirting", from: [2, 1.5], [1, 0], to: [3, 1.0], [4, 0.25])
        let g = PlanBuilder.build(rooms: [room4()], readings: [r])
        let x = try XCTUnwrap(g.removals.first)
        XCTAssertEqual(x.wallId, "w1")
        XCTAssertEqual(x.t0 ?? -1, 0.25, accuracy: 0.01)
        XCTAssertEqual(x.t1 ?? -1, 1.0, accuracy: 0.01)
    }

    func testRemovalAcrossTwoWallsIsRejected() {
        // Start on w1, end in the middle of w3 (the opposite wall).
        let r = removal("plasterboard", from: [2, 1.0], [2, 0], to: [2, 2.0], [2, 3])
        let g = PlanBuilder.build(rooms: [room4()], readings: [r])
        XCTAssertTrue(g.removals.isEmpty)
        XCTAssertEqual(g.rejectedRemovals.first?.id, "x-plasterboard")
        XCTAssertTrue(g.rejectedRemovals.first?.reason.contains("different walls") ?? false)
    }

    func testTooShortRemovalIsRejected() {
        let r = removal("plasterboard", from: [2, 1.0], [2, 0], to: [2, 1.0], [2.01, 0])
        XCTAssertEqual(PlanBuilder.build(rooms: [room4()], readings: [r]).rejectedRemovals.count, 1)
    }

    func testFlooringFromCornersAndWholeRoom() throws {
        func pose(_ p: PlanVec, from c: PlanVec) -> PBPose {
            let cw = WorldVec(c.x, 1.4, c.y), t = WorldVec(p.x, 0, p.y)
            return PBPose(cameraPosition: cw, cameraForward: simd_normalize(t - cw), hit: t)
        }
        var f = PBReading(id: "fl", seq: 1, kind: "removal", value: nil, material: "flooring", takenAt: "",
                          cameraPosition: WorldVec(2, 1.4, 1.5), cameraForward: WorldVec(0, -1, 0))
        f.corners = [pose([0.5, 0.5], from: [2, 1.5]), pose([2.5, 0.5], from: [2, 1.5]),
                     pose([2.5, 2.0], from: [2, 1.5]), pose([0.5, 2.0], from: [2, 1.5])]
        f.floorType = "vinyl"
        var whole = f
        whole.id = "wr"
        whole.corners = []
        whole.wholeRoom = true
        var crossed = f
        crossed.id = "bad"
        crossed.corners = [f.corners[0], f.corners[2], f.corners[1], f.corners[3]]   // bow-tie
        let g = PlanBuilder.build(rooms: [room4()], readings: [f, whole, crossed])
        let a = try XCTUnwrap(g.removals.first { $0.id == "fl" }?.area)
        XCTAssertEqual(FloorArea.area(a), 3.0, accuracy: 0.02)
        XCTAssertNil(g.removals.first?.wallId)
        XCTAssertEqual(FloorArea.area(try XCTUnwrap(g.removals.first { $0.id == "wr" }?.area)), 12, accuracy: 0.02)
        XCTAssertEqual(g.rejectedRemovals.map { $0.id }, ["bad"])

        let doc = PlanDocument.newDocument(id: "J", address: "", jobRef: "", createdAt: Date(), now: Date(), geometry: g)
        let rem = ((doc["markup"] as! [String: Any])["removals"] as! [[String: Any]]).first { $0["id"] as? String == "fl" }!
        XCTAssertEqual(rem["item"] as? String, "flooring")
        XCTAssertEqual((rem["area"] as? [[Double]])?.count, 4)
        XCTAssertEqual(rem["floorType"] as? String, "vinyl")
        XCTAssertEqual(rem["underlay"] as? Bool, false)
        XCTAssertNil(rem["wallId"])
        XCTAssertEqual(rem["status"] as? String, "proposed")
    }

    func testFloorAreaHelpers() {
        let sq: [PlanVec] = [[0, 0], [2, 0], [2, 2], [0, 2]]
        XCTAssertTrue(FloorArea.inside([1, 1], sq))
        XCTAssertFalse(FloorArea.inside([3, 1], sq))
        XCTAssertEqual(FloorArea.area(sq), 4, accuracy: 1e-9)
        XCTAssertFalse(FloorArea.selfIntersects(sq))
        XCTAssertTrue(FloorArea.selfIntersects([[0, 0], [2, 2], [2, 0], [0, 2]]))
        XCTAssertEqual(FloorArea.room(containing: [1, 1], rooms: [[[-5, -5], [5, -5], [5, 5], [-5, 5]], sq]), 1)   // smallest
        if case .failure(let e) = FloorArea.polygon([[0, 0], [1, 0]]) { XCTAssertTrue(e.message.contains("3 corners")) } else { XCTFail() }
        if case .success(let p) = FloorArea.polygon([[0, 0], [1, 0], [1, 0.01], [1, 1], [0, 1], [0, 0.01]]) { XCTAssertEqual(p.count, 4) } else { XCTFail() }
    }

    func testDemoRemovalsAndFloors() throws {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        XCTAssertTrue(g.rejectedRemovals.isEmpty, "\(g.rejectedRemovals)")
        let r1 = try XCTUnwrap(g.removals.first { $0.id == "sim-r1" })
        XCTAssertEqual(r1.wallId, "w2")
        XCTAssertEqual(r1.t0 ?? -1, 0.3 / 2.8, accuracy: 0.02)
        XCTAssertEqual(r1.t1 ?? -1, 2.5 / 2.8, accuracy: 0.02)
        let r2 = try XCTUnwrap(g.removals.first { $0.id == "sim-r2" })
        XCTAssertEqual(r2.wallId, "w13")
        XCTAssertEqual(r2.heightMm, 100)
        let r3 = try XCTUnwrap(g.removals.first { $0.id == "sim-r3" })
        XCTAssertEqual(FloorArea.area(try XCTUnwrap(r3.area)), 5.04, accuracy: 0.15)
        XCTAssertEqual(g.floors.first?.type, "carpet")
        XCTAssertEqual(FloorArea.area(g.floors.first?.polygon ?? []), 9.66, accuracy: 0.2)

        var doc = PlanDocument.newDocument(id: "J", address: "", jobRef: "", createdAt: Date(), now: Date(), geometry: g)
        var markup = doc["markup"] as! [String: Any]
        XCTAssertEqual((markup["floors"] as? [[String: Any]])?.first?["type"] as? String, "carpet")
        // Regenerate keeps an edited removal and its geometry is rebuilt.
        var rems = markup["removals"] as! [[String: Any]]
        rems[0]["heightMm"] = 1200
        rems[0]["t0"] = 0.9
        markup["removals"] = rems
        doc["markup"] = markup
        let merged = (PlanDocument.merged(existing: doc, geometry: g)["markup"] as! [String: Any])["removals"] as! [[String: Any]]
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0]["heightMm"] as? Int, 1200)
        XCTAssertEqual(PlanDocument.number(merged[0]["t0"]) ?? -1, 0.3 / 2.8, accuracy: 0.02)
    }

    func testLiveSameWallCheck() {
        let n = WorldVec(0, 0, 1)
        XCTAssertEqual(RemovalCheck.sameWall(startHit: [0, 0.5, 0], startNormal: n, endHit: [2, 0.6, 0.05], endNormal: n), true)
        XCTAssertEqual(RemovalCheck.sameWall(startHit: [0, 0.5, 0], startNormal: n, endHit: [2, 0.6, 0.5], endNormal: n), false)
        XCTAssertEqual(RemovalCheck.sameWall(startHit: [0, 0.5, 0], startNormal: n, endHit: [2, 0.6, 0], endNormal: WorldVec(1, 0, 0)), false)
        XCTAssertNil(RemovalCheck.sameWall(startHit: [0, 0, 0], startNormal: WorldVec(0, 1, 0), endHit: [1, 0, 0], endNormal: WorldVec(0, 1, 0)))
        XCTAssertNil(RemovalCheck.sameWall(startHit: nil, startNormal: n, endHit: [1, 0, 0], endNormal: n))
    }
}

final class AlignmentTests: XCTestCase {

    /// A "new session" frame: plan point -> world point via a rotation,
    /// an offset and a floor height (the inverse of what we want to recover).
    func session(_ p: PlanVec, angle: Double, offset: PlanVec, floorY: Double, noise: PlanVec = .zero) -> WorldVec {
        let truth = PlanTransform(angle: angle, offset: offset)
        return truth.world(p + noise, y: floorY)
    }

    func testTwoCornersRecoverRotationAndOffset() throws {
        let a: PlanVec = [0, 0], b: PlanVec = [3.45, 2.8]
        for deg in [-170.0, -45, 0, 12, 90, 135] {
            let ang = deg * .pi / 180, off = PlanVec(2.7, -1.3)
            let w = [session(a, angle: ang, offset: off, floorY: -1.31), session(b, angle: ang, offset: off, floorY: -1.31)]
            guard case .success(let f) = Alignment.fit(world: w, plan: [a, b]) else { return XCTFail("\(deg)") }
            XCTAssertEqual(PlanBuilder.normaliseAngle(f.transform.angle - ang), 0, accuracy: 1e-9, "\(deg)")
            XCTAssertEqual(simd_distance(f.transform.offset, off), 0, accuracy: 1e-9)
            XCTAssertEqual(f.floorY, -1.31, accuracy: 1e-9)
            XCTAssertTrue(f.ok)
            // Any other plan point round-trips world <-> plan.
            let p = PlanVec(1.2, 2.2), wp = Revisit.world(p, height: 0.6, alignment: f.transform, floorY: f.floorY)
            XCTAssertEqual(simd_distance(f.transform.point(wp), p), 0, accuracy: 1e-9)
            XCTAssertEqual(wp.y, -0.71, accuracy: 1e-9)
        }
    }

    func testDistanceMismatchIsReportedAndThirdCornerRefines() throws {
        let plan: [PlanVec] = [[0, 0], [4, 0], [4, 3]]
        let ang = 0.6, off = PlanVec(1, 1)
        // B measured 12 cm too far along: reported.
        let bad = [session(plan[0], angle: ang, offset: off, floorY: 0), session(plan[1], angle: ang, offset: off, floorY: 0, noise: [0.12, 0])]
        guard case .success(let f2) = Alignment.fit(world: bad, plan: Array(plan[0...1])) else { return XCTFail() }
        XCTAssertEqual(f2.distanceError, 0.12, accuracy: 1e-6)
        XCTAssertFalse(f2.ok)
        // Small noise on three corners: least squares stays within 3 cm everywhere.
        let noisy = [session(plan[0], angle: ang, offset: off, floorY: 0, noise: [0.02, -0.01]),
                     session(plan[1], angle: ang, offset: off, floorY: 0, noise: [-0.015, 0.02]),
                     session(plan[2], angle: ang, offset: off, floorY: 0, noise: [0.01, 0.015])]
        guard case .success(let f3) = Alignment.fit(world: noisy, plan: plan) else { return XCTFail() }
        XCTAssertLessThan(f3.maxResidual, 0.03)
        XCTAssertEqual(PlanBuilder.normaliseAngle(f3.transform.angle - ang), 0, accuracy: 0.01)
        XCTAssertNil(Alignment.diagnose(world: noisy, plan: plan))
    }

    func testDegenerateAndWrongOrderCorners() {
        let p: PlanVec = [1, 1]
        let w = WorldVec(0, 0, 0)
        XCTAssertEqual(Alignment.fit(world: [w, w], plan: [p, [3, 3]]).failureValue, .tooClose)
        XCTAssertEqual(Alignment.fit(world: [w], plan: [p]).failureValue, .countMismatch)
        // Corners B and C tapped the wrong way round.
        let plan: [PlanVec] = [[0, 0], [4, 0], [4, 3]]
        let ang = -0.4, off = PlanVec(0.5, 2)
        let world = [session(plan[0], angle: ang, offset: off, floorY: 0), session(plan[2], angle: ang, offset: off, floorY: 0),
                     session(plan[1], angle: ang, offset: off, floorY: 0)]
        XCTAssertEqual(Alignment.diagnose(world: world, plan: plan), .swapped([0, 2, 1]))
        // A mirror image only fits mirrored.
        let mirrored = plan.map { session($0, angle: ang, offset: off, floorY: 0) }.map { WorldVec(-$0.x, $0.y, $0.z) }
        XCTAssertEqual(Alignment.diagnose(world: mirrored, plan: plan), .mirrored)
    }

    func testCornerChoice() {
        let l: [PlanVec] = [[0, 2.91], [5.36, 2.91], [5.36, 5.91], [4.36, 5.91], [4.36, 3.91], [0, 3.91]]
        let pair = Corners.defaultPair(l)!
        XCTAssertEqual(Set([pair.0, pair.1]), [0, 2])      // (0, 2.91) and (5.36, 5.91): farthest apart
        XCTAssertEqual(Corners.nearest(to: [5.2, 5.8], in: l), 2)
        XCTAssertNil(Corners.nearest(to: [2.5, 0], in: l))
        XCTAssertEqual(Corners.room(at: [1, 1], polygons: SimulatedScan.truePolygons), 0)
        XCTAssertEqual(Alignment.floorHeight([[0, -1.3, 0], [0, -1.1, 0]]) ?? .nan, -1.3, accuracy: 1e-9)
        XCTAssertEqual(Alignment.floorHeight([[0, -2.3, 0], [0, -1.1, 0], [0, -1.1, 0]]) ?? .nan, -1.8, accuracy: 1e-9)   // outlier clamped
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}

final class RevisitDocumentTests: XCTestCase {

    func demoDoc(visits: [[String: Any]]? = nil, current: String? = nil) -> [String: Any] {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        var doc = PlanDocument.newDocument(id: "J", address: "A", jobRef: "", createdAt: ISOTime.date("2026-11-12T02:00:00Z")!,
                                           now: Date(), geometry: g)
        if let visits {
            var m = doc["markup"] as! [String: Any]
            m["visits"] = visits
            if let current { m["currentVisit"] = current }
            doc["markup"] = m
        }
        return doc
    }

    let perth = TimeZone(identifier: "Australia/Perth")!

    func testVisitIsStartedOnALaterDayOnly() {
        let doc = demoDoc()
        let same = Revisit.startVisitIfNeeded(plan: doc, now: ISOTime.date("2026-11-12T08:00:00Z")!, timeZone: perth)
        XCTAssertFalse(same.started)
        XCTAssertEqual(same.visit, "v1")
        let later = Revisit.startVisitIfNeeded(plan: doc, now: ISOTime.date("2026-11-15T01:00:00Z")!, timeZone: perth)
        XCTAssertTrue(later.started)
        XCTAssertEqual(later.visit, "v2")
        let m = later.plan["markup"] as! [String: Any]
        let visits = m["visits"] as! [[String: Any]]
        XCTAssertEqual(visits.map { $0["id"] as? String }, ["v1", "v2"])
        XCTAssertEqual(visits[0]["date"] as? String, "2026-11-12")
        XCTAssertEqual(visits[1]["date"] as? String, "2026-11-15")
        XCTAssertEqual(visits[1]["type"] as? String, "monitoring")
        XCTAssertEqual(m["currentVisit"] as? String, "v2")
        // Same day again: no third visit.
        let again = Revisit.startVisitIfNeeded(plan: later.plan, now: ISOTime.date("2026-11-15T05:00:00Z")!, timeZone: perth)
        XCTAssertFalse(again.started)
        XCTAssertEqual(again.visit, "v2")
        XCTAssertEqual(Revisit.startVisitIfNeeded(plan: later.plan, now: ISOTime.date("2026-11-19T01:00:00Z")!, timeZone: perth).visit, "v3")
    }

    func testRemeasureWritesHistoryAndMirror() throws {
        let doc = demoDoc(visits: [["id": "v1", "n": 1, "date": "2026-11-12"], ["id": "v2", "n": 2, "date": "2026-11-15"]], current: "v2")
        let out = try XCTUnwrap(Revisit.recordMeasurement(plan: doc, readingId: "sim-01", visit: "v2", value: 18.5,
                                                          takenAt: "2026-11-15T01:10:00Z", photo: "data:image/jpeg;base64,AA", note: nil))
        let r = ((out["markup"] as! [String: Any])["readings"] as! [[String: Any]]).first { $0["id"] as? String == "sim-01" }!
        let h = r["history"] as! [[String: Any]]
        XCTAssertEqual(h.map { $0["visit"] as? String }, ["v1", "v2"])
        XCTAssertEqual(PlanDocument.number(h[0]["value"]), 24.5)
        XCTAssertEqual(PlanDocument.number(h[1]["value"]), 18.5)
        XCTAssertEqual(PlanDocument.number(r["value"]), 18.5)
        XCTAssertEqual(r["takenAt"] as? String, "2026-11-15T01:10:00Z")
        XCTAssertEqual(r["photo"] as? String, "data:image/jpeg;base64,AA")
        // Re-measuring again in the same visit replaces that visit's entry.
        let again = try XCTUnwrap(Revisit.recordMeasurement(plan: out, readingId: "sim-01", visit: "v2", value: 17,
                                                            takenAt: "2026-11-15T01:20:00Z", photo: nil, note: "retake"))
        let r2 = ((again["markup"] as! [String: Any])["readings"] as! [[String: Any]]).first { $0["id"] as? String == "sim-01" }!
        XCTAssertEqual((r2["history"] as! [[String: Any]]).count, 2)
        XCTAssertEqual(PlanDocument.number(r2["value"]), 17)
        XCTAssertNil(Revisit.recordMeasurement(plan: doc, readingId: "sim-03", visit: "v2", value: 1, takenAt: "", photo: nil, note: nil))   // a moisture-line mark
        // Markers: reading 1 is measured in v2, the others are not.
        let ms = Revisit.markers(plan: again, visit: "v2")
        XCTAssertEqual(ms.first { $0.id == "sim-01" }?.measured, true)
        XCTAssertEqual(ms.first { $0.id == "sim-02" }?.measured, false)
        XCTAssertEqual(ms.first { $0.id == "sim-01" }?.label, "1 · 17%")
        let p = Revisit.progress(ms)
        XCTAssertEqual(p.done, 1)
        XCTAssertEqual(p.total, 7)
        XCTAssertEqual(ms.filter { $0.kind == "equipment" }.count, 3)
        XCTAssertEqual(ms.filter { $0.kind == "removal" }.count, 3)          // two wall bands + the flooring section
        XCTAssertEqual(ms.filter { $0.kind == "removal" && $0.polygon != nil }.count, 1)   // flooring: drawn on the floor
        XCTAssertEqual(ms.filter { $0.kind == "boundary" }.count, 4)         // previous visit's moisture line
    }

    func testEquipmentRemovedAndRemovalDone() throws {
        let doc = demoDoc(visits: [["id": "v1", "n": 1, "date": "2026-11-12"], ["id": "v2", "n": 2, "date": "2026-11-15"]], current: "v2")
        let e = try XCTUnwrap(Revisit.markEquipmentRemoved(plan: doc, id: "sim-e1", visit: "v2", at: "2026-11-15T02:00:00Z"))
        let eq = ((e["markup"] as! [String: Any])["equipment"] as! [[String: Any]])[0]
        XCTAssertEqual(eq["removed"] as? String, "v2")
        XCTAssertEqual(eq["removedAt"] as? String, "2026-11-15T02:00:00Z")
        XCTAssertFalse(Revisit.markers(plan: e, visit: "v2").contains { $0.id == "sim-e1" })
        let d = try XCTUnwrap(Revisit.markRemovalDone(plan: doc, id: "sim-r1", visit: "v2", photo: "data:image/jpeg;base64,BB",
                                                      takenAt: "2026-11-15T02:05:00Z", cam: [2, 1]))
        let x = ((d["markup"] as! [String: Any])["removals"] as! [[String: Any]]).first { $0["id"] as? String == "sim-r1" }!
        XCTAssertEqual(x["status"] as? String, "done")
        XCTAssertEqual(x["doneVisit"] as? String, "v2")
        let photos = x["photos"] as! [[String: Any]]
        XCTAssertEqual(photos.map { $0["stage"] as? String }, ["after"])
        XCTAssertEqual(photos[0]["visit"] as? String, "v2")
        XCTAssertNotNil(photos[0]["cam"])
        // Logged with a start photo: that frame is the "before" photo.
        let logged = PlanRemoval(id: "x", item: "plasterboard", heightMm: 600, note: "", takenAt: "2026-11-12T03:00:00Z",
                                 photo: "data:image/jpeg;base64,CC", wallId: "w2", t0: 0.1, t1: 0.9, area: nil,
                                 floorType: nil, underlay: false, cam: [2, 1])
        let j = PlanDocument.removalJSON(logged, visit: "v1")
        let before = j["photos"] as! [[String: Any]]
        XCTAssertEqual(before.first?["stage"] as? String, "before")
        XCTAssertEqual(before.first?["visit"] as? String, "v1")
        XCTAssertEqual(j["heightMm"] as? Int, 600)
    }

    /// A whole return visit in a rotated, offset session: corners -> alignment
    /// -> aim at a saved reading -> re-measure; and a new reading logged.
    func testSimulatedReturnVisit() throws {
        let doc = demoDoc(visits: [["id": "v1", "n": 1, "date": "2026-11-12"], ["id": "v2", "n": 2, "date": "2026-11-15"]], current: "v2")
        // The new session sees the house rotated by 70 degrees, shifted, floor at -1.45.
        let truth = PlanTransform(angle: 70 * .pi / 180, offset: PlanVec(-3.2, 4.1))
        let floorY = -1.45
        let bedroom = Revisit.rooms(doc)[0]
        let (ia, ib) = try XCTUnwrap(Corners.defaultPair(bedroom))
        let hits = [truth.world(bedroom[ia], y: floorY + 0.02), truth.world(bedroom[ib], y: floorY)]
        guard case .success(let fit) = Alignment.fit(world: hits, plan: [bedroom[ia], bedroom[ib]]) else { return XCTFail() }
        XCTAssertTrue(fit.ok)
        // Aim at reading 1 from 1.2 m away.
        let ms = Revisit.markers(plan: doc, visit: "v2")
        let candidates = ms.map { Revisit.Candidate(id: $0.id, kind: $0.kind,
                                                    world: Revisit.world($0.pos, height: $0.height, alignment: fit.transform, floorY: fit.floorY),
                                                    radius: $0.kind == "reading" ? 0.15 : 0.3) }
        let r1 = try XCTUnwrap(ms.first { $0.id == "sim-01" })
        let target = Revisit.world(r1.pos, height: r1.height, alignment: fit.transform, floorY: fit.floorY)
        let cam = truth.world(PlanVec(2.3, 1.0), y: floorY + 1.4)
        let hit = Revisit.target(candidates, origin: cam, direction: target - cam + WorldVec(0, 0.05, 0))
        XCTAssertEqual(hit?.id, "sim-01")
        XCTAssertNil(Revisit.target(candidates, origin: cam, direction: WorldVec(0, 1, 0)))
        XCTAssertEqual(Revisit.turnHint(camera: cam, forward: target - cam, target: target), 0, accuracy: 1e-6)

        // Re-measure it.
        let out = try XCTUnwrap(Revisit.recordMeasurement(plan: doc, readingId: "sim-01", visit: "v2", value: 15,
                                                          takenAt: "2026-11-15T01:00:00Z", photo: nil, note: nil))
        XCTAssertEqual(Revisit.progress(Revisit.markers(plan: out, visit: "v2")).done, 1)

        // Log a new reading on wall w3 at (1.8, 2.8), 0.4 m up, through the alignment.
        let t = truth.world(PlanVec(1.8, 2.8), y: floorY + 0.4), c = truth.world(PlanVec(1.8, 1.8), y: floorY + 1.4)
        let pb = PBReading(id: "rv-1", seq: 1, kind: "reading", value: 21, material: "wall", takenAt: "2026-11-15T01:05:00Z",
                           cameraPosition: c, cameraForward: simd_normalize(t - c), hit: t)
        guard case .success(let item) = Revisit.itemJSON(for: pb, plan: out, alignment: fit.transform, floorY: fit.floorY, visit: "v2")
        else { return XCTFail() }
        XCTAssertEqual(item["wallId"] as? String, "w3")
        XCTAssertEqual(PlanDocument.number(item["height"]) ?? -1, 0.4, accuracy: 0.03)
        XCTAssertEqual(item["visit"] as? String, "v2")
        let added = Revisit.addItem(plan: out, item: item)
        let readings = (added["markup"] as! [String: Any])["readings"] as! [[String: Any]]
        XCTAssertEqual(readings.last?["id"] as? String, "rv-1")
        XCTAssertEqual(PlanDocument.number(readings.last?["n"]), 8)
        // A floor-type tag in the laundry, and equipment, go to their own lists.
        var ft = pb
        ft.id = "ft"; ft.kind = "floorType"; ft.material = "tile"; ft.floorType = "tile"
        ft.cameraPosition = truth.world(PlanVec(4.5, 1.5), y: floorY + 1.4)
        guard case .success(let zone) = Revisit.itemJSON(for: ft, plan: added, alignment: fit.transform, floorY: fit.floorY, visit: "v2")
        else { return XCTFail() }
        let withZone = Revisit.addItem(plan: added, item: zone)
        XCTAssertEqual(((withZone["markup"] as! [String: Any])["floors"] as? [[String: Any]])?.last?["type"] as? String, "tile")
    }

    func testTurnHintSign() {
        let cam = WorldVec(0, 0, 0), fwd = WorldVec(0, 0, -1)
        XCTAssertGreaterThan(Revisit.turnHint(camera: cam, forward: fwd, target: [1, 0, -1]), 0)    // to the right
        XCTAssertLessThan(Revisit.turnHint(camera: cam, forward: fwd, target: [-1, 0, -1]), 0)
        XCTAssertEqual(abs(Revisit.turnHint(camera: cam, forward: fwd, target: [0, 0, 1])), 180, accuracy: 1e-9)
    }
}
