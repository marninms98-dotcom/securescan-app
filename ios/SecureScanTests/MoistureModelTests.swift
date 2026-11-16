//
//  MoistureModelTests.swift
//  SecureScanTests
//
//  The moisture model's physics, fitting and scoper tweaks (docs/MOISTURE.md).
//

import XCTest
import simd

final class MoistureModelTests: XCTestCase {

    private func floorWet(_ r: MoistResult, room: String) -> Double {
        r.report().floors.first { $0.roomId == room }?.wetArea.total ?? 0
    }

    private func face(_ rep: MoistReport, _ wall: String, _ side: MoistSide) -> MoistFaceReport? {
        rep.faces.first { $0.wallId == wall && $0.side == side }
    }

    // MARK: Physics

    func testCavityLeakInSharedWallWetsBothRooms() {
        var input = MoistFixtures.twoRooms(door: false)
        input.sources = [MoistSource(id: "s1", label: "Burst pipe in wall", type: .pipe, pos: MoistVec(4, 1.5), wallId: "wS", height: 0.8, side: .cavity)]
        let r = MoistModel.run(input)
        let rep = r.report()
        let a = face(rep, "wS", .a), b = face(rep, "wS", .b)
        XCTAssertGreaterThan(a?.wetArea.total ?? 0, 0.2)
        XCTAssertGreaterThan(b?.wetArea.total ?? 0, 0.2)
        XCTAssertGreaterThan(floorWet(r, room: "A"), 0.1)
        XCTAssertGreaterThan(floorWet(r, room: "B"), 0.1)
        // Symmetric wall, symmetric result.
        XCTAssertEqual(a?.wetArea.total ?? 0, b?.wetArea.total ?? 1, accuracy: 0.15 * max(a?.wetArea.total ?? 0, 0.1))
        XCTAssertGreaterThan(rep.cavities.first { $0.wallId == "wS" }?.wetLength ?? 0, 0.5)
        // Everything here is physics only.
        XCTAssertEqual(rep.totals.wallLining.measured, 0)
        XCTAssertGreaterThan(rep.totals.wallLining.estimated, 0)
        XCTAssertEqual(r.state(r.grid.floorCell(at: MoistVec(0.3, 0.3))!), .dry)
    }

    func testTiledShowerFaceStaysDrierThanBedroomFace() {
        let input = MoisturePlan.input(plan: MoistFixtures.ensuitePlan(readings: false))
        var tiled = input
        tiled.tweaks = [MoistTweak(id: "t1", kind: .lining, wallId: "wS", side: .a, value: "tiled")]
        for inp in [input, tiled] {
            let r = MoistModel.run(inp)
            let rep = r.report()
            let ens = face(rep, "wS", .a)?.wetArea.total ?? 0
            let bed = face(rep, "wS", .b)?.wetArea.total ?? 0
            if inp.tweaks.isEmpty {
                XCTAssertEqual(face(rep, "wS", .a)?.lining, "plasterboard")
            } else {
                XCTAssertEqual(face(rep, "wS", .a)?.lining, "tiled")
                XCTAssertGreaterThan(bed, 0.2)
                XCTAssertLessThan(ens, bed * 0.5, "tiled \(ens) vs bedroom \(bed)")
                // And the ensuite tiles stay drier than the bedroom carpet.
                XCTAssertLessThan(r.wetness(floor: MoistVec(1.9, 0.5)) ?? 1, r.wetness(floor: MoistVec(2.1, 0.5)) ?? 0)
            }
        }
    }

    func testCarpetSpreadsFurtherThanTile() {
        var areas: [MoistCovering: Double] = [:]
        var reach: [MoistCovering: Double] = [:]
        for cov in [MoistCovering.carpet, .tile, .vinyl] {
            var input = MoistFixtures.oneRoom(cov)
            input.sources = [MoistFixtures.floorSource(MoistVec(1.5, 2.0))]
            let r = MoistModel.run(input)
            areas[cov] = floorWet(r, room: "r1")
            var x = 1.5
            while x < 6, (r.wetness(floor: MoistVec(x, 2.05)) ?? 0) >= MoistScale.dampLevel { x += 0.1 }
            reach[cov] = x - 1.5
        }
        XCTAssertGreaterThan(areas[.carpet]!, areas[.tile]! * 1.2, "carpet \(areas[.carpet]!) tile \(areas[.tile]!)")
        XCTAssertGreaterThan(reach[.carpet]!, reach[.tile]!)
        XCTAssertGreaterThan(areas[.tile]!, 0.5)
    }

