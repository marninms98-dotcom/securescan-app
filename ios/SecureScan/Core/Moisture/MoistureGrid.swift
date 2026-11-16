//
//  MoistureGrid.swift
//  SecureScan
//
//  The cell graph the moisture model runs on (docs/MOISTURE.md, "Cells").
//  Floor cells on a square grid inside the room polygons; for every wall a
//  grid of cells (along x height, up to maxWallHeight) on each room-facing
//  face and in the cavity. Two kinds of connection:
//
//  - diffusion links (capillary wicking, drying), with a conductance class so
//    the fitted multipliers can rescale them without rebuilding the grid;
//  - free-water flow edges (where liquid water runs: down, along the plate,
//    out under the skirting, across floors), with a cost in metres.
//
//  Built once per cell size. Deterministic: everything is in array order.
//

import Foundation
import simd

/// Per-wall build decisions, from defaults, readings and scoper tweaks.
struct MoistWallSetup: Equatable {
    var core: MoistCore
    var masonry: Bool
    var liningA: MoistLining
    var liningB: MoistLining

    func lining(_ side: MoistSide) -> MoistLining { side == .b ? liningB : liningA }
}

enum MoistSetup {
    /// Linings and construction for every wall, in input order.
    static func walls(_ input: MoistInput) -> [MoistWallSetup] {
        input.walls.map { (w: MoistWall) -> MoistWallSetup in
            var masonry = false
            for t in input.tweaks where t.kind == .construction && t.wallId == w.id {
                masonry = (t.value ?? "").lowercased().hasPrefix("mason") || (t.value ?? "").lowercased().contains("brick")
            }
            let base = masonry ? MoistMaterials.render : MoistMaterials.plasterboard
            var la = base, lb = base
            // A reading taken on tiles marks that face as tiled.
            for r in input.readings where r.wallId == w.id && r.isTiled {
                if r.side == .a { la = MoistMaterials.tiled }
                if r.side == .b { lb = MoistMaterials.tiled }
            }
            for t in input.tweaks where t.kind == .lining && t.wallId == w.id {
                guard let l = MoistMaterials.lining(t.value) else { continue }
                if t.side == .a { la = l } else if t.side == .b { lb = l }
            }
            return MoistWallSetup(core: masonry ? MoistMaterials.masonry : MoistMaterials.stud, masonry: masonry, liningA: la, liningB: lb)
        }
    }

    /// Floor "no spread past here" lines.
    static func barriers(_ input: MoistInput) -> [(MoistVec, MoistVec)] {
        input.tweaks.compactMap { (t: MoistTweak) -> (MoistVec, MoistVec)? in
            t.kind == .barrier && t.points.count >= 2 ? (t.points[0], t.points[1]) : nil
        }
    }

    /// The covering of a room with no floor zone: wet rooms are usually tiled.
    static func defaultCovering(roomName: String) -> MoistCovering {
        let n = roomName.lowercased()
        for k in ["bath", "ensuite", "en-suite", "shower", "laundry", "wc", "toilet", "powder"] where n.contains(k) { return .tile }
        return .other
    }
}

final class MoistGrid {

    struct Cell {
        var surface: MoistSurface
        var wall: Int = -1            // index into input.walls
        var side: MoistSide? = nil    // face: a / b, cavity: .cavity
        var col: Int = 0              // floor: i, wall: column
        var row: Int = 0              // floor: j, wall: row (0 = at the floor)
        var room: Int = -1            // index into input.rooms
        var covering: MoistCovering? = nil
        var pos = MoistVec(0, 0)      // floor: centre; wall: point on the wall line
        var along: Double = 0         // metres from wall end a
        var z: Double = 0             // height of the centre above the floor
        var area: Double = 0          // m²
        var capacity: Double = 0      // litres of free water taken up
        var wetLevel: Double = 1      // wetness when flooded
        var dryRate: Double = 0       // 1/h
    }

