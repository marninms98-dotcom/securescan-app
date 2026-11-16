//
//  CaptureTests.swift
//  SecureScanTests
//
//  The one capture screen's pure rules (docs/UX2.md): projection and
//  near-plane clipping, what the reticle is on, the Mark tool's intent,
//  the words on the screen, the capture stack, the duplicate-equipment
//  guard, plain-language problems and room names.
//  Coordinates here are made up; none come from a real job.
//

import XCTest
import simd

final class CaptureTests: XCTestCase {

    // MARK: Projection

    private func camera() -> PinholeProjector {
        PinholeProjector(position: WorldVec(0, 0, 0), lookAt: WorldVec(0, 0, -1), fovYDegrees: 90, viewport: ScreenVec(400, 800))
    }

    func testPinholeProjectsLikeACamera() {
        let p = camera()
        XCTAssertEqual(p.focal, 400, accuracy: 1e-9)
        let c = p.project(WorldVec(0, 0, -2))!
        XCTAssertEqual(c.x, 200, accuracy: 1e-9); XCTAssertEqual(c.y, 400, accuracy: 1e-9)
        let r = p.project(WorldVec(1, 0, -2))!
        XCTAssertEqual(r.x, 400, accuracy: 1e-9)                       // right of centre
        let u = p.project(WorldVec(0, 1, -2))!
        XCTAssertEqual(u.y, 200, accuracy: 1e-9)                       // up is up the screen
        XCTAssertNil(p.project(WorldVec(0, 0, 1)))                     // behind the camera
        XCTAssertNil(p.project(WorldVec(0, 0, -0.01)))                 // inside the near plane
        XCTAssertEqual(p.depth(WorldVec(3, 2, -5)), 5, accuracy: 1e-9)
        // The ray through a screen point comes back to the same point.
        let ray = p.ray(through: ScreenVec(300, 250))
        let back = p.project(ray * 3)!
        XCTAssertEqual(back.x, 300, accuracy: 1e-6); XCTAssertEqual(back.y, 250, accuracy: 1e-6)
    }

    func testSegmentsAreClippedAtTheNearPlaneNotProjectedFromBehind() {
        let p = camera()
        // From behind the camera to in front of it.
        let c = Clip.segment(WorldVec(0, -1, 1), WorldVec(0, -1, -3), near: p.near, depth: { p.depth($0) })!
        XCTAssertEqual(p.depth(c.0), p.near, accuracy: 1e-9)
        XCTAssertEqual(c.1, WorldVec(0, -1, -3))
        XCTAssertNil(Clip.segment(WorldVec(0, 0, 1), WorldVec(0, 0, 2), near: p.near, depth: { p.depth($0) }))
        let s = p.projectSegment(WorldVec(0, -1, 1), WorldVec(0, -1, -3))!
        XCTAssertGreaterThan(s.0.y, 800)                               // runs off the bottom, never flips
        XCTAssertEqual(s.1.y, 400 + 400.0 / 3, accuracy: 1e-6)
    }

    func testFloorPolygonsUnderTheCameraAreClipped() {
        let p = camera()
        let floor = [WorldVec(-1, -1, 1), WorldVec(1, -1, 1), WorldVec(1, -1, -3), WorldVec(-1, -1, -3)]
        let clipped = Clip.polygon(floor, near: p.near, depth: { p.depth($0) })
        XCTAssertEqual(clipped.count, 4)
        XCTAssertTrue(clipped.allSatisfy { p.depth($0) >= p.near - 1e-9 })
        XCTAssertEqual(p.projectPolygon(floor).count, 4)
        XCTAssertTrue(Clip.polygon(floor.map { $0 + WorldVec(0, 0, 10) }, near: p.near, depth: { p.depth($0) }).isEmpty)
        // A polyline that dips behind the camera splits into two visible runs.
        let line = [WorldVec(-2, 0, -2), WorldVec(-1, 0, 1), WorldVec(1, 0, 1), WorldVec(2, 0, -2)]
        XCTAssertEqual(Clip.polyline(line, near: p.near, depth: { p.depth($0) }).count, 2)
    }

    func testOffscreenItemsPointTheRightWay() {
        let p = camera()
        XCTAssertGreaterThan(p.offscreenDirection(WorldVec(5, 0, -1)).x, 0.9)   // far right
        XCTAssertLessThan(p.offscreenDirection(WorldVec(-1, 0, 2)).x, -0.9)     // behind, to the left
    }

