//
//  SimulatedScan.swift
//  SecureScan
//
//  A deterministic, hand-made "scan" of a small 3-room house, expressed as the
//  same plain input types PlanBuilder gets from RoomPlan. Used by
//  "Create demo job" (so everything after the camera can be tried on the iOS
//  Simulator) and by the unit tests. No randomness: every imperfection is a
//  fixed number in a table below.
//
//  True layout (plan metres, x right, y down; inner wall faces; partitions 0.11 m):
//
//     (0,0) +------------ 3.45 ----------+  +----- 1.8 -----+ (5.36,0)
//           |  Bedroom 3.45 x 2.80       |  | Laundry       |
//           |                            |  | 1.80 x 2.80   |
//           +-------------[door]---------+  +---[door]------+ y=2.80
//     y=2.91+-------------[door]-------------------------------+
//           |  Hallway (L-shaped)                               |
//     y=3.91+-------------------------------------+             |
//                                          x=4.36 |             | x=5.36
//                                                 +-------------+ y=5.91
//
//  Imperfections, like a real scan: the house is rotated 30 degrees about the
//  vertical axis and offset from the origin; each wall is rotated about its
//  middle by up to 1.5 degrees; wall ends stop up to 5 cm short of the corner;
//  the floor is at world y = -1.32 (ARKit's origin is where the phone started).
//

import Foundation
import simd

enum SimulatedScan {

    // MARK: World placement

    static let houseAngleDegrees = 30.0
    static let houseOffset = PlanVec(2.3, -1.7)      // world (x, z)
    static let floorY = -1.32
    static let wallHeight = 2.4
    static let cameraHeight = 1.4

    // MARK: Truth tables (used by the tests)

    /// True wall segments per room, in the order they are fed to PlanBuilder,
    /// so the expected plan ids are w1...w14.
    static let trueWalls: [(room: Int, a: PlanVec, b: PlanVec)] = [
        // Bedroom (r1): w1..w4
        (0, [0, 0], [3.45, 0]), (0, [3.45, 0], [3.45, 2.8]), (0, [3.45, 2.8], [0, 2.8]), (0, [0, 2.8], [0, 0]),
        // Laundry (r2): w5..w8
        (1, [3.56, 0], [5.36, 0]), (1, [5.36, 0], [5.36, 2.8]), (1, [5.36, 2.8], [3.56, 2.8]), (1, [3.56, 2.8], [3.56, 0]),
        // Hallway (r3): w9..w14
        (2, [0, 2.91], [5.36, 2.91]), (2, [5.36, 2.91], [5.36, 5.91]), (2, [5.36, 5.91], [4.36, 5.91]),
        (2, [4.36, 5.91], [4.36, 3.91]), (2, [4.36, 3.91], [0, 3.91]), (2, [0, 3.91], [0, 2.91]),
    ]

    /// Per-wall rotation error (degrees). Length-weighted mean is ~0.05 deg.
    static let angleErrors: [Double] = [1.2, -0.8, 1.0, -1.5, -1.1, 0.9, -0.6, 1.3, 0.4, -1.2, 1.5, -0.9, -0.3, 0.7]
    /// Per-wall shortfall at end a / end b (metres): the ends miss the corner.
    static let shortfalls: [(Double, Double)] = [
        (0.03, 0.01), (0.02, 0.05), (0.00, 0.04), (0.05, 0.02), (0.01, 0.03), (0.04, 0.00), (0.02, 0.02),
        (0.03, 0.05), (0.05, 0.01), (0.00, 0.03), (0.02, 0.04), (0.03, 0.00), (0.01, 0.05), (0.04, 0.02),
    ]

    static let truePolygons: [[PlanVec]] = [
        [[0, 0], [3.45, 0], [3.45, 2.8], [0, 2.8]],
        [[3.56, 0], [5.36, 0], [5.36, 2.8], [3.56, 2.8]],
        [[0, 2.91], [5.36, 2.91], [5.36, 5.91], [4.36, 5.91], [4.36, 3.91], [0, 3.91]],
    ]
    static let trueRoomAreas: [Double] = [9.66, 5.04, 7.36]

    /// Expected wallId of each opening, in PlanBuilder output order
    /// (per room: doors, then windows, then openings).
    static let expectedOpeningWalls = ["w3", "w1", "w7", "w9"]

