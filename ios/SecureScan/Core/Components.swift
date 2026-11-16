//
//  Components.swift
//  SecureScan
//
//  Marking by component (docs/MARKING.md): the room as things you can point at -
//  wall faces and their segments, skirting runs, the floor, doors and windows,
//  cabinets and appliances - and the rules that keep a finger's scrub on the
//  thing it started on:
//    * WorldOpening / WorldObject - RoomPlan's openings and objects, world space
//    * ComponentIndex             - segments, the hovered component, ray / box hits
//    * WallRun / Scrub            - skirting scrubs: snapping, the run round a corner
//    * FloorPaint                 - floor scrubs: painted cells, area, outline
//    * TideLine                   - the moisture tide line along a wall
//    * StripBack                  - wall strip-back: the cut height and its snapping
//    * Suggest                    - the one suggestion chip after a capture
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

// MARK: - Openings and objects (world space, y up, floor = CaptureWorld.floorY)

struct WorldOpening: Equatable {
    var id: String
    /// "door" | "window" | "opening"
    var kind: String
    var wallId: String
    /// Along the wall a -> b.
    var t0: Double
    var t1: Double
    /// Above the floor (m).
    var bottom: Double
    var top: Double

    /// Doors and floor-reaching openings cut the skirting; windows don't.
    var reachesFloor: Bool { kind != "window" && bottom < 0.15 }
}

struct WorldObject: Equatable {
    var id: String
    /// RoomPlan's category name ("storage", "sink", ...).
    var category: String
    /// Box centre (world).
    var center: WorldVec
    /// Width (local x), height (y), depth (local z), metres.
    var size: WorldVec
    /// Rotation about +y: local x = (cos, 0, -sin), local z = (sin, 0, cos).
    var yaw: Double

    static let cabinetry: Set<String> = ["storage", "sink", "oven", "dishwasher", "stove"]
    static let appliances: Set<String> = ["refrigerator", "washerDryer"]
    static let waterEntry: Set<String> = ["sink", "toilet", "bathtub", "washerDryer", "dishwasher"]

    var isCabinetry: Bool { Self.cabinetry.contains(category) }
    var isAppliance: Bool { Self.appliances.contains(category) }
    /// Strip-out can remove it (cabinetry, or an appliance taken out with it).
    var isRemovable: Bool { isCabinetry || isAppliance }
    var isWaterEntry: Bool { Self.waterEntry.contains(category) }

    var axisX: WorldVec { WorldVec(cos(yaw), 0, -sin(yaw)) }
    var axisZ: WorldVec { WorldVec(sin(yaw), 0, cos(yaw)) }

    /// The 8 corners: bottom 4 (front-left, front-right, back-right, back-left), then the top 4.
    var corners: [WorldVec] {
        let hx = axisX * (size.x / 2), hz = axisZ * (size.z / 2), hy = WorldVec(0, size.y / 2, 0)
        let base = [center - hx + hz, center + hx + hz, center + hx - hz, center - hx - hz]
        return base.map { $0 - hy } + base.map { $0 + hy }
    }

    /// Heights for objects saved without one (plan.json keeps footprints only).
    static func defaultHeight(_ category: String) -> Double {
        switch category {
        case "bathtub": return 0.55
        case "toilet": return 0.8
        case "refrigerator": return 1.8
        case "table": return 0.75
        case "bed", "sofa": return 0.6
        default: return 0.9
        }
    }

    /// Plain words: "vanity" for storage with a sink near it is decided by the caller.
    var name: String {
        switch category {
        case "storage": return "cabinet"
        case "washerDryer": return "washer"
        case "refrigerator": return "fridge"
        default: return category
        }
    }
}

// MARK: - Components

struct Component: Equatable, Identifiable {
    enum Kind: Equatable { case skirting, wallFace, cabinet, floor, waterCandidate, ceiling }
    var id: String
    var kind: Kind
    var wallId: String? = nil
    var t0 = 0.0
    var t1 = 1.0
    var objectId: String? = nil
    var roomName: String? = nil
    /// Water candidates: the point the ring is drawn at.
    var point: WorldVec? = nil
}

