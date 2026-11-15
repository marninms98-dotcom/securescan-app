//
//  ScopeTests.swift
//  SecureScanTests
//
//  Prices on / off, the scope of works the crew sees (tags, descriptions,
//  done counts), the air mover's airflow from the phone's heading, and
//  readings pinned to things that are not walls.
//

import XCTest
import simd

final class ScopeTests: XCTestCase {

    func testDocumentsWithPricesHidden() {
        XCTAssertEqual(DocumentKind.offered(visitCount: 1, lastVisitType: nil, pricesVisible: false), [.initial, .scope])
        XCTAssertEqual(DocumentKind.offered(visitCount: 2, lastVisitType: "final", pricesVisible: false), [.initial, .scope, .final])
        XCTAssertEqual(DocumentKind.offered(visitCount: 1, lastVisitType: nil, pricesVisible: true), [.initial, .quote])
        // Never the quote with prices hidden.
        XCTAssertFalse(DocumentKind.available(.quote, editorKinds: ["quote"], editorHidesPrices: true, pricesVisible: false))
        // An editor that can't hide prices makes nothing on a no-prices phone.
        XCTAssertFalse(DocumentKind.available(.initial, editorKinds: [], editorHidesPrices: false, pricesVisible: false))
        XCTAssertFalse(DocumentKind.available(.scope, editorKinds: nil, editorHidesPrices: false, pricesVisible: false))
        // Not loaded yet: offered, checked again when tapped.
        XCTAssertTrue(DocumentKind.available(.scope, editorKinds: nil, editorHidesPrices: nil, pricesVisible: false))
        XCTAssertTrue(DocumentKind.available(.scope, editorKinds: ["initial", "scope"], editorHidesPrices: true, pricesVisible: false))
        // Old editor (no kinds): only its one report, and only with prices shown.
        XCTAssertTrue(DocumentKind.available(.initial, editorKinds: [], editorHidesPrices: false, pricesVisible: true))
        XCTAssertFalse(DocumentKind.available(.quote, editorKinds: [], editorHidesPrices: false, pricesVisible: true))
        XCTAssertFalse(DocumentKind.available(.scope, editorKinds: [], editorHidesPrices: true, pricesVisible: false))
        XCTAssertEqual(DocumentKind.scope.fileName(address: "1 Demo St"), "1 Demo St-scope-of-works.pdf")
        XCTAssertEqual(WorkMode.quote.label(pricesVisible: false), "Scope")
        XCTAssertEqual(WorkMode.quote.label(pricesVisible: true), "Quote")
        XCTAssertEqual(WorkMode.inspect.label(pricesVisible: false), "Inspect")
    }

    func testOfficePINRule() {
        XCTAssertTrue(PinRule.valid("1234"))
        XCTAssertTrue(PinRule.valid("12345678"))
        XCTAssertFalse(PinRule.valid("123"))
        XCTAssertFalse(PinRule.valid("123456789"))
        XCTAssertFalse(PinRule.valid("12a4"))
        XCTAssertFalse(PinRule.valid("１２３４"))     // full-width digits
    }

    func plan() -> [String: Any] {
        let walls: [[String: Any]] = [["id": "w1", "a": [0.0, 0.0], "b": [4.0, 0.0], "height": 2.4],
                                      ["id": "w2", "a": [4.0, 0.0], "b": [4.0, 3.0], "height": 2.4]]
        let removals: [[String: Any]] = [
            ["id": "x1", "item": "plasterboard", "wallId": "w1", "t0": 0.6, "t1": 0.05, "heightMm": 1200, "status": "proposed"],
            ["id": "x2", "item": "flooring", "area": [[0.0, 0.0], [2.0, 0.0], [2.0, 1.6], [0.0, 1.6]], "floorType": "carpet",
             "underlay": true, "status": "done"],
            ["id": "x3", "item": "skirting", "wallId": "w-gone", "t0": 0.0, "t1": 1.0, "heightMm": 100],   // wall no longer in the plan
            ["id": "x4", "item": "skirting", "wallId": "w2", "t0": 0.0, "t1": 0.6, "heightMm": 100],
        ]
        let equipment: [[String: Any]] = [
            ["id": "e1", "type": "airMover", "label": "AM-03", "pos": [1.0, 1.0], "status": "planned", "dir": 1.5708],
            ["id": "e2", "type": "dehumidifier", "label": "", "pos": [2.0, 2.0]],
            ["id": "e3", "type": "airMover", "label": "AM-04", "pos": [3.0, 1.0], "removed": "v2"],
        ]
        let markup: [String: Any] = ["removals": removals, "equipment": equipment]
        return ["walls": walls, "markup": markup]
    }