    struct Expected {
        var id: String
        var kind: String
        var n: Int?
        var wallId: String?
        var wallT: Double?
        var height: Double
        var plan: PlanVec            // true plan position of the target
        var camera: PlanVec          // true plan position of the camera
    }

    // MARK: Logged items (target on a known wall at a known height)

    private struct Shot {
        var id: String
        var kind: String
        var value: Double?
        var material: String
        var reference: Bool
        var note: String
        var target: PlanVec
        var height: Double
        var camera: PlanVec
        var wall: Int?               // 1-based true wall index, nil = floor
        var time: Double             // seconds after `startTime`
        /// kind "removal": the second tap (target + camera) and the height.
        var end: PlanVec? = nil
        var endCamera: PlanVec? = nil
        var heightMm: Double? = nil
        /// kind "removal" flooring / kind "floorType"
        var wholeRoom = false
        var floorType: String? = nil
    }

    /// When the simulated inspection started (10:10 am in Perth).
    static let startTime = "2026-11-12T02:10:00Z"
    static var startDate: Date { ISOTime.date(startTime)! }

    /// In capture order (seq 1, 2, ...). The four "boundary" marks on w2 are a
    /// moisture line stepping down along the bedroom side of the laundry wall.
    private static let shots: [Shot] = [
        Shot(id: "sim-01", kind: "reading", value: 24.5, material: "skirting", reference: false, note: "",
             target: [3.45, 1.0], height: 0.05, camera: [2.45, 1.0], wall: 2, time: 40),
        Shot(id: "sim-02", kind: "reading", value: 18, material: "wall", reference: false, note: "",
             target: [0, 1.4], height: 0.3, camera: [1.0, 1.4], wall: 4, time: 75),
        Shot(id: "sim-03", kind: "boundary", value: nil, material: "wall", reference: false, note: "",
             target: [3.45, 1.6], height: 0.45, camera: [2.45, 1.6], wall: 2, time: 130),
        Shot(id: "sim-04", kind: "reading", value: 31, material: "wall", reference: false, note: "",
             target: [1.0, 2.8], height: 0.6, camera: [1.0, 1.8], wall: 3, time: 170),
        Shot(id: "sim-05", kind: "boundary", value: nil, material: "wall", reference: false, note: "",
             target: [3.45, 2.2], height: 0.35, camera: [2.45, 2.2], wall: 2, time: 200),
        Shot(id: "sim-11", kind: "boundary", value: nil, material: "wall", reference: false, note: "",
             target: [3.45, 0.5], height: 0.55, camera: [2.45, 0.6], wall: 2, time: 214),
        Shot(id: "sim-12", kind: "boundary", value: nil, material: "wall", reference: false, note: "",
             target: [3.45, 1.1], height: 0.5, camera: [2.45, 1.2], wall: 2, time: 226),
        Shot(id: "sim-src", kind: "source", value: nil, material: "wall", reference: false, note: "Flexi hose",
             target: [4.0, 0], height: 0.3, camera: [4.0, 1.2], wall: 5, time: 300),
        Shot(id: "sim-06", kind: "reading", value: 12, material: "wall", reference: false, note: "",
             target: [5.36, 1.5], height: 1.2, camera: [4.36, 1.5], wall: 6, time: 330),
        Shot(id: "sim-07", kind: "reading", value: 22, material: "floor", reference: false, note: "",
             target: [4.5, 1.4], height: 0, camera: [4.5, 2.2], wall: nil, time: 352),
        Shot(id: "sim-08", kind: "reading", value: 27, material: "skirting", reference: false, note: "",
             target: [2.0, 3.91], height: 0.3, camera: [2.0, 3.41], wall: 13, time: 420),
        Shot(id: "sim-09", kind: "photo", value: nil, material: "wall", reference: false, note: "Inspection opening",
             target: [0, 3.41], height: 1.0, camera: [1.0, 3.41], wall: 14, time: 455),
        Shot(id: "sim-10", kind: "reading", value: 11, material: "wall", reference: true, note: "Dry reference",
             target: [1.0, 2.91], height: 0.6, camera: [1.0, 3.41], wall: 9, time: 480),
        // Drying equipment on the floor (material = equipment type, note = label).
        Shot(id: "sim-e1", kind: "equipment", value: nil, material: "airMover", reference: false, note: "AM-01",
             target: [4.4, 1.9], height: 0, camera: [4.4, 2.6], wall: nil, time: 520),
        Shot(id: "sim-e2", kind: "equipment", value: nil, material: "airMover", reference: false, note: "AM-02",
             target: [2.9, 2.3], height: 0, camera: [2.0, 2.3], wall: nil, time: 532),
        Shot(id: "sim-e3", kind: "equipment", value: nil, material: "dehumidifier", reference: false, note: "DH-01",
             target: [3.2, 3.4], height: 0, camera: [2.2, 3.4], wall: nil, time: 545),
        // Removals: two taps each on a wall (material = item); flooring as the
        // whole laundry; and the bedroom tagged as carpet.
        Shot(id: "sim-r1", kind: "removal", value: nil, material: "plasterboard", reference: false, note: "Cut above the moisture line",
             target: [3.45, 0.3], height: 0.6, camera: [2.3, 0.5], wall: 2, time: 560,
             end: [3.45, 2.5], endCamera: [2.3, 2.3], heightMm: 600),
        Shot(id: "sim-r2", kind: "removal", value: nil, material: "skirting", reference: false, note: "",
             target: [3.0, 3.91], height: 0.05, camera: [3.0, 3.3], wall: 13, time: 580,
             end: [1.2, 3.91], endCamera: [1.2, 3.3], heightMm: 100),
        Shot(id: "sim-r3", kind: "removal", value: nil, material: "flooring", reference: false, note: "Vinyl lifting at the joins",
             target: [4.5, 1.4], height: 0, camera: [4.5, 2.2], wall: nil, time: 595,
             wholeRoom: true, floorType: "vinyl"),
        Shot(id: "sim-f1", kind: "floorType", value: nil, material: "carpet", reference: false, note: "",
             target: [1.6, 1.8], height: 0, camera: [1.6, 2.3], wall: nil, time: 610, floorType: "carpet"),
    ]