    enum LinkClass: Int { case floor = 0, faceAlong, faceUp, cavity, lining, plate, faceFloor, cavityFloor }

    struct Link {
        var from: Int
        var to: Int
        var k0: Double          // scaled by the class multiplier
        var kg: Double          // gravity part, never scaled
        var cls: LinkClass
    }

    struct WallLayout {
        var wall: Int
        var cols: Int
        var rows: Int
        var colWidth: Double
        var index: [Int]        // [side 0 a / 1 b / 2 cavity][col][row] -> cell or -1
        var faceRoom: [[Int]]   // [side 0/1][col] -> room or -1

        func cell(_ side: MoistSide, _ col: Int, _ row: Int) -> Int {
            guard col >= 0, col < cols, row >= 0, row < rows else { return -1 }
            let s = side == .a ? 0 : side == .b ? 1 : 2
            return index[(s * cols + col) * rows + row]
        }
    }

    let h: Double
    let input: MoistInput
    let setups: [MoistWallSetup]
    private(set) var cells: [Cell] = []
    private(set) var links: [Link] = []
    private(set) var walls: [WallLayout] = []

    // Floor lookup.
    private(set) var origin = MoistVec(0, 0)
    private(set) var nx = 0
    private(set) var ny = 0
    private var floorIndex: [Int] = []

    // Diffusion links grouped by receiving cell (CSR).
    private(set) var inStart: [Int] = []
    private(set) var inLink: [Int] = []
    // Free-water edges grouped by sending cell (CSR).
    private(set) var flowStart: [Int] = []
    private(set) var flowTo: [Int] = []
    private(set) var flowCost: [Double] = []

    /// Scoper "no spread past here" lines.
    private(set) var barriers: [(MoistVec, MoistVec)] = []

    /// Each wall's openings as (from, to, sill, top) in metres along / up.
    private(set) var gaps: [[(s0: Double, s1: Double, sill: Double, top: Double, passage: Bool)]] = []

    var count: Int { cells.count }

    init(input: MoistInput, cellSize: Double) {
        h = max(0.04, cellSize)
        self.input = input
        setups = MoistSetup.walls(input)
        buildGaps()
        var flows: [(Int, Int, Double)] = []
        buildFloor(&flows)
        buildWalls(&flows)
        finish(flows)
    }

    // MARK: Openings

    private func buildGaps() {
        gaps = Array(repeating: [], count: input.walls.count)
        for o in input.openings {
            var wi = o.wallId.flatMap { id in input.walls.firstIndex { $0.id == id } }
            if wi == nil {
                // Unknown wall: the one both ends lie on.
                var best = (0.0, -1)
                for (i, w) in input.walls.enumerated() where w.length > 0.05 {
                    let e = max(abs(w.offset(o.a)), abs(w.offset(o.b)))
                    if e < 0.1, best.1 < 0 || e < best.0 { best = (e, i) }
                }
                wi = best.1 >= 0 ? best.1 : nil
            }
            guard let i = wi else { continue }
            let w = input.walls[i]
            let s0 = min(w.along(o.a), w.along(o.b)), s1 = max(w.along(o.a), w.along(o.b))
            gaps[i].append((s0, s1, o.sill, o.sill + o.height, o.isPassage))
        }
    }

    /// True when the floor segment p -> q may pass the wall here (a doorway).
    private func crossing(_ p: MoistVec, _ q: MoistVec) -> (blocked: Bool, doorway: Bool) {
        var doorway = false
        for (i, w) in input.walls.enumerated() {
            guard let t = MoistGeom.cross(p, q, w.a, w.b) else { continue }
            let s = t * w.length
            if gaps[i].contains(where: { $0.passage && $0.sill < 0.3 && s >= $0.s0 - 0.02 && s <= $0.s1 + 0.02 }) {
                doorway = true
            } else {
                return (true, false)
            }
        }
        return (false, doorway)
    }

    // MARK: Floors