    // MARK: What the reticle is on

    private let room = CaptureWorld(floorY: 0, walls: [WorldWall(id: "w1", a: PlanVec(0, 0), b: PlanVec(3, 0), height: 2.4),
                                                       WorldWall(id: "w2", a: PlanVec(3, 0), b: PlanVec(3, 3), height: 2.4)],
                                    rooms: [WorldRoom(name: "Bedroom", polygon: [PlanVec(0, 0), PlanVec(3, 0), PlanVec(3, 3), PlanVec(0, 3)])])

    private func aim(_ hit: WorldVec?, _ normal: WorldVec, tracking: Bool = true) -> Aim {
        AimInterpreter.interpret(AimSample(camera: WorldVec(1.5, 1.4, 2.5), forward: WorldVec(0, -0.3, -1), hit: hit, normal: normal, tracking: tracking), world: room)
    }

    func testReticleKnowsWallSkirtingFloorAndNothing() {
        let wall = aim(WorldVec(1.2, 0.32, 0), WorldVec(0, 0, 1))
        XCTAssertEqual(wall.surface, .wall)
        XCTAssertEqual(wall.wall?.id, "w1")
        XCTAssertEqual(CaptureCopy.reticle(wall), "Wall · 0.32 m up")
        XCTAssertEqual(CaptureCopy.material(wall), "wall")
        let skirting = aim(WorldVec(1.2, 0.06, 0), WorldVec(0, 0, 1))
        XCTAssertEqual(CaptureCopy.reticle(skirting), "Skirting")
        XCTAssertTrue(skirting.inSkirtingZone)
        XCTAssertEqual(CaptureCopy.material(skirting), "skirting")
        let floorByWall = aim(WorldVec(1.2, 0, 0.1), WorldVec(0, 1, 0))
        XCTAssertEqual(floorByWall.surface, .floor)
        XCTAssertTrue(floorByWall.inSkirtingZone)                       // the floor within 150 mm of a wall
        XCTAssertEqual(floorByWall.room, "Bedroom")
        let floorMiddle = aim(WorldVec(1.2, 0, 1.4), WorldVec(0, 1, 0))
        XCTAssertFalse(floorMiddle.inSkirtingZone)
        XCTAssertEqual(CaptureCopy.reticle(floorMiddle), "Floor")
        XCTAssertEqual(aim(nil, WorldVec(0, 1, 0)).blocked, CaptureCopy.pointAtSurface)
        XCTAssertEqual(aim(WorldVec(1, 1, 0), WorldVec(0, 0, 1), tracking: false).blocked, CaptureCopy.findingRoom)
    }

    func testWallEndsSnapWithinFifteenCentimetres() {
        let a = aim(WorldVec(2.9, 1.0, 0), WorldVec(0, 0, 1))
        XCTAssertTrue(a.snapped)
        XCTAssertEqual(a.hit!.x, 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.hit!.y, 1.0, accuracy: 1e-9)                   // height kept
        XCTAssertEqual(a.wallT, 1)
        XCTAssertFalse(aim(WorldVec(2.7, 1.0, 0), WorldVec(0, 0, 1)).snapped)
    }

    // MARK: The Mark tool by intent

    private func wallPt(_ x: Double, _ h: Double) -> MarkPoint {
        MarkPoint(world: WorldVec(x, h, 0), surface: .wall, height: h, distanceToWall: 0, wallId: "w1")
    }
    private func floorPt(_ x: Double, _ z: Double, toWall d: Double) -> MarkPoint {
        MarkPoint(world: WorldVec(x, 0, z), surface: .floor, height: 0, distanceToWall: d)
    }

