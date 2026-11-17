//
//  PlanBuilder.swift
//  SecureScan
//
//  Pure maths: RoomPlan-style capture data -> a clean, dimensioned 2D plan.
//
//  This file deliberately does NOT import RoomPlan, ARKit or UIKit. It works on
//  plain value types (PBSurface, PBRoom, PBReading) so it can be unit tested with
//  hand-made transforms. RoomPlanAdapter.swift converts RoomPlan's CapturedRoom
//  into these types; SimulatedScan.swift produces them without a scan.
//
//  Coordinate conventions (see docs/SPEC.md, "Contract 1"):
//    * RoomPlan / ARKit world space is right-handed, metres, +Y up.
//    * Plan space is 2D, metres, x to the right, y DOWN the page.
//      planX = worldX, planY = worldZ  (a straight projection onto the floor).
//    * After projecting, the whole plan is rotated so the dominant wall
//      direction is axis-aligned, then translated so min x / min y = 0.
//      That single PlanTransform is kept and used for readings too.
//
//  Surfaces (walls, doors, windows, openings) follow RoomPlan's convention:
//    * transform.columns.3 = centre of the surface (world)
//    * transform.columns.0 = the surface's local x axis = along the wall
//    * transform.columns.1 = local y axis = up (for wall-like surfaces)
//    * dimensions.x = width (wall length), dimensions.y = height
//

import Foundation
import simd

// MARK: - Vector shorthands

typealias PlanVec = SIMD2<Double>
typealias WorldVec = SIMD3<Double>

@inline(__always) func cross2(_ a: PlanVec, _ b: PlanVec) -> Double { a.x * b.y - a.y * b.x }

// MARK: - Input value types (what RoomPlan gives us, minus RoomPlan)

/// A wall, door, window, opening or floor.
struct PBSurface {
    var id: UUID
    var parentId: UUID?
    var transform: simd_float4x4
    var dimensions: SIMD3<Float>
    /// RoomPlan's polygonCorners. Assumed to be in the surface's LOCAL space, but
    /// PlanBuilder also tries "already world space" and keeps whichever fits the
    /// room's walls better (Apple's documentation does not state the space).
    var polygonCorners: [SIMD3<Float>] = []

    var centre: WorldVec {
        let c = transform.columns.3
        return WorldVec(Double(c.x), Double(c.y), Double(c.z))
    }
    var xAxis: WorldVec {
        let c = transform.columns.0
        return WorldVec(Double(c.x), Double(c.y), Double(c.z))
    }
    /// Local point -> world point.
    func world(_ local: SIMD3<Float>) -> WorldVec {
        let p = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        return WorldVec(Double(p.x), Double(p.y), Double(p.z))
    }
}

/// Furniture / fixture. `category` is RoomPlan's category name ("bed", "washerDryer"...).
struct PBObject {
    var category: String
    var transform: simd_float4x4
    var dimensions: SIMD3<Float>
}

/// One captured room.
struct PBRoom {
    var walls: [PBSurface] = []
    var doors: [PBSurface] = []
    var windows: [PBSurface] = []
    var openings: [PBSurface] = []
    var floors: [PBSurface] = []
    var objects: [PBObject] = []
    /// RoomPlan Section labels as strings: "bedroom", "bathroom", "kitchen",
    /// "livingRoom", "diningRoom", "unidentified".
    var sectionLabels: [String] = []
}

/// One item logged during the scan (moisture reading, moisture-line mark,
/// photo note or water source), with raw world-space data.
struct PBReading {
    var id: String
    /// Capture order across ALL kinds (1, 2, 3...). PlanBuilder derives `n`.
    var seq: Int
    /// "reading" | "boundary" (moisture-line mark) | "photo" (photo note) |
    /// "source" (water source; its label is `note`) | "equipment" (drying
    /// equipment; `material` holds its type key, `note` its label). Sources and
    /// equipment are returned in PlanGeometry.sources / .equipment, everything
    /// else in PlanGeometry.readings.
    var kind: String = "reading"
    /// Meter value in %; nil for boundary / photo.
    var value: Double?
    var material: String
    var note: String = ""
    var reference: Bool = false
    var takenAt: String
    var photo: String? = nil              // JPEG data URL, passed straight through
    var cameraPosition: WorldVec
    var cameraForward: WorldVec           // camera -Z axis (world)
    var hit: WorldVec? = nil              // ARKit raycast hit from the screen centre
    /// kind "removal" only: the second tap ("End here"); the first tap is
    /// the item's own camera/hit. `material` holds the removal item, `note` the note.
    var end: PBPose? = nil
    var heightMm: Double? = nil
    /// kind "removal" with material "flooring": corner taps on the floor
    /// (the item's own pose is NOT a corner), or the whole room the camera is in.
    var corners: [PBPose] = []
    var wholeRoom: Bool = false
    var floorType: String? = nil
    var underlay: Bool = false
    /// kind "source": "suspected" | "confirmed" (docs/MARKING.md; nil = suspected).
    var status: String? = nil
    /// Wall-attached items: "a" | "b" (by the wall's normal) | "cavity" (inside the wall).
    var side: String? = nil
}

/// Camera pose and raycast hit of one tap.
struct PBPose {
    var cameraPosition: WorldVec
    var cameraForward: WorldVec
    var hit: WorldVec? = nil
}

