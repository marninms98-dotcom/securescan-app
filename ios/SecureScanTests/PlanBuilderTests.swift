//
//  PlanBuilderTests.swift
//  SecureScanTests
//
//  Pure-maths tests. This target compiles PlanBuilder.swift, PlanDocument.swift,
//  AddressFormatter.swift and SimulatedScan.swift directly (no app host, no
//  RoomPlan), so it runs on any simulator.
//

import XCTest
import simd

final class PlanBuilderTests: XCTestCase {

    // MARK: Helpers

    /// RoomPlan-style wall from plan points (planY = worldZ), centred at mid height.
    func wall(_ a: PlanVec, _ b: PlanVec, height: Double = 2.4, floorY: Double = 0, id: Int) -> PBSurface {
        let mid = (a + b) / 2
        let centre = WorldVec(mid.x, floorY + height / 2, mid.y)
        return PBSurface(id: SimulatedScan.uuid(id), parentId: nil,
                         transform: SimulatedScan.surfaceTransform(centre: centre, dir: b - a),
                         dimensions: SIMD3<Float>(Float(simd_length(b - a)), Float(height), 0))
    }

    func rotated(_ p: PlanVec, degrees: Double, about c: PlanVec = .zero) -> PlanVec {
        let a = degrees * .pi / 180
        let v = p - c
        return c + PlanVec(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y)
    }

    func isAxisAligned(_ w: PlanWall) -> Bool { w.a.x == w.b.x || w.a.y == w.b.y }

    // MARK: Rectangle rotated 30 degrees

    func testRotatedRectangleBecomesAxisAligned() {
        let base: [PlanVec] = [[0, 0], [3.45, 0], [3.45, 2.8], [0, 2.8]]
        let corners = base.map { rotated($0 + PlanVec(1.7, -0.6), degrees: 30) }
        var room = PBRoom()
        for i in 0..<4 { room.walls.append(wall(corners[i], corners[(i + 1) % 4], id: i + 1)) }

        let g = PlanBuilder.build(rooms: [room], readings: [])

        XCTAssertEqual(g.walls.count, 4)
        for w in g.walls { XCTAssertTrue(isAxisAligned(w), "\(w.id) not axis-aligned: \(w.a) \(w.b)") }
        let lengths = g.walls.map(\.length).sorted()
        XCTAssertEqual(lengths[0], 2.8, accuracy: 0.002)
        XCTAssertEqual(lengths[1], 2.8, accuracy: 0.002)
        XCTAssertEqual(lengths[2], 3.45, accuracy: 0.002)
        XCTAssertEqual(lengths[3], 3.45, accuracy: 0.002)
        XCTAssertEqual(g.rooms.count, 1)
        XCTAssertEqual(g.rooms[0].area, 3.45 * 2.8, accuracy: 0.01)
        XCTAssertEqual(g.rooms[0].name, "Room 1")
        let xs = g.walls.flatMap { [$0.a.x, $0.b.x] }, ys = g.walls.flatMap { [$0.a.y, $0.b.y] }
        XCTAssertEqual(xs.min()!, 0, accuracy: 1e-9)
        XCTAssertEqual(ys.min()!, 0, accuracy: 1e-9)
        XCTAssertEqual(g.transform.angle * 180 / .pi, -30, accuracy: 0.01)
    }

    func testDominantAngleRotatesTheShortWay() {
        // Walls at 80 / 170 degrees should be rotated +10 degrees, not -80.
        let a = PlanBuilder.dominantAngle([(PlanVec(0, 0), rotated([4, 0], degrees: 80)),
                                           (PlanVec(0, 0), rotated([3, 0], degrees: 170))])
        XCTAssertEqual(a * 180 / .pi, -10, accuracy: 0.01)
    }

    // MARK: Reading on a known wall