    func testTagsFollowTheEditorsRule() {
        let refs = ScopeList.refs(plan: plan())
        XCTAssertEqual(refs["x1"], "X1")
        XCTAssertEqual(refs["x2"], "F1")
        XCTAssertNil(refs["x3"])                    // its wall isn't in the plan: no tag, as in the editor
        XCTAssertEqual(refs["x4"], "X2")
    }

    /// The editor's removalRefs exactly: X only on a wall the editor keeps
    /// (both ends finite points, more than 1 cm apart), F only with no wallId
    /// at all ("" counts as none) and 3+ finite points, every removal counted
    /// in document order even without an id.
    func testTagsEdgeCasesMatchTheEditor() {
        let walls: [[String: Any]] = [["id": "w1", "a": [0.0, 0.0], "b": [4.0, 0.0], "height": 2.4],
                                      ["id": "w0", "a": [1.0, 1.0], "b": [1.005, 1.0], "height": 2.4],      // 5 mm: degenerate
                                      ["id": "w3", "a": [0.0, 3.0, 0.0], "b": [4.0, 3.0, 0.0], "height": 2.4]]  // 3 numbers: still points
        let area: [Any] = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]
        let notAllPoints: [Any] = [[0.0, 0.0], [1.0, true] as [Any], [1.0, 1.0]]
        let removals: [[String: Any]] = [
            ["item": "plasterboard", "wallId": "w1", "t0": 0.0, "t1": 0.5],               // no id: X1 used up
            ["id": "a", "item": "plasterboard", "wallId": "w1", "t0": 0.5, "t1": 1.0],   // X2
            ["id": "b", "item": "flooring", "wallId": "w0", "area": area],                // degenerate wall: no tag
            ["id": "c", "item": "flooring", "wallId": "gone", "area": area],              // missing wall: no tag
            ["id": "d", "item": "flooring", "wallId": "", "area": area],                  // "" is no wallId: F1
            ["id": "e", "item": "flooring", "wallId": NSNull(), "area": notAllPoints],  // not all points
            ["id": "f", "item": "flooring", "area": [[0.0, 0.0], [1.0, 0.0]] as [Any]],    // 2 points
            ["id": "g", "item": "skirting", "wallId": "w3", "t0": 0.0, "t1": 1.0],        // X3
            ["id": "h", "item": "flooring", "area": area],                                // F2
        ]
        let markup: [String: Any] = ["removals": removals]
        let refs = ScopeList.refs(plan: ["walls": walls, "markup": markup])
        XCTAssertEqual(refs, ["a": "X2", "d": "F1", "g": "X3", "h": "F2"])
    }

    /// markup.equipment[].dir: radians in plan coordinates (x right, y down the
    /// plan), 0 = +x, pi/2 = +y; the editor draws the airflow from pos towards
    /// pos + (cos dir, sin dir). Pointing the phone from the air mover at a spot
    /// must give a dir whose arrow points at that spot on the plan.
    func testAirflowDirMatchesTheEditorsConvention() throws {
        let t = PlanTransform(angle: 2.1, offset: PlanVec(-1.5, 4))
        let fan = WorldVec(0.4, 0, -1.2), target = WorldVec(2.9, 0, 0.7)
        let dir = try XCTUnwrap(Airflow.planAngle(forward: target - fan, transform: t))
        let p0 = t.point(fan), p1 = t.point(target)
        let arrow = PlanVec(cos(dir), sin(dir))
        XCTAssertEqual(simd_distance(arrow, simd_normalize(p1 - p0)), 0, accuracy: 1e-9)
        // Plan +y (down the plan) is dir = pi/2.
        let down = t.world(t.offset + PlanVec(0, 1), y: 0)
        XCTAssertEqual(try XCTUnwrap(Airflow.planAngle(forward: down, transform: t)), Double.pi / 2, accuracy: 1e-9)
    }

    func testScopeItemsAndProgress() throws {
        let items = ScopeList.items(plan: plan())
        XCTAssertEqual(items.map(\.tag), ["X1", "F1", "X2", "AM-03", "DH-1"])
        XCTAssertEqual(items[0].title, "X1 · remove plasterboard, wall w1, 2.20 × 1.20 m")
        XCTAssertEqual(items[0].t0 ?? -1, 0.05, accuracy: 1e-9)
        XCTAssertEqual(items[1].title, "F1 · lift carpet + underlay, 3.20 m²")
        XCTAssertEqual(items[2].title, "X2 · remove skirting, wall w2, 1.80 m")
        XCTAssertEqual(items[3].actionTitle, "Mark placed: AM-03")
        XCTAssertEqual(items[3].dir ?? 0, 1.5708, accuracy: 1e-9)
        XCTAssertTrue(items[4].done)                // placed before scoping existed: counts as placed
        XCTAssertEqual(items[0].actionTitle, "Mark done + after photo")
        let p = ScopeList.progress(items)
        XCTAssertEqual(p.done, 2)
        XCTAssertEqual(p.total, 5)
        let placed = try XCTUnwrap(ScopeList.markPlaced(plan: plan(), id: "e1", visit: "v2", at: "2026-11-16T01:00:00Z"))
        XCTAssertEqual(ScopeList.progress(ScopeList.items(plan: placed)).done, 3)
        let e1 = ((placed["markup"] as? [String: Any])?["equipment"] as? [[String: Any]])?.first
        XCTAssertEqual(e1?["status"] as? String, "placed")
        XCTAssertEqual(e1?["placed"] as? String, "v2")
        XCTAssertNil(ScopeList.markPlaced(plan: plan(), id: "nope", visit: "v2", at: ""))
    }

    func testAirflowFromThePhonesHeading() throws {
        let t = PlanTransform(angle: 0.5, offset: PlanVec(3, -2))
        // Level phone pointing along world +x: plan angle = the frame's rotation.
        XCTAssertEqual(try XCTUnwrap(Airflow.planAngle(forward: WorldVec(1, 0, 0), transform: t)), 0.5, accuracy: 1e-9)
        // Tilted down 45°: same heading.
        XCTAssertEqual(try XCTUnwrap(Airflow.planAngle(forward: simd_normalize(WorldVec(1, -1, 0)), transform: t)), 0.5, accuracy: 1e-9)
        // Straight down: no heading.
        XCTAssertNil(Airflow.planAngle(forward: WorldVec(0.05, -1, 0), transform: t))
        // Round trip back to the world.
        let f = simd_normalize(WorldVec(0.3, 0, -0.8))
        let a = try XCTUnwrap(Airflow.planAngle(forward: f, transform: t))
        let w = Airflow.worldDirection(a, transform: t)
        XCTAssertEqual(simd_distance(w, f), 0, accuracy: 1e-9)
    }

    func testReadingsOffTheWallStayWhereTheyWerePinned() {
        let walls = [PlanWall(id: "w1", a: PlanVec(0, 0), b: PlanVec(4, 0), height: 2.4, roomIndex: 0)]
        let t = PlanTransform(angle: 0, offset: .zero)
        // A vanity front 20 cm off the wall, 0.85 m up (floor at y = 0).
        let cam = WorldVec(2, 1.4, 1.5)
        let hit = WorldVec(2, 0.85, 0.2)
        func reading(_ material: String) -> PBReading {
            PBReading(id: "r", seq: 1, kind: "reading", value: 30, material: material, takenAt: "",
                      cameraPosition: cam, cameraForward: simd_normalize(hit - cam), hit: hit)
        }
        let cab = PlanBuilder.resolve(reading("cabinetry"), walls: walls, wallFloorY: [0], globalFloorY: 0, transform: t)
        XCTAssertNil(cab.wallId)
        XCTAssertEqual(simd_distance(cab.pos, PlanVec(2, 0.2)), 0, accuracy: 1e-9)
        XCTAssertEqual(cab.height ?? -1, 0.85, accuracy: 1e-9)
        // The same spot as a wall reading snaps onto the wall.
        let wall = PlanBuilder.resolve(reading("wall"), walls: walls, wallFloorY: [0], globalFloorY: 0, transform: t)
        XCTAssertEqual(wall.wallId, "w1")
        // A ceiling reading keeps its height (not clamped to the wall top).
        let ceilHit = WorldVec(2, 2.4, 0.15)
        let ceil = PlanBuilder.resolve(PBReading(id: "c", seq: 2, kind: "reading", value: 18, material: "ceiling", takenAt: "",
                                                 cameraPosition: cam, cameraForward: simd_normalize(ceilHit - cam), hit: ceilHit),
                                       walls: walls, wallFloorY: [0], globalFloorY: 0, transform: t)
        XCTAssertNil(ceil.wallId)
        XCTAssertEqual(ceil.height ?? -1, 2.4, accuracy: 1e-9)
        // Stored like any reading: pos and height, wallId null.
        let d = PlanDocument.readingJSON(cab)
        XCTAssertTrue(d["wallId"] is NSNull)
        XCTAssertEqual(PlanDocument.number(d["height"]) ?? -1, 0.85, accuracy: 1e-9)
    }
}