/// A removal logged with two taps, resolved into plan space.
struct PlanRemoval {
    var id: String
    var item: String               // plasterboard | skirting | cabinetry | flooring | other
    var heightMm: Double
    var note: String
    var takenAt: String
    var photo: String?
    /// Wall stretch: wallId + t0 <= t1.
    var wallId: String?
    var t0: Double?
    var t1: Double?
    /// Flooring: the section of floor (plan polygon), its floor type and underlay.
    var area: [PlanVec]?
    var floorType: String?
    var underlay: Bool = false
    var cam: PlanVec?
    /// "a" | "b" (docs/MARKING.md H; optional).
    var side: String? = nil
}

/// A floor-type zone (markup.floors): the room the camera was in.
struct PlanFloorZone {
    var id: String
    var polygon: [PlanVec]
    var type: String
    var takenAt: String
}

/// A wet floor area traced in AR (markup.affected): kind "affected", its
/// outline in `corners` (taps or a swept edge), label in `note`.
struct PlanAffected {
    var id: String
    var polygon: [PlanVec]
    var label: String
    var takenAt: String
}

enum RemovalResolution {
    case placed(PlanRemoval)
    case rejected(String)          // why, in plain words
}

// MARK: - Output value types (plan space)

struct PlanTransform: Equatable {
    /// Rotation applied to (worldX, worldZ), radians.
    var angle: Double
    /// Translation applied after the rotation.
    var offset: PlanVec

    func rotate(_ v: PlanVec) -> PlanVec {
        let c = cos(angle), s = sin(angle)
        return PlanVec(c * v.x - s * v.y, s * v.x + c * v.y)
    }
    /// World point -> plan point.
    func point(_ w: WorldVec) -> PlanVec { rotate(PlanVec(w.x, w.z)) + offset }
    /// World direction -> plan direction (horizontal component only, not normalised).
    func direction(_ w: WorldVec) -> PlanVec { rotate(PlanVec(w.x, w.z)) }
    /// Plan point + world height -> world point (the inverse of `point`).
    func world(_ p: PlanVec, y: Double) -> WorldVec {
        let v = p - offset
        let c = cos(-angle), s = sin(-angle)
        return WorldVec(c * v.x - s * v.y, y, s * v.x + c * v.y)
    }
}

struct PlanWall {
    var id: String
    var a: PlanVec
    var b: PlanVec
    var height: Double
    var roomIndex: Int          // not exported; used for floor heights / tests
    var length: Double { simd_length(b - a) }
}

struct PlanOpening {
    var id: String
    var type: String            // "door" | "window" | "opening"
    var wallId: String?
    var a: PlanVec
    var b: PlanVec
    var height: Double
    var sill: Double
}

struct PlanRoom {
    var id: String
    var name: String
    var polygon: [PlanVec]
    var area: Double
}

struct PlanObject {
    var id: String
    var category: String
    var center: PlanVec
    var size: PlanVec
    var rotation: Double
}

struct PlanReading {
    var id: String
    var kind: String
    /// Display number: 1,2,3 among kind "reading"; P-number among "photo";
    /// nil for "boundary" and "source" (not numbered).
    var n: Int?
    var pos: PlanVec
    var value: Double?
    var material: String
    var note: String
    var photo: String?
    var takenAt: String
    var height: Double?
    var wallId: String?
    var wallT: Double?
    var reference: Bool
    /// Resolved 3D point in WORLD space (for the 3D view), nil if only the
    /// camera position was known.
    var worldPoint: WorldVec?
    /// Camera position at capture, in plan coordinates ("cam" in plan.json).
    var cam: PlanVec? = nil
    /// Sources: "suspected" | "confirmed" (optional; docs/MARKING.md).
    var status: String? = nil
    /// "a" | "b" | "cavity" (optional; docs/MARKING.md H).
    var side: String? = nil
}

struct PlanGeometry {
    var walls: [PlanWall] = []
    var openings: [PlanOpening] = []
    var rooms: [PlanRoom] = []
    var objects: [PlanObject] = []
    var readings: [PlanReading] = []
    /// Water sources logged in AR (kind "source").
    var sources: [PlanReading] = []
    /// Drying equipment placed in AR (kind "equipment"), on the floor.
    var equipment: [PlanReading] = []
    /// Removals logged in AR with two taps (kind "removal").
    var removals: [PlanRemoval] = []
    /// Removals that could not be placed (ids -> reason); kept in the raw log.
    var rejectedRemovals: [(id: String, reason: String)] = []
    /// Floor types tagged during the scan (kind "floorType").
    var floors: [PlanFloorZone] = []
    /// Wet floor areas traced in AR (kind "affected").
    var affected: [PlanAffected] = []
    var transform = PlanTransform(angle: 0, offset: .zero)
    var floorY: Double?
    var totalArea: Double { rooms.reduce(0) { $0 + $1.area } }
}

// MARK: - The builder

enum PlanBuilder {

    // Tuning constants (metres / degrees).
    static let minWallLength = 0.10
    static let snapTolerance = 0.08
    static let straightenToleranceDegrees = 2.0
    static let polygonSnapTolerance = 0.15
    static let chainTolerance = 0.12
    static let readingRayMax = 3.0
    static let readingWallSnap = 0.30
    /// Reading materials that are not on a wall (stored by position and height, wallId null).
    static let offWallMaterials: Set<String> = ["ceiling", "cabinetry", "other"]
    static let openingNearestWallMax = 0.5
    /// Below this sine of the ray/wall angle (~24 degrees) the raycast hit wins.
    static let grazingSine = 0.4
    /// A wall crossing this much nearer than the raycast hit is not the target.
    static let beyondHitTolerance = 0.25
    /// Furthest floor point accepted for equipment (metres along the ray).
    static let floorRayMax = 6.0
    /// A removal end this close to the start's wall is snapped onto it.
    static let removalSnap = 0.4
    /// Shortest removal accepted (metres).
    static let removalMinLength = 0.05