    private func buildFloor(_ flows: inout [(Int, Int, Double)]) {
        let pts = input.rooms.flatMap { $0.polygon }
        guard !pts.isEmpty else { return }
        var lo = pts[0], hi = pts[0]
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        origin = lo
        nx = max(1, Int(ceil((hi.x - lo.x) / h - 1e-9)))
        ny = max(1, Int(ceil((hi.y - lo.y) / h - 1e-9)))
        floorIndex = Array(repeating: -1, count: nx * ny)
        let roomAreas = input.rooms.map { MoistGeom.area($0.polygon) }
        let zoneAreas = input.floors.map { MoistGeom.area($0.polygon) }
        for j in 0..<ny {
            for i in 0..<nx {
                let p = origin + MoistVec((Double(i) + 0.5) * h, (Double(j) + 0.5) * h)
                var room = -1
                for (k, r) in input.rooms.enumerated() where MoistGeom.inside(p, r.polygon) {
                    if room < 0 || roomAreas[k] < roomAreas[room] { room = k }
                }
                guard room >= 0 else { continue }
                var zone = -1
                for (k, z) in input.floors.enumerated() where MoistGeom.inside(p, z.polygon) {
                    if zone < 0 || zoneAreas[k] < zoneAreas[zone] { zone = k }
                }
                let cov = zone >= 0 ? input.floors[zone].covering : MoistSetup.defaultCovering(roomName: input.rooms[room].name)
                let m = MoistMaterials.floor(cov)
                floorIndex[j * nx + i] = cells.count
                cells.append(Cell(surface: .floor, col: i, row: j, room: room, covering: cov, pos: p,
                                  area: h * h, capacity: m.capacity * h * h, wetLevel: m.wetLevel, dryRate: 1 / m.dryHours))
            }
        }
        // Lines are lengthened a little so a link through their very end can't slip past.
        let barriers = MoistSetup.barriers(input).map { MoistGeom.extend($0.0, $0.1, by: 0.03) }
        self.barriers = barriers
        let thresholds = input.floorThresholds.map { (MoistGeom.extend($0.a, $0.b, by: 0.05), $0.type) }
        for j in 0..<ny {
            for i in 0..<nx {
                let c = floorIndex[j * nx + i]
                guard c >= 0 else { continue }
                for (di, dj) in [(1, 0), (0, 1)] {
                    guard i + di < nx, j + dj < ny else { continue }
                    let n = floorIndex[(j + dj) * nx + i + di]
                    guard n >= 0 else { continue }
                    let p = cells[c].pos, q = cells[n].pos
                    if barriers.contains(where: { MoistGeom.cross(p, q, $0.0, $0.1) != nil }) { continue }
                    let x = crossing(p, q)
                    if x.blocked { continue }
                    var f: Double? = nil
                    for t in thresholds where MoistGeom.cross(p, q, t.0.0, t.0.1) != nil {
                        f = min(f ?? 1, MoistMaterials.thresholdFactor(t.1))
                    }
                    if f == nil && x.doorway { f = MoistMaterials.doorwayFactor(cells[c].covering ?? .other, cells[n].covering ?? .other) }
                    let factor = f ?? 1
                    guard factor > 0 else { continue }
                    let k = MoistGrid.harmonic(floorD(c), floorD(n)) / (h * h) * factor
                    links.append(Link(from: c, to: n, k0: k, kg: 0, cls: .floor))
                    links.append(Link(from: n, to: c, k0: k, kg: 0, cls: .floor))
                    let cost = h + (1 / factor - 1) * MoistGrid.thresholdPenalty
                    flows.append((c, n, cost)); flows.append((n, c, cost))
                }
                // Free water also runs diagonally (round puddles, not diamonds).
                for di in [1, -1] {
                    guard i + di >= 0, i + di < nx, j + 1 < ny else { continue }
                    let n = floorIndex[(j + 1) * nx + i + di]
                    guard n >= 0 else { continue }
                    let p = cells[c].pos, q = cells[n].pos
                    if barriers.contains(where: { MoistGeom.cross(p, q, $0.0, $0.1) != nil }) { continue }
                    let x = crossing(p, q)
                    if x.blocked { continue }
                    var f: Double? = nil
                    for t in thresholds where MoistGeom.cross(p, q, t.0.0, t.0.1) != nil {
                        f = min(f ?? 1, MoistMaterials.thresholdFactor(t.1))
                    }
                    if f == nil && x.doorway { f = MoistMaterials.doorwayFactor(cells[c].covering ?? .other, cells[n].covering ?? .other) }
                    let factor = f ?? 1
                    guard factor > 0 else { continue }
                    let cost = h * 2.0.squareRoot() + (1 / factor - 1) * MoistGrid.thresholdPenalty
                    flows.append((c, n, cost)); flows.append((n, c, cost))
                }
            }
        }
    }