    func testDoorwayThresholdReducesSpread() {
        var wetB: [String: Double] = [:]
        for type in ["none", "strip", "sealed"] {
            var input = MoistFixtures.twoRooms(door: true, covering: .vinyl)
            input.sources = [MoistFixtures.floorSource(MoistVec(3.2, 1.5))]
            input.floorThresholds = [MoistFloorThreshold(id: "t1", a: MoistVec(4, 1.1), b: MoistVec(4, 1.9), type: type)]
            wetB[type] = floorWet(MoistModel.run(input), room: "B")
        }
        XCTAssertGreaterThan(wetB["none"]!, 0.5)
        XCTAssertLessThan(wetB["strip"]!, wetB["none"]!)
        XCTAssertLessThan(wetB["sealed"]!, wetB["strip"]!)
        XCTAssertLessThan(wetB["sealed"]!, 0.3 * wetB["none"]!)
        // No door: nothing gets through the wall's floor line (only via the wall itself).
        var closed = MoistFixtures.twoRooms(door: false, covering: .vinyl)
        closed.sources = [MoistFixtures.floorSource(MoistVec(3.2, 1.5))]
        XCTAssertLessThan(floorWet(MoistModel.run(closed), room: "B"), wetB["none"]!)
    }

    // MARK: Readings

    func testDryReadingStopsSpread() {
        var input = MoistFixtures.oneRoom(.carpet)
        input.sources = [MoistFixtures.floorSource(MoistVec(1.5, 2.0))]
        let free = MoistModel.run(input)
        let p = MoistVec(3.6, 2.0)
        XCTAssertGreaterThanOrEqual(free.wetness(floor: p) ?? 0, MoistScale.dampLevel, "precondition: physics alone reaches \(p)")
        input.readings = [MoistFixtures.floorReading("m1", p, 10), MoistFixtures.floorReading("m2", MoistVec(1.6, 2.1), 35)]
        let fitted = MoistModel.run(input)
        XCTAssertTrue(fitted.fit.fitted)
        XCTAssertLessThan(fitted.wetness(floor: p) ?? 1, MoistScale.dampLevel)
        XCTAssertLessThan(fitted.wetness(floor: MoistVec(4.2, 2.0)) ?? 1, MoistScale.dampLevel)
        XCTAssertLessThan(floorWet(fitted, room: "r1"), floorWet(free, room: "r1"))
        XCTAssertGreaterThanOrEqual(fitted.wetness(floor: MoistVec(1.6, 2.1)) ?? 0, MoistScale.wetLevel)
        XCTAssertLessThan(fitted.params.volumes["s1"] ?? 99, free.params.volumes["s1"] ?? 0)
        if let c = fitted.grid.floorCell(at: p) { XCTAssertEqual(fitted.provenance[c], .measured) }
        XCTAssertTrue(fitted.fit.checks.allSatisfy { $0.explained })
    }