    /// Working wall in rotated (not yet translated) plan space.
    struct WorkWall {
        enum Axis { case none, horizontal, vertical }
        var roomIndex: Int
        var surfaceId: UUID?
        var a: PlanVec
        var b: PlanVec
        var height: Double
        var axis: Axis = .none
    }

    static func build(rooms: [PBRoom], readings: [PBReading]) -> PlanGeometry {
        var g = PlanGeometry()

        // 1. Floor level per room: lowest floor surface, else lowest wall base.
        let roomFloorY: [Double?] = rooms.map { floorY(of: $0) }
        let globalFloorY: Double? = roomFloorY.compactMap { $0 }.min()
        g.floorY = globalFloorY

        // 2. Wall segments projected onto the floor (unrotated plan coords).
        var raw: [WorkWall] = []
        for (ri, room) in rooms.enumerated() {
            for s in room.walls {
                guard let seg = segment(of: s), simd_length(seg.b - seg.a) >= minWallLength else { continue }
                raw.append(WorkWall(roomIndex: ri, surfaceId: s.id, a: seg.a, b: seg.b,
                                    height: Double(s.dimensions.y)))
            }
        }

        // 3. Dominant direction -> rotation that makes it axis-aligned.
        let phi = dominantAngle(raw.map { ($0.a, $0.b) })
        let rotation = PlanTransform(angle: -phi, offset: .zero)

        // 4. Rotate, straighten, snap.
        var walls = raw.map { w -> WorkWall in
            var w = w
            w.a = rotation.rotate(w.a)
            w.b = rotation.rotate(w.b)
            return w
        }
        cleanUp(&walls)
        walls.removeAll { simd_length($0.b - $0.a) < 0.05 }

        // 5. Room polygons (rotated frame).
        var polygons: [[PlanVec]] = []
        for (ri, room) in rooms.enumerated() {
            let roomWalls = walls.filter { $0.roomIndex == ri }
            polygons.append(roomPolygon(room: room, walls: roomWalls, rotation: rotation))
        }

        // 6. Translation so min x/y = 0.
        var pts: [PlanVec] = walls.flatMap { [$0.a, $0.b] } + polygons.flatMap { $0 }
        if pts.isEmpty {
            pts = readings.map { r in rotation.point(r.hit ?? r.cameraPosition) }
        }
        var offset = PlanVec.zero
        if let minX = pts.map(\.x).min(), let minY = pts.map(\.y).min() {
            offset = PlanVec(-minX, -minY)
        }
        let transform = PlanTransform(angle: -phi, offset: offset)
        g.transform = transform

        // 7. Final walls.
        g.walls = walls.enumerated().map { i, w in
            PlanWall(id: "w\(i + 1)", a: w.a + offset, b: w.b + offset, height: w.height, roomIndex: w.roomIndex)
        }

        // 8. Rooms.
        for (ri, room) in rooms.enumerated() {
            let poly = polygons[ri].map { $0 + offset }
            guard poly.count >= 3 else { continue }
            g.rooms.append(PlanRoom(id: "r\(ri + 1)",
                                    name: roomName(labels: room.sectionLabels, index: ri),
                                    polygon: poly,
                                    area: abs(signedArea(poly))))
        }

        // 9. Openings, attached to walls.
        var oi = 0
        for (ri, room) in rooms.enumerated() {
            let groups: [([PBSurface], String)] = [(room.doors, "door"), (room.windows, "window"), (room.openings, "opening")]
            for (list, type) in groups {
                for s in list {
                    guard let seg = segment(of: s) else { continue }
                    var a = transform.point(WorldVec(seg.a.x, 0, seg.a.y))
                    var b = transform.point(WorldVec(seg.b.x, 0, seg.b.y))
                    var wallIndex: Int? = nil
                    if let pid = s.parentId, let idx = walls.firstIndex(where: { $0.surfaceId == pid }) {
                        wallIndex = idx
                    } else {
                        wallIndex = nearestWall(to: (a + b) / 2, walls: g.walls, maxDistance: openingNearestWallMax)?.index
                    }
                    if let wi = wallIndex {
                        let w = g.walls[wi]
                        a = w.a + (w.b - w.a) * projectParam(a, w.a, w.b)
                        b = w.a + (w.b - w.a) * projectParam(b, w.a, w.b)
                    }
                    let h = Double(s.dimensions.y)
                    let bottom = s.centre.y - h / 2
                    let base = roomFloorY[ri] ?? globalFloorY ?? bottom
                    var sill = type == "door" ? 0 : max(0, bottom - base)
                    if sill < 0.03 { sill = 0 }
                    oi += 1
                    let wallId: String? = wallIndex.map { g.walls[$0].id }
                    g.openings.append(PlanOpening(id: "o\(oi)", type: type, wallId: wallId,
                                                  a: a, b: b, height: h, sill: sill))
                }
            }
        }

        // 10. Objects.
        var obi = 0
        for room in rooms {
            for o in room.objects {
                let t = o.transform
                let c = WorldVec(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
                let x = WorldVec(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z))
                guard o.dimensions.x > 0.01, o.dimensions.z > 0.01 else { continue }
                let rot = normaliseAngle(atan2(x.z, x.x) + transform.angle)
                obi += 1
                g.objects.append(PlanObject(id: "ob\(obi)", category: o.category,
                                            center: transform.point(c),
                                            size: PlanVec(Double(o.dimensions.x), Double(o.dimensions.z)),
                                            rotation: rot))
            }
        }

        // 11. Readings.
        let finalWalls = g.walls
        let wallFloorY: [Double?] = finalWalls.map { roomFloorY.indices.contains($0.roomIndex) ? roomFloorY[$0.roomIndex] : nil }
        var readingCount = 0, photoCount = 0
        let roomPolygons = g.rooms.map(\.polygon)
        for r in readings.filter({ $0.kind == "removal" }).sorted(by: { $0.seq < $1.seq }) {
            switch resolveRemoval(r, walls: finalWalls, wallFloorY: wallFloorY, globalFloorY: globalFloorY,
                                  transform: transform, rooms: roomPolygons) {
            case .placed(let x): g.removals.append(x)
            case .rejected(let why): g.rejectedRemovals.append((id: r.id, reason: why))
            }
        }
        for r in readings.filter({ $0.kind == "floorType" }).sorted(by: { $0.seq < $1.seq }) {
            if let z = floorZone(r, transform: transform, rooms: roomPolygons) { g.floors.append(z) }
        }
        for r in readings.filter({ $0.kind == "affected" }).sorted(by: { $0.seq < $1.seq }) {
            if case .success(let a) = affectedArea(r, globalFloorY: globalFloorY, transform: transform) { g.affected.append(a) }
        }
        let all = readings.filter { $0.kind != "removal" && $0.kind != "floorType" && $0.kind != "affected" }.sorted { $0.seq < $1.seq }.map { r -> PlanReading in
            var out = resolve(r, walls: finalWalls, wallFloorY: wallFloorY, globalFloorY: globalFloorY, transform: transform)
            if r.kind == "equipment" {
                return resolveOnFloor(r, globalFloorY: globalFloorY, transform: transform)
            }
            switch r.kind {
            case "boundary", "source": out.n = nil
            case "photo": photoCount += 1; out.n = photoCount
            default: readingCount += 1; out.n = readingCount
            }
            return out
        }
        g.readings = all.filter { $0.kind != "source" && $0.kind != "equipment" }
        g.sources = all.filter { $0.kind == "source" }
        g.equipment = all.filter { $0.kind == "equipment" }
        return g
    }

