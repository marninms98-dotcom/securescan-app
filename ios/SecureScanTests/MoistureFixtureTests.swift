//
//  MoistureFixtureTests.swift
//  SecureScanTests
//
//  Fixtures for the moisture model, and the owner's real case: an ensuite and
//  a bedroom sharing a stud wall, the shower mixer leaking inside that wall,
//  wet readings along the bedroom skirting (18–31 %) and dry readings across
//  the bedroom (10–12 %). Prints text heatmaps into the test log so the result
//  can be read in CI without a phone.
//

import XCTest
import simd

enum MoistFixtures {

    static func wall(_ id: String, _ a: [Double], _ b: [Double]) -> [String: Any] { ["id": id, "a": a, "b": b, "height": 2.4] }
    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [[Double]] { [[x0, y0], [x1, y0], [x1, y1], [x0, y1]] }

    /// Ensuite x 0…2, y 0…2.4 (tiles); bedroom x 2…5.6, y 0…3.6 (carpet).
    /// Shared wall wS runs (2,0) -> (2,2.4): its normal is (-1, 0), so side
    /// "a" faces the ensuite and side "b" the bedroom. The ensuite door is in
    /// wS (1.5…2.3 m along). Shower in the ensuite corner against wS; the
    /// mixer leaks inside the wall 0.5 m along, 1.0 m up.
    static func ensuitePlan(readings: Bool = true) -> [String: Any] {
        let walls: [[String: Any]] = [
            wall("wS", [2, 0], [2, 2.4]),
            wall("wE1", [0, 0], [2, 0]), wall("wE2", [2, 2.4], [0, 2.4]), wall("wE3", [0, 2.4], [0, 0]),
            wall("wB1", [2, 0], [5.6, 0]), wall("wB2", [5.6, 0], [5.6, 3.6]), wall("wB3", [5.6, 3.6], [2, 3.6]), wall("wB4", [2, 3.6], [2, 2.4]),
        ]
        let openings: [[String: Any]] = [
            ["id": "o1", "type": "door", "wallId": "wS", "a": [2, 1.5], "b": [2, 2.3], "height": 2.04, "sill": 0],
            ["id": "o2", "type": "door", "wallId": "wB3", "a": [3.0, 3.6], "b": [3.82, 3.6], "height": 2.04, "sill": 0],
        ]
        let rooms: [[String: Any]] = [
            ["id": "r1", "name": "Ensuite", "polygon": rect(0, 0, 2, 2.4)],
            ["id": "r2", "name": "Bedroom", "polygon": [[2, 0], [5.6, 0], [5.6, 3.6], [2, 3.6]]],
        ]
        var rs: [[String: Any]] = []
        if readings {
            // Bedroom side of the shared wall, at the skirting (owner's readings 18–31 %).
            for (k, (y, v)) in [(0.2, 31.0), (0.6, 28.0), (1.0, 24.0), (1.4, 18.0)].enumerated() {
                rs.append(["id": "m\(k + 1)", "n": k + 1, "pos": [2, y], "wallId": "wS", "wallT": y / 2.4, "height": 0.05,
                           "side": "b", "material": "skirting", "value": v])
            }
            // The shower face beside the mixer, on the tiles: reads dry.
            rs.append(["id": "m5", "n": 5, "pos": [2, 0.5], "wallId": "wS", "wallT": 0.5 / 2.4, "height": 0.3, "side": "a",
                       "material": "wall tile", "value": 14])
            // Dry across the bedroom (10–12 %).
            rs.append(["id": "m6", "n": 6, "pos": [3.3, 1.0], "material": "floor", "value": 11])
            rs.append(["id": "m7", "n": 7, "pos": [4.5, 2.0], "material": "floor", "value": 10])
            rs.append(["id": "m8", "n": 8, "pos": [3.0, 3.1], "material": "floor", "value": 12])
            rs.append(["id": "m9", "n": 9, "pos": [5.6, 1.0], "wallId": "wB2", "wallT": 1.0 / 3.6, "height": 0.05, "side": "a",
                       "material": "skirting", "value": 10, "reference": true])
        }
        return [
            "version": 1, "id": "ensuite-case", "walls": walls, "openings": openings, "rooms": rooms, "objects": [],
            "markup": [
                "sources": [["id": "s1", "pos": [2, 0.5], "label": "Shower mixer", "wallId": "wS", "wallT": 0.5 / 2.4,
                             "height": 1.0, "side": "cavity"]],
                "readings": rs,
                "thresholds": ["damp": 15, "wet": 20],
                "floors": [["id": "f1", "polygon": rect(0, 0, 2, 2.4), "type": "tile"],
                           ["id": "f2", "polygon": rect(2, 0, 5.6, 3.6), "type": "carpet"]],
                "floorThresholds": [["id": "t1", "a": [2, 1.5], "b": [2, 2.3], "type": "strip"]],
                "affected": [], "removals": [],
            ] as [String: Any],
        ]
    }