extension CaptureWorld {
    /// A ray against the room model (walls with their heights, the floor and ceiling inside the
    /// rooms, objects): the first hit and its normal. For a finger on the screen.
    func raycast(origin o: WorldVec, dir d: WorldVec) -> (WorldVec, WorldVec)? {
        let fy = floorY ?? 0
        var best: (Double, WorldVec)? = nil
        func consider(_ t: Double, _ n: WorldVec) { if t > 0.02, t < (best?.0 ?? .infinity) { best = (t, n) } }
        for w in walls {
            let ab = w.b - w.a
            let n2 = PlanVec(-ab.y, ab.x)
            let n = WorldVec(n2.x, 0, n2.y)
            let denom = simd_dot(d, n)
            guard abs(denom) > 1e-9 else { continue }
            let t = simd_dot(WorldVec(w.a.x, 0, w.a.y) - WorldVec(o.x, 0, o.z), n) / denom
            let p = o + d * t
            let u = simd_dot(PlanVec(p.x, p.z) - w.a, ab) / max(simd_length_squared(ab), 1e-12)
            guard u >= 0, u <= 1, p.y >= fy, p.y <= fy + w.height else { continue }
            let nn = simd_normalize(n)
            consider(t, simd_dot(nn, d) > 0 ? -nn : nn)
        }
        let top = fy + (walls.map(\.height).max() ?? 2.4)
        if abs(d.y) > 1e-9 {
            for (y, n) in [(fy, WorldVec(0, 1, 0)), (top, WorldVec(0, -1, 0))] {
                let t = (y - o.y) / d.y
                let p = o + d * t
                if rooms.isEmpty || room(containing: PlanVec(p.x, p.z)) != nil { consider(t, n) }
            }
        }
        for ob in objects { if let t = ComponentIndex.rayBox(origin: o, dir: d, ob) { consider(t, WorldVec(0, 1, 0)) } }
        return best.map { (o + d * $0.0, $0.1) }
    }

    func wall(_ id: String?) -> WorldWall? { id.flatMap { i in walls.first { $0.id == i } } }
    func object(_ id: String?) -> WorldObject? { id.flatMap { i in objects.first { $0.id == i } } }
    func openings(on wallId: String) -> [WorldOpening] { openings.filter { $0.wallId == wallId } }
}

enum ComponentIndex {
    static let minSegment = 0.10
    /// A floor aim this close to a wall counts as aiming at its skirting.
    static let floorToWall = 0.35

    /// A wall's stretches between doors (`floorOnly`: only openings that reach the floor cut it).
    static func segments(_ wall: WorldWall, openings: [WorldOpening], floorOnly: Bool = true) -> [(Double, Double)] {
        let len = max(wall.length, 1e-9)
        let cuts = openings.filter { $0.wallId == wall.id && (!floorOnly || $0.reachesFloor) }
            .map { (max(0, min($0.t0, $0.t1)), min(1, max($0.t0, $0.t1))) }
            .sorted { $0.0 < $1.0 }
        var out: [(Double, Double)] = []
        var start = 0.0
        for c in cuts {
            if (c.0 - start) * len >= minSegment { out.append((start, c.0)) }
            start = max(start, c.1)
        }
        if (1 - start) * len >= minSegment { out.append((start, 1)) }
        return out
    }

    /// The segment containing `t` (nil inside a doorway).
    static func segment(containing t: Double, _ segs: [(Double, Double)]) -> (Int, (Double, Double))? {
        for (i, s) in segs.enumerated() where t >= s.0 - 1e-9 && t <= s.1 + 1e-9 { return (i, s) }
        return nil
    }

    /// The wall the aim is on (or, on the floor, the nearest wall within 0.35 m) and its t.
    static func aimedWall(_ aim: Aim, world: CaptureWorld) -> (WorldWall, Double)? {
        guard let h = aim.hit else { return nil }
        let p = PlanVec(h.x, h.z)
        if let w = aim.wall { return (w, PlanBuilder.projectParam(p, w.a, w.b)) }
        if aim.surface == .wall || aim.surface == .floor, let n = world.nearestWall(to: p, maxDistance: aim.surface == .wall ? 0.3 : floorToWall) {
            return (n.wall, n.t)
        }
        return nil
    }