    func testWetReadingFarFromSourceFlagsSecondSource() {
        var input = MoistFixtures.twoRooms(door: true, covering: .carpet)
        input.sources = [MoistFixtures.floorSource(MoistVec(1.0, 1.5), intensity: nil)]
        input.readings = [MoistFixtures.floorReading("m1", MoistVec(1.2, 1.5), 30),
                          MoistFixtures.floorReading("m2", MoistVec(3.2, 1.5), 10),
                          MoistFixtures.floorReading("m3", MoistVec(5.0, 1.5), 11)]
        var far = MoistReading(id: "m4", n: 4, pos: MoistVec(8, 2.0))
        far.value = 30; far.wallId = "e"; far.height = 0.05; far.material = "skirting"
        input.readings.append(far)
        let r = MoistModel.run(input)
        #if DEBUG
        print("\n===== SECOND SOURCE =====")
        print(MoistDebug.summary(r, r.report()))
        print(MoistDebug.floor(r))
        #endif
        XCTAssertTrue(r.secondSourceLikely)
        let hint = r.hints.first
        XCTAssertEqual(hint?.readingIds, ["m4"])
        XCTAssertEqual(hint?.roomId, "B")
        XCTAssertEqual(hint?.wallId, "e")
        XCTAssertGreaterThan(hint?.improvement ?? 0, 0.3)
        XCTAssertTrue(hint?.message.contains("second source") ?? false)
        XCTAssertFalse(r.fit.checks.first { $0.readingId == "m4" }?.explained ?? true)
        // The estimate is pulled out to the reading anyway: wet there and around it.
        XCTAssertGreaterThanOrEqual(r.wetness(wall: "e", side: .a, along: 2.0, height: 0.05) ?? 0, MoistScale.wetLevel)
        XCTAssertGreaterThanOrEqual(r.wetness(wall: "e", side: .a, along: 2.25, height: 0.05) ?? 0, MoistScale.dampLevel)
        // Dry readings stay dry.
        XCTAssertLessThan(r.wetness(floor: MoistVec(5.0, 1.5)) ?? 1, MoistScale.dampLevel)
    }

    func testWetReadingsWithNoSourceSayWhereOneIs() {
        var input = MoistFixtures.oneRoom(.timber)
        input.readings = [MoistFixtures.floorReading("m1", MoistVec(4, 2), 28)]
        let r = MoistModel.run(input)
        XCTAssertEqual(r.hints.count, 1)
        XCTAssertTrue(r.hints[0].message.hasPrefix("No water source is marked"))
        XCTAssertGreaterThanOrEqual(r.wetness(floor: MoistVec(4, 2)) ?? 0, MoistScale.wetLevel)
        XCTAssertLessThan(r.wetness(floor: MoistVec(1, 1)) ?? 1, MoistScale.dampLevel)
    }