    // MARK: Surfaces

    /// Floor Y for a room: lowest floor surface centre, else lowest wall base.
    static func floorY(of room: PBRoom) -> Double? {
        if let f = room.floors.map({ $0.centre.y }).min() { return f }
        return room.walls.map { $0.centre.y - Double($0.dimensions.y) / 2 }.min()
    }

    /// Endpoints of a wall-like surface projected to (worldX, worldZ).
    /// Curved walls are treated as a straight chord of the same width.
    static func segment(of s: PBSurface) -> (a: PlanVec, b: PlanVec)? {
        let c = s.centre
        let x = s.xAxis
        var d = PlanVec(x.x, x.z)
        let len = simd_length(d)
        guard len > 1e-6 else { return nil }
        d /= len
        let half = Double(s.dimensions.x) / 2
        let centre = PlanVec(c.x, c.z)
        return (centre - d * half, centre + d * half)
    }

    // MARK: Dominant angle

    /// Length-weighted histogram of wall angles modulo 90 degrees, refined by a
    /// weighted circular mean around the peak. Returns the angle in (-45, 45]
    /// degrees (radians) so the plan is rotated as little as possible.
    static func dominantAngle(_ segments: [(PlanVec, PlanVec)]) -> Double {
        var hist = [Double](repeating: 0, count: 90)
        var items: [(deg: Double, w: Double)] = []
        for (a, b) in segments {
            let d = b - a
            let len = simd_length(d)
            guard len > 1e-6 else { continue }
            var deg = atan2(d.y, d.x) * 180 / .pi
            deg = deg.truncatingRemainder(dividingBy: 90)
            if deg < 0 { deg += 90 }
            if deg >= 90 { deg -= 90 }
            hist[min(89, Int(deg))] += len
            items.append((deg, len))
        }
        guard !items.isEmpty else { return 0 }
        var best = 0, bestScore = -1.0
        for i in 0..<90 {
            let s = hist[(i + 89) % 90] + 2 * hist[i] + hist[(i + 1) % 90]
            if s > bestScore { bestScore = s; best = i }
        }
        let peak = Double(best) + 0.5
        var sx = 0.0, sy = 0.0
        for it in items {
            var diff = abs(it.deg - peak)
            diff = min(diff, 90 - diff)
            guard diff <= 5 else { continue }
            let a4 = it.deg * .pi / 180 * 4      // period 90 deg -> 360 deg
            sx += it.w * cos(a4)
            sy += it.w * sin(a4)
        }
        guard sx != 0 || sy != 0 else { return 0 }
        return atan2(sy, sx) / 4
    }

    // MARK: Clean-up: straighten + snap