    /// Items that get a generated demo photo (id, title, subtitle).
    static let demoPhotos: [(id: String, title: String, subtitle: String)] = [
        ("sim-01", "Reading 1 · 24.5%", "Skirting, laundry side wall"),
        ("sim-03", "Moisture line", "Tide mark on plasterboard"),
        ("sim-04", "Reading 3 · 31%", "Wall beside bedroom door"),
        ("sim-src", "Water source", "Split cold flexi hose behind washer"),
        ("sim-08", "Reading 6 · 27%", "Hallway skirting"),
        ("sim-09", "Inspection opening", "Water in the wall cavity"),
        ("sim-r1", "Removal · start", "Plasterboard to 600 mm"),
    ]

    /// Spoken site notes (as the app would transcribe them), seconds after
    /// `startTime`, interleaved with the logged items above.
    static let spokenNotes: [(id: String, time: Double, duration: Double, text: String)] = [
        ("demo-n1", 0, 9, "Starting in the main bedroom. Owner says the washing machine hose in the laundry let go overnight and water came under the wall."),
        ("demo-n2", 125, 8, "Skirting on the laundry wall is reading high. Marking the moisture line now, it's about half a metre up and dropping towards the door."),
        ("demo-n3", 295, 7, "Moving into the laundry. Source is the cold flexi hose behind the washing machine, it's split near the tap."),
        ("demo-n4", 365, 5, "Laundry floor is wet right across. Vinyl will have to come up."),
        ("demo-n5", 440, 8, "Hallway skirting is wet near the bedroom door. Cut an inspection hole low in the hallway wall, there's water in the cavity."),
        ("demo-n6", 500, 9, "Dry reference taken in the hallway. Recommend removing plasterboard to six hundred along the laundry wall and setting up drying equipment."),
    ]

    /// Extra photo notes for the CI stress job: spread round every wall at
    /// varying heights, each taken from 1 m inside its room. Deterministic.
    static func stressPhotos(count: Int) -> [PBReading] {
        (0..<count).map { i in
            let w = trueWalls[i % trueWalls.count]
            let t = 0.25 + 0.5 * Double((i * 7) % 10) / 10
            let target = w.a + (w.b - w.a) * t
            let poly = truePolygons[w.room]
            let dir = simd_normalize(w.b - w.a)
            var inward = PlanVec(-dir.y, dir.x)
            if !inside(target + inward * 0.3, poly) { inward = -inward }
            let camera = target + inward * 0.8
            let height = 0.4 + 0.1 * Double(i % 10)
            let tw = world(target, y: floorY + height), cw = world(camera, y: floorY + cameraHeight)
            return PBReading(id: String(format: "stress-%02ld", i + 1), seq: 100 + i, kind: "photo", value: nil,
                             material: "wall", note: "Wall \(i % trueWalls.count + 1) close-up", reference: false,
                             takenAt: ISOTime.string(startDate.addingTimeInterval(600 + Double(i) * 20)),
                             photo: nil, cameraPosition: cw, cameraForward: simd_normalize(tw - cw), hit: tw)
        }
    }

