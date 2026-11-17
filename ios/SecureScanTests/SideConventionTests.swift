//
//  SideConventionTests.swift
//  One wall-side convention end to end: a mark captured on side "a" in AR
//  (world x, z; WallSide in Components.swift) is on side "a" in plan.json
//  (plan x, y; PlanBuilder) and on the moisture engine's side "a" face
//  (MoistWall.normal, docs/MOISTURE.md).
//

import XCTest
import simd

final class SideConventionTests: XCTestCase {

    /// A plan transform with a rotation and an offset, as PlanBuilder makes them.
    let transform = PlanTransform(angle: 0.7, offset: PlanVec(3, -1))

    func testCaptureSideAMatchesThePlanAndTheMoistureEngine() {
        // A wall in the AR session and a camera standing on one side of it.
        let wa = WorldVec(1, 0, 2), wb = WorldVec(4, 0, 2.5)
        let world = WorldWall(id: "w1", a: PlanVec(wa.x, wa.z), b: PlanVec(wb.x, wb.z), height: 2.4)
        for cam in [WorldVec(2.5, 1.4, 4.0), WorldVec(2.5, 1.4, 0.5)] {
            let captured = WallSide.side(of: PlanVec(cam.x, cam.z), wall: world)
            // plan.json: the same wall, a -> b kept, in plan coordinates (x, y down the page).
            let pa = transform.point(wa), pb = transform.point(wb), pc = transform.point(cam)
            let plan = PlanWall(id: "w1", a: pa, b: pb, height: 2.4, roomIndex: 0)
            XCTAssertEqual(PlanBuilder.side(of: pc, wall: plan), captured)
            // The moisture engine: side "a" is +n, n = (-d.y, d.x).
            let moist = MoistWall(id: "w1", a: pa, b: pb, height: 2.4)
            let engineSide: MoistSide = moist.offset(pc) >= 0 ? .a : .b
            XCTAssertEqual(engineSide.rawValue, captured)
            XCTAssertEqual(MoistSide.parse(captured), engineSide)
        }
        // The room side of w1 (camera at larger z) is "a" in both.
        XCTAssertEqual(WallSide.side(of: PlanVec(2.5, 4.0), wall: world), "a")
    }

    func testPlanBuilderKeepsTheSideWhenThePlanWallRunsTheOtherWay() {
        // The live wall ran a -> b; the plan's wall runs b -> a. The stored "a" becomes "b".
        let cam = WorldVec(2.5, 1.4, 4.0)
        let reversed = PlanWall(id: "w1", a: PlanVec(4, 2.5), b: PlanVec(1, 2), height: 2.4, roomIndex: 0)
        XCTAssertEqual(PlanBuilder.side(of: PlanVec(cam.x, cam.z), wall: reversed), "b")
        let r = PBReading(id: "r1", seq: 1, kind: "reading", value: 30, material: "wall", takenAt: "",
                          cameraPosition: cam, cameraForward: simd_normalize(WorldVec(0, -0.3, -1)), hit: WorldVec(2.5, 0.6, 2.25))
        var pb = r
        pb.side = "a"
        let one = PlanTransform(angle: 0, offset: PlanVec(0, 0))
        let out = PlanBuilder.resolve(pb, walls: [reversed], wallFloorY: [0], globalFloorY: 0, transform: one)
        XCTAssertEqual(out.wallId, "w1")
        XCTAssertEqual(out.side, "b")
    }
}