    /// Straightens walls within ~2 degrees of an axis and snaps endpoints that
    /// are within ~8 cm of each other to one shared point. A shared corner takes
    /// its x from the vertical walls meeting there and its y from the horizontal
    /// ones, so axis-aligned walls stay exactly axis-aligned. Repeated a few
    /// times because each step slightly disturbs the other.
    static func cleanUp(_ walls: inout [WorkWall]) {
        let tol = sin(straightenToleranceDegrees * .pi / 180)
        for _ in 0..<4 {
            for i in walls.indices {
                let d = walls[i].b - walls[i].a
                let len = simd_length(d)
                guard len > 1e-9 else { walls[i].axis = .none; continue }
                if abs(d.y) / len <= tol {
                    let y = (walls[i].a.y + walls[i].b.y) / 2
                    walls[i].a.y = y; walls[i].b.y = y
                    walls[i].axis = .horizontal
                } else if abs(d.x) / len <= tol {
                    let x = (walls[i].a.x + walls[i].b.x) / 2
                    walls[i].a.x = x; walls[i].b.x = x
                    walls[i].axis = .vertical
                } else {
                    walls[i].axis = .none
                }
            }
            // Union-find over endpoints. Endpoint k: wall k/2, end k%2 (0 = a, 1 = b).
            let n = walls.count * 2
            guard n > 0 else { return }
            func pos(_ k: Int) -> PlanVec { k % 2 == 0 ? walls[k / 2].a : walls[k / 2].b }
            var parent = Array(0..<n)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
                return x
            }
            for i in 0..<n {
                for j in (i + 1)..<n where i / 2 != j / 2 {
                    if simd_distance(pos(i), pos(j)) <= snapTolerance {
                        let ri = find(i), rj = find(j)
                        if ri != rj { parent[rj] = ri }
                    }
                }
            }
            var clusters: [Int: [Int]] = [:]
            for k in 0..<n { clusters[find(k), default: []].append(k) }
            for (_, members) in clusters where members.count > 1 {
                let all = members.map(pos)
                let vx = members.filter { walls[$0 / 2].axis == .vertical }.map { pos($0).x }
                let hy = members.filter { walls[$0 / 2].axis == .horizontal }.map { pos($0).y }
                let x = vx.isEmpty ? all.map(\.x).reduce(0, +) / Double(all.count) : vx.reduce(0, +) / Double(vx.count)
                let y = hy.isEmpty ? all.map(\.y).reduce(0, +) / Double(all.count) : hy.reduce(0, +) / Double(hy.count)
                for k in members {
                    if k % 2 == 0 { walls[k / 2].a = PlanVec(x, y) } else { walls[k / 2].b = PlanVec(x, y) }
                }
            }
        }
    }

    // MARK: Room polygons

    static func roomPolygon(room: PBRoom, walls: [WorkWall], rotation: PlanTransform) -> [PlanVec] {
        let endpoints = walls.flatMap { [$0.a, $0.b] }

        // a) Floor polygonCorners (largest floor with >= 3 corners).
        var best: [PlanVec] = []
        var bestArea = 0.0
        for f in room.floors where f.polygonCorners.count >= 3 {
            let local = f.polygonCorners.map { rotation.point(f.world($0)) }
            let asWorld = f.polygonCorners.map { rotation.point(WorldVec(Double($0.x), Double($0.y), Double($0.z))) }
            let chosen: [PlanVec]
            if !walls.isEmpty {
                chosen = meanDistance(local, to: walls) <= meanDistance(asWorld, to: walls) ? local : asWorld
            } else {
                let c = rotation.point(f.centre)
                chosen = simd_distance(centroid(local), c) <= simd_distance(centroid(asWorld), c) ? local : asWorld
            }
            let area = abs(signedArea(chosen))
            if area > bestArea { bestArea = area; best = chosen }
        }
        if best.count >= 3 && bestArea > 0.05 {
            // Snap each vertex to the nearest wall endpoint so walls and floor agree.
            let snapped = best.map { p -> PlanVec in
                guard let q = endpoints.min(by: { simd_distance($0, p) < simd_distance($1, p) }),
                      simd_distance(q, p) <= polygonSnapTolerance else { return p }
                return q
            }
            return dedupe(snapped)
        }

        // b) Chain the room's walls into a closed loop.
        if let loop = chainLoop(walls), loop.count >= 3, abs(signedArea(loop)) > 0.05 {
            return dedupe(loop)
        }

        // c) Floor rectangle from dimensions. Try both plausible local planes
        //    (x-y and x-z) and keep the one with the bigger footprint.
        if let f = room.floors.max(by: { $0.dimensions.x * max($0.dimensions.y, $0.dimensions.z) < $1.dimensions.x * max($1.dimensions.y, $1.dimensions.z) }) {
            let hx = f.dimensions.x / 2, hy = f.dimensions.y / 2, hz = f.dimensions.z / 2
            let xy: [SIMD3<Float>] = [[-hx, -hy, 0], [hx, -hy, 0], [hx, hy, 0], [-hx, hy, 0]]
            let xz: [SIMD3<Float>] = [[-hx, 0, -hz], [hx, 0, -hz], [hx, 0, hz], [-hx, 0, hz]]
            let p1 = xy.map { rotation.point(f.world($0)) }
            let p2 = xz.map { rotation.point(f.world($0)) }
            let r = abs(signedArea(p1)) >= abs(signedArea(p2)) ? p1 : p2
            if abs(signedArea(r)) > 0.05 { return r }
        }

        // d) Last resort: convex hull of the wall endpoints.
        let hull = convexHull(endpoints)
        return hull.count >= 3 ? hull : []
    }

    /// Follows walls end-to-end from the first wall until it returns to the start.
    static func chainLoop(_ walls: [WorkWall]) -> [PlanVec]? {
        guard walls.count >= 3 else { return nil }
        var used: Set<Int> = [0]
        let start = walls[0].a
        var poly: [PlanVec] = [start]
        var current = walls[0].b
        while true {
            if poly.count >= 3 && simd_distance(current, start) <= chainTolerance { return poly }
            var next: (index: Int, flip: Bool, d: Double)? = nil
            for (i, w) in walls.enumerated() where !used.contains(i) {
                let da = simd_distance(w.a, current), db = simd_distance(w.b, current)
                if da <= chainTolerance, da < (next?.d ?? .infinity) { next = (i, false, da) }
                if db <= chainTolerance, db < (next?.d ?? .infinity) { next = (i, true, db) }
            }
            guard let nx = next else { return nil }
            used.insert(nx.index)
            poly.append(current)
            current = nx.flip ? walls[nx.index].a : walls[nx.index].b
        }
    }

    // MARK: Readings

    /// Resolves a reading into plan space (see SPEC addendum v1.1):
    ///  1. intersect the camera ray (2D) with the walls, nearest hit within 3 m
    ///     in front of the camera (ignoring hits that would be below the floor
    ///     or above the wall, i.e. the camera was really looking at the floor
    ///     or ceiling). When a raycast hit exists, walls seen at a grazing angle
    ///     and wall lines crossed well before the hit (doorways) are skipped;
    ///  2. else the ARKit raycast hit;  3. else the camera position.
    /// Then, unless the material is "floor", snap to a wall within 0.3 m and set
    /// wallId / wallT / height (clamped to 0...wall height).
    static func resolve(_ r: PBReading, walls: [PlanWall], wallFloorY: [Double?],
                        globalFloorY: Double?, transform: PlanTransform) -> PlanReading {
        let camPlan = transform.point(r.cameraPosition)
        let flen = simd_length(r.cameraForward)
        let f3 = flen > 1e-9 ? r.cameraForward / flen : WorldVec(0, 0, -1)
        let fh = transform.direction(f3)              // |fh| = cos(pitch)
        let isFloor = r.material == "floor"
        // A reading on a ceiling, a cabinet / vanity or anything else that is not
        // a wall stays where the raycast hit it: no wall line, no snapping.
        let offWall = r.kind == "reading" && Self.offWallMaterials.contains(r.material)

        var world: WorldVec? = nil
        if !isFloor && !offWall && simd_length(fh) > 0.05 {
            var bestT = Double.infinity
            // Distance along the ray to the ARKit raycast hit (the real surface), if any.
            let hitT: Double? = r.hit.map { simd_dot($0 - r.cameraPosition, f3) }
            for (i, w) in walls.enumerated() {
                let e = w.b - w.a
                let denom = cross2(fh, e)
                if abs(denom) < 1e-9 { continue }
                // Looking almost along a wall: a 2 cm error in the wall line moves the
                // intersection tens of cm. Trust the raycast hit instead, if there is one.
                if hitT != nil, abs(denom) / (simd_length(fh) * simd_length(e)) < grazingSine { continue }
                let q = w.a - camPlan
                let t = cross2(q, e) / denom          // distance along the 3D unit ray
                let u = cross2(q, fh) / denom         // 0..1 along the wall
                guard t > 0.01, t <= readingRayMax, u >= -0.02, u <= 1.02, t < bestT else { continue }
                // The real surface is well beyond this wall line: the ray went through a
                // doorway / opening (wall segments here have no gaps for openings).
                if let ht = hitT, t < ht - beyondHitTolerance { continue }
                let y = r.cameraPosition.y + t * f3.y
                if let base = wallFloorY[i] ?? globalFloorY {
                    guard y >= base - 0.05, y <= base + w.height + 0.10 else { continue }
                }
                bestT = t
            }
            if bestT.isFinite { world = r.cameraPosition + f3 * bestT }
        }
        if world == nil, let hit = r.hit { world = hit }
        if world == nil, isFloor, let fy = globalFloorY, f3.y < -0.05 {
            let t = (fy - r.cameraPosition.y) / f3.y
            if t > 0, t <= readingRayMax { world = r.cameraPosition + f3 * t }
        }

        var pos = world.map { transform.point($0) } ?? camPlan
        var wallId: String? = nil
        var wallT: Double? = nil
        var height: Double? = nil

        if !isFloor, !offWall, let near = nearestWall(to: pos, walls: walls, maxDistance: readingWallSnap) {
            let w = walls[near.index]
            let u = projectParam(pos, w.a, w.b)
            pos = w.a + (w.b - w.a) * u
            wallId = w.id
            wallT = u
            if let y = world?.y, let base = wallFloorY[near.index] ?? globalFloorY {
                height = min(max(y - base, 0), w.height)
            }
        }
        if wallId == nil, let y = world?.y, let base = globalFloorY {
            height = isFloor ? 0 : max(0, y - base)
        }

        // The side, against the plan wall's own a -> b (the live wall may have run the other way).
        var side = r.side
        if let wid = wallId, let w = walls.first(where: { $0.id == wid }), side == "a" || side == "b",
           r.cameraPosition.x.isFinite && r.cameraPosition.z.isFinite {
            side = Self.side(of: camPlan, wall: w)
        }
        return PlanReading(id: r.id, kind: r.kind, n: nil, pos: pos,
                           value: r.kind == "reading" ? r.value : nil, material: r.material,
                           note: r.note, photo: r.photo, takenAt: r.takenAt,
                           height: height, wallId: wallId, wallT: wallT,
                           reference: r.reference, worldPoint: world,
                           cam: (r.cameraPosition.x.isFinite && r.cameraPosition.z.isFinite) ? camPlan : nil,
                           status: r.status, side: side)
    }

    /// Which side of a plan wall a point is on (docs/MARKING.md H, docs/MOISTURE.md): "a" when it
    /// is on the side of the wall's left normal n = (-d.y, d.x), d = b - a; else "b".
    static func side(of p: PlanVec, wall w: PlanWall) -> String {
        let d = w.b - w.a
        return simd_dot(p - w.a, PlanVec(-d.y, d.x)) >= 0 ? "a" : "b"
    }

    /// Equipment stands on the floor: the floor point under the crosshair (the
    /// camera ray meets the floor plane); if the ray meets the floor well beyond
    /// the raycast hit (looking at a wall) or not at all, the raycast hit
    /// projected to the floor; else the camera position. Never snapped to a wall.
    /// kind "affected": every outline point onto the floor, then closed,
    /// simplified and checked (Sweep.floorPolygon).
    static func affectedArea(_ r: PBReading, globalFloorY: Double?, transform: PlanTransform) -> Result<PlanAffected, RevisitError> {
        let pts = r.corners.map { c -> PlanVec in
            let one = PBReading(id: r.id, seq: r.seq, kind: "equipment", value: nil, material: "", takenAt: r.takenAt,
                                cameraPosition: c.cameraPosition, cameraForward: c.cameraForward, hit: c.hit)
            return resolveOnFloor(one, globalFloorY: globalFloorY, transform: transform).pos
        }
        return Sweep.floorPolygon(pts).map { PlanAffected(id: r.id, polygon: $0, label: r.note, takenAt: r.takenAt) }
    }

    static func resolveOnFloor(_ r: PBReading, globalFloorY: Double?, transform: PlanTransform) -> PlanReading {
        let camPlan = transform.point(r.cameraPosition)
        let flen = simd_length(r.cameraForward)
        let f3 = flen > 1e-9 ? r.cameraForward / flen : WorldVec(0, 0, -1)
        let hitT: Double? = r.hit.map { simd_dot($0 - r.cameraPosition, f3) }
        var world: WorldVec? = nil
        if let fy = globalFloorY, f3.y < -0.05 {
            let t = (fy - r.cameraPosition.y) / f3.y
            if t > 0, t <= floorRayMax, t <= (hitT ?? .infinity) + 0.3 {
                world = r.cameraPosition + f3 * t
            }
        }
        if world == nil, let hit = r.hit {
            world = WorldVec(hit.x, globalFloorY ?? hit.y, hit.z)
        }
        return PlanReading(id: r.id, kind: r.kind, n: nil, pos: world.map { transform.point($0) } ?? camPlan,
                           value: nil, material: r.material, note: r.note, photo: r.photo, takenAt: r.takenAt,
                           height: 0, wallId: nil, wallT: nil, reference: false, worldPoint: world,
                           cam: (r.cameraPosition.x.isFinite && r.cameraPosition.z.isFinite) ? camPlan : nil)
    }

    /// Two taps -> one stretch of one wall (or, for flooring away from walls,
    /// two floor points). Both taps go through the same resolver as readings.
    /// If they land on different walls, the end is snapped onto the start's
    /// wall when it is within `removalSnap` of it (or the start onto the end's
    /// wall); otherwise the removal is rejected.
    static func resolveRemoval(_ r: PBReading, walls: [PlanWall], wallFloorY: [Double?],
                               globalFloorY: Double?, transform: PlanTransform,
                               rooms: [[PlanVec]] = []) -> RemovalResolution {
        let flooring = r.material == "flooring"
        let cam: PlanVec? = (r.cameraPosition.x.isFinite && r.cameraPosition.z.isFinite) ? transform.point(r.cameraPosition) : nil
        var out = PlanRemoval(id: r.id, item: r.material, heightMm: r.heightMm ?? 0, note: r.note, takenAt: r.takenAt,
                              photo: r.photo, wallId: nil, t0: nil, t1: nil, area: nil,
                              floorType: r.floorType, underlay: r.underlay, cam: cam)
        out.side = r.side

        if flooring {
            if r.wholeRoom {
                guard let c = cam, let i = FloorArea.room(containing: c, rooms: rooms) else {
                    return .rejected("You weren't standing inside a scanned room, so the whole room couldn't be used.")
                }
                out.area = rooms[i]
                return .placed(out)
            }
            let pts = r.corners.map { pose -> PlanVec in
                var c = r
                c.cameraPosition = pose.cameraPosition
                c.cameraForward = pose.cameraForward
                c.hit = pose.hit
                return resolveOnFloor(c, globalFloorY: globalFloorY, transform: transform).pos
            }
            switch FloorArea.polygon(pts) {
            case .success(let poly): out.area = poly; return .placed(out)
            case .failure(let e): return .rejected(e.message)
            }
        }

        guard let end = r.end else { return .rejected("The removal has no end point.") }
        var a = r
        a.kind = "removal-point"
        a.material = "wall"
        var b = a
        b.cameraPosition = end.cameraPosition
        b.cameraForward = end.cameraForward
        b.hit = end.hit
        b.photo = nil
        let ra = resolve(a, walls: walls, wallFloorY: wallFloorY, globalFloorY: globalFloorY, transform: transform)
        let rb = resolve(b, walls: walls, wallFloorY: wallFloorY, globalFloorY: globalFloorY, transform: transform)
        func wall(_ id: String?) -> PlanWall? { walls.first { $0.id == id } }
        if let wa = wall(ra.wallId), ra.wallId == rb.wallId {
            return stretch(&out, wall: wa, ra.pos, rb.pos)
        }
        if let wa = wall(ra.wallId), distanceToSegment(rb.pos, wa.a, wa.b) <= removalSnap {
            return stretch(&out, wall: wa, ra.pos, rb.pos)
        }
        if let wb = wall(rb.wallId), distanceToSegment(ra.pos, wb.a, wb.b) <= removalSnap {
            return stretch(&out, wall: wb, ra.pos, rb.pos)
        }
        if ra.wallId == nil || rb.wallId == nil {
            return .rejected("One end of the removal is not on a wall.")
        }
        return .rejected("The start and end are on different walls. Mark each wall as its own removal.")
    }

    private static func stretch(_ out: inout PlanRemoval, wall w: PlanWall, _ p: PlanVec, _ q: PlanVec) -> RemovalResolution {
        let u = projectParam(p, w.a, w.b), v = projectParam(q, w.a, w.b)
        guard abs(v - u) * w.length >= removalMinLength else { return .rejected("The removal is too short - the two points are in the same place.") }
        out.wallId = w.id
        out.t0 = min(u, v)
        out.t1 = max(u, v)
        if let c = out.cam, out.side == "a" || out.side == "b" { out.side = side(of: c, wall: w) }
        return .placed(out)
    }

    /// "Floor type" tag: the room the camera is in gets that floor type.
    static func floorZone(_ r: PBReading, transform: PlanTransform, rooms: [[PlanVec]]) -> PlanFloorZone? {
        let cam = transform.point(r.cameraPosition)
        guard let i = FloorArea.room(containing: cam, rooms: rooms) else { return nil }
        return PlanFloorZone(id: r.id, polygon: rooms[i], type: r.floorType ?? r.material, takenAt: r.takenAt)
    }

    // MARK: Naming

    static func roomName(labels: [String], index: Int) -> String {
        let map = ["bedroom": "Bedroom", "bathroom": "Bathroom", "kitchen": "Kitchen",
                   "livingRoom": "Living Room", "diningRoom": "Dining Room"]
        var counts: [String: Int] = [:]
        var order: [String] = []
        for l in labels {
            guard let name = map[l] else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        var best: String? = nil
        for name in order where best == nil || counts[name]! > counts[best!]! { best = name }
        return best ?? "Room \(index + 1)"
    }

    // MARK: Geometry helpers

    static func signedArea(_ p: [PlanVec]) -> Double {
        guard p.count >= 3 else { return 0 }
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    static func centroid(_ p: [PlanVec]) -> PlanVec {
        guard !p.isEmpty else { return .zero }
        return p.reduce(PlanVec.zero, +) / Double(p.count)
    }

    /// Parameter (clamped 0...1) of the projection of p onto segment a-b.
    static func projectParam(_ p: PlanVec, _ a: PlanVec, _ b: PlanVec) -> Double {
        let e = b - a
        let l2 = simd_dot(e, e)
        guard l2 > 1e-12 else { return 0 }
        return min(max(simd_dot(p - a, e) / l2, 0), 1)
    }

    static func distanceToSegment(_ p: PlanVec, _ a: PlanVec, _ b: PlanVec) -> Double {
        simd_distance(p, a + (b - a) * projectParam(p, a, b))
    }

    static func nearestWall(to p: PlanVec, walls: [PlanWall], maxDistance: Double) -> (index: Int, distance: Double)? {
        var best: (Int, Double)? = nil
        for (i, w) in walls.enumerated() {
            let d = distanceToSegment(p, w.a, w.b)
            if d <= maxDistance, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best.map { (index: $0.0, distance: $0.1) }
    }

    static func meanDistance(_ pts: [PlanVec], to walls: [WorkWall]) -> Double {
        guard !pts.isEmpty, !walls.isEmpty else { return .infinity }
        let total = pts.reduce(0.0) { acc, p in
            acc + (walls.map { distanceToSegment(p, $0.a, $0.b) }.min() ?? 0)
        }
        return total / Double(pts.count)
    }

    static func dedupe(_ p: [PlanVec]) -> [PlanVec] {
        var out: [PlanVec] = []
        for q in p where out.last.map({ simd_distance($0, q) > 0.01 }) ?? true { out.append(q) }
        if out.count > 1, let f = out.first, let l = out.last, simd_distance(f, l) <= 0.01 { out.removeLast() }
        return out
    }

    static func convexHull(_ points: [PlanVec]) -> [PlanVec] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count >= 3 else { return p }
        var lower: [PlanVec] = [], upper: [PlanVec] = []
        for q in p {
            while lower.count >= 2 && cross2(lower[lower.count - 1] - lower[lower.count - 2], q - lower[lower.count - 2]) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross2(upper[upper.count - 1] - upper[upper.count - 2], q - upper[upper.count - 2]) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    static func normaliseAngle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x <= -.pi { x += 2 * .pi }
        return x
    }
}