    static func wallComponent(_ kind: Component.Kind, wall: WorldWall, t: Double, world: CaptureWorld) -> Component? {
        let segs = segments(wall, openings: world.openings)
        guard let found = segment(containing: min(max(t, 0), 1), segs) else { return nil }
        let tag = kind == .skirting ? "skirting" : "face"
        return Component(id: "\(tag)-\(wall.id)-\(found.0)", kind: kind, wallId: wall.id, t0: found.1.0, t1: found.1.1)
    }

    /// The component under the reticle for a kind of marking (nil = nothing to highlight).
    static func hover(_ kind: Component.Kind, aim: Aim, origin: WorldVec?, dir: WorldVec?, world: CaptureWorld) -> Component? {
        switch kind {
        case .skirting, .wallFace:
            guard let aimed = aimedWall(aim, world: world) else { return nil }
            return wallComponent(kind, wall: aimed.0, t: aimed.1, world: world)
        case .cabinet:
            guard let o = origin, let d = dir else { return nil }
            var best: (Double, WorldObject)? = nil
            for ob in world.objects where ob.isRemovable {
                if let t = rayBox(origin: o, dir: d, ob), t < (best?.0 ?? .infinity) { best = (t, ob) }
            }
            return best.map { Component(id: "cab-\($0.1.id)", kind: .cabinet, objectId: $0.1.id) }
        case .floor:
            guard let h = aim.hit, let room = world.room(containing: PlanVec(h.x, h.z)) else { return nil }
            return Component(id: "floor-\(room.name)", kind: .floor, roomName: room.name)
        case .waterCandidate, .ceiling:
            if aim.surface == .ceiling, let h = aim.hit { return Component(id: "ceiling", kind: .ceiling, point: h) }
            let cands = waterCandidates(world)
            if let o = origin, let d = dir {
                for ob in world.objects where ob.isWaterEntry {
                    if rayBox(origin: o, dir: d, ob) != nil { return cands.first { $0.objectId == ob.id } }
                }
            }
            guard let h = aim.hit else { return nil }
            return cands.min { simd_distance($0.point ?? h, h) < simd_distance($1.point ?? h, h) }
                .flatMap { c in simd_distance(c.point ?? .zero, h) <= 0.6 ? c : nil }
        }
    }

    /// Sinks, toilets, baths, washers, dishwashers (their top centre) and window sills.
    static func waterCandidates(_ world: CaptureWorld) -> [Component] {
        var out: [Component] = []
        for ob in world.objects where ob.isWaterEntry {
            out.append(Component(id: "water-\(ob.id)", kind: .waterCandidate, objectId: ob.id,
                                 point: ob.center + WorldVec(0, ob.size.y / 2, 0)))
        }
        let fy = world.floorY ?? 0
        for op in world.openings where op.kind == "window" {
            guard let w = world.wall(op.wallId) else { continue }
            let p = w.a + (w.b - w.a) * ((op.t0 + op.t1) / 2)
            out.append(Component(id: "water-\(op.id)", kind: .waterCandidate, wallId: w.id, t0: op.t0, t1: op.t1,
                                 point: WorldVec(p.x, fy + op.bottom, p.y)))
        }
        return out
    }

    /// Distance along a ray to where it enters a box (nil = misses).
    static func rayBox(origin: WorldVec, dir: WorldVec, _ ob: WorldObject) -> Double? {
        let rel = origin - ob.center
        let o = WorldVec(simd_dot(rel, ob.axisX), rel.y, simd_dot(rel, ob.axisZ))
        let d = WorldVec(simd_dot(dir, ob.axisX), dir.y, simd_dot(dir, ob.axisZ))
        let half = ob.size / 2
        var tmin = -Double.infinity, tmax = Double.infinity
        for k in 0..<3 {
            if abs(d[k]) < 1e-12 {
                if abs(o[k]) > half[k] { return nil }
                continue
            }
            var a = (-half[k] - o[k]) / d[k], b = (half[k] - o[k]) / d[k]
            if a > b { swap(&a, &b) }
            tmin = max(tmin, a)
            tmax = min(tmax, b)
            if tmin > tmax { return nil }
        }
        guard tmax > 0 else { return nil }
        return max(tmin, 0)
    }