    private func floorD(_ c: Int) -> Double {
        let m = MoistMaterials.floor(cells[c].covering ?? .other)
        return m.wick * m.wick / m.dryHours
    }

    static func harmonic(_ a: Double, _ b: Double) -> Double { a + b > 0 ? 2 * a * b / (a + b) : 0 }

    /// Free water crossing a threshold of factor f costs (1/f - 1) x this many metres
    /// (strip 0.35 -> 0.9 m, step 0.1 -> 4.5 m, sealed 0.02 -> 25 m).
    static let thresholdPenalty = 0.5
    /// Getting under a wall from the floor is harder than coming out of it.
    static let underWallIn = 3.0
    static let underWallOut = 1.0

    func floorCell(at p: MoistVec) -> Int? {
        guard nx > 0 else { return nil }
        let i = Int(floor((p.x - origin.x) / h)), j = Int(floor((p.y - origin.y) / h))
        guard i >= 0, j >= 0, i < nx, j < ny else { return nil }
        let c = floorIndex[j * nx + i]
        return c >= 0 ? c : nil
    }

    /// The floor cell at `p`, else the nearest one within `maxDist`.
    func nearestFloorCell(_ p: MoistVec, maxDist: Double = 0.5, room: Int? = nil) -> Int? {
        if let c = floorCell(at: p), room == nil || cells[c].room == room { return c }
        guard nx > 0 else { return nil }
        let ci = Int(floor((p.x - origin.x) / h)), cj = Int(floor((p.y - origin.y) / h))
        let r = Int(ceil(maxDist / h))
        let j0 = max(0, cj - r), j1 = min(ny - 1, cj + r), i0 = max(0, ci - r), i1 = min(nx - 1, ci + r)
        guard j0 <= j1, i0 <= i1 else { return nil }
        var bestD = Double.infinity
        var best = -1
        for j in j0...j1 {
            for i in i0...i1 {
                let c = floorIndex[j * nx + i]
                guard c >= 0, room == nil || cells[c].room == room else { continue }
                let d = simd_length(cells[c].pos - p)
                if d <= maxDist, d < bestD { bestD = d; best = c }
            }
        }
        return best >= 0 ? best : nil
    }

    // MARK: Walls