    func testTwoLowWallTapsAreASkirtingRemoval() {
        let r = MarkIntent.shape([wallPt(0.4, 0.05), wallPt(2.1, 0.08)])!
        XCTAssertEqual(r.shape, .line)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: r.shape, points: r.points, context: .inspect), .skirting)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: r.shape, points: r.points, context: .scope), .skirting)
        XCTAssertEqual(MarkIntent.startShape(wallPt(0.4, 0.05)), .line)
    }

    /// The owner's real case (15 Nov): in the floor tool he tapped twice along the
    /// skirting ("from there to there"); four taps came out as two pairs of
    /// near-duplicates on the floor beside the wall. That is a skirting line,
    /// never "the section is too small" and never dropped.
    func testOwnersTwoFloorTapsAlongAWallAreASkirtingLine() {
        let taps = [floorPt(-0.40, 0.100, toWall: 0.10), floorPt(0.30, 0.090, toWall: 0.09),
                    floorPt(0.29, 0.095, toWall: 0.095), floorPt(-0.39, 0.105, toWall: 0.105)]
        XCTAssertEqual(MarkIntent.clean(taps).count, 2)
        let r = MarkIntent.shape(taps)!
        XCTAssertEqual(r.shape, .line)
        XCTAssertEqual(r.points.count, 2)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: r.shape, points: r.points, context: .inspect), .skirting)
        XCTAssertEqual(MarkIntent.options(shape: .line, default: .skirting).first, .skirting)
        // And the floor beside the wall reads as the skirting band from the reticle too.
        XCTAssertTrue(aim(WorldVec(0.4, 0, 0.1), WorldVec(0, 1, 0)).inSkirtingZone)
    }

    func testHigherWallLinesDependOnTheWork() {
        let pts = [wallPt(0.4, 0.62), wallPt(1.9, 0.58)]
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: .line, points: pts, context: .inspect), .moistureLine)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: .line, points: pts, context: .scope), .wallLining)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: .line, points: pts, context: .inspect, remembered: ["highLine": .wallLining]), .wallLining)
        XCTAssertEqual(MarkIntent.memoryKey(shape: .line, points: pts), "highLine")
    }

    func testFloorAreasAndTheQuestion() {
        let area = [floorPt(0.6, 0.8, toWall: 0.8), floorPt(1.9, 0.75, toWall: 0.75), floorPt(2.0, 1.7, toWall: 1.0), floorPt(0.7, 1.75, toWall: 0.7)]
        let r = MarkIntent.shape(area)!
        XCTAssertEqual(r.shape, .area)
        XCTAssertEqual(MarkIntent.area(r.points), 1.25, accuracy: 0.05)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: .area, points: r.points, context: .inspect), .wetFloor)
        XCTAssertEqual(MarkIntent.defaultMeaning(shape: .area, points: r.points, context: .scope), .liftFlooring)
        XCTAssertEqual(MarkIntent.startShape(area[0]), .area)
        // Two floor taps away from the walls: a line, and the tray asks.
        let two = MarkIntent.shape([floorPt(0.6, 0.8, toWall: 0.8), floorPt(1.9, 0.9, toWall: 0.9)])!
        XCTAssertEqual(two.shape, .line)
        XCTAssertNil(MarkIntent.defaultMeaning(shape: two.shape, points: two.points, context: .inspect))
        // A sliver is not an area: it becomes a line, never an error.
        let sliver = MarkIntent.shape([floorPt(0, 1, toWall: 1), floorPt(2, 1, toWall: 1), floorPt(2, 1.02, toWall: 1)])!
        XCTAssertEqual(sliver.shape, .line)
        XCTAssertNil(MarkIntent.shape([floorPt(0, 1, toWall: 1)]))
    }

    func testLiningHeightIsPreselectedFromTheEndTap() {
        XCTAssertEqual(MarkIntent.liningHeightMm(endHeight: 0.32), 300)
        XCTAssertEqual(MarkIntent.liningHeightMm(endHeight: 0.55), 600)
        XCTAssertEqual(MarkIntent.liningHeightMm(endHeight: 0.95), 1200)
        XCTAssertEqual(MarkIntent.liningHeightMm(endHeight: 1.7, fullMm: 2400), 2400)
        XCTAssertEqual(MarkIntent.liningHeightMm(endHeight: 0.05), 600)
        XCTAssertEqual(MarkIntent.liningHeightMm(endHeight: nil), 600)
        XCTAssertEqual(MarkIntent.defaultHeightMm(.skirting), 100)
    }

    func testAMarkAcrossTwoWallsNeedsAQuickFix() {
        let across = MarkCheck.problem(meaning: .skirting, points: [WorldVec(1, 0.05, 0.02), WorldVec(3, 0.05, 2)], world: room)
        XCTAssertEqual(across?.sentence, "This line runs across two walls.")
        XCTAssertNil(MarkCheck.problem(meaning: .skirting, points: [WorldVec(1, 0.05, 0.02), WorldVec(2.9, 0.05, 0.3)], world: room))
        XCTAssertNil(MarkCheck.problem(meaning: .moistureLine, points: [WorldVec(1, 0.5, 0), WorldVec(3, 0.5, 2)], world: room))
        XCTAssertEqual(MarkCheck.problem(meaning: .wallLining, points: [WorldVec(1, 0.5, 1.5), WorldVec(2, 0.5, 0)], world: room)?.sentence,
                       "One end of this line isn't on a wall.")
    }

    // MARK: Words

    func testPrimaryButtonSaysWhatTheTapDoes() {
        XCTAssertEqual(CaptureCopy.endHere(2.354), "End here · 2.35 m")
        XCTAssertEqual(CaptureCopy.endHere(nil), "End here")
        XCTAssertEqual(CaptureCopy.closeArea(3.21), "Close area · 3.2 m²")
        XCTAssertEqual(CaptureCopy.addCorner(1.04), "Add corner · 1.0 m²")
        XCTAssertEqual(CaptureCopy.place("airMover"), "Place air mover")
        XCTAssertEqual(CaptureCopy.place("dehumidifier"), "Place dehumidifier")
        XCTAssertEqual(CaptureCopy.remeasure("R3"), "Re-measure R3")
        XCTAssertEqual(CaptureCopy.saveReading("18"), "Save · 18%")
        XCTAssertEqual(CaptureCopy.saveReading(""), "Type the reading")
        XCTAssertEqual(CaptureCopy.saveMark(.skirting, length: 2.354, area: nil), "Save · Skirting 2.35 m")
        XCTAssertEqual(CaptureCopy.saveMark(.liftFlooring, length: nil, area: 3.2), "Save · Flooring 3.2 m²")
        XCTAssertEqual(CaptureCopy.saveMark(nil, length: 1, area: nil), "Choose what it is")
        XCTAssertEqual(CaptureCopy.phase("Scanning", room: "Bedroom"), "Scanning · Bedroom")
        XCTAssertEqual(CaptureCopy.visit(2, done: 4, total: 9), "Visit 2 · 4 of 9")
        XCTAssertEqual(EquipmentGuard.action(for: .init(id: "a", type: "airMover", pos: .zero, hasAirflow: false, tag: "AM 1")), "Set airflow · AM 1")
        // Sentence case, no shouting, no "could not".
        let all = [CaptureCopy.addReading, CaptureCopy.takePhoto, CaptureCopy.startHere, CaptureCopy.markSource, CaptureCopy.setAirflow, CaptureCopy.markDone]
        for s in all { XCTAssertNotEqual(s, s.uppercased()); XCTAssertFalse(s.lowercased().contains("could not")) }
        XCTAssertEqual(CaptureTool.modes(returnVisit: false).map(\.title), ["Moisture", "Strip-out", "Equipment", "Source"])
        XCTAssertEqual(CaptureTool.modes(returnVisit: true).map(\.title), ["Re-measure", "Moisture", "Strip-out", "Equipment"])
        XCTAssertEqual(CaptureTool.modes(returnVisit: false, scopeOnSite: true), [.equipment, .stripOut])
        // Every mode has a first-use line (the Tips list) and the sub-pickers are as designed.
        XCTAssertEqual(CaptureCopy.tips(CaptureTool.modes(returnVisit: false)).count, 4)
        XCTAssertEqual(CaptureCopy.subPicker(.stripOut).map(\.title), ["Skirting", "Wall", "Cabinets", "Floor"])
        XCTAssertEqual(CaptureCopy.subPicker(.equipment).first?.key, "airMover")
        XCTAssertTrue(CaptureCopy.subPicker(.source).isEmpty)
        XCTAssertEqual(CaptureCopy.subtitle(phase: "Scanning", tool: .moisture, readings: 3, marks: 0, units: 0, fixed: false), "Scanning · 3 readings")
        XCTAssertEqual(CaptureCopy.subtitle(phase: "Marking", tool: .equipment, readings: 0, marks: 0, units: 1, fixed: false), "Drying setup · 1 unit")
        XCTAssertEqual(CaptureCopy.subtitle(phase: "Visit 2 · 1 of 3", tool: .moisture, readings: 5, marks: 0, units: 0, fixed: true), "Visit 2 · 1 of 3")
        XCTAssertFalse(CaptureCopy.causes.isEmpty)
        XCTAssertEqual(CaptureCopy.causes.last, "Unknown")
    }

    func testProblemsInPlainWords() {
        let p = PlainWords.problem("The section is too small. Tap its corners on the floor.")
        XCTAssertEqual(p.sentence, "This floor area is too small to draw.")
        for reason in ["The section is too small. Tap its corners on the floor.", "Tap at least 3 corners of the floor section.",
                       "The corners cross over. Tap them in order around the section.", "One end of the removal is not on a wall.",
                       "The start and end are on different walls. Mark each wall as its own removal.",
                       "The removal is too short - the two points are in the same place.",
                       "You weren't standing inside a scanned room, so the whole room couldn't be used.", "something new"] {
            let q = PlainWords.problem(reason)
            XCTAssertFalse(q.sentence.lowercased().contains("could not"), reason)
            XCTAssertFalse(q.sentence.lowercased().hasPrefix("you"), reason)
            XCTAssertFalse(q.fix.isEmpty)
        }
        XCTAssertEqual(PlainWords.jobNote(fixCount: 1), "1 mark needs a quick fix — open Items")
        XCTAssertEqual(PlainWords.jobNote(fixCount: 3), "3 marks need a quick fix — open Items")
        XCTAssertNil(PlainWords.jobNote(fixCount: 0))
    }

    // MARK: The capture stack

    func testStackCountsCapturesNotRawItems() {
        var s = CaptureStack()
        s.add(.init(id: "r1", ids: ["r1"], kind: "reading", title: "R1 · 10%", detail: "", hasPhoto: true))
        s.add(.init(id: "b1", ids: ["b1", "b2", "b3"], kind: "mark", title: "Moisture line", detail: "", hasPhoto: true))
        s.add(.init(id: "e1", ids: ["e1"], kind: "equipment", title: "Air mover 1", detail: "", hasPhoto: false))
        XCTAssertEqual(s.count, 3)                                     // a three-point line is one capture
        XCTAssertEqual(s.lastPhoto?.id, "b1")
        XCTAssertEqual(s.remove(id: "b2")?.ids.count, 3)               // deleting part of a line removes the line
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.popLast()?.id, "e1")                          // undo
        XCTAssertEqual(s.count, 1)
        var fix = CaptureStack.Entry(id: "x1", ids: [], kind: "mark", title: "Skirting", detail: "", hasPhoto: false)
        fix.needsFix = "This line runs across two walls."
        s.add(fix)
        s.add(.init(id: "p1", ids: ["p1"], kind: "photo", title: "P1", detail: "", hasPhoto: true))
        XCTAssertEqual(s.needsFixCount, 1)
        XCTAssertEqual(s.reviewOrder.map(\.id), ["x1", "p1", "r1"])  // fixes first, then newest first
        XCTAssertEqual(CaptureCopy.stackBadge(0), nil)
        XCTAssertEqual(CaptureCopy.stackBadge(7), "7")
        XCTAssertEqual(CaptureCopy.stackBadge(120), "99+")
    }

    // MARK: One air mover is one air mover

    func testScopeViewSelectsTheExistingAirMoverInsteadOfADuplicate() {
        // An air mover placed while scanning, and the spot aimed at later (8 cm away).
        let units = [EquipmentGuard.Unit(id: "ar-1", type: "airMover", pos: PlanVec(0.47, 0.57), hasAirflow: false, tag: "AM 1"),
                     EquipmentGuard.Unit(id: "ar-2", type: "airMover", pos: PlanVec(-0.79, 0.04), hasAirflow: true, tag: "AM 2")]
        XCTAssertEqual(EquipmentGuard.existing(type: "airMover", at: PlanVec(0.49, 0.65), units: units)?.id, "ar-1")
        XCTAssertEqual(EquipmentGuard.existing(type: "airMover", at: PlanVec(-0.64, 0.03), units: units)?.id, "ar-2")
        XCTAssertNil(EquipmentGuard.existing(type: "dehumidifier", at: PlanVec(0.49, 0.65), units: units))
        XCTAssertNil(EquipmentGuard.existing(type: "airMover", at: PlanVec(1.2, 0.57), units: units))
        XCTAssertEqual(EquipmentGuard.action(for: units[1]), "Re-aim airflow · AM 2")
    }

    // MARK: Rooms

    func testRoomNamesFromRoomPlanSections() {
        XCTAssertEqual(RoomNaming.suggestions(sectionLabels: ["bedroom", "bathroom"]), ["Bedroom + Ensuite", "Bedroom", "Ensuite"])
        XCTAssertEqual(RoomNaming.preselected(sectionLabels: ["bedroom", "bathroom", "bedroom"]), "Bedroom + Ensuite")
        XCTAssertEqual(RoomNaming.preselected(sectionLabels: ["kitchen"]), "Kitchen")
        XCTAssertNil(RoomNaming.preselected(sectionLabels: ["unidentified"]))
        XCTAssertEqual(RoomNaming.chipList(sectionLabels: ["bathroom"]).first, "Bathroom")
        XCTAssertEqual(RoomNaming.chipList(sectionLabels: []).count, RoomNaming.chips.count)
    }

    func testFloorEstimateTakesTheLowestFloorHit() {
        var f: Double? = nil
        f = FloorEstimate.update(f, hit: WorldVec(0, -1.30, 0), normalY: 0.99, cameraY: 0)
        XCTAssertEqual(f, -1.30)
        f = FloorEstimate.update(f, hit: WorldVec(0, -0.5, 0), normalY: 0.99, cameraY: 0)      // a bed top: ignored
        XCTAssertEqual(f, -1.30)
        f = FloorEstimate.update(f, hit: WorldVec(0, -1.6, 0), normalY: 0.99, cameraY: 0)      // a step down: moves slowly
        XCTAssertEqual(f!, -1.35, accuracy: 1e-9)
        XCTAssertEqual(FloorEstimate.update(nil, hit: WorldVec(0, -1.3, 0), normalY: 0.1, cameraY: 0), nil)
    }

    // MARK: Return visits

    func testUndoingAReMeasureRestoresTheLastVisit() {
        let plan: [String: Any] = ["markup": [
            "visits": [["id": "v1"], ["id": "v2"]],
            "readings": [["id": "r1", "kind": "reading", "value": 15.0,
                          "history": [["visit": "v1", "value": 20.0], ["visit": "v2", "value": 15.0]]]],
        ]]
        let out = Revisit.undoMeasurement(plan: plan, readingId: "r1", visit: "v2")!
        let r = ((out["markup"] as! [String: Any])["readings"] as! [[String: Any]])[0]
        XCTAssertEqual(PlanDocument.number(r["value"]), 20)
        XCTAssertEqual((r["history"] as! [[String: Any]]).count, 1)
        XCTAssertNil(Revisit.undoMeasurement(plan: out, readingId: "r1", visit: "v2"))
    }

    func testSavedPlanMarkersBecomeOverlayMarks() {
        let walls = [PlanWall(id: "w1", a: PlanVec(0, 0), b: PlanVec(4, 0), height: 2.4, roomIndex: 0)]
        var eq = Revisit.Marker(id: "e1", kind: "equipment", label: "Air mover", pos: PlanVec(1, 1), height: 0.15)
        eq.type = "airMover"
        eq.dir = 0
        let rem = Revisit.Marker(id: "x1", kind: "removal", label: "Remove skirting", pos: PlanVec(1, 0), height: 0.05,
                                 wallId: "w1", t0: 0.25, t1: 0.75, top: 0.1)
        let rd = Revisit.Marker(id: "r1", kind: "reading", label: "2 · 18%", pos: PlanVec(2, 0), height: 0.3, value: 18, status: "elevated")
        let marks = OverlayBuild.marks([eq, rem, rd], walls: walls, alignment: PlanTransform(angle: 0, offset: .zero), floorY: -1.3)
        XCTAssertEqual(marks.count, 3)
        XCTAssertEqual(marks[0].style, .equipment(type: "airMover", planned: false))
        XCTAssertEqual(marks[0].airflow!.x, 1, accuracy: 1e-9)
        XCTAssertEqual(marks[1].style, .skirting)
        XCTAssertEqual(marks[1].tag, "Skirting · 2.00 m")
        XCTAssertEqual(marks[1].points[0].y, -1.3, accuracy: 1e-9)
        XCTAssertEqual(marks[2].style, .reading(status: "elevated", reference: false))
        XCTAssertEqual(marks[2].tag, "R2")
        XCTAssertEqual(marks[2].value, "18")
    }
}