    func testReadingSixtyCentimetresUpAKnownWall() {
        let c: [PlanVec] = [[0, 0], [3.45, 0], [3.45, 2.8], [0, 2.8]]
        var room = PBRoom()
        for i in 0..<4 { room.walls.append(wall(c[i], c[(i + 1) % 4], id: i + 1)) }
        // Camera 1.0 m from wall w1 (z = 0), 1.5 m high, aimed at (1.2, 0.6, 0).
        let cam = WorldVec(1.2, 1.5, 1.0)
        let target = WorldVec(1.2, 0.6, 0)
        let r = PBReading(id: "m1", seq: 1, value: 24.5, material: "wall", takenAt: "2026-11-12T00:00:00Z",
                          cameraPosition: cam, cameraForward: simd_normalize(target - cam))

        let g = PlanBuilder.build(rooms: [room], readings: [r])
        let out = g.readings[0]
        XCTAssertEqual(out.wallId, "w1")
        XCTAssertEqual(out.wallT ?? -1, 1.2 / 3.45, accuracy: 0.001)
        XCTAssertEqual(out.height ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(out.pos.x, 1.2, accuracy: 0.001)
        XCTAssertEqual(out.pos.y, 0, accuracy: 0.001)
        XCTAssertEqual(out.n, 1)
        XCTAssertEqual(out.kind, "reading")
    }

    func testFloorReadingIsNotSnappedAndRaycastFallbackSnaps() {
        let c: [PlanVec] = [[0, 0], [3, 0], [3, 3], [0, 3]]
        var room = PBRoom()
        for i in 0..<4 { room.walls.append(wall(c[i], c[(i + 1) % 4], id: i + 1)) }
        // Looking straight down at the floor 0.2 m from wall w4 (x = 0).
        let floorReading = PBReading(id: "f", seq: 1, value: 30, material: "floor", takenAt: "",
                                     cameraPosition: [0.2, 1.4, 1.5], cameraForward: [0, -1, 0], hit: [0.2, 0, 1.5])
        // Skirting: ray would pass below the floor before reaching a wall, so the
        // raycast hit is used and then snapped to w4.
        let cam = WorldVec(1.5, 1.4, 1.5), hit = WorldVec(0.05, 0.04, 1.5)
        let skirting = PBReading(id: "s", seq: 2, value: 22, material: "skirting", takenAt: "",
                                 cameraPosition: cam, cameraForward: simd_normalize(WorldVec(0.05, -0.2, 1.5) - cam), hit: hit)
        let g = PlanBuilder.build(rooms: [room], readings: [floorReading, skirting])
        XCTAssertNil(g.readings[0].wallId)
        XCTAssertEqual(g.readings[0].height ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(g.readings[1].wallId, "w4")
        XCTAssertEqual(g.readings[1].height ?? -1, 0.04, accuracy: 0.001)
        XCTAssertEqual(g.readings[1].wallT ?? -1, 0.5, accuracy: 0.001)    // w4 runs (0,3) -> (0,0)
    }

    // MARK: Simulated 3-room house (whole pipeline, deliberately imperfect input)

    func testSimulatedHouse() {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())

        // Walls: count, axis-aligned, true lengths within 2 cm.
        XCTAssertEqual(g.walls.count, SimulatedScan.trueWalls.count)
        for (i, w) in g.walls.enumerated() {
            XCTAssertEqual(w.id, "w\(i + 1)")
            XCTAssertTrue(isAxisAligned(w), "\(w.id) not axis-aligned")
            let t = SimulatedScan.trueWalls[i]
            XCTAssertEqual(w.length, simd_length(t.b - t.a), accuracy: 0.02, "\(w.id) length")
        }

        // Corners closed: within each room every endpoint is shared, exactly, with one other wall.
        for room in 0..<3 {
            let ws = g.walls.filter { $0.roomIndex == room }
            for w in ws {
                for p in [w.a, w.b] {
                    let matches = ws.filter { $0.id != w.id && ($0.a == p || $0.b == p) }.count
                    XCTAssertEqual(matches, 1, "room \(room + 1) \(w.id) endpoint \(p) shared by \(matches)")
                }
            }
        }

        // Rooms: areas within 2 %, names.
        XCTAssertEqual(g.rooms.count, 3)
        for (i, r) in g.rooms.enumerated() {
            XCTAssertEqual(r.area, SimulatedScan.trueRoomAreas[i], accuracy: SimulatedScan.trueRoomAreas[i] * 0.02, "room \(i + 1) area")
        }
        XCTAssertEqual(g.rooms[0].name, "Bedroom")
        XCTAssertEqual(g.rooms[1].name, "Room 2")
        XCTAssertEqual(g.rooms[2].polygon.count, 6)      // L-shaped hallway, from wall chaining

        // Openings attached to the right walls; window sill.
        XCTAssertEqual(g.openings.map { $0.wallId ?? "nil" }, SimulatedScan.expectedOpeningWalls)
        XCTAssertEqual(g.openings[1].type, "window")
        XCTAssertEqual(g.openings[1].sill, 0.9, accuracy: 0.01)
        for o in g.openings {
            let w = g.walls.first { $0.id == o.wallId }!
            XCTAssertLessThan(PlanBuilder.distanceToSegment(o.a, w.a, w.b), 1e-6)
            XCTAssertLessThan(PlanBuilder.distanceToSegment(o.b, w.a, w.b), 1e-6)
        }
        XCTAssertEqual(g.objects.map(\.category), ["bed", "washerDryer", "storage"])

        // Readings, moisture-line marks, the photo note and the AR source.
        let expected = SimulatedScan.expected
        XCTAssertEqual(g.readings.map(\.id), expected.filter { !["source", "equipment", "removal", "floorType"].contains($0.kind) }.map(\.id))
        XCTAssertEqual(g.sources.map(\.id), expected.filter { $0.kind == "source" }.map(\.id))
        XCTAssertEqual(g.equipment.map(\.id), ["sim-e1", "sim-e2", "sim-e3"])
        XCTAssertEqual(g.equipment.map(\.material), ["airMover", "airMover", "dehumidifier"])
        XCTAssertTrue(g.equipment.allSatisfy { $0.wallId == nil && $0.n == nil })
        let all = g.readings + g.sources + g.equipment
        for e in expected where e.kind != "removal" && e.kind != "floorType" {
            guard let r = all.first(where: { $0.id == e.id }) else { XCTFail("missing \(e.id)"); continue }
            XCTAssertEqual(r.id, e.id)
            XCTAssertEqual(r.kind, e.kind, e.id)
            XCTAssertEqual(r.n, e.n, "\(e.id) number")
            XCTAssertEqual(r.wallId, e.wallId, "\(e.id) wall")
            if let et = e.wallT { XCTAssertEqual(r.wallT ?? -1, et, accuracy: 0.03, "\(e.id) wallT") }
            XCTAssertEqual(r.height ?? -1, e.height, accuracy: 0.02, "\(e.id) height")
            XCTAssertEqual(simd_distance(r.pos, e.plan), 0, accuracy: 0.03, "\(e.id) position")
            if e.kind != "reading" { XCTAssertNil(r.value) }
            // Camera position at capture, in plan coordinates.
            XCTAssertEqual(simd_distance(r.cam ?? PlanVec(-99, -99), e.camera), 0, accuracy: 0.03, "\(e.id) cam")
        }
        XCTAssertEqual(g.readings.filter { $0.kind == "boundary" }.count, 4)
        XCTAssertTrue(g.readings.filter { $0.kind == "boundary" }.allSatisfy { $0.wallId == "w2" })
        XCTAssertEqual(g.sources.first?.wallId, "w5")
        XCTAssertNil(g.sources.first?.n)
        XCTAssertEqual(g.sources.first?.note, "Flexi hose")
        XCTAssertEqual(g.readings.first { $0.kind == "photo" }?.n, 1)
        XCTAssertEqual(g.readings.last?.reference, true)
    }

    // MARK: Regenerate keeps the editor's work

    func testMergeKeepsMarkupNamesAndReadingEdits() throws {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        var doc = PlanDocument.newDocument(id: "J", address: "1 Demo St", jobRef: "", createdAt: Date(timeIntervalSince1970: 0),
                                           now: Date(timeIntervalSince1970: 0), geometry: g)
        // Simulate editor edits.
        var rooms = doc["rooms"] as! [[String: Any]]
        rooms[1]["name"] = "Laundry"
        doc["rooms"] = rooms
        doc["address"] = "30 Sample Cr, Testwood, WA"
        var markup = doc["markup"] as! [String: Any]
        markup["meter"] = "Ozito digital moisture meter"
        markup["sources"] = [["id": "s1", "pos": [4.0, 1.0], "label": "Burst flexi hose"]] as [[String: Any]]
        var readings = markup["readings"] as! [[String: Any]]
        readings[0]["value"] = 26.0
        readings[0]["note"] = "behind washing machine"
        readings[0]["pos"] = [9.0, 9.0]                       // geometry: app-owned, will be rebuilt
        readings.remove(at: 2)                                 // sim-03 tape mark missing from the doc
        readings.append(["id": "m-manual", "n": 99, "value": 15, "material": "wall", "pos": [1.0, 1.0], "source": "manual"])
        markup["readings"] = readings
        doc["markup"] = markup

        let merged = PlanDocument.merged(existing: doc, geometry: g)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(merged))
        _ = try PlanDocument.data(merged)

        XCTAssertEqual(merged["address"] as? String, "30 Sample Cr, Testwood, WA")
        XCTAssertEqual((merged["rooms"] as! [[String: Any]])[1]["name"] as? String, "Laundry")
        let mm = merged["markup"] as! [String: Any]
        XCTAssertEqual(mm["meter"] as? String, "Ozito digital moisture meter")
        let sources = mm["sources"] as! [[String: Any]]
        XCTAssertEqual(sources.count, 2)                       // manual one kept + the AR one
        XCTAssertEqual(sources[0]["label"] as? String, "Burst flexi hose")
        XCTAssertEqual(sources[1]["id"] as? String, "sim-src")
        XCTAssertEqual(sources[1]["source"] as? String, "ar")
        XCTAssertEqual(sources[1]["wallId"] as? String, "w5")
        XCTAssertNotNil(sources[1]["cam"])
        let out = mm["readings"] as! [[String: Any]]
        let first = out.first { $0["id"] as? String == "sim-01" }!
        XCTAssertEqual(PlanDocument.number(first["value"]), 26.0)
        XCTAssertEqual(first["note"] as? String, "behind washing machine")
        XCTAssertNotEqual((first["pos"] as! [Double])[0], 9.0)
        XCTAssertEqual(first["wallId"] as? String, "w2")
        XCTAssertNotNil(out.first { $0["id"] as? String == "m-manual" })
        let readded = out.first { $0["id"] as? String == "sim-03" }!
        XCTAssertEqual(readded["kind"] as? String, "boundary")
        XCTAssertTrue(readded["n"] is NSNull)
        XCTAssertEqual(out.count, g.readings.count + 1)
    }