    /// The wall a box stands against (its back within 0.3 m) and its stretch on it.
    static func wallStretch(_ ob: WorldObject, world: CaptureWorld) -> (WorldWall, Double, Double)? {
        let c = PlanVec(ob.center.x, ob.center.z)
        guard let n = world.nearestWall(to: c, maxDistance: max(ob.size.x, ob.size.z) / 2 + 0.3) else { return nil }
        let base = ob.corners.prefix(4).map { PlanVec($0.x, $0.z) }
        let ts = base.map { PlanBuilder.projectParam($0, n.wall.a, n.wall.b) }
        guard let lo = ts.min(), let hi = ts.max() else { return nil }
        return (n.wall, max(0, lo), min(1, hi))
    }
}

// MARK: - Scrubbing along a wall's base (skirting) or over its face

struct WallPiece: Equatable {
    var wallId: String
    /// Where the piece started (a segment end when it came round a corner) and where it got to.
    var tA: Double
    var tB: Double
}

struct WallRun: Equatable {
    var pieces: [WallPiece]

    func length(_ world: CaptureWorld) -> Double {
        pieces.reduce(0) { s, p in s + abs(p.tB - p.tA) * (world.wall(p.wallId)?.length ?? 0) }
    }

    /// The pieces as world lines at floor level (for drawing and saving).
    func lines(_ world: CaptureWorld) -> [(WorldVec, WorldVec, String)] {
        let fy = world.floorY ?? 0
        return pieces.compactMap { p in
            guard let w = world.wall(p.wallId) else { return nil }
            let a = w.a + (w.b - w.a) * min(p.tA, p.tB), b = w.a + (w.b - w.a) * max(p.tA, p.tB)
            return (WorldVec(a.x, fy, a.y), WorldVec(b.x, fy, b.y), w.id)
        }
    }
}

enum Scrub {
    static let snapDistance = 0.15
    /// How far past a corner the finger must go onto the next wall to continue the run.
    static let cornerEnter = 0.10
    static let cornerTolerance = 0.08

    /// Where a ray meets a wall's vertical plane: t along the wall (unclamped) and the height
    /// above the floor. A ray that reaches the floor first is projected from the floor onto the wall.
    static func wallHit(origin o: WorldVec, dir d: WorldVec, wall w: WorldWall, floorY: Double) -> (t: Double, h: Double)? {
        let ab = w.b - w.a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-12 else { return nil }
        let n = WorldVec(-ab.y, 0, ab.x)
        let denom = simd_dot(d, n)
        var hit: WorldVec? = nil
        if abs(denom) > 1e-9 {
            let t = simd_dot(WorldVec(w.a.x, 0, w.a.y) - WorldVec(o.x, 0, o.z), n) / denom
            if t > 0 { hit = o + d * t }
        }
        if (hit == nil || hit!.y < floorY), d.y < -1e-9 {
            let tf = (floorY - o.y) / d.y
            if tf > 0 { hit = WorldVec(o.x + d.x * tf, floorY, o.z + d.z * tf) }
        }
        guard let p = hit else { return nil }
        let t = simd_dot(PlanVec(p.x, p.z) - w.a, ab) / len2
        return (t, max(0, p.y - floorY))
    }

    /// `t` kept inside the segment, and snapped onto its ends within 0.15 m.
    static func snap(_ t: Double, segment s: (Double, Double), length: Double) -> Double {
        let c = min(max(t, s.0), s.1)
        if (c - s.0) * length <= snapDistance { return s.0 }
        if (s.1 - c) * length <= snapDistance { return s.1 }
        return c
    }

    /// The wall sharing the corner at `point` (other than `wall`), and that corner's t on it.
    static func neighbour(of wall: WorldWall, at point: PlanVec, world: CaptureWorld) -> (WorldWall, Double)? {
        for w in world.walls where w.id != wall.id {
            if simd_distance(w.a, point) <= cornerTolerance { return (w, 0) }
            if simd_distance(w.b, point) <= cornerTolerance { return (w, 1) }
        }
        return nil
    }