    private func buildWalls(_ flows: inout [(Int, Int, Double)]) {
        let maxH = max(h, input.options.maxWallHeight)
        for (wi, w) in input.walls.enumerated() {
            let L = w.length
            guard L >= 0.05 else { continue }
            let cols = max(1, Int((L / h).rounded()))
            let cw = L / Double(cols)
            let rows = max(1, Int(ceil(min(maxH, max(w.height, h)) / h - 1e-9)))
            let setup = setups[wi]
            var layout = WallLayout(wall: wi, cols: cols, rows: rows, colWidth: cw,
                                    index: Array(repeating: -1, count: 3 * cols * rows),
                                    faceRoom: [Array(repeating: -1, count: cols), Array(repeating: -1, count: cols)])
            let n = w.normal
            for c in 0..<cols {
                let s = (Double(c) + 0.5) * cw
                let wp = w.point(along: s)
                for (k, side) in [MoistSide.a, MoistSide.b].enumerated() {
                    let probe = wp + n * (side.sign * 0.15)
                    layout.faceRoom[k][c] = roomIndex(at: probe)
                }
            }
            for (k, side) in [MoistSide.a, MoistSide.b, MoistSide.cavity].enumerated() {
                for c in 0..<cols {
                    if k < 2 && layout.faceRoom[k][c] < 0 { continue }
                    if k == 2 && layout.faceRoom[0][c] < 0 && layout.faceRoom[1][c] < 0 { continue }
                    let s = (Double(c) + 0.5) * cw
                    for r in 0..<rows {
                        let z = (Double(r) + 0.5) * h
                        if gaps[wi].contains(where: { s >= $0.s0 && s <= $0.s1 && z >= $0.sill && z <= $0.top }) { continue }
                        var cell = Cell(surface: k < 2 ? .face : .cavity, wall: wi, side: side, col: c, row: r,
                                        room: k < 2 ? layout.faceRoom[k][c] : -1, pos: w.point(along: s), along: s, z: z, area: cw * h)
                        if k < 2 {
                            let lin = setup.lining(side)
                            cell.capacity = lin.capacity * cw * h
                            cell.wetLevel = lin.wetLevel
                            cell.dryRate = 1 / lin.dryHours
                        } else {
                            cell.capacity = (r == 0 ? setup.core.plateCapacity : setup.core.capacity) * cw * h
                            cell.wetLevel = r == 0 ? setup.core.wetLevel : setup.core.trickleLevel
                            cell.dryRate = 1 / setup.core.dryHours
                        }
                        layout.index[(k * cols + c) * rows + r] = cells.count
                        cells.append(cell)
                    }
                }
            }
            linkWall(layout, setup: setup, wall: w, flows: &flows)
            walls.append(layout)
        }
    }

    private func roomIndex(at p: MoistVec) -> Int {
        var best = -1
        var bestArea = Double.infinity
        for (k, r) in input.rooms.enumerated() where MoistGeom.inside(p, r.polygon) {
            let a = MoistGeom.area(r.polygon)
            if a < bestArea { best = k; bestArea = a }
        }
        return best
    }