final class OverlayLayoutTests: XCTestCase {

    /// Every Studio scene, laid out with the renderer's own layout code: no label, pin, glyph
    /// or the reticle (and its label) overlaps another; no label sits on an airflow arrow;
    /// every label is inside the screen below the top bar.
    func testNoStudioSceneHasOverlaps() {
        for name in StudioScenes.all {
            let d = StudioScenes.data(name)
            let proj = StudioScenes.projector(d)
            let plan = OverlayLayout.plan(d.marks, projector: proj, reticleLabel: d.reticle, measure: .estimate)
            XCTAssertEqual(plan.overlaps(), [], name)
            let screen = CGRect(x: 0, y: 0, width: StudioScenes.viewport.x, height: StudioScenes.viewport.y)
            for (id, r) in plan.labels {
                XCTAssertTrue(screen.insetBy(dx: OverlayLayout.margin - 0.5, dy: 0).contains(r), "\(name): \(id) off screen \(r)")
                if id != "reticle" { XCTAssertGreaterThanOrEqual(r.minY, OverlayLayout.topLimit - 0.5, "\(name): \(id) under the top bar") }
            }
        }
    }

    func testScenesShowTheirLabels() {
        // The scope scene keeps both floor/wall tags visible (moved, not dropped).
        let d = StudioScenes.data("scope-on-site")
        let plan = OverlayLayout.plan(d.marks, projector: StudioScenes.projector(d), reticleLabel: nil, measure: .estimate)
        XCTAssertNotNil(plan.labels["f1"])
        XCTAssertNotNil(plan.labels["a1"])
        XCTAssertNotNil(plan.glyphs["a1"])
        // Equipment is a 3D model with its own airflow: no 2D arrow, the tag above the model.
        XCTAssertNil(plan.arrows["a1"])
        XCTAssertLessThan(plan.labels["a1"]!.maxY, plan.glyphs["a1"]!.minY + 1)
        // Reading pins: every pin placed, none on another.
        let r = StudioScenes.data("reading-saved")
        let rp = OverlayLayout.plan(r.marks, projector: StudioScenes.projector(r), reticleLabel: r.reticle, measure: .estimate)
        XCTAssertEqual(rp.pins.count, 3)
    }

