//
//  ComponentTests.swift
//  Marking by component (docs/MARKING.md): the component index, constrained
//  scrubbing, snapping, the run round a corner, floor painting, the tide line,
//  the cut height and the suggestion rules.
//

import XCTest
import simd

final class ComponentTests: XCTestCase {

    /// A 4 x 3 m room: w1 along z = 0 (x 0..4), w2 along x = 4, w3 along z = 3, w4 along x = 0
    /// (with a door 1.0..1.8 m from its start), corners shared.
    let world: CaptureWorld = {
        let walls = [
            WorldWall(id: "w1", a: PlanVec(0, 0), b: PlanVec(4, 0), height: 2.4),
            WorldWall(id: "w2", a: PlanVec(4, 0), b: PlanVec(4, 3), height: 2.4),
            WorldWall(id: "w3", a: PlanVec(4, 3), b: PlanVec(0, 3), height: 2.4),
            WorldWall(id: "w4", a: PlanVec(0, 3), b: PlanVec(0, 0), height: 2.4),
        ]
        let room = WorldRoom(name: "Kitchen", polygon: [PlanVec(0, 0), PlanVec(4, 0), PlanVec(4, 3), PlanVec(0, 3)])
        let door = WorldOpening(id: "d1", kind: "door", wallId: "w4", t0: 1.0 / 3, t1: 1.8 / 3, bottom: 0, top: 2.04)
        let window = WorldOpening(id: "win", kind: "window", wallId: "w1", t0: 0.25, t1: 0.5, bottom: 0.9, top: 2.0)
        let sink = WorldObject(id: "s1", category: "sink", center: WorldVec(2.0, 0.45, 0.3), size: WorldVec(0.8, 0.9, 0.6), yaw: 0)
        let sofa = WorldObject(id: "f1", category: "sofa", center: WorldVec(2.0, 0.4, 2.5), size: WorldVec(2.0, 0.8, 0.9), yaw: 0)
        return CaptureWorld(floorY: 0, walls: walls, rooms: [room], openings: [door, window], objects: [sink, sofa])
    }()