    private func linkWall(_ L: WallLayout, setup: MoistWallSetup, wall w: MoistWall, flows: inout [(Int, Int, Double)]) {
        let hh = h * h, cw = L.colWidth
        let core = setup.core
        for side in [MoistSide.a, MoistSide.b, MoistSide.cavity] {
            let lin: MoistLining? = side == .cavity ? nil : setup.lining(side)
            for c in 0..<L.cols {
                for r in 0..<L.rows {
                    let i = L.cell(side, c, r)
                    guard i >= 0 else { continue }
                    // Along the wall (not across a scoper barrier).
                    let e = L.cell(side, c + 1, r)
                    let p0 = w.point(along: (Double(c) + 0.5) * cw), p1 = w.point(along: (Double(c) + 1.5) * cw)
                    if e >= 0 && !barriers.contains(where: { MoistGeom.cross(p0, p1, $0.0, $0.1) != nil }) {
                        let k: Double
                        if let lin = lin { k = lin.wickAlong * lin.wickAlong / lin.dryHours / (cw * cw) }
                        else {
                            let wk = r == 0 ? core.wickPlate : core.wickAlong
                            k = wk * wk / core.dryHours / (cw * cw)
                        }
                        let cls: LinkClass = lin == nil ? .cavity : .faceAlong
                        links.append(Link(from: i, to: e, k0: k, kg: 0, cls: cls))
                        links.append(Link(from: e, to: i, k0: k, kg: 0, cls: cls))
                        if lin == nil && r == 0 && core.freePlate { flows.append((i, e, cw)); flows.append((e, i, cw)) }
                    }
                    // Up / down.
                    let u = L.cell(side, c, r + 1)
                    if u >= 0 {
                        let k: Double, g: Double
                        let cls: LinkClass
                        if let lin = lin { k = lin.wickUp * lin.wickUp / lin.dryHours / hh; g = lin.fallSpeed / h; cls = .faceUp }
                        else { k = core.wickUp * core.wickUp / core.dryHours / hh; g = core.fallSpeed / h; cls = .cavity }
                        links.append(Link(from: i, to: u, k0: k, kg: 0, cls: cls))     // capillary rise
                        links.append(Link(from: u, to: i, k0: k, kg: g, cls: cls))     // and gravity
                        flows.append((u, i, 0))                                         // free water falls
                    }
                }
            }
        }
        // Through the lining, and at the base.
        for (k, side) in [MoistSide.a, MoistSide.b].enumerated() {
            let lin = setup.lining(side)
            let dUp = lin.wickUp * lin.wickUp / lin.dryHours
            for c in 0..<L.cols {
                for r in 0..<L.rows {
                    let f = L.cell(side, c, r)
                    guard f >= 0 else { continue }
                    let v = L.cell(.cavity, c, r)
                    if v >= 0 {
                        let kl = lin.toCavity * dUp / hh
                        links.append(Link(from: f, to: v, k0: kl, kg: 0, cls: .lining))
                        links.append(Link(from: v, to: f, k0: kl, kg: 0, cls: .lining))
                        if r == 0 {
                            let kp = lin.toPlate * 2 * dUp / hh
                            links.append(Link(from: f, to: v, k0: kp, kg: 0, cls: .plate))
                            links.append(Link(from: v, to: f, k0: kp, kg: 0, cls: .plate))
                        }
                    }
                    guard r == 0, let fl = floorBeside(w, along: cells[f].along, side: side, room: L.faceRoom[k][c]) else { continue }
                    let kf = lin.toFloor * 2 * min(floorD(fl), dUp) / hh
                    links.append(Link(from: f, to: fl, k0: kf, kg: 0, cls: .faceFloor))
                    links.append(Link(from: fl, to: f, k0: kf, kg: 0, cls: .faceFloor))
                    flows.append((f, fl, h))                                            // runs off the face onto the floor
                    if v >= 0 {
                        let kc = lin.underSkirting * floorD(fl) / hh
                        links.append(Link(from: v, to: fl, k0: kc, kg: 0, cls: .cavityFloor))
                        links.append(Link(from: fl, to: v, k0: kc, kg: 0, cls: .cavityFloor))
                        if setup.core.freePlate && lin.underSkirting > 0 {
                            flows.append((v, fl, h + (1 / lin.underSkirting - 1) * MoistGrid.underWallOut))   // out under the skirting
                            flows.append((fl, v, h + (1 / lin.underSkirting - 1) * MoistGrid.underWallIn))    // in under it
                        }
                    }
                }
            }
        }
    }

    /// The floor cell just off the wall on `side` at `along`.
    private func floorBeside(_ w: MoistWall, along s: Double, side: MoistSide, room: Int) -> Int? {
        let base = w.point(along: s)
        for off in [0.5, 1.5, 2.5] {
            let p = base + w.normal * (side.sign * off * h)
            if let c = floorCell(at: p), w.offset(cells[c].pos) * side.sign > 0, room < 0 || cells[c].room == room { return c }
        }
        return nil
    }

    func layout(wall id: String) -> WallLayout? {
        guard let wi = input.walls.firstIndex(where: { $0.id == id }) else { return nil }
        return walls.first { $0.wall == wi }
    }

    func layout(wallIndex wi: Int) -> WallLayout? { walls.first { $0.wall == wi } }