    func testCoincidentPinsStepApartAndLabelsAvoidThem() {
        let proj = PinholeProjector(position: WorldVec(0, 1.4, 3), lookAt: WorldVec(0, 0.5, 0), fovYDegrees: 62, viewport: ScreenVec(402, 874))
        let marks = [StudioScenes.pin("a", WorldVec(0.5, 0.5, 0), 12, 1), StudioScenes.pin("b", WorldVec(0.52, 0.5, 0), 22, 2),
                     OverlayMark(id: "s", style: .skirting, points: [WorldVec(0.2, 0.05, 0), WorldVec(0.8, 0.05, 0)], tag: "Skirting · 0.60 m")]
        let plan = OverlayLayout.plan(marks, projector: proj, reticleLabel: "Wall · 0.50 m up", measure: .estimate)
        XCTAssertEqual(plan.overlaps(), [])
        XCTAssertGreaterThan(abs(plan.pins["a"]!.centre.x - plan.pins["b"]!.centre.x), 30)
    }

    func testOffscreenAnchorsGetNoLabel() {
        let proj = PinholeProjector(position: WorldVec(0, 1.4, 3), lookAt: WorldVec(0, 0.5, 0), fovYDegrees: 62, viewport: ScreenVec(402, 874))
        let far = OverlayMark(id: "w", style: .wetFloor, points: [WorldVec(8, 0, 0), WorldVec(9, 0, 0), WorldVec(9, 0, 1)], tag: "Wet floor")
        XCTAssertNil(OverlayLayout.plan([far], projector: proj, reticleLabel: nil, measure: .estimate).labels["w"])
    }