    /// Two rooms side by side: A x 0…4, B x 4…8, y 0…3. Shared wall wS (4,0) -> (4,3):
    /// side a = room A, side b = room B. Optional door in wS at 1.1…1.9 m.
    static func twoRooms(door: Bool, covering: MoistCovering = .carpet, coveringB: MoistCovering? = nil) -> MoistInput {
        var input = MoistInput()
        func w(_ id: String, _ a: MoistVec, _ b: MoistVec) -> MoistWall { MoistWall(id: id, a: a, b: b, height: 2.4) }
        input.walls = [
            w("wS", MoistVec(4, 0), MoistVec(4, 3)),
            w("n1", MoistVec(0, 0), MoistVec(4, 0)), w("n2", MoistVec(4, 0), MoistVec(8, 0)),
            w("e", MoistVec(8, 0), MoistVec(8, 3)),
            w("s2", MoistVec(8, 3), MoistVec(4, 3)), w("s1", MoistVec(4, 3), MoistVec(0, 3)),
            w("west", MoistVec(0, 3), MoistVec(0, 0)),
        ]
        if door {
            input.openings = [MoistOpening(id: "d1", type: "door", wallId: "wS", a: MoistVec(4, 1.1), b: MoistVec(4, 1.9))]
        }
        input.rooms = [MoistRoom(id: "A", name: "Room A", polygon: [MoistVec(0, 0), MoistVec(4, 0), MoistVec(4, 3), MoistVec(0, 3)]),
                       MoistRoom(id: "B", name: "Room B", polygon: [MoistVec(4, 0), MoistVec(8, 0), MoistVec(8, 3), MoistVec(4, 3)])]
        input.floors = [MoistFloorZone(id: "fA", polygon: input.rooms[0].polygon, covering: covering),
                        MoistFloorZone(id: "fB", polygon: input.rooms[1].polygon, covering: coveringB ?? covering)]
        return input
    }

    /// One room x 0…6, y 0…4 with one covering.
    static func oneRoom(_ covering: MoistCovering) -> MoistInput {
        var input = MoistInput()
        let c = [MoistVec(0, 0), MoistVec(6, 0), MoistVec(6, 4), MoistVec(0, 4)]
        input.walls = (0..<4).map { MoistWall(id: "w\($0 + 1)", a: c[$0], b: c[($0 + 1) % 4], height: 2.4) }
        input.rooms = [MoistRoom(id: "r1", name: "Living", polygon: c)]
        input.floors = [MoistFloorZone(id: "f1", polygon: c, covering: covering)]
        return input
    }

    static func floorSource(_ id: String = "s1", _ p: MoistVec, _ type: MoistSourceType = .flexiHose, intensity: Double? = nil) -> MoistSource {
        var s = MoistSource(id: id, label: type.rawValue, type: type, pos: p)
        if let i = intensity { s.intensity = i; s.intensityFixed = true }
        return s
    }

    static func floorReading(_ id: String, _ p: MoistVec, _ v: Double) -> MoistReading {
        var r = MoistReading(id: id, pos: p)
        r.value = v
        r.material = "floor"
        return r
    }