    /// The wall cell nearest (along, height) on that side; skips openings.
    func wallCell(wall wi: Int, side: MoistSide, along: Double, height: Double) -> Int? {
        guard let L = layout(wallIndex: wi) else { return nil }
        let c0 = min(L.cols - 1, max(0, Int(floor(along / L.colWidth))))
        let r = min(L.rows - 1, max(0, Int(floor(max(0, height) / h))))
        for d in 0..<max(1, min(L.cols, 8)) {
            for c in d == 0 ? [c0] : [c0 - d, c0 + d] {
                let i = L.cell(side, c, r)
                if i >= 0 { return i }
            }
        }
        return nil
    }

    /// The same place on another grid (used to carry a coarse solution to a fine one).
    func cellMatching(_ other: Cell, in otherGrid: MoistGrid) -> Int? {
        switch other.surface {
        case .floor: return floorCell(at: other.pos)
        case .face, .cavity:
            guard let side = other.side else { return nil }
            return wallCell(wall: other.wall, side: side, along: other.along, height: other.z)
        }
    }

    // MARK: Finish

    private func finish(_ flows: [(Int, Int, Double)]) {
        let n = cells.count
        var countIn = Array(repeating: 0, count: n + 1)
        for l in links { countIn[l.to + 1] += 1 }
        for i in 0..<n { countIn[i + 1] += countIn[i] }
        inStart = countIn
        inLink = Array(repeating: 0, count: links.count)
        var fill = countIn
        for (e, l) in links.enumerated() { inLink[fill[l.to]] = e; fill[l.to] += 1 }

        var countOut = Array(repeating: 0, count: n + 1)
        for f in flows { countOut[f.0 + 1] += 1 }
        for i in 0..<n { countOut[i + 1] += countOut[i] }
        flowStart = countOut
        flowTo = Array(repeating: 0, count: flows.count)
        flowCost = Array(repeating: 0, count: flows.count)
        var put = countOut
        for f in flows { flowTo[put[f.0]] = f.1; flowCost[put[f.0]] = f.2; put[f.0] += 1 }
    }
}

// MARK: - Geometry helpers

enum MoistGeom {
    /// Even-odd point-in-polygon.
    static func inside(_ p: MoistVec, _ poly: [MoistVec]) -> Bool {
        guard poly.count >= 3 else { return false }
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    static func signedArea(_ poly: [MoistVec]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    static func area(_ poly: [MoistVec]) -> Double { abs(signedArea(poly)) }

    /// If segment p-q crosses segment a-b, the parameter (0…1) along a-b.
    static func cross(_ p: MoistVec, _ q: MoistVec, _ a: MoistVec, _ b: MoistVec) -> Double? {
        let r = q - p, s = b - a
        let den = r.x * s.y - r.y * s.x
        guard abs(den) > 1e-12 else { return nil }
        let ap = a - p
        let u = (ap.x * s.y - ap.y * s.x) / den     // along p-q
        let t = (ap.x * r.y - ap.y * r.x) / den     // along a-b
        return u >= 0 && u <= 1 && t >= 0 && t <= 1 ? t : nil
    }

    /// The segment a-b lengthened by `d` at both ends.
    static func extend(_ a: MoistVec, _ b: MoistVec, by d: Double) -> (MoistVec, MoistVec) {
        let l = simd_length(b - a)
        guard l > 1e-9 else { return (a, b) }
        let u = (b - a) / l
        return (a - u * d, b + u * d)
    }

    static func distanceToSegment(_ p: MoistVec, _ a: MoistVec, _ b: MoistVec) -> Double {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        let t = l2 > 1e-12 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
        return simd_length(p - (a + ab * t))
    }

    static func distanceToPolygonEdge(_ p: MoistVec, _ poly: [MoistVec]) -> Double {
        guard poly.count >= 2 else { return .infinity }
        var d = Double.infinity
        for i in 0..<poly.count { d = min(d, distanceToSegment(p, poly[i], poly[(i + 1) % poly.count])) }
        return d
    }
}