    func testAirflowArrowIsOneMetreFlatOnTheFloor() {
        let a = OverlayLayout.arrow(from: WorldVec(1, 0, 1), dir: WorldVec(0, 0, 2))
        XCTAssertEqual(a.count, 7)
        XCTAssertTrue(a.allSatisfy { abs($0.y - 0.01) < 1e-9 })
        XCTAssertEqual(a[3].z - 1, 1.0, accuracy: 1e-9)                 // tip 1.0 m from the unit
        XCTAssertEqual(abs(a[2].x - a[4].x), 0.4, accuracy: 1e-9)       // head 0.40 m wide
        XCTAssertEqual(abs(a[0].x - a[6].x), 0.18, accuracy: 1e-9)      // shaft 0.18 m
    }

    func testReadingTagsOnlyWhenSelected() {
        var m = StudioScenes.pin("a", WorldVec(0.5, 0.5, 0), 12, 1)
        XCTAssertNil(OverlayLayout.displayTag(m))
        m.selected = true
        XCTAssertEqual(OverlayLayout.displayTag(m), "R1")
        let eq = OverlayMark(id: "e", style: .equipment(type: "airMover", planned: false), points: [.zero], tag: "AM-03")
        XCTAssertEqual(OverlayLayout.displayTag(eq), "AM-03 · Air mover")
    }
}