    /// Even-odd point-in-polygon test.
    static func inside(_ p: PlanVec, _ poly: [PlanVec]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    /// markup.notes for the demo job.
    static func notes() -> [[String: Any]] {
        spokenNotes.map { n in
            ["id": n.id,
             "t": ISOTime.string(startDate.addingTimeInterval(n.time)),
             "end": ISOTime.string(startDate.addingTimeInterval(n.time + n.duration)),
             "text": n.text,
             "source": "voice",
             "edited": false] as [String: Any]
        }
    }

    static var expected: [Expected] {
        var readingN = 0, photoN = 0
        return shots.map { s in
            var n: Int? = nil
            if s.kind == "reading" { readingN += 1; n = readingN }
            if s.kind == "photo" { photoN += 1; n = photoN }
            var t: Double? = nil
            if let w = s.wall {
                let tw = trueWalls[w - 1]
                t = simd_dot(s.target - tw.a, tw.b - tw.a) / simd_length_squared(tw.b - tw.a)
            }
            return Expected(id: s.id, kind: s.kind, n: n, wallId: s.wall.map { "w\($0)" },
                            wallT: t, height: s.height, plan: s.target, camera: s.camera)
        }
    }

    // MARK: Generator

    static func rooms() -> [PBRoom] {
        var rooms = [PBRoom(), PBRoom(), PBRoom()]
        var wallIds: [UUID] = []
        for (i, w) in trueWalls.enumerated() {
            let id = uuid(100 + i)
            wallIds.append(id)
            rooms[w.room].walls.append(wallSurface(id: id, a: w.a, b: w.b,
                                                   angleError: angleErrors[i], shortfall: shortfalls[i]))
        }
        // Openings. Bedroom door + window and laundry door name their parent wall;
        // the hallway's side of the bedroom door does not (tests nearest-wall).
        rooms[0].doors.append(opening(id: uuid(200), parent: wallIds[2], a: [3.02, 2.8], b: [2.2, 2.8], height: 2.04, sill: 0))
        rooms[0].windows.append(opening(id: uuid(201), parent: wallIds[0], a: [1.0, 0], b: [2.2, 0], height: 1.2, sill: 0.9))
        rooms[1].doors.append(opening(id: uuid(202), parent: wallIds[6], a: [5.2, 2.8], b: [4.4, 2.8], height: 2.04, sill: 0))
        rooms[2].doors.append(opening(id: uuid(203), parent: nil, a: [2.2, 2.91], b: [3.02, 2.91], height: 2.04, sill: 0))

        // Floors with polygon corners for bedroom + laundry; the hallway has none,
        // so its outline comes from chaining its walls.
        rooms[0].floors.append(floor(id: uuid(300), polygon: truePolygons[0]))
        rooms[1].floors.append(floor(id: uuid(301), polygon: truePolygons[1]))

        rooms[0].objects.append(object("bed", centre: [1.6, 1.3], size: [1.53, 0.55, 2.03], angle: 0))
        rooms[1].objects.append(object("washerDryer", centre: [4.0, 0.35], size: [0.6, 0.85, 0.6], angle: 0))
        rooms[2].objects.append(object("storage", centre: [4.86, 5.6], size: [0.9, 1.8, 0.4], angle: 0))

        rooms[0].sectionLabels = ["bedroom"]
        return rooms
    }

    static func readings() -> [PBReading] {
        shots.enumerated().map { i, s in
            let target = world(s.target, y: floorY + s.height)
            let cam = world(s.camera, y: floorY + cameraHeight)
            let fwd = simd_normalize(target - cam)
            var r = PBReading(id: s.id, seq: i + 1, kind: s.kind, value: s.value, material: s.material,
                              note: s.note, reference: s.reference,
                              takenAt: ISOTime.string(startDate.addingTimeInterval(s.time)),
                              photo: nil, cameraPosition: cam, cameraForward: fwd, hit: target)
            if let e = s.end, let ec = s.endCamera {
                let et = world(e, y: floorY + s.height), ecw = world(ec, y: floorY + cameraHeight)
                r.end = PBPose(cameraPosition: ecw, cameraForward: simd_normalize(et - ecw), hit: et)
                r.heightMm = s.heightMm
            }
            r.wholeRoom = s.wholeRoom
            r.floorType = s.floorType
            return r
        }
    }

    // MARK: Helpers

    static func rotateHouse(_ v: PlanVec) -> PlanVec {
        let a = houseAngleDegrees * .pi / 180
        return PlanVec(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y)
    }

    /// True plan point + world height -> world point (planY maps to worldZ).
    static func world(_ p: PlanVec, y: Double) -> WorldVec {
        let r = rotateHouse(p) + houseOffset
        return WorldVec(r.x, y, r.y)
    }

    static func uuid(_ n: Int) -> UUID {
        let hex = String(n, radix: 16, uppercase: true)
        let padded = String(repeating: "0", count: max(0, 12 - hex.count)) + hex
        return UUID(uuidString: "5EC0BE00-0000-4000-8000-" + padded)!
    }

    /// A RoomPlan-like transform: x axis along `dir` (plan, already in world
    /// orientation), y up, z = x cross y.
    static func surfaceTransform(centre: WorldVec, dir: PlanVec) -> simd_float4x4 {
        let d = simd_normalize(dir)
        return simd_float4x4(columns: (
            SIMD4<Float>(Float(d.x), 0, Float(d.y), 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(Float(-d.y), 0, Float(d.x), 0),
            SIMD4<Float>(Float(centre.x), Float(centre.y), Float(centre.z), 1)))
    }

    static func wallSurface(id: UUID, a: PlanVec, b: PlanVec, angleError: Double, shortfall: (Double, Double)) -> PBSurface {
        let len = simd_length(b - a)
        let mid = (a + b) / 2
        let e = angleError * .pi / 180
        let t = simd_normalize(b - a)
        let dir = PlanVec(cos(e) * t.x - sin(e) * t.y, sin(e) * t.x + cos(e) * t.y)
        let a2 = mid - dir * (len / 2) + dir * shortfall.0
        let b2 = mid + dir * (len / 2) - dir * shortfall.1
        let centre = world((a2 + b2) / 2, y: floorY + wallHeight / 2)
        return PBSurface(id: id, parentId: nil,
                         transform: surfaceTransform(centre: centre, dir: rotateHouse(dir)),
                         dimensions: SIMD3<Float>(Float(simd_length(b2 - a2)), Float(wallHeight), 0))
    }

    static func opening(id: UUID, parent: UUID?, a: PlanVec, b: PlanVec, height: Double, sill: Double) -> PBSurface {
        let centre = world((a + b) / 2, y: floorY + sill + height / 2)
        return PBSurface(id: id, parentId: parent,
                         transform: surfaceTransform(centre: centre, dir: rotateHouse(b - a)),
                         dimensions: SIMD3<Float>(Float(simd_length(b - a)), Float(height), 0))
    }

    /// Floor surface whose local x-y plane is horizontal; polygonCorners are
    /// given in that LOCAL space (relative to the floor's centre).
    static func floor(id: UUID, polygon: [PlanVec]) -> PBSurface {
        let c = polygon.reduce(PlanVec.zero, +) / Double(polygon.count)
        let u = rotateHouse([1, 0]), v = rotateHouse([0, 1])
        let cw = world(c, y: floorY)
        let m = simd_float4x4(columns: (
            SIMD4<Float>(Float(u.x), 0, Float(u.y), 0),
            SIMD4<Float>(Float(v.x), 0, Float(v.y), 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(Float(cw.x), Float(cw.y), Float(cw.z), 1)))
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        return PBSurface(id: id, parentId: nil, transform: m,
                         dimensions: SIMD3<Float>(Float(xs.max()! - xs.min()!), Float(ys.max()! - ys.min()!), 0),
                         polygonCorners: polygon.map { SIMD3<Float>(Float($0.x - c.x), Float($0.y - c.y), 0) })
    }

    static func object(_ category: String, centre: PlanVec, size: SIMD3<Double>, angle: Double) -> PBObject {
        let dir = rotateHouse(PlanVec(cos(angle), sin(angle)))
        return PBObject(category: category,
                        transform: surfaceTransform(centre: world(centre, y: floorY + size.y / 2), dir: dir),
                        dimensions: SIMD3<Float>(Float(size.x), Float(size.y), Float(size.z)))
    }
}
