//
//  MarkupTests.swift
//  SecureScanTests
//
//  AR mark-up maths: swept moisture lines (Douglas-Peucker, per-wall split),
//  traced wet floor areas, edits by id ("Move here", height nudge, delete),
//  and how the mark-up screen gets its coordinate frame.
//

import XCTest
import simd

final class SweepTests: XCTestCase {

    func testStraightNoisyLineCollapsesToItsEnds() {
        let pts = (0...40).map { i in PlanVec(Double(i) * 0.05, (i % 2 == 0 ? 0.004 : -0.004)) }
        XCTAssertEqual(Sweep.simplify(pts, tolerance: 0.03), [0, 40])
    }

    func testCornerIsKept() {
        // Up the wall then along it: the bend must survive.
        let up = (0...10).map { PlanVec(0, Double($0) * 0.1) }
        let along = (1...10).map { PlanVec(Double($0) * 0.1, 1.0) }
        let idx = Sweep.simplify(up + along, tolerance: 0.03)
        XCTAssertEqual(idx, [0, 10, 20])
    }

    func testAtMostTwelvePointsPerWall() {
        // A zigzag with 60 real bends.
        let pts = (0..<61).map { PlanVec(Double($0) * 0.05, $0 % 2 == 0 ? 0 : 0.3) }
        let idx = Sweep.simplify(pts, tolerance: 0.03, maxPoints: 12)
        XCTAssertLessThanOrEqual(idx.count, 12)
        XCTAssertEqual(idx.first, 0)
        XCTAssertEqual(idx.last, 60)
    }

    func sample(_ i: Int, _ wall: String?, _ t: Double, _ h: Double) -> Sweep.WallSample {
        Sweep.WallSample(index: i, wallId: wall, wallT: wall == nil ? nil : t, height: wall == nil ? nil : h, wallLength: 3)
    }