final class CaptureFrameTests: XCTestCase {

    func testFramedViewportIsThreeByFourOnModernPhones() {
        // iPhone 16 Pro: 402 x 874, safe area 62 / 34.
        let f = CaptureFrame.layout(width: 402, height: 874, safeTop: 62, safeBottom: 34)
        XCTAssertEqual(f.viewport, 536, accuracy: 0.5)
        XCTAssertEqual(f.top + f.viewport + f.bottom, 874, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(f.bottom, CaptureFrame.panelContent + 34)
        // iPhone SE: the viewport gives way so the controls still fit.
        let se = CaptureFrame.layout(width: 375, height: 667, safeTop: 20, safeBottom: 0)
        XCTAssertLessThan(se.viewport, 375 * 4 / 3)
        XCTAssertGreaterThanOrEqual(se.bottom, CaptureFrame.panelContent - 0.5)
    }

    func testModeStripCentresTheSelectedModeAndLandsOnTheNearest() {
        let l = ModeStripLayout(widths: [70, 80, 90, 60], gap: 26)
        XCTAssertEqual(l.centre(0), 35)
        XCTAssertEqual(l.centre(1), 70 + 26 + 40)
        XCTAssertEqual(l.offset(selected: 1, in: 400) + l.centre(1), 200)
        XCTAssertEqual(l.landing(from: 1, drag: 0), 1)
        XCTAssertEqual(l.landing(from: 1, drag: -110), 2)      // swipe left: the next mode
        XCTAssertEqual(l.landing(from: 1, drag: 110), 0)       // swipe right: the previous one
        XCTAssertEqual(l.landing(from: 0, drag: 2000), 0)      // clamped
        XCTAssertEqual(l.landing(from: 0, drag: -2000), 3)
    }

    func testHapticRateLimiterAllowsOnePer250ms() {
        var r = HapticRateLimiter(interval: 0.25)
        XCTAssertTrue(r.allow(at: 10.0))
        XCTAssertFalse(r.allow(at: 10.1))
        XCTAssertFalse(r.allow(at: 10.24))
        XCTAssertTrue(r.allow(at: 10.26))
        XCTAssertFalse(r.allow(at: 10.3))
        // A clock that went backwards never blocks for ever.
        XCTAssertTrue(r.allow(at: 5.0))
    }

    func testStructureDiffCountsOnlyNewPieces() {
        var d = StructureDiff()
        XCTAssertEqual(d.add(["w1", "w2"]), 2)
        XCTAssertEqual(d.add(["w1", "w2"]), 0)               // RoomPlan re-sends the whole room
        XCTAssertEqual(d.add(["w1", "w2", "door1"]), 1)
        XCTAssertEqual(d.add(["w2"]), 0)                     // something merged away: no tick
        d.reset()
        XCTAssertEqual(d.add(["w1"]), 1)                     // a new room
    }

    func testStripOutKindFollowsTheAim() {
        let base = MarkPoint(world: .zero, surface: .wall, height: 0.05, distanceToWall: 0)
        XCTAssertEqual(MarkIntent.stripKind(base), .skirting)
        XCTAssertEqual(MarkIntent.stripKind(MarkPoint(world: .zero, surface: .wall, height: 0.8, distanceToWall: 0)), .wallLining)
        XCTAssertEqual(MarkIntent.stripKind(MarkPoint(world: .zero, surface: .wall, height: 0.8, distanceToWall: 0),
                                            remembered: ["stripLine": .cabinetry]), .cabinetry)
        XCTAssertEqual(MarkIntent.stripKind(MarkPoint(world: .zero, surface: .floor, height: 0, distanceToWall: 1.2)), .liftFlooring)
        XCTAssertEqual(MarkIntent.stripKind(MarkPoint(world: .zero, surface: .floor, height: 0, distanceToWall: 0.05)), .skirting)
        XCTAssertEqual(MarkIntent.stripKind(nil), .skirting)
        XCTAssertTrue(MarkIntent.savesDirectly(.skirting))
        XCTAssertFalse(MarkIntent.savesDirectly(.wallLining))
    }
}