    /// A synthetic 5-room house (9 x 7.5 m) for the speed test.
    static func house() -> MoistInput {
        var input = MoistInput()
        var k = 0
        func w(_ a: MoistVec, _ b: MoistVec) { k += 1; input.walls.append(MoistWall(id: "w\(k)", a: a, b: b, height: 2.4)) }
        w(MoistVec(0, 0), MoistVec(9, 0)); w(MoistVec(9, 0), MoistVec(9, 7.5)); w(MoistVec(9, 7.5), MoistVec(0, 7.5)); w(MoistVec(0, 7.5), MoistVec(0, 0))
        w(MoistVec(0, 4), MoistVec(4, 4)); w(MoistVec(4, 4), MoistVec(6.5, 4)); w(MoistVec(6.5, 4), MoistVec(9, 4))
        w(MoistVec(5, 0), MoistVec(5, 4)); w(MoistVec(4, 4), MoistVec(4, 7.5)); w(MoistVec(6.5, 4), MoistVec(6.5, 7.5))
        input.openings = [
            MoistOpening(id: "o1", type: "opening", wallId: "w8", a: MoistVec(5, 1), b: MoistVec(5, 2.5)),
            MoistOpening(id: "o2", type: "door", wallId: "w5", a: MoistVec(1, 4), b: MoistVec(1.8, 4)),
            MoistOpening(id: "o3", type: "door", wallId: "w6", a: MoistVec(4.5, 4), b: MoistVec(5.3, 4)),
            MoistOpening(id: "o4", type: "door", wallId: "w7", a: MoistVec(7.5, 4), b: MoistVec(8.3, 4)),
            MoistOpening(id: "o5", type: "window", wallId: "w1", a: MoistVec(1, 0), b: MoistVec(3, 0), sill: 0.9, height: 1.2),
        ]
        func room(_ id: String, _ name: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> MoistRoom {
            MoistRoom(id: id, name: name, polygon: [MoistVec(x0, y0), MoistVec(x1, y0), MoistVec(x1, y1), MoistVec(x0, y1)])
        }
        input.rooms = [room("living", "Living", 0, 0, 5, 4), room("kitchen", "Kitchen", 5, 0, 9, 4), room("bed1", "Bedroom 1", 0, 4, 4, 7.5),
                       room("bath", "Bathroom", 4, 4, 6.5, 7.5), room("bed2", "Bedroom 2", 6.5, 4, 9, 7.5)]
        input.floors = [
            MoistFloorZone(id: "f1", polygon: input.rooms[0].polygon, covering: .carpet),
            MoistFloorZone(id: "f2", polygon: input.rooms[1].polygon, covering: .vinyl),
            MoistFloorZone(id: "f3", polygon: input.rooms[2].polygon, covering: .carpet),
            MoistFloorZone(id: "f4", polygon: input.rooms[3].polygon, covering: .tile),
            MoistFloorZone(id: "f5", polygon: input.rooms[4].polygon, covering: .carpet),
        ]
        input.sources = [floorSource("s1", MoistVec(8.4, 0.6), .appliance)]
        input.readings = [floorReading("m1", MoistVec(8.0, 1.0), 32), floorReading("m2", MoistVec(6.0, 2.0), 22),
                          floorReading("m3", MoistVec(3.0, 2.0), 11), floorReading("m4", MoistVec(7.7, 5.5), 10),
                          floorReading("m5", MoistVec(5.5, 3.6), 12), floorReading("m6", MoistVec(6.0, 0.5), 25)]
        var wr = MoistReading(id: "m7", pos: MoistVec(9, 1.5))
        wr.value = 27; wr.wallId = "w2"; wr.height = 0.05; wr.material = "skirting"; wr.side = .a
        input.readings.append(wr)
        return input
    }
}

final class MoistureFixtureTests: XCTestCase {

    func solve(_ plan: [String: Any]) -> (MoistResult, MoistReport) {
        let r = MoistModel.run(MoisturePlan.input(plan: plan))
        return (r, r.report())
    }