    func testSweepRoundACornerSplitsPerWall() {
        var s: [Sweep.WallSample] = []
        for i in 0..<20 { s.append(sample(i, "w1", 0.5 + Double(i) * 0.025, 1.0 - Double(i) * 0.01)) }
        s.append(sample(20, nil, 0, 0))                       // a sample that hit nothing
        for i in 21..<40 { s.append(sample(i, "w2", Double(i - 21) * 0.03, 0.8)) }
        let runs = Sweep.runs(s)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map { $0.first?.wallId }, ["w1", "w2"])
        let kept = Sweep.strokePoints(s)
        // Each wall's run is straight: its two ends only.
        XCTAssertEqual(kept.map(\.index), [0, 19, 21, 39])
        XCTAssertTrue(kept.allSatisfy { $0.wallId != nil })
    }

    func testSimplificationIsInMetresAlongTheWall() {
        // 2 cm wobble on a 3 m wall: under the 3 cm tolerance -> ends only.
        let s = (0..<30).map { sample($0, "w1", Double($0) / 29, 1.0 + ($0 % 2 == 0 ? 0.01 : -0.01)) }
        XCTAssertEqual(Sweep.strokePoints(s).count, 2)
        // A real 30 cm step in the middle is kept.
        let step = (0..<30).map { sample($0, "w1", Double($0) / 29, $0 < 15 ? 1.2 : 0.9) }
        XCTAssertGreaterThan(Sweep.strokePoints(step).count, 2)
    }

    func testSweptFloorSquareCloses() throws {
        // 1.5 m square traced with ~120 jittery points, back to near the start.
        var pts: [PlanVec] = []
        let c: [PlanVec] = [[0, 0], [1.5, 0], [1.5, 1.5], [0, 1.5]]
        for k in 0..<4 {
            let a = c[k], b = c[(k + 1) % 4]
            for i in 0..<30 { pts.append(a + (b - a) * (Double(i) / 30) + PlanVec(0.005, -0.005) * Double(i % 2)) }
        }
        pts.append(PlanVec(0.02, 0.01))
        let poly = try Sweep.floorPolygon(pts).get()
        XCTAssertGreaterThanOrEqual(poly.count, 4)
        XCTAssertLessThanOrEqual(poly.count, 24)
        XCTAssertEqual(FloorArea.area(poly), 2.25, accuracy: 0.1)
        XCTAssertGreaterThan(simd_distance(poly.first!, poly.last!), 0.05)    // closure is implied, not repeated
    }

    func testCrossingTraceIsRejected() {
        // A figure of eight.
        let pts: [PlanVec] = [[0, 0], [1, 1], [1, 0], [0, 1]]
        guard case .failure(let e) = Sweep.floorPolygon(pts) else { return XCTFail("should fail") }
        XCTAssertTrue(e.message.contains("cross"))
    }

    func testTinyTraceIsRejected() {
        let pts: [PlanVec] = [[0, 0], [0.2, 0], [0.2, 0.2], [0, 0.2]]
        guard case .failure(let e) = Sweep.floorPolygon(pts) else { return XCTFail("should fail") }
        XCTAssertTrue(e.message.contains("small"))
        XCTAssertNotNil(try? Sweep.floorPolygon([[0, 0], [0.5, 0], [0.5, 0.5], [0, 0.5]]).get())
    }

    func testConcaveOutlineIsFilledExactly() {
        // An L-shaped wet area, clockwise.
        let l: [PlanVec] = [[0, 0], [0, 2], [1, 2], [1, 1], [2, 1], [2, 0]]
        let t = Triangulate.ears(l)
        XCTAssertEqual(t.count, 12)
        var area = 0.0
        for k in stride(from: 0, to: t.count, by: 3) { area += abs(PlanBuilder.signedArea([l[t[k]], l[t[k + 1]], l[t[k + 2]]])) }
        XCTAssertEqual(area, 3, accuracy: 1e-9)
        XCTAssertTrue(Triangulate.ears([[0, 0], [1, 0]]).isEmpty)
    }

    func testTooFewPointsIsRejected() {
        guard case .failure = Sweep.floorPolygon([[0, 0], [1, 0]]) else { return XCTFail("should fail") }
    }

    func testAffectedAreaFromFloorHits() throws {
        // Camera at 1.4 m looking down at floor points (floor at y = 0).
        let cam = WorldVec(1, 1.4, 1)
        let floor: [PlanVec] = [[0, 0], [2, 0], [2, 1.5], [0, 1.5]]
        let poses = floor.map { p -> PBPose in
            let hit = WorldVec(p.x, 0, p.y)
            return PBPose(cameraPosition: cam, cameraForward: simd_normalize(hit - cam), hit: hit)
        }
        var r = PBReading(id: "ar-a1", seq: 1, kind: "affected", value: nil, material: "floor", takenAt: "2026-11-15T01:00:00Z",
                          cameraPosition: cam, cameraForward: WorldVec(0, -1, 0))
        r.corners = poses
        r.note = "Hallway"
        let a = try PlanBuilder.affectedArea(r, globalFloorY: 0, transform: PlanTransform(angle: 0, offset: .zero)).get()
        XCTAssertEqual(a.polygon.count, 4)
        XCTAssertEqual(FloorArea.area(a.polygon), 3, accuracy: 0.01)
        XCTAssertEqual(a.label, "Hallway")
        let d = PlanDocument.affectedJSON(a, visit: "v1")
        XCTAssertEqual(d["source"] as? String, "ar")
        XCTAssertEqual((d["polygon"] as? [[Double]])?.count, 4)
        // It goes to markup.affected, not floors.
        let plan = Revisit.addItem(plan: ["markup": [String: Any]()], item: d)
        XCTAssertEqual(((plan["markup"] as? [String: Any])?["affected"] as? [[String: Any]])?.count, 1)
        XCTAssertNil((plan["markup"] as? [String: Any])?["floors"])
        // Merging: an AR area is rewritten by id, a drawn one is kept, a new one added.
        var moved = a
        moved.polygon = a.polygon.map { $0 + PlanVec(0.1, 0) }
        let drawn: [String: Any] = ["id": "a-drawn", "polygon": [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]], "label": ""]
        let old: [[String: Any]] = [d, drawn]
        let fresh = [moved, PlanAffected(id: "ar-a2", polygon: [[0, 0], [1, 0], [1, 1]], label: "", takenAt: "")]
        let merged = PlanDocument.mergeAffected(old: old, fresh: fresh, visit: "v1")
        XCTAssertEqual(merged.map { $0["id"] as? String }, ["ar-a1", "a-drawn", "ar-a2"])
        XCTAssertEqual(((merged[0]["polygon"] as? [[Double]])?.first?.first) ?? -1, 0.1, accuracy: 1e-9)
    }
}

final class MarkupEditTests: XCTestCase {

    func doc() -> [String: Any] {
        let walls: [[String: Any]] = [["id": "w1", "a": [0.0, 0.0], "b": [4.0, 0.0], "height": 2.4]]
        let readings: [[String: Any]] = [["id": "m1", "kind": "reading", "n": 1, "value": 22.0, "pos": [1.0, 0.0], "wallId": "w1",
                                          "wallT": 0.25, "height": 0.3, "source": "ar"]]
        let equipment: [[String: Any]] = [["id": "e1", "type": "airMover", "pos": [2.0, 1.0], "source": "ar"]]
        let affected: [[String: Any]] = [["id": "a1", "polygon": [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]]]
        let markup: [String: Any] = ["readings": readings, "equipment": equipment, "affected": affected]
        return ["walls": walls, "markup": markup]
    }

