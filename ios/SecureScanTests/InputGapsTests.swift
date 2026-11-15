//
//  InputGapsTests.swift
//  SecureScanTests
//
//  Round 8: wall-end snapping and "Whole wall", the height picked from the
//  end tap, items kept after the app closed mid-scan, and the editor's
//  wall names / removal tags in the AR descriptions.
//

import XCTest
import simd

final class InputGapsTests: XCTestCase {

    func testTapsNearAWallEndLandOnIt() {
        let a = WorldVec(0, 0, 0), b = WorldVec(4, 0, 0)
        let near = WallEndSnap.snapPoint(WorldVec(3.9, 1.1, 0.02), wallA: a, wallB: b)
        XCTAssertEqual(simd_distance(near, WorldVec(4, 1.1, 0)), 0, accuracy: 1e-9)      // height kept
        let start = WallEndSnap.snapPoint(WorldVec(0.1, 0.5, 0), wallA: a, wallB: b)
        XCTAssertEqual(simd_distance(start, WorldVec(0, 0.5, 0)), 0, accuracy: 1e-9)
        let mid = WorldVec(2, 0.5, 0.01)
        XCTAssertEqual(WallEndSnap.snapPoint(mid, wallA: a, wallB: b), mid)               // untouched
        XCTAssertEqual(WallEndSnap.snapPoint(WorldVec(0.3, 0.5, 0), wallA: a, wallB: b), WorldVec(0.3, 0.5, 0))
    }

    func testWholeWallEnds() {
        let (p, q) = WallEndSnap.wholeWall(a: WorldVec(0, 2, 0), b: WorldVec(0, 2, 3), y: 0.9)
        XCTAssertEqual(simd_distance(p, WorldVec(0, 0.9, 0.03)), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(q, WorldVec(0, 0.9, 2.97)), 0, accuracy: 1e-9)
    }

    func testHeightFromTheEndTap() {
        XCTAssertEqual(HeightSnap.suggested(endHeightMetres: 0.58), 600)
        XCTAssertEqual(HeightSnap.suggested(endHeightMetres: 1.23), 1200)
        XCTAssertEqual(HeightSnap.suggested(endHeightMetres: 0.95), 950)
        XCTAssertNil(HeightSnap.suggested(endHeightMetres: 0.1))       // aimed low: the item's default
        XCTAssertNil(HeightSnap.suggested(endHeightMetres: nil))
    }

    func testItemsKeptAfterAnUnfinishedScan() {
        let readings: [[String: Any]] = [["id": "ar-1"], ["id": "ar-2", "kind": "boundary"]]
        let markup: [String: Any] = ["readings": readings, "equipment": [["id": "ar-3"]], "affected": [["id": "ar-9"]]]
        let ids = Recovery.planIds(["markup": markup])
        XCTAssertEqual(ids, ["ar-1", "ar-2", "ar-3", "ar-9"])
        XCTAssertEqual(Recovery.unplaced(rawIds: ["ar-1", "ar-4", "ar-5", "ar-3"], planIds: ids), ["ar-4", "ar-5"])
        XCTAssertEqual(Recovery.unplaced(rawIds: ["ar-1"], planIds: []), ["ar-1"])        // no plan yet: all of them
        XCTAssertEqual(Recovery.banner(unplaced: 12), "12 items from an unfinished room were kept")
        XCTAssertEqual(Recovery.banner(unplaced: 1), "1 item from an unfinished room was kept")
    }

    func testEditorNamesInDescriptions() {
        let n = EditorNames.parse(wallNames: ["w1": "Wall B", "w2": 7] as [String: Any],
                                  removalRefs: [["id": "x1", "tag": "X7"], ["id": "x9"]] as [[String: Any]])
        XCTAssertEqual(n.wallNames, ["w1": "Wall B"])
        XCTAssertEqual(n.removalRefs, ["x1": "X7"])
        XCTAssertEqual(EditorNames.wallLabel("w1", n), "wall B")
        XCTAssertEqual(EditorNames.wallLabel("w3", n), "wall w3")
        XCTAssertEqual(EditorNames.wallLabel("w1", nil), "wall w1")
        XCTAssertEqual(EditorNames.parse(wallNames: nil, removalRefs: nil), EditorNames())

        let walls: [[String: Any]] = [["id": "w1", "a": [0.0, 0.0], "b": [4.0, 0.0], "height": 2.4]]
        let removals: [[String: Any]] = [["id": "x1", "item": "plasterboard", "wallId": "w1", "t0": 0.0, "t1": 0.5, "heightMm": 600],
                                         ["id": "x2", "item": "skirting", "wallId": "w1", "t0": 0.5, "t1": 1.0, "heightMm": 100]]
        let plan: [String: Any] = ["walls": walls, "markup": ["removals": removals] as [String: Any]]
        let items = ScopeList.items(plan: plan, names: n)
        // The editor's tag where it has one, the Swift port for anything newer.
        XCTAssertEqual(items.map(\.tag), ["X7", "X2"])
        XCTAssertEqual(items[0].title, "X7 · remove plasterboard, wall B, 2.00 × 0.60 m")
        XCTAssertEqual(ScopeList.items(plan: plan).first?.title, "X1 · remove plasterboard, wall w1, 2.00 × 0.60 m")
    }
}