    /// A new run from a ray on a component (skirting segment).
    static func start(_ c: Component, origin: WorldVec, dir: WorldVec, world: CaptureWorld) -> WallRun? {
        guard let w = world.wall(c.wallId), let h = wallHit(origin: origin, dir: dir, wall: w, floorY: world.floorY ?? 0) else { return nil }
        let t = snap(h.t, segment: (c.t0, c.t1), length: w.length)
        return WallRun(pieces: [WallPiece(wallId: w.id, tA: t, tB: t)])
    }

    /// The run after the finger moved: along its segment, snapping to ends; round a corner onto
    /// the next wall only when the finger is clearly on it; back again when it returns.
    static func extend(_ run: WallRun, origin o: WorldVec, dir d: WorldVec, world: CaptureWorld) -> WallRun {
        var r = run
        guard var last = r.pieces.last, let wall = world.wall(last.wallId) else { return r }
        let fy = world.floorY ?? 0
        let len = max(wall.length, 1e-9)
        // Where the finger's ray really lands (walls, floor, objects), to tell which wall it is on.
        let landed = world.raycast(origin: o, dir: d).map { PlanVec($0.0.x, $0.0.z) }
        func dist(_ w: WorldWall) -> Double { landed.map { PlanBuilder.distanceToSegment($0, w.a, w.b) } ?? .infinity }
        // Back onto the previous wall: the last piece goes.
        if r.pieces.count > 1, let pw = world.wall(r.pieces[r.pieces.count - 2].wallId), let lp = landed, dist(pw) < dist(wall) - 0.02 {
            var prev = r.pieces[r.pieces.count - 2]
            let corner = prev.tB
            let pt = PlanBuilder.projectParam(lp, pw.a, pw.b)
            let inside = corner >= 0.5 ? (corner - pt) * pw.length : (pt - corner) * pw.length
            if inside >= cornerEnter {
                let segs = ComponentIndex.segments(pw, openings: world.openings)
                let seg = ComponentIndex.segment(containing: corner, segs)?.1 ?? (0, 1)
                let ph = wallHit(origin: o, dir: d, wall: pw, floorY: fy)?.t ?? pt
                prev.tB = snap(ph, segment: seg, length: pw.length)
                r.pieces.removeLast()
                r.pieces[r.pieces.count - 1] = prev
                return r
            }
        }
        let segs = ComponentIndex.segments(wall, openings: world.openings)
        let seg = ComponentIndex.segment(containing: last.tA, segs)?.1 ?? (0, 1)
        // Onto the neighbour round a corner (the segment ends at the wall's end), only when the
        // finger is clearly on that wall.
        if let lp = landed {
            for end in [seg.1, seg.0] where end <= 1e-9 || end >= 1 - 1e-9 {
                let point = end >= 0.5 ? wall.b : wall.a
                guard let nbr = neighbour(of: wall, at: point, world: world) else { continue }
                let nb = nbr.0, ct = nbr.1
                guard dist(nb) < dist(wall) - 0.02 else { continue }
                let nt = PlanBuilder.projectParam(lp, nb.a, nb.b)
                let into = ct < 0.5 ? nt * nb.length : (1 - nt) * nb.length
                guard into >= cornerEnter, nt >= -0.05, nt <= 1.05 else { continue }
                let nsegs = ComponentIndex.segments(nb, openings: world.openings)
                guard let nseg = ComponentIndex.segment(containing: ct, nsegs)?.1 else { continue }
                let nh = wallHit(origin: o, dir: d, wall: nb, floorY: fy)?.t ?? nt
                last.tB = end
                r.pieces[r.pieces.count - 1] = last
                r.pieces.append(WallPiece(wallId: nb.id, tA: ct, tB: snap(nh, segment: nseg, length: nb.length)))
                return r
            }
        }
        guard let h = wallHit(origin: o, dir: d, wall: wall, floorY: fy) else { return r }
        last.tB = snap(h.t, segment: seg, length: len)
        r.pieces[r.pieces.count - 1] = last
        return r
    }