    func testSegmentsSplitAtDoorsNotWindows() {
        let w4 = world.walls[3], w1 = world.walls[0]
        let s4 = ComponentIndex.segments(w4, openings: world.openings)
        XCTAssertEqual(s4.count, 2)
        XCTAssertEqual(s4[0].1, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(s4[1].0, 1.8 / 3, accuracy: 1e-9)
        XCTAssertEqual(ComponentIndex.segments(w1, openings: world.openings).count, 1)       // a window doesn't cut skirting
        XCTAssertEqual(ComponentIndex.segments(w1, openings: world.openings, floorOnly: false).count, 2)
        XCTAssertNil(ComponentIndex.segment(containing: 0.45, s4))                            // in the doorway
    }

    func testCabinetryAndWaterCandidates() {
        XCTAssertTrue(world.objects[0].isCabinetry)
        XCTAssertFalse(world.objects[1].isRemovable)
        let cands = ComponentIndex.waterCandidates(world)
        XCTAssertEqual(Set(cands.compactMap(\.objectId)), ["s1"])
        XCTAssertTrue(cands.contains { $0.wallId == "w1" })                                 // the window sill
    }

    func testHoverPicksTheAimedComponent() {
        var aim = Aim(hit: WorldVec(1.0, 0.05, 0), surface: .wall, height: 0.05)
        aim.wall = world.walls[0]
        let c = ComponentIndex.hover(.skirting, aim: aim, origin: WorldVec(1, 1.4, 2), dir: simd_normalize(WorldVec(0, -1.35, -2)), world: world)
        XCTAssertEqual(c?.wallId, "w1")
        XCTAssertEqual(c?.t0, 0)
        XCTAssertEqual(c?.t1, 1)
        // The floor near a wall counts as its skirting.
        let floorAim = Aim(hit: WorldVec(2.0, 0, 2.8), surface: .floor, height: 0)
        XCTAssertEqual(ComponentIndex.hover(.skirting, aim: floorAim, origin: nil, dir: nil, world: world)?.wallId, "w3")
        // A ray into the sink cabinet hits its box; the sofa is not cabinetry.
        let cab = ComponentIndex.hover(.cabinet, aim: Aim(), origin: WorldVec(2, 1.5, 2), dir: simd_normalize(WorldVec(0, -1.0, -1.7)), world: world)
        XCTAssertEqual(cab?.objectId, "s1")
        let floor = ComponentIndex.hover(.floor, aim: floorAim, origin: nil, dir: nil, world: world)
        XCTAssertEqual(floor?.roomName, "Kitchen")
    }

    func testRayBox() {
        let ob = world.objects[0]
        XCTAssertNotNil(ComponentIndex.rayBox(origin: WorldVec(2, 0.45, 2), dir: WorldVec(0, 0, -1), ob))
        XCTAssertNil(ComponentIndex.rayBox(origin: WorldVec(3, 0.45, 2), dir: WorldVec(0, 0, -1), ob))
        XCTAssertNil(ComponentIndex.rayBox(origin: WorldVec(2, 0.45, 2), dir: WorldVec(0, 0, 1), ob))   // behind
    }

    func testWallHitProjectsTheRay() {
        let w1 = world.walls[0]
        let h = Scrub.wallHit(origin: WorldVec(1, 1.4, 2), dir: simd_normalize(WorldVec(0, -0.4, -2)), wall: w1, floorY: 0)
        XCTAssertEqual(h?.t ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(h?.h ?? -1, 1.0, accuracy: 1e-6)
        // A ray that reaches the floor first: projected from the floor onto the wall, at the base.
        let f = Scrub.wallHit(origin: WorldVec(1, 1.4, 2), dir: simd_normalize(WorldVec(0, -1.4, -1)), wall: w1, floorY: 0)
        XCTAssertEqual(f?.t ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(f?.h ?? -1, 0, accuracy: 1e-9)
    }

    func testSnapToSegmentEnds() {
        XCTAssertEqual(Scrub.snap(0.03, segment: (0, 1), length: 4), 0)        // 0.12 m from the end
        XCTAssertEqual(Scrub.snap(0.05, segment: (0, 1), length: 4), 0.05)     // 0.20 m: no snap
        XCTAssertEqual(Scrub.snap(1.2, segment: (0, 1), length: 4), 1)         // never past the end
        XCTAssertEqual(Scrub.snap(0.5, segment: (0.6, 1), length: 3), 0.6)
    }

    /// A ray from a camera at `cam` towards a world point.
    func ray(_ cam: WorldVec, _ p: WorldVec) -> (WorldVec, WorldVec) { (cam, simd_normalize(p - cam)) }

    func testRunContinuesRoundACornerOnlyWhenScrubbedIntoAndComesBack() {
        let cam = WorldVec(2, 1.4, 2)
        var (o, d) = ray(cam, WorldVec(2.0, 0.05, 0))
        let c = Component(id: "skirting-w1-0", kind: .skirting, wallId: "w1", t0: 0, t1: 1)
        var run = Scrub.start(c, origin: o, dir: d, world: world)!
        XCTAssertEqual(run.pieces[0].tA, 0.5, accuracy: 1e-6)
        // Along w1 to x = 3.5.
        (o, d) = ray(cam, WorldVec(3.5, 0.05, 0))
        run = Scrub.extend(run, origin: o, dir: d, world: world)
        XCTAssertEqual(run.pieces.count, 1)
        XCTAssertEqual(run.length(world), 1.5, accuracy: 1e-6)
        // Just past the corner (5 cm onto w2): not enough, the run stops at the corner.
        (o, d) = ray(cam, WorldVec(4.0, 0.05, 0.05))
        run = Scrub.extend(run, origin: o, dir: d, world: world)
        XCTAssertEqual(run.pieces.count, 1)
        XCTAssertEqual(run.pieces[0].tB, 1, accuracy: 1e-9)
        // Deliberately onto w2 (0.6 m along it): the run continues round the corner.
        (o, d) = ray(cam, WorldVec(4.0, 0.05, 0.6))
        run = Scrub.extend(run, origin: o, dir: d, world: world)
        XCTAssertEqual(run.pieces.count, 2)
        XCTAssertEqual(run.pieces[1].wallId, "w2")
        XCTAssertEqual(run.pieces[1].tA, 0)
        XCTAssertEqual(run.length(world), 2.0 + 0.6, accuracy: 1e-6)
        // Back onto w1: the extra piece goes again.
        (o, d) = ray(cam, WorldVec(3.0, 0.05, 0))
        run = Scrub.extend(run, origin: o, dir: d, world: world)
        XCTAssertEqual(run.pieces.count, 1)
        XCTAssertEqual(run.length(world), 1.0, accuracy: 1e-6)
    }

    func testRunStopsAtADoorJamb() {
        // w4 runs from (0,3) to (0,0); its first segment ends at the door (t 1/3).
        let cam = WorldVec(2, 1.4, 2.5)
        var (o, d) = ray(cam, WorldVec(0, 0.05, 2.8))
        let c = Component(id: "skirting-w4-0", kind: .skirting, wallId: "w4", t0: 0, t1: 1.0 / 3)
        var run = Scrub.start(c, origin: o, dir: d, world: world)!
        (o, d) = ray(cam, WorldVec(0, 0.05, 1.5))                  // into the doorway
        run = Scrub.extend(run, origin: o, dir: d, world: world)
        XCTAssertEqual(run.pieces.count, 1)
        XCTAssertEqual(run.pieces[0].tB, 1.0 / 3, accuracy: 1e-9)
        let left = Scrub.remaining(run, world: world)
        XCTAssertEqual(left?.metres ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(left?.wallEnd, false)                       // it's a door, not the wall's end
    }

    func testFloorPaintStaysInTheRoom() {
        var p = FloorPaint(room: world.rooms[0].polygon)
        p.paint(PlanVec(2, 1.5))
        let one = p.area
        XCTAssertGreaterThan(one, 0.12)
        XCTAssertLessThan(one, 0.28)                                // about a 0.25 m disc
        p.paint(PlanVec(2, 1.5))
        XCTAssertEqual(p.area, one, accuracy: 1e-9)                 // painting twice adds nothing
        var edge = FloorPaint(room: world.rooms[0].polygon)
        edge.paint(PlanVec(0.02, 0.02))                             // in the corner: a quarter disc
        XCTAssertLessThan(edge.area, one / 2)
        XCTAssertGreaterThanOrEqual(p.outline.count, 4)
        XCTAssertGreaterThanOrEqual(FloorArea.area(p.outline), one - 1e-9)
    }

    func testFloorOutlineFollowsTheScrub() {
        // An L-shaped scrub: the saved outline is concave, close to the painted area.
        var p = FloorPaint(room: world.rooms[0].polygon)
        for x in stride(from: 0.6, through: 3.0, by: 0.1) { p.paint(PlanVec(x, 0.6)) }
        for z in stride(from: 0.6, through: 2.4, by: 0.1) { p.paint(PlanVec(0.6, z)) }
        let poly = p.outline
        XCTAssertGreaterThanOrEqual(poly.count, 5)
        let a = FloorArea.area(poly)
        XCTAssertEqual(a, p.area, accuracy: p.area * 0.15)
        XCTAssertLessThan(a, FloorArea.area(PlanBuilder.convexHull(poly)) * 0.8)     // not the hull
    }

    func testTideLine() {
        var t = TideLine(wallId: "w1")
        t.add(t: 0.10, height: 0.40, wallLength: 4)
        t.add(t: 0.20, height: 0.45, wallLength: 4)
        t.add(t: 0.20, height: 0.42, wallLength: 4)                 // the last height scrubbed at a spot wins
        XCTAssertEqual(t.maxMm, 420)
        let pts = t.points(world)
        XCTAssertEqual(pts.count, 2)
        XCTAssertTrue(pts.allSatisfy { abs($0.z) < 1e-9 })          // on w1
        XCTAssertLessThan(pts[0].x, pts[1].x)                       // in wall order
    }

    func testCutHeightAndSnapping() {
        XCTAssertEqual(StripBack.cut(forTideMm: 450), 600)
        XCTAssertEqual(StripBack.cut(forTideMm: 100), 300)
        XCTAssertEqual(StripBack.cut(forTideMm: 800), 1200)
        XCTAssertNil(StripBack.cut(forTideMm: 1100))                // full height
        XCTAssertEqual(StripBack.snap(630, fullMm: 2400), 600)
        XCTAssertEqual(StripBack.snap(720, fullMm: 2400), 700)
        XCTAssertEqual(StripBack.snap(2380, fullMm: 2400), 2400)
        XCTAssertEqual(StripBack(wallId: "w1", t0: 0, t1: 0.5, heightMm: 600).area(world), 1.2, accuracy: 1e-9)
    }

    func testSuggestionRules() {
        XCTAssertEqual(Suggest.afterReading(value: 28, height: 0.08, wallId: "w1", wallsWithSkirting: [])?.kind, .skirtingWall(wallId: "w1"))
        XCTAssertNil(Suggest.afterReading(value: 12, height: 0.08, wallId: "w1", wallsWithSkirting: []))       // dry
        XCTAssertNil(Suggest.afterReading(value: 28, height: 0.9, wallId: "w1", wallsWithSkirting: []))        // not skirting height
        XCTAssertNil(Suggest.afterReading(value: 28, height: 0.08, wallId: "w1", wallsWithSkirting: ["w1"]))   // already marked
        let tide = Suggest.afterTide(maxMm: 450, wallId: "w1")
        XCTAssertEqual(tide.kind, .stripWall(wallId: "w1", mm: 600))
        XCTAssertEqual(tide.text, "Moisture reached 450 — cut at 600?")
        XCTAssertNotNil(Suggest.afterWetFloor(floorType: "carpet", areaId: "a"))
        XCTAssertNil(Suggest.afterWetFloor(floorType: "tile", areaId: "a"))
        XCTAssertEqual(Suggest.afterSource(at: WorldVec(2.0, 1.0, 0.1), objects: world.objects)?.kind, .removeCabinet(objectId: "s1"))
        XCTAssertNil(Suggest.afterSource(at: WorldVec(0.2, 1.0, 2.0), objects: world.objects))
    }

    func testRoomModelRaycast() {
        let hit = world.raycast(origin: WorldVec(2, 0.5, 1.5), dir: WorldVec(0, 0, -1))
        XCTAssertEqual(hit?.0.z ?? -1, 0.6, accuracy: 1e-6)          // the sink cabinet's front, before w1
        let wall = world.raycast(origin: WorldVec(1, 1.4, 1.5), dir: WorldVec(0, 0, -1))
        XCTAssertEqual(wall?.0.z ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(wall?.1.z ?? 0, 1, accuracy: 1e-9)            // facing the camera
    }

    // MARK: Walls have two sides (docs/MARKING.md H)

    func testSideOfAWall() {
        let w1 = world.walls[0]                                       // (0,0) -> (4,0): side "a" is +z, the room
        XCTAssertEqual(WallSide.side(of: PlanVec(2, 1), wall: w1), "a")
        XCTAssertEqual(WallSide.side(of: PlanVec(2, -1), wall: w1), "b")
        XCTAssertTrue(Visibility.sideVisible(side: "a", wallId: "w1", camera: WorldVec(2, 1.4, 2), world: world))
        XCTAssertFalse(Visibility.sideVisible(side: "a", wallId: "w1", camera: WorldVec(2, 1.4, -2), world: world))
        XCTAssertTrue(Visibility.sideVisible(side: "cavity", wallId: "w1", camera: WorldVec(2, 1.4, -2), world: world))
        XCTAssertTrue(Visibility.sideVisible(side: nil, wallId: "w1", camera: WorldVec(2, 1.4, -2), world: world))
    }

    func testCavityMarkIsDrawnOnTheFaceYouLookAt() {
        var leak = OverlayMark(id: "s", style: .source, points: [WorldVec(2.5, 0.6, 0)], tag: "Leak")
        leak.wallId = "w1"
        leak.side = "cavity"
        let fromRoom = Visibility.prepare(leak, camera: WorldVec(2, 1.4, 2), world: world)
        let fromNext = Visibility.prepare(leak, camera: WorldVec(2, 1.4, -2), world: world)
        XCTAssertEqual(fromRoom?.points[0].z ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(fromNext?.points[0].z ?? 0, -0.02, accuracy: 1e-9)
        XCTAssertEqual(fromRoom?.points[0].x ?? 0, 2.5, accuracy: 1e-9)    // same place along the wall
        XCTAssertEqual(fromNext?.points[0].y ?? 0, 0.6, accuracy: 1e-9)    // and the same height
    }

    func testOcclusionByWalls() {
        let inRoom = WorldVec(2, 1.4, 2)
        // A point in the next room (behind w1) is hidden; one in the room is not.
        XCTAssertTrue(Visibility.occluded(WorldVec(2, 0.5, -1), camera: inRoom, world: world))
        XCTAssertFalse(Visibility.occluded(WorldVec(2, 0.5, 1), camera: inRoom, world: world))
        // A mark on w1's face (lifted towards the camera) is not hidden by w1 itself.
        var pin = OverlayMark(id: "r", style: .reading(status: "wet", reference: false), points: [WorldVec(2, 0.5, 0)], value: "30")
        pin.wallId = "w1"; pin.side = "a"
        XCTAssertNotNil(Visibility.prepare(pin, camera: inRoom, world: world))
        XCTAssertNil(Visibility.prepare(pin, camera: WorldVec(2, 1.4, -2), world: world))       // the far side
        // Through the doorway in w4 (z 1.0...1.8 from its start at z 3 -> z 2.0...1.2): visible.
        XCTAssertFalse(Visibility.occluded(WorldVec(-1.5, 0.8, 1.6), camera: WorldVec(2, 1.0, 1.6), world: world))
        XCTAssertTrue(Visibility.occluded(WorldVec(-1.5, 0.8, 0.5), camera: WorldVec(2, 1.0, 0.5), world: world))
        // Equipment in the next room disappears.
        let unit = OverlayMark(id: "a", style: .equipment(type: "airMover", planned: false), points: [WorldVec(2, 0, -1.5)], tag: "AM-1")
        XCTAssertNil(Visibility.prepare(unit, camera: inRoom, world: world))
    }
}