    /// The owner's ensuite / bedroom case.
    func testEnsuiteShowerLeakOwnerCase() {
        let (r, rep) = solve(MoistFixtures.ensuitePlan())
        #if DEBUG
        print("\n===== ENSUITE CASE =====")
        print(MoistDebug.summary(r, rep))
        print(MoistDebug.wall(r, id: "wS"))
        print(MoistDebug.wall(r, id: "wS", provenance: true))
        print(MoistDebug.floor(r))
        print(MoistDebug.floor(r, provenance: true))
        #endif
        // Every reading is honoured by the final answer.
        let checks: [(String, MoistSide, Double, MoistState)] = [("m1", .b, 0.2, .wet), ("m2", .b, 0.6, .wet), ("m3", .b, 1.0, .wet), ("m4", .b, 1.4, .damp)]
        for (id, side, along, st) in checks {
            let w = r.wetness(wall: "wS", side: side, along: along, height: 0.05) ?? -1
            XCTAssertEqual(MoistScale.state(w), st, "reading \(id) at \(along) m: wetness \(w)")
        }
        for p in [MoistVec(3.3, 1.0), MoistVec(4.5, 2.0), MoistVec(3.0, 3.1)] {
            XCTAssertLessThan(r.wetness(floor: p) ?? 1, MoistScale.dampLevel, "dry reading at \(p)")
        }
        // Both sides of the shared wall are affected, the tiled shower face much less than the bedroom face.
        let bed = rep.faces.first { $0.wallId == "wS" && $0.side == .b }
        let ens = rep.faces.first { $0.wallId == "wS" && $0.side == .a }
        XCTAssertNotNil(bed); XCTAssertNotNil(ens)
        XCTAssertEqual(ens?.lining, "tiled")
        XCTAssertGreaterThan(bed?.wetArea.total ?? 0, 0.3)
        XCTAssertGreaterThan(bed?.wetArea.total ?? 0, 2 * (ens?.wetArea.total ?? 0))
        XCTAssertGreaterThan(bed?.wetArea.measured ?? 0, 0)
        // A tide line on the bedroom face, between skirting height and 1 m.
        XCTAssertFalse(bed?.tideLine.isEmpty ?? true)
        XCTAssertGreaterThan(bed?.maxHeight ?? 0, 0.15)
        XCTAssertLessThan(bed?.maxHeight ?? 2, 1.05)
        // Wet inside the wall under the mixer.
        let cav = rep.cavities.first { $0.wallId == "wS" }
        XCTAssertNotNil(cav)
        XCTAssertGreaterThan(cav?.wetLength ?? 0, 0.5)
        // Bedroom carpet wet along the wall, not across the room.
        let bedFloor = rep.floors.first { $0.roomId == "r2" }
        XCTAssertNotNil(bedFloor)
        XCTAssertGreaterThan(bedFloor?.wetArea.total ?? 0, 0.2)
        XCTAssertLessThan(bedFloor?.wetArea.total ?? 99, 6)
        XCTAssertGreaterThan(r.wetness(floor: MoistVec(2.1, 0.5)) ?? 0, MoistScale.dampLevel)
        // A strip-out suggestion on the bedroom side at 600 or 900, skirting along the wet run.
        let strip = rep.suggestions.first { $0.kind == .stripLining && $0.wallId == "wS" && $0.side == .b }
        XCTAssertNotNil(strip)
        XCTAssertTrue([600, 900].contains(strip?.cutHeightMm ?? 0), "cut \(String(describing: strip?.cutHeightMm))")
        XCTAssertTrue(rep.suggestions.contains { $0.kind == .removeSkirting && $0.wallId == "wS" && $0.side == .b })
        XCTAssertFalse(rep.suggestions.contains { $0.kind == .stripLining && $0.side == .a && $0.wallId == "wS" })
        // The readings are explained by the one source.
        XCTAssertTrue(r.hints.isEmpty, r.hints.map { $0.message }.joined(separator: "; "))
        // Measured and estimated are kept apart.
        XCTAssertGreaterThan(rep.totals.wallLining.estimated + rep.totals.floor.estimated, 0)
        XCTAssertGreaterThan(rep.totals.wallLining.measured, 0)
    }