    /// Metres left from the run's head to the end of its segment, and what that end is.
    static func remaining(_ run: WallRun, world: CaptureWorld) -> (metres: Double, wallEnd: Bool)? {
        guard let p = run.pieces.last, let w = world.wall(p.wallId) else { return nil }
        let segs = ComponentIndex.segments(w, openings: world.openings)
        guard let seg = ComponentIndex.segment(containing: p.tA, segs)?.1 else { return nil }
        let forward = p.tB >= p.tA
        let end = forward ? seg.1 : seg.0
        return (abs(end - p.tB) * w.length, end <= 1e-9 || end >= 1 - 1e-9)
    }
}

// MARK: - Painting the floor

struct FloorPaint: Equatable {
    struct Cell: Hashable { var x: Int; var z: Int }
    static let cell = 0.10
    static let brush = 0.25

    var room: [PlanVec]
    private(set) var cells: Set<Cell> = []

    init(room: [PlanVec]) { self.room = room }

    /// Paints a brush-sized disc at a floor point (inside the room only).
    mutating func paint(_ p: PlanVec) {
        let r = Int((Self.brush / Self.cell).rounded(.up))
        let cx = Int((p.x / Self.cell).rounded(.down)), cz = Int((p.y / Self.cell).rounded(.down))
        for dx in -r...r { for dz in -r...r {
            let c = Cell(x: cx + dx, z: cz + dz)
            let centre = PlanVec((Double(c.x) + 0.5) * Self.cell, (Double(c.z) + 0.5) * Self.cell)
            guard simd_distance(centre, p) <= Self.brush else { continue }
            if room.count >= 3 && !FloorArea.inside(centre, room) { continue }
            cells.insert(c)
        } }
    }

    var area: Double { Double(cells.count) * Self.cell * Self.cell }

    /// The painted outline (convex hull of the cells' corners) - the polygon that is saved.
    var outline: [PlanVec] {
        var pts: [PlanVec] = []
        for c in cells {
            let x = Double(c.x) * Self.cell, z = Double(c.z) * Self.cell
            pts += [PlanVec(x, z), PlanVec(x + Self.cell, z), PlanVec(x + Self.cell, z + Self.cell), PlanVec(x, z + Self.cell)]
        }
        return pts.count >= 3 ? PlanBuilder.convexHull(pts) : []
    }
}

// MARK: - The moisture tide line

struct TideLine: Equatable {
    static let bucket = 0.10
    var wallId: String
    /// Bucket (0.10 m along the wall) -> height above the floor (m): the last height scrubbed there.
    private(set) var samples: [Int: Double] = [:]

    init(wallId: String) { self.wallId = wallId }

    mutating func add(t: Double, height: Double, wallLength: Double) {
        let k = Int((min(max(t, 0), 1) * wallLength / Self.bucket).rounded(.down))
        samples[k] = max(0, height)
    }

    var maxHeight: Double { samples.values.max() ?? 0 }
    var maxMm: Int { Int((maxHeight * 1000).rounded()) }

    /// The line on the wall, in wall order, every `every` metres (world points).
    func points(_ world: CaptureWorld, every: Double = 0.25) -> [WorldVec] {
        guard let w = world.wall(wallId), !samples.isEmpty else { return [] }
        let fy = world.floorY ?? 0
        let keys = samples.keys.sorted()
        let step = max(1, Int((every / Self.bucket).rounded()))
        var chosen: [Int] = []
        for (i, k) in keys.enumerated() where i % step == 0 || i == keys.count - 1 { chosen.append(k) }
        return chosen.map { k in
            let t = min(1, (Double(k) + 0.5) * Self.bucket / max(w.length, 1e-9))
            let p = w.a + (w.b - w.a) * t
            return WorldVec(p.x, fy + (samples[k] ?? 0), p.y)
        }
    }
}

// MARK: - Wall strip-back

struct StripBack: Equatable {
    static let standards = [300, 600, 900, 1200]
    var wallId: String
    var t0: Double
    var t1: Double
    var heightMm: Int

    /// Snapped to 300 / 600 / 900 / 1200 within 40 mm, else to 50 mm (at least 100 mm).
    static func snap(_ mm: Double, fullMm: Int) -> Int {
        if let s = standards.first(where: { abs(Double($0) - mm) <= 40 }) { return s }
        if abs(Double(fullMm) - mm) <= 40 { return fullMm }
        return min(fullMm, max(100, Int((mm / 50).rounded()) * 50))
    }