    func testMoistureLineMarksSetTheTideLine() {
        var input = MoistFixtures.oneRoom(.timber)
        input.sources = [MoistFixtures.floorSource(MoistVec(3, 0.3), intensity: 0.35)]
        // Tape marks on wall w1 (0,0)->(6,0): side a faces +y? normal of +x is (0, 1): yes, into the room.
        for (k, s) in [2.0, 3.0, 4.0].enumerated() {
            var b = MoistReading(id: "b\(k)", kind: .boundary, pos: MoistVec(s, 0))
            b.wallId = "w1"; b.height = 0.7; b.material = "wall"
            input.readings.append(b)
        }
        let rep = MoistModel.run(input).report()
        let f = face(rep, "w1", .a)
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.maxHeight ?? 0, 0.7, accuracy: 0.2)
    }

    // MARK: Scoper

    func testScoperBrushOverrides() {
        var input = MoistFixtures.oneRoom(.carpet)
        input.sources = [MoistFixtures.floorSource(MoistVec(1.5, 2.0))]
        let base = MoistModel.run(input)
        let wetSpot = MoistVec(2.0, 2.0), drySpot = MoistVec(5.5, 3.5)
        XCTAssertGreaterThanOrEqual(base.wetness(floor: wetSpot) ?? 0, MoistScale.wetLevel)
        XCTAssertLessThan(base.wetness(floor: drySpot) ?? 1, MoistScale.dampLevel)
        input.tweaks = [MoistTweak(id: "k1", kind: .brush, surface: .floor, points: [wetSpot], radius: 0.3, state: .dry),
                        MoistTweak(id: "k2", kind: .brush, surface: .floor, points: [drySpot, drySpot + MoistVec(-0.3, 0)], radius: 0.25, state: .wet)]
        let r = MoistModel.run(input)
        XCTAssertLessThan(r.wetness(floor: wetSpot) ?? 1, MoistScale.dampLevel)
        XCTAssertGreaterThanOrEqual(r.wetness(floor: drySpot) ?? 0, MoistScale.wetLevel)
        for p in [wetSpot, drySpot] {
            guard let c = r.grid.floorCell(at: p) else { return XCTFail("no cell at \(p)") }
            XCTAssertEqual(r.provenance[c], .scoper)
        }
        XCTAssertGreaterThan(r.report().totals.floor.scoper, 0.1)
        // A wall brush.
        var wall = input
        wall.tweaks = [MoistTweak(id: "k3", kind: .brush, surface: .face, wallId: "w3", side: .a, points: [MoistVec(3, 0.9)], radius: 0.2, state: .wet)]
        let rw = MoistModel.run(wall)
        XCTAssertGreaterThanOrEqual(rw.wetness(wall: "w3", side: .a, along: 3, height: 0.9) ?? 0, MoistScale.wetLevel)
    }

    func testScoperTideLineAndBarrierAndIntensity() {
        // Tide line dragged to 0.9 m on wall w1.
        var input = MoistFixtures.oneRoom(.carpet)
        input.sources = [MoistFixtures.floorSource(MoistVec(3, 0.4))]
        input.tweaks = [MoistTweak(id: "k1", kind: .tideLine, wallId: "w1", side: .a, points: [MoistVec(1.5, 0.9), MoistVec(4.5, 0.9)])]
        let rep = MoistModel.run(input).report()
        XCTAssertEqual(face(rep, "w1", .a)?.maxHeight ?? 0, 0.9, accuracy: 0.15)

        // A barrier across the room stops the spread.
        var b = MoistFixtures.oneRoom(.carpet)
        b.sources = [MoistFixtures.floorSource(MoistVec(1.5, 2.0))]
        let open = MoistModel.run(b)
        XCTAssertGreaterThanOrEqual(open.wetness(floor: MoistVec(3.4, 2.0)) ?? 0, MoistScale.dampLevel)
        b.tweaks = [MoistTweak(id: "k2", kind: .barrier, points: [MoistVec(3.0, 0), MoistVec(3.0, 4)])]
        let blocked = MoistModel.run(b)
        XCTAssertLessThan(blocked.wetness(floor: MoistVec(3.4, 2.0)) ?? 1, MoistScale.dampLevel)

        // Source intensity set by the scoper: heavy spreads further than light.
        var light = MoistFixtures.oneRoom(.carpet)
        light.sources = [MoistFixtures.floorSource(MoistVec(3, 2))]
        var heavy = light
        light.tweaks = [MoistTweak(id: "k3", kind: .source, sourceId: "s1", intensity: 0.35)]
        heavy.tweaks = [MoistTweak(id: "k3", kind: .source, sourceId: "s1", intensity: 3)]
        XCTAssertGreaterThan(floorWet(MoistModel.run(heavy), room: "r1"), floorWet(MoistModel.run(light), room: "r1") * 1.5)
    }

    // MARK: Determinism and speed

    func testSameInputSameOutput() {
        let input = MoisturePlan.input(plan: MoistFixtures.ensuitePlan())
        let a = MoistModel.run(input), b = MoistModel.run(input)
        XCTAssertEqual(a.wetness, b.wetness)
        XCTAssertEqual(a.provenance, b.provenance)
        XCTAssertEqual(a.params, b.params)
        XCTAssertEqual(a.report(), b.report())
        XCTAssertEqual(a.hints, b.hints)
    }

    func testSpeedOnFiveRoomHouse() {
        let input = MoistFixtures.house()
        _ = MoistModel.run(input)                       // warm up
        let t0 = Date()
        let r = MoistModel.run(input)
        let rep = r.report()
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "\n===== 5-ROOM HOUSE: %.1f ms (%ld cells) =====", ms, r.grid.count))
        print(MoistDebug.summary(r, rep))
        #if DEBUG
        print(MoistDebug.floor(r))
        // Unoptimised test build on a CI simulator; the phone target is < 50 ms in a release build.
        XCTAssertLessThan(ms, 4000)
        #else
        XCTAssertLessThan(ms, 50)
        #endif
        XCTAssertGreaterThan(r.grid.count, 10000)
        XCTAssertGreaterThan(rep.totals.floor.total, 1)
        XCTAssertLessThan(r.wetness(floor: MoistVec(3.0, 2.0)) ?? 1, MoistScale.dampLevel)
    }

    // MARK: Pieces

    func testScale() {
        let s = MoistScale(thresholds: MoistThresholds(damp: 15, wet: 20))
        XCTAssertEqual(s.wetness(15), MoistScale.dampLevel, accuracy: 1e-9)
        XCTAssertEqual(s.wetness(20), MoistScale.wetLevel, accuracy: 1e-9)
        XCTAssertEqual(s.wetness(8), 0)
        XCTAssertEqual(s.wetness(60), 1)
        for v in stride(from: 9.0, to: 40, by: 0.5) {
            XCTAssertLessThanOrEqual(s.wetness(v), s.wetness(v + 0.5))
            XCTAssertEqual(s.value(s.wetness(v)), v, accuracy: 1e-6)
        }
        XCTAssertEqual(MoistScale.state(s.wetness(18)), .damp)
        XCTAssertEqual(s.state(value: 18), .damp)
        XCTAssertEqual(MoistShapesMath.cutHeightMm(tide: 0.25), 600)
        XCTAssertEqual(MoistShapesMath.cutHeightMm(tide: 0.45), 900)
        XCTAssertEqual(MoistShapesMath.cutHeightMm(tide: 0.85), 1200)
        XCTAssertEqual(MoistSourceType.infer("Burst flexi hose"), .flexiHose)
        XCTAssertEqual(MoistSourceType.infer("Shower mixer"), .shower)
        XCTAssertEqual(MoistSourceType.infer("Burst pipe"), .pipe)
        XCTAssertEqual(MoistSide.parse(-1), .b)
        XCTAssertEqual(MoistSide.parse("cavity"), .cavity)
        XCTAssertEqual(MoistCovering.parse("Carpet + underlay"), .carpet)
    }

    func testMarchingSquares() {
        // A 3 x 2 block of wet cells in a 6 x 5 grid.
        var v = Array(repeating: 0.0, count: 30)
        for j in 1...2 { for i in 1...3 { v[j * 6 + i] = 1 } }
        let loops = MoistShapesMath.contours(v, nx: 6, ny: 5, iso: 0.5)
        XCTAssertEqual(loops.count, 1)
        // Iso 0.5 halfway between centres: the outline is the cells' own edges, cut at the corners.
        XCTAssertEqual(MoistGeom.area(loops[0]), 6 - 4 * 0.125, accuracy: 1e-6)
        // A dry hole in the middle of a wet block makes a second ring.
        var h = Array(repeating: 1.0, count: 25)
        h[12] = 0
        XCTAssertEqual(MoistShapesMath.contours(h, nx: 5, ny: 5, iso: 0.5).count, 2)
    }

    func testFloodFillsCheapestCellsFirst() {
        var input = MoistFixtures.oneRoom(.tile)
        input.sources = [MoistFixtures.floorSource(MoistVec(3, 2))]
        let g = MoistGrid(input: input, cellSize: 0.1)
        let start = g.floorCell(at: MoistVec(3, 2))!
        let cap = MoistMaterials.floor(.tile).capacity
        let f = MoistSolver.flood(g, start: start, litres: cap * 0.5)          // 0.5 m² of tile
        XCTAssertGreaterThanOrEqual(f.count, 50)
        XCTAssertEqual(f.first?.cell, start)
        let used = f.reduce(0.0) { $0 + $1.wet / MoistMaterials.floor(.tile).wetLevel * g.cells[$1.cell].capacity }
        XCTAssertEqual(used, cap * 0.5, accuracy: 1e-6)
        XCTAssertTrue(f.allSatisfy { simd_length(g.cells[$0.cell].pos - MoistVec(3, 2)) < 0.6 })
        // Water inside a wall falls to the plate first.
        var w = MoistFixtures.twoRooms(door: false)
        w.sources = []
        let gw = MoistGrid(input: w, cellSize: 0.1)
        let wi = w.walls.firstIndex { $0.id == "wS" }!
        let top = gw.wallCell(wall: wi, side: .cavity, along: 1.5, height: 1.0)!
        let ff = MoistSolver.flood(gw, start: top, litres: 0.05)
        XCTAssertTrue(ff.contains { gw.cells[$0.cell].row == 0 && gw.cells[$0.cell].surface == .cavity })
        XCTAssertFalse(ff.contains { gw.cells[$0.cell].z > 1.06 })
    }
}