    func list(_ d: [String: Any], _ k: String) -> [[String: Any]] { (d["markup"] as? [String: Any])?[k] as? [[String: Any]] ?? [] }

    func testUpdateAndDeleteFindTheRightList() throws {
        let d = try XCTUnwrap(MarkupEdit.update(doc(), id: "m1", set: ["value": 31.5, "material": "skirting"]))
        XCTAssertEqual(PlanDocument.number(list(d, "readings")[0]["value"]), 31.5)
        XCTAssertEqual(list(d, "readings")[0]["material"] as? String, "skirting")
        XCTAssertNil(MarkupEdit.update(doc(), id: "nope", set: [:]))
        let gone = try XCTUnwrap(MarkupEdit.delete(doc(), id: "a1"))
        XCTAssertTrue(list(gone, "affected").isEmpty)
        XCTAssertEqual(list(gone, "readings").count, 1)
    }

    func testMoveHere() throws {
        let to = PlanReading(id: "x", kind: "reading", n: nil, pos: PlanVec(3, 0), value: nil, material: "wall", note: "",
                             photo: nil, takenAt: "", height: 0.62, wallId: "w1", wallT: 0.75, reference: false,
                             worldPoint: nil, cam: PlanVec(3, 1.2))
        let d = try XCTUnwrap(MarkupEdit.move(doc(), id: "m1", to: to))
        let r = list(d, "readings")[0]
        XCTAssertEqual(r["pos"] as? [Double], [3, 0])
        XCTAssertEqual(PlanDocument.number(r["wallT"]), 0.75)
        XCTAssertEqual(PlanDocument.number(r["height"]), 0.62)
        XCTAssertEqual(PlanDocument.number(r["value"]), 22)        // the value is untouched
        // Equipment keeps to the floor: no wall fields.
        let e = try XCTUnwrap(MarkupEdit.move(doc(), id: "e1", to: to))
        XCTAssertEqual(list(e, "equipment")[0]["pos"] as? [Double], [3, 0])
        XCTAssertNil(list(e, "equipment")[0]["wallId"])
    }

    func testHeightNudgeStopsAtTheFloor() throws {
        let up = try XCTUnwrap(MarkupEdit.nudgeHeight(doc(), id: "m1", by: 0.05))
        XCTAssertEqual(PlanDocument.number(list(up, "readings")[0]["height"]) ?? .nan, 0.35, accuracy: 1e-9)
        let down = try XCTUnwrap(MarkupEdit.nudgeHeight(doc(), id: "m1", by: -1))
        XCTAssertEqual(PlanDocument.number(list(down, "readings")[0]["height"]), 0)
        XCTAssertNil(MarkupEdit.nudgeHeight(doc(), id: "e1", by: 0.05))   // no height on equipment
    }

    func testStartStrategy() {
        XCTAssertEqual(MarkupStart.strategy(sharedSessionRunning: true, hasPlanFrame: true, hasWorldMap: true), .sharedSession)
        XCTAssertEqual(MarkupStart.strategy(sharedSessionRunning: true, hasPlanFrame: true, hasWorldMap: false), .sharedSession)
        XCTAssertEqual(MarkupStart.strategy(sharedSessionRunning: false, hasPlanFrame: true, hasWorldMap: true), .worldMap)
        XCTAssertEqual(MarkupStart.strategy(sharedSessionRunning: false, hasPlanFrame: true, hasWorldMap: false), .corners)
        XCTAssertEqual(MarkupStart.strategy(sharedSessionRunning: true, hasPlanFrame: false, hasWorldMap: true), .corners)
    }

    func testScanWorldConversionIsIdentityWhenShared() {
        let f = PlanTransform(angle: 0.7, offset: PlanVec(2, -1))
        let w = WorldVec(1.2, -0.4, 3.3)
        let same = MarkupFrame.toScanWorld(w, session: f, sessionFloorY: -1.4, scan: f, scanFloorY: -1.4)
        XCTAssertEqual(simd_distance(same, w), 0, accuracy: 1e-9)
        // A different session frame: the plan point and the height above the floor are kept.
        let other = PlanTransform(angle: -0.3, offset: PlanVec(0.5, 4))
        let s = MarkupFrame.toScanWorld(w, session: other, sessionFloorY: -1.0, scan: f, scanFloorY: -1.4)
        XCTAssertEqual(simd_distance(f.point(s), other.point(w)), 0, accuracy: 1e-9)
        XCTAssertEqual(s.y - (-1.4), w.y - (-1.0), accuracy: 1e-9)
    }
}