    /// The cut for a tide line H mm: the smallest standard height at least H + 150 (nil = full height).
    static func cut(forTideMm h: Int) -> Int? { standards.first { $0 >= h + 150 } }

    func area(_ world: CaptureWorld) -> Double {
        (world.wall(wallId)?.length ?? 0) * abs(t1 - t0) * Double(heightMm) / 1000
    }
}

// MARK: - Suggestions

struct Suggestion: Equatable {
    enum Kind: Equatable {
        case skirtingWall(wallId: String)
        case stripWall(wallId: String, mm: Int?)
        case liftCarpet(areaId: String)
        case removeCabinet(objectId: String)
    }
    var kind: Kind
    var text: String
    var action: String

    /// For "don't offer this again".
    var key: String {
        switch kind {
        case .skirtingWall(let w): return "skirting-\(w)"
        case .stripWall(let w, _): return "strip-\(w)"
        case .liftCarpet(let a): return "carpet-\(a)"
        case .removeCabinet(let o): return "cab-\(o)"
        }
    }
}

enum Suggest {
    static let skirtingHeight = 0.15

    /// A wet reading at skirting height on a wall that has no skirting removal yet.
    static func afterReading(value: Double, height: Double?, wallId: String?, wet: Double = 20, wallsWithSkirting: Set<String>) -> Suggestion? {
        guard value >= wet, let h = height, h <= skirtingHeight, let w = wallId, !wallsWithSkirting.contains(w) else { return nil }
        return Suggestion(kind: .skirtingWall(wallId: w), text: "Mark skirting along this wall?", action: "Yes")
    }

    /// A tide line H mm high: strip the wall to the next standard cut.
    static func afterTide(maxMm h: Int, wallId: String) -> Suggestion {
        let c = StripBack.cut(forTideMm: h)
        return Suggestion(kind: .stripWall(wallId: wallId, mm: c),
                          text: "Moisture reached \(h) — cut at \(c.map(String.init) ?? "full height")?", action: "Yes")
    }

    /// A wet floor area on carpet: lift the carpet and underlay there.
    static func afterWetFloor(floorType: String?, areaId: String) -> Suggestion? {
        guard floorType == "carpet" else { return nil }
        return Suggestion(kind: .liftCarpet(areaId: areaId), text: "Lift carpet + underlay in this area?", action: "Add")
    }

    /// A leak at a sink or a vanity: remove that cabinet.
    static func afterSource(at p: WorldVec, objects: [WorldObject]) -> Suggestion? {
        let near = objects.filter { ($0.category == "sink" || $0.category == "storage") && distance(p, $0) <= 0.8 }
        guard let ob = near.min(by: { distance(p, $0) < distance(p, $1) }) else { return nil }
        let name = ob.category == "sink" || objects.contains(where: { $0.category == "sink" && simd_distance($0.center, ob.center) < 0.8 }) ? "vanity" : "cabinet"
        return Suggestion(kind: .removeCabinet(objectId: ob.id), text: "Remove cabinetry: \(name)?", action: "Add")
    }

    /// Point-to-box distance (0 inside).
    static func distance(_ p: WorldVec, _ ob: WorldObject) -> Double {
        let rel = p - ob.center
        let l = WorldVec(simd_dot(rel, ob.axisX), rel.y, simd_dot(rel, ob.axisZ))
        let q = simd_max(simd_abs(l) - ob.size / 2, WorldVec(0, 0, 0))
        return simd_length(q)
    }
}

// MARK: - Walls have two sides (docs/MARKING.md H)

enum WallSide {
    static let a = "a", b = "b", cavity = "cavity"

    /// Side "a" is where the wall's left normal points (a -> b in plan x, z); "b" the other.
    static func normal(_ w: WorldWall) -> PlanVec {
        let ab = w.b - w.a
        let l = simd_length(ab)
        return l > 1e-12 ? PlanVec(-ab.y, ab.x) / l : PlanVec(0, 1)
    }

    /// Which side of the wall a point (a camera) is on.
    static func side(of p: PlanVec, wall w: WorldWall) -> String {
        simd_dot(p - w.a, normal(w)) >= 0 ? a : b
    }