    /// plan.json in, markup.moistureModel out, tweaks round trip, hash stable.
    func testPlanRoundTrip() {
        var plan = MoistFixtures.ensuitePlan()
        let brush = MoistTweak(id: "k1", kind: .brush, surface: .floor, points: [MoistVec(4.0, 0.5)], radius: 0.3, state: .wet)
        plan = MoisturePlan.adding(brush, to: plan)
        let input = MoisturePlan.input(plan: plan)
        XCTAssertEqual(input.walls.count, 8)
        XCTAssertEqual(input.rooms.count, 2)
        XCTAssertEqual(input.readings.count, 9)
        XCTAssertEqual(input.sources.first?.type, .shower)
        XCTAssertEqual(input.sources.first?.side, .cavity)
        XCTAssertEqual(input.tweaks, [brush])
        XCTAssertEqual(input.readings.first { $0.id == "m5" }?.isTiled, true)
        let r = MoistModel.run(input)
        let rep = r.report()
        let json = MoisturePlan.modelJSON(r, report: rep)
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual((json["tweaks"] as? [[String: Any]])?.compactMap(MoisturePlan.tweak), [brush])
        let solved = json["solved"] as? [String: Any]
        XCTAssertEqual(solved?["inputsHash"] as? String, MoisturePlan.inputsHash(input))
        XCTAssertNotNil(solved?["faces"] as? [[String: Any]])
        XCTAssertFalse((solved?["suggestions"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        // Same plan read again -> same hash; a changed reading -> a different one.
        XCTAssertEqual(MoisturePlan.inputsHash(MoisturePlan.input(plan: plan)), MoisturePlan.inputsHash(input))
        var other = input
        other.readings[0].value = 30
        XCTAssertNotEqual(MoisturePlan.inputsHash(other), MoisturePlan.inputsHash(input))
        // The brush is honoured and labelled.
        XCTAssertGreaterThanOrEqual(r.wetness(floor: MoistVec(4.0, 0.5)) ?? 0, 0.5)
        if let c = r.grid.floorCell(at: MoistVec(4.0, 0.5)) { XCTAssertEqual(r.provenance[c], .scoper) } else { XCTFail("no cell") }
    }

    /// Readings for a later visit come from `history`; marks from that visit only.
    func testVisitReadings() {
        var plan = MoistFixtures.ensuitePlan()
        var markup = plan["markup"] as! [String: Any]
        var rs = markup["readings"] as! [[String: Any]]
        rs[0]["history"] = [["visit": "v1", "value": 31], ["visit": "v2", "value": 16]]
        rs.append(["id": "b1", "kind": "boundary", "pos": [2, 0.3], "wallId": "wS", "height": 0.4, "side": "b", "visit": "v2", "value": NSNull()])
        rs.append(["id": "b0", "kind": "boundary", "pos": [2, 0.3], "wallId": "wS", "height": 0.7, "side": "b", "value": NSNull()])
        markup["readings"] = rs
        markup["visits"] = [["id": "v1", "n": 1], ["id": "v2", "n": 2]]
        plan["markup"] = markup
        let v2 = MoisturePlan.input(plan: plan, visit: "v2")
        XCTAssertEqual(v2.readings.filter { $0.kind == .reading }.map { $0.id }, ["m1"])
        XCTAssertEqual(v2.readings.first?.value, 16)
        XCTAssertEqual(v2.readings.filter { $0.kind == .boundary }.map { $0.id }, ["b1"])
        let latest = MoisturePlan.input(plan: plan)
        XCTAssertEqual(latest.readings.filter { $0.kind == .boundary }.map { $0.id }, ["b1"])
        let v1 = MoisturePlan.input(plan: plan, visit: "v1")
        XCTAssertEqual(v1.readings.first { $0.id == "m1" }?.value, 31)
        XCTAssertEqual(v1.readings.filter { $0.kind == .boundary }.map { $0.id }, ["b0"])
    }
}