    func testNewDocumentShape() {
        let g = PlanBuilder.build(rooms: SimulatedScan.rooms(), readings: SimulatedScan.readings())
        let doc = PlanDocument.newDocument(id: "J", address: "A", jobRef: "R", createdAt: Date(timeIntervalSince1970: 0),
                                           now: Date(timeIntervalSince1970: 0), geometry: g)
        XCTAssertEqual(doc["version"] as? Int, 1)
        XCTAssertEqual(doc["createdAt"] as? String, "1970-01-01T00:00:00Z")
        let w = (doc["walls"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(w.keys), ["id", "a", "b", "height"])
        let o = (doc["openings"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(o.keys), ["id", "type", "wallId", "a", "b", "height", "sill"])
        let markup = doc["markup"] as! [String: Any]
        XCTAssertEqual(PlanDocument.number((markup["thresholds"] as! [String: Any])["damp"]), 15)
        let r = (markup["readings"] as! [[String: Any]])[0]
        for key in ["id", "kind", "n", "pos", "value", "material", "note", "photo", "takenAt",
                    "height", "wallId", "wallT", "reference", "source", "cam"] {
            XCTAssertNotNil(r[key], "reading key \(key)")
        }
        XCTAssertEqual(r["source"] as? String, "ar")
        let cam = r["cam"] as! [Double]
        XCTAssertEqual(cam[0], 2.45, accuracy: 0.03)          // sim-01's camera
        XCTAssertEqual(cam[1], 1.0, accuracy: 0.03)
        XCTAssertTrue((markup["notes"] as? [Any])?.isEmpty ?? false)
        let s = (markup["sources"] as! [[String: Any]])[0]
        for key in ["id", "pos", "label", "height", "wallId", "wallT", "source", "takenAt", "cam"] {
            XCTAssertNotNil(s[key], "source key \(key)")
        }
        XCTAssertEqual(PlanDocument.number(s["height"]) ?? -1, 0.3, accuracy: 0.02)
    }

    // MARK: Edge cases (independent review)

    /// One room whose walls trace `poly`, rotated about the origin, then offset.
    func room(_ poly: [PlanVec], degrees: Double, offset: PlanVec = .zero) -> PBRoom {
        var r = PBRoom()
        let pts = poly.map { rotated($0, degrees: degrees) + offset }
        for i in pts.indices { r.walls.append(wall(pts[i], pts[(i + 1) % pts.count], id: i + 1)) }
        return r
    }

    /// Horizontal floor surface rotated like `room(...)`. Corners in LOCAL plane
    /// coordinates (as Apple documents), or in world space if `worldCorners`.
    func floorSurface(_ poly: [PlanVec], degrees: Double, offset: PlanVec, worldCorners: Bool) -> PBSurface {
        let c = poly.reduce(PlanVec.zero, +) / Double(poly.count)
        let u = rotated(PlanVec(1, 0), degrees: degrees), v = rotated(PlanVec(0, 1), degrees: degrees)
        let cw = rotated(c, degrees: degrees) + offset
        let m = simd_float4x4(columns: (
            SIMD4<Float>(Float(u.x), 0, Float(u.y), 0),
            SIMD4<Float>(Float(v.x), 0, Float(v.y), 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(Float(cw.x), 0, Float(cw.y), 1)))
        let corners: [SIMD3<Float>] = poly.map { p -> SIMD3<Float> in
            if worldCorners {
                let w = rotated(p, degrees: degrees) + offset
                return SIMD3<Float>(Float(w.x), 0, Float(w.y))
            }
            return SIMD3<Float>(Float(p.x - c.x), Float(p.y - c.y), 0)
        }
        return PBSurface(id: SimulatedScan.uuid(900), parentId: nil, transform: m,
                         dimensions: SIMD3<Float>(1, 1, 0), polygonCorners: corners)
    }

    func testFortyFiveDegreeWallIsNotStraightened() {
        let poly: [PlanVec] = [[0, 0], [4, 0], [4, 2], [3, 3], [0, 3]]
        let g = PlanBuilder.build(rooms: [room(poly, degrees: 30, offset: PlanVec(1, 1))], readings: [])
        XCTAssertEqual(g.walls.count, 5)
        let diagonal = g.walls.filter { !isAxisAligned($0) }
        XCTAssertEqual(diagonal.count, 1)
        if let d = diagonal.first {
            XCTAssertEqual(d.length, 2.0.squareRoot(), accuracy: 0.01)
            let deg = abs(atan2(d.b.y - d.a.y, d.b.x - d.a.x)) * 180 / .pi
            XCTAssertEqual(min(deg, 180 - deg), 45, accuracy: 0.5)
        }
        XCTAssertEqual(g.rooms.first?.area ?? 0, 11.5, accuracy: 0.05)
    }

    func testLShapedRoomFromFloorPolygonInEitherSpace() {
        // One wall missing, so wall chaining cannot close the loop: the outline
        // must come from the floor's polygonCorners, whichever space they are in.
        let poly: [PlanVec] = [[0, 0], [5, 0], [5, 2], [2, 2], [2, 4], [0, 4]]
        for worldCorners in [false, true] {
            var r = room(poly, degrees: 12, offset: PlanVec(-3, 2))
            r.walls.removeLast()
            r.floors = [floorSurface(poly, degrees: 12, offset: PlanVec(-3, 2), worldCorners: worldCorners)]
            let g = PlanBuilder.build(rooms: [r], readings: [])
            XCTAssertEqual(g.rooms.count, 1)
            XCTAssertEqual(g.rooms.first?.polygon.count, 6, "worldCorners \(worldCorners)")
            XCTAssertEqual(g.rooms.first?.area ?? 0, 14, accuracy: 0.01, "worldCorners \(worldCorners)")
        }
    }

    func testHouseRotatedNear45DegreesIsSquaredUp() {
        for degrees in [44.0, 46.0] {
            let g = PlanBuilder.build(rooms: [room([[0, 0], [4, 0], [4, 3], [0, 3]], degrees: degrees)], readings: [])
            XCTAssertEqual(g.walls.count, 4)
            for w in g.walls { XCTAssertTrue(isAxisAligned(w), "\(degrees) deg: \(w.id)") }
            let lengths = g.walls.map(\.length).sorted()
            for (l, e) in zip(lengths, [3.0, 3.0, 4.0, 4.0]) { XCTAssertEqual(l, e, accuracy: 0.002, "\(degrees) deg") }
            XCTAssertEqual(g.rooms.first?.area ?? 0, 12, accuracy: 0.01)
        }
    }

    func testGrazingReadingPrefersRaycastHit() {
        // Phone 15 cm off wall w1 (z = 0), looking along it at a spot 2 m away.
        // The real wall face is 2 cm in front of the scanned wall line, which on
        // its own would move the camera-ray intersection ~30 cm along the wall.
        let cam = WorldVec(1.0, 1.4, 0.15), target = WorldVec(3.0, 0.3, 0.02)
        let r = PBReading(id: "g", seq: 1, value: 20, material: "wall", takenAt: "",
                          cameraPosition: cam, cameraForward: simd_normalize(target - cam), hit: target)
        let out = PlanBuilder.build(rooms: [room([[0, 0], [4, 0], [4, 3], [0, 3]], degrees: 0)], readings: [r]).readings[0]
        XCTAssertEqual(out.wallId, "w1")
        XCTAssertEqual(out.pos.x, 3.0, accuracy: 0.02)
        XCTAssertEqual(out.height ?? -1, 0.3, accuracy: 0.02)
    }

    func testReadingThroughADoorwayLandsOnTheFarWall() {
        // Standing outside wall w1, looking through its doorway at far wall w3.
        let cam = WorldVec(2, 1.4, -1.0), target = WorldVec(2, 0.5, 3.0)
        let r = PBReading(id: "d", seq: 1, value: 20, material: "wall", takenAt: "",
                          cameraPosition: cam, cameraForward: simd_normalize(target - cam), hit: target)
        let out = PlanBuilder.build(rooms: [room([[0, 0], [4, 0], [4, 3], [0, 3]], degrees: 0)], readings: [r]).readings[0]
        XCTAssertEqual(out.wallId, "w3")
        XCTAssertEqual(out.height ?? -1, 0.5, accuracy: 0.01)
    }

    func testEmptyInputDoesNotCrash() {
        let g = PlanBuilder.build(rooms: [PBRoom()], readings: [])
        XCTAssertTrue(g.walls.isEmpty)
        XCTAssertTrue(g.rooms.isEmpty)
        // Zero-length wall and zero forward vector must not produce NaN.
        var r = PBRoom()
        r.walls.append(wall([1, 1], [1, 1], id: 1))
        let reading = PBReading(id: "z", seq: 1, value: 10, material: "wall", takenAt: "",
                                cameraPosition: [0, 1, 0], cameraForward: [0, 0, 0])
        let g2 = PlanBuilder.build(rooms: [r], readings: [reading])
        XCTAssertTrue(g2.walls.isEmpty)
        XCTAssertTrue(g2.readings[0].pos.x.isFinite && g2.readings[0].pos.y.isFinite)
    }

    func testSanitisedReplacesNonFiniteNumbers() throws {
        let doc: [String: Any] = ["a": Double.nan, "b": [1.5, Double.infinity, "x"] as [Any],
                                  "c": ["d": true, "e": 2] as [String: Any]]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(doc))
        let clean = try XCTUnwrap(PlanDocument.sanitised(doc) as? [String: Any])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(clean))
        XCTAssertTrue(clean["a"] is NSNull)
        XCTAssertTrue((clean["b"] as? [Any])?[1] is NSNull)
        XCTAssertEqual((clean["b"] as? [Any])?[2] as? String, "x")
        XCTAssertEqual((clean["c"] as? [String: Any])?["d"] as? Bool, true)
    }

    // MARK: Address

    func testAddressFormatting() {
        XCTAssertEqual(AddressFormatter.format(number: "30", street: "Sample Crescent", suburb: "Testwood", state: "WA"),
                       "30 Sample Cr, Testwood, WA")
        XCTAssertEqual(AddressFormatter.format(number: nil, street: "Wanneroo Road", suburb: "Wangara", state: "Western Australia"),
                       "Wanneroo Rd, Wangara, WA")
        XCTAssertEqual(AddressFormatter.format(number: nil, street: nil, suburb: nil, state: nil), "")
    }
}