    /// The point on a wall's face (`side` "a" / "b"), `offset` metres off the wall line.
    static func facePoint(_ w: WorldWall, t: Double, height: Double, floorY: Double, side: String, offset: Double = 0.01) -> WorldVec {
        let n = normal(w) * (side == b ? -1 : 1)
        let p = w.a + (w.b - w.a) * t + n * offset
        return WorldVec(p.x, floorY + height, p.y)
    }

    /// The wall a point sits on (within `within` m of its line, inside its length).
    static func wall(at p: WorldVec, world: CaptureWorld, within: Double = 0.15) -> WorldWall? {
        world.nearestWall(to: PlanVec(p.x, p.z), maxDistance: within).map(\.wall)
    }
}

enum Visibility {
    /// A surface more than this in front of a mark hides it.
    static let tolerance = 0.05

    /// True when a wall of the room model stands between the camera and the point (by more than
    /// 5 cm). Doors, openings and windows don't block.
    static func occluded(_ p: WorldVec, camera c: WorldVec, world: CaptureWorld) -> Bool {
        let fy = world.floorY ?? 0
        let v = p - c
        let dist = simd_length(v)
        guard dist > 1e-6 else { return false }
        let d = v / dist
        for w in world.walls {
            let ab = w.b - w.a
            let n = WorldVec(-ab.y, 0, ab.x)
            let denom = simd_dot(d, n)
            guard abs(denom) > 1e-9 else { continue }
            let t = simd_dot(WorldVec(w.a.x, 0, w.a.y) - WorldVec(c.x, 0, c.z), n) / denom
            guard t > 0.02, t < dist - tolerance else { continue }
            let q = c + d * t
            let u = simd_dot(PlanVec(q.x, q.z) - w.a, ab) / max(simd_length_squared(ab), 1e-12)
            let h = q.y - fy
            guard u >= 0, u <= 1, h >= 0, h <= w.height else { continue }
            let throughOpening = world.openings.contains { $0.wallId == w.id && u >= $0.t0 && u <= $0.t1 && h >= $0.bottom && h <= $0.top }
            if !throughOpening { return true }
        }
        return false
    }

    /// One-sided marks show only from their side of the wall.
    static func sideVisible(side: String?, wallId: String?, camera: WorldVec, world: CaptureWorld) -> Bool {
        guard let s = side, s != WallSide.cavity, let w = world.wall(wallId) else { return true }
        return WallSide.side(of: PlanVec(camera.x, camera.z), wall: w) == s
    }

    /// A mark as the camera should see it: nil when it is on the far side of its wall or behind
    /// another wall; a cavity mark moved onto the face towards the camera.
    static func prepare(_ m: OverlayMark, camera: WorldVec, world: CaptureWorld) -> OverlayMark? {
        var m = m
        if m.side == WallSide.cavity, let w = world.wall(m.wallId), let p = m.points.first {
            let s = WallSide.side(of: PlanVec(camera.x, camera.z), wall: w)
            let t = PlanBuilder.projectParam(PlanVec(p.x, p.z), w.a, w.b)
            m.points = [WallSide.facePoint(w, t: t, height: p.y - (world.floorY ?? 0), floorY: world.floorY ?? 0, side: s, offset: 0.02)]
        }
        guard sideVisible(side: m.side, wallId: m.wallId, camera: camera, world: world) else { return nil }
        // Hidden when every sample point is behind a wall.
        var samples = [WorldVec]()
        if let f = m.points.first { samples.append(f) }
        if m.points.count > 1, let l = m.points.last { samples.append(l) }
        if m.points.count > 2 { samples.append(m.points.reduce(WorldVec(0, 0, 0), +) / Double(m.points.count)) }
        // Points on the floor or a wall face: test a hair in front of them (towards the camera).
        let lifted = samples.map { p -> WorldVec in
            let v = camera - p
            let l = simd_length(v)
            return l > 1e-6 ? p + v / l * 0.03 : p
        }
        if !lifted.isEmpty && lifted.allSatisfy({ occluded($0, camera: camera, world: world) }) { return nil }
        return m
    }
}
