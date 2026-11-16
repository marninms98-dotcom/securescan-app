//
//  MoistureEngine.swift
//  SecureScan
//
//  The moisture model end to end (docs/MOISTURE.md):
//
//    1. resolve sources, readings and scoper marks to places in the building;
//    2. fit a handful of parameters (each source's volume, floor wicking,
//       capillary rise, lining permeability) to the readings and the scoper's
//       marks on a coarse grid, by bounded coordinate descent on log-params
//       with priors toward the material defaults;
//    3. look for readings the sources cannot explain ("second source likely");
//    4. solve on the fine grid with readings and scoper marks as constraints,
//       pull cells near each reading into agreement with it, and label every
//       cell measured / estimated / set by scoper.
//
//  Shapes, areas, suggestions and confidence: MoistureShapes.swift.
//

import Foundation
import simd

/// A place in the building, independent of the grid.
struct MoistLocation: Equatable {
    var surface: MoistSurface
    var wall: Int = -1
    var side: MoistSide? = nil
    var along: Double = 0
    var height: Double = 0
    var pos: MoistVec
    var room: Int = -1

    func cell(in g: MoistGrid) -> Int? {
        switch surface {
        case .floor: return g.nearestFloorCell(pos, maxDist: 0.5, room: room >= 0 ? room : nil) ?? g.nearestFloorCell(pos, maxDist: 0.5)
        case .face, .cavity:
            return g.wallCell(wall: wall, side: side ?? .cavity, along: along, height: height)
        }
    }

    /// Distance from a cell on the same surface (same room / wall face), else nil.
    func distance(to c: MoistGrid.Cell) -> Double? {
        switch surface {
        case .floor:
            guard c.surface == .floor, room < 0 || c.room == room else { return nil }
            return simd_length(c.pos - pos)
        case .face, .cavity:
            guard c.surface == surface, c.wall == wall, c.side == side else { return nil }
            let da = c.along - along, dz = c.z - height
            return (da * da + dz * dz).squareRoot()
        }
    }
}

struct MoistConstraint {
    enum Origin: Equatable { case reading(Int), boundary(Int), scoper(Int) }
    enum Region { case point, disc(Double), inside([MoistVec]), band([MoistVec], Double) }
    var loc: MoistLocation
    var lo: Double
    var hi: Double
    var target: Double?
    var tol: Double = 0.06
    var weight: Double = 1
    var origin: Origin
    var region: Region = .point
    var useInFit: Bool = true

    func violation(_ w: Double) -> Double {
        if let t = target { return max(0, abs(w - t) - tol) }
        return max(0, lo - w) + max(0, w - hi)
    }

    var isScoper: Bool { if case .scoper = origin { return true }; return false }
}

struct MoistReadingCheck: Equatable {
    var readingId: String
    var n: Int?
    var measured: MoistState
    var measuredWetness: Double
    var physics: Double          // the fitted physics alone, before readings are applied
    var explained: Bool          // physics agrees with the reading's state
}

struct MoistSourceHint: Equatable {
    var readingIds: [String]
    var surface: MoistSurface
    var roomId: String?
    var wallId: String?
    var side: MoistSide?
    var pos: MoistVec
    var along: Double?
    var height: Double?
    var improvement: Double      // 0…1: how much of the misfit a source here explains
    var message: String
}

struct MoistFitReport: Equatable {
    var fitted: Bool
    var objectiveBefore: Double
    var objective: Double
    var evaluations: Int
    var checks: [MoistReadingCheck]
}

struct MoistResolvedSource: Equatable {
    var source: MoistSource
    var profile: MoistSourceProfile
    var loc: MoistLocation?
    var litres: Double
}

final class MoistResult {
    let input: MoistInput
    let grid: MoistGrid
    let wetness: [Double]
    let provenance: [MoistProvenance]
    let scale: MoistScale
    let params: MoistParams
    let hours: Double
    let sources: [MoistResolvedSource]
    let fit: MoistFitReport
    let hints: [MoistSourceHint]
    let constraints: [MoistConstraint]
    let iterations: Int
    var timings: [String: Double] = [:]

    init(input: MoistInput, grid: MoistGrid, wetness: [Double], provenance: [MoistProvenance], scale: MoistScale,
         params: MoistParams, hours: Double, sources: [MoistResolvedSource], fit: MoistFitReport, hints: [MoistSourceHint],
         constraints: [MoistConstraint], iterations: Int) {
        self.input = input; self.grid = grid; self.wetness = wetness; self.provenance = provenance; self.scale = scale
        self.params = params; self.hours = hours; self.sources = sources; self.fit = fit; self.hints = hints
        self.constraints = constraints; self.iterations = iterations
    }

    func state(_ cell: Int) -> MoistState { MoistScale.state(wetness[cell]) }

    /// Wetness at a place (nil when the place is not in the model).
    func wetness(at loc: MoistLocation) -> Double? { loc.cell(in: grid).map { wetness[$0] } }

    func wetness(floor p: MoistVec) -> Double? { grid.nearestFloorCell(p, maxDist: 0.15).map { wetness[$0] } }

    func wetness(wall id: String, side: MoistSide, along: Double, height: Double) -> Double? {
        guard let wi = input.walls.firstIndex(where: { $0.id == id }) else { return nil }
        return grid.wallCell(wall: wi, side: side, along: along, height: height).map { wetness[$0] }
    }

    /// The fitted physics said "unexplained" for some readings: a second source is likely.
    var secondSourceLikely: Bool { !hints.isEmpty }
}

enum MoistModel {

    // MARK: Resolving places

    static func roomIndex(_ input: MoistInput, at p: MoistVec) -> Int {
        var best = -1, bestArea = Double.infinity
        for (k, r) in input.rooms.enumerated() where MoistGeom.inside(p, r.polygon) {
            let a = MoistGeom.area(r.polygon)
            if a < bestArea { best = k; bestArea = a }
        }
        return best
    }

    /// Which side of wall `w` has a room at `along` (a, b, or nil if both / none).
    static func roomSide(_ input: MoistInput, wall w: MoistWall, along: Double) -> MoistSide? {
        let p = w.point(along: along)
        let a = roomIndex(input, at: p + w.normal * 0.15) >= 0
        let b = roomIndex(input, at: p - w.normal * 0.15) >= 0
        if a && !b { return MoistSide.a }
        if b && !a { return MoistSide.b }
        return nil
    }

    static func location(_ input: MoistInput, reading r: MoistReading) -> MoistLocation {
        let onFloor = r.material.lowercased() == "floor" || r.material.lowercased().hasPrefix("floor")
        if !onFloor, let wid = r.wallId, let wi = input.walls.firstIndex(where: { $0.id == wid }) {
            let w = input.walls[wi]
            let along = min(max(0, w.along(r.pos)), w.length)
            var side = r.side
            if side == nil, let cam = r.cam {
                let o = w.offset(cam)
                if abs(o) > 0.02 { side = o > 0 ? MoistSide.a : MoistSide.b }
            }
            if side == nil { side = roomSide(input, wall: w, along: along) ?? .a }
            let height = r.height ?? (r.material.lowercased().contains("skirting") ? 0.05 : 0.3)
            let surface: MoistSurface = side == .cavity ? .cavity : .face
            let probe = w.point(along: along) + w.normal * ((side ?? .a).sign * 0.15)
            return MoistLocation(surface: surface, wall: wi, side: side, along: along, height: height, pos: w.point(along: along),
                                 room: surface == .face ? roomIndex(input, at: probe) : -1)
        }
        return MoistLocation(surface: .floor, pos: r.pos, room: roomIndex(input, at: r.pos))
    }

    static func location(_ input: MoistInput, source s: MoistSource, profile: MoistSourceProfile) -> MoistLocation? {
        var placement = profile.placement
        if s.onFloor { placement = .floor }
        if let side = s.side { placement = side == .cavity ? .cavity : .face }
        if let wid = s.wallId, let wi = input.walls.firstIndex(where: { $0.id == wid }), placement != .floor {
            let w = input.walls[wi]
            let along = min(max(0, w.along(s.pos)), w.length)
            let height = min(s.height ?? (placement == .face ? 1.0 : 0.9), input.options.maxWallHeight - 0.05)
            if placement == .cavity {
                return MoistLocation(surface: .cavity, wall: wi, side: .cavity, along: along, height: height, pos: w.point(along: along))
            }
            let side = faceSide(s.side) ?? roomSide(input, wall: w, along: along) ?? .a
            return MoistLocation(surface: .face, wall: wi, side: side, along: along, height: height, pos: w.point(along: along))
        }
        // On the floor. A point on a wall line steps into the room on its side.
        var p = s.pos
        if let wid = s.wallId, let w = input.walls.first(where: { $0.id == wid }) {
            let along = min(max(0, w.along(s.pos)), w.length)
            let side = faceSide(s.side) ?? roomSide(input, wall: w, along: along) ?? .a
            p = w.point(along: along) + w.normal * (side.sign * 0.2)
        }
        return MoistLocation(surface: .floor, pos: p, room: roomIndex(input, at: p))
    }

    static func faceSide(_ s: MoistSide?) -> MoistSide? { s == .cavity ? nil : s }

    static func resolveSources(_ input: MoistInput) -> [MoistResolvedSource] {
        input.sources.map { (s0: MoistSource) -> MoistResolvedSource in
            var s = s0
            for t in input.tweaks where t.kind == .source && t.sourceId == s.id {
                if let i = t.intensity { s.intensity = i; s.intensityFixed = true }
                if let ty = t.sourceType, let st = MoistSourceType(rawValue: ty) { s.type = st }
                if let p = t.placement?.lowercased() {
                    if p == "floor" { s.onFloor = true; s.side = nil }
                    else if let side = MoistSide(rawValue: p) { s.side = side; s.onFloor = false }
                }
            }
            let prof = MoistSourceProfiles.profile(s.type)
            return MoistResolvedSource(source: s, profile: prof, loc: location(input, source: s, profile: prof),
                                       litres: prof.litres * s.intensity)
        }
    }

    // MARK: Constraints

    static func constraints(_ input: MoistInput, scale: MoistScale) -> [MoistConstraint] {
        var out: [MoistConstraint] = []
        let wd = MoistScale.dampLevel, ww = MoistScale.wetLevel
        for (i, r) in input.readings.enumerated() {
            let loc = location(input, reading: r)
            switch r.kind {
            case .reading:
                guard let v = r.value else { continue }
                let w = scale.wetness(v)
                switch scale.state(value: v) {
                case .wet:
                    out.append(MoistConstraint(loc: loc, lo: max(ww, w - 0.05), hi: min(1, w + 0.05), target: w, origin: .reading(i)))
                case .damp:
                    out.append(MoistConstraint(loc: loc, lo: max(wd, w - 0.05), hi: min(ww - 0.005, w + 0.05), target: w, origin: .reading(i)))
                case .dry:
                    out.append(MoistConstraint(loc: loc, lo: 0, hi: wd - 0.03, target: nil, origin: .reading(i)))
                }
            case .boundary:
                guard loc.surface != .floor else { continue }
                out.append(MoistConstraint(loc: loc, lo: wd - 0.05, hi: wd + 0.05, target: wd, tol: 0.05, weight: 0.7, origin: .boundary(i)))
                var above = loc
                above.height = loc.height + 0.15
                if above.height < input.options.maxWallHeight {
                    out.append(MoistConstraint(loc: above, lo: 0, hi: wd - 0.03, target: nil, weight: 0.5, origin: .boundary(i)))
                }
            }
        }
        for (ti, t) in input.tweaks.enumerated() {
            switch t.kind {
            case .brush:
                guard let state = t.state else { continue }
                let (lo, hi): (Double, Double) = state == .wet ? (0.55, 1) : state == .damp ? (0.22, 0.38) : (0, 0.05)
                for p in t.points {
                    guard let loc = scoperLocation(input, t, point: p) else { continue }
                    out.append(MoistConstraint(loc: loc, lo: lo, hi: hi, target: nil, weight: 3, origin: .scoper(ti), region: .disc(max(0.05, t.radius))))
                }
            case .tideLine:
                guard let wid = t.wallId, let wi = input.walls.firstIndex(where: { $0.id == wid }), t.points.count >= 1 else { continue }
                let side = t.side ?? .a
                let pts = t.points.sorted { $0.x < $1.x }
                let maxH = input.options.maxWallHeight
                var s = pts[0].x
                let end = pts[pts.count - 1].x
                repeat {
                    let hl = MoistShapesMath.interpolate(pts, at: s)
                    let base = MoistLocation(surface: side == .cavity ? .cavity : .face, wall: wi, side: side, along: s, height: 0,
                                             pos: input.walls[wi].point(along: s))
                    var z = 0.05
                    var first = true
                    while z < hl - 0.08 {
                        var l = base; l.height = z
                        out.append(MoistConstraint(loc: l, lo: wd + 0.02, hi: 1, target: nil, weight: 2, origin: .scoper(ti), region: .disc(0.12),
                                                   useInFit: first || z + 0.2 >= hl - 0.08))
                        first = false
                        z += 0.2
                    }
                    z = hl + 0.1
                    first = true
                    while z < maxH {
                        var l = base; l.height = z
                        out.append(MoistConstraint(loc: l, lo: 0, hi: wd - 0.02, target: nil, weight: 2, origin: .scoper(ti), region: .disc(0.12),
                                                   useInFit: first))
                        first = false
                        z += 0.2
                    }
                    s += 0.2
                } while s <= end + 1e-9
            case .floorOutline:
                guard t.points.count >= 3 else { continue }
                let poly = t.points
                let c = poly.reduce(MoistVec(0, 0)) { $0 + $1 } / Double(poly.count)
                out.append(MoistConstraint(loc: MoistLocation(surface: .floor, pos: c, room: -1), lo: wd + 0.02, hi: 1, target: nil,
                                           weight: 2, origin: .scoper(ti), region: .inside(poly), useInFit: false))
                out.append(MoistConstraint(loc: MoistLocation(surface: .floor, pos: c, room: -1), lo: 0, hi: wd - 0.02, target: nil,
                                           weight: 2, origin: .scoper(ti), region: .band(poly, 0.4), useInFit: false))
                // Fit samples just inside and just outside each edge.
                let ccw = MoistGeom.signedArea(poly) > 0
                for k in 0..<poly.count {
                    let a = poly[k], b = poly[(k + 1) % poly.count]
                    let m = (a + b) / 2, d = b - a
                    let len = simd_length(d)
                    guard len > 0.05 else { continue }
                    var inward = MoistVec(-d.y, d.x) / len
                    if !ccw { inward = -inward }
                    let pin = m + inward * 0.15, pout = m - inward * 0.15
                    out.append(MoistConstraint(loc: MoistLocation(surface: .floor, pos: pin, room: roomIndex(input, at: pin)), lo: wd + 0.02, hi: 1,
                                               target: nil, weight: 2, origin: .scoper(ti)))
                    out.append(MoistConstraint(loc: MoistLocation(surface: .floor, pos: pout, room: roomIndex(input, at: pout)), lo: 0, hi: wd - 0.02,
                                               target: nil, weight: 2, origin: .scoper(ti)))
                }
            default:
                continue
            }
        }
        return out
    }

    static func scoperLocation(_ input: MoistInput, _ t: MoistTweak, point p: MoistVec) -> MoistLocation? {
        let surface: MoistSurface
        if let s = t.surface { surface = s } else if t.wallId == nil { surface = .floor } else { surface = t.side == .cavity ? .cavity : .face }
        if surface == .floor { return MoistLocation(surface: .floor, pos: p, room: roomIndex(input, at: p)) }
        guard let wid = t.wallId, let wi = input.walls.firstIndex(where: { $0.id == wid }) else { return nil }
        let w = input.walls[wi]
        let side: MoistSide = surface == .cavity ? .cavity : (t.side ?? .a)
        return MoistLocation(surface: surface, wall: wi, side: side, along: p.x, height: p.y, pos: w.point(along: p.x))
    }

    // MARK: Evaluation

    struct Evaluation {
        var w: [Double]
        var objective: Double
        var misfit: Double
        var iterations: Int
    }

    struct Problem {
        let grid: MoistGrid
        let sources: [MoistResolvedSource]
        let startCells: [Int?]
        let constraintCells: [Int?]
        let constraints: [MoistConstraint]
        let hours: Double
        let reach: Double
    }

    static func pins(_ g: MoistGrid, sources: [MoistResolvedSource], startCells: [Int?], volumes: [Double], extra: [(Int, Double)] = []) -> [Double] {
        var pin = Array(repeating: -1.0, count: g.count)
        for (k, s) in startCells.enumerated() {
            guard let c = s else { continue }
            for f in MoistSolver.flood(g, start: c, litres: volumes[k]) where f.wet > pin[f.cell] { pin[f.cell] = f.wet }
        }
        for (c, litres) in extra {
            for f in MoistSolver.flood(g, start: c, litres: litres) where f.wet > pin[f.cell] { pin[f.cell] = f.wet }
        }
        return pin
    }

    static func evaluate(_ P: Problem, params: MoistParams, volumes: [Double], prior: Double, warm: [Double]?, iterations: Int,
                         extra: [(Int, Double)] = []) -> Evaluation {
        let g = P.grid
        let k = MoistSolver.conductance(g, params: params, hours: P.hours)
        let pin = pins(g, sources: P.sources, startCells: P.startCells, volumes: volumes, extra: extra)
        var seeds: [Int] = []
        for i in 0..<g.count where pin[i] >= 0 { seeds.append(i) }
        let lo = Array(repeating: 0.0, count: g.count), hi = Array(repeating: 1.0, count: g.count)
        let act = MoistSolver.active(g, seeds: seeds, reach: P.reach)
        let r = MoistSolver.solve(g, k, pin: pin, lo: lo, hi: hi, initial: warm, active: act, maxIterations: iterations, tolerance: 5e-4)
        var misfit = 0.0
        for (i, c) in P.constraints.enumerated() where c.useInFit {
            guard let cell = P.constraintCells[i] else { continue }
            let v = c.violation(r.w[cell])
            misfit += c.weight * v * v
        }
        return Evaluation(w: r.w, objective: misfit + prior, misfit: misfit, iterations: r.iterations)
    }

    // MARK: Run

    static func run(_ input: MoistInput) -> MoistResult {
        let t0 = Date()
        let opt = input.options
        let refs = input.readings.filter { $0.reference && $0.kind == .reading }.compactMap { $0.value }
        let scale = MoistScale(thresholds: input.thresholds, references: refs)
        let sources = resolveSources(input)
        let cons = constraints(input, scale: scale)
        let hours = opt.hoursSinceEvent ?? (sources.map { $0.profile.hours }.max() ?? 72)

        // Parameters: log-space vector [volumes of free sources…, floor, rise, lining].
        var names: [String] = []
        var theta: [Double] = []
        var theta0: [Double] = []
        var sigma: [Double] = []
        var lower: [Double] = []
        var upper: [Double] = []
        for s in sources where !s.source.intensityFixed && s.loc != nil {
            let l = log(max(1e-3, s.litres))
            names.append("vol:" + s.source.id); theta.append(l); theta0.append(l); sigma.append(1.5)
            lower.append(l - log(10)); upper.append(l + log(10))
        }
        for n in ["floor", "rise", "lining"] {
            names.append(n); theta.append(0); theta0.append(0); sigma.append(n == "lining" ? 0.8 : 0.5)
            lower.append(log(MoistParams.bounds.min)); upper.append(log(MoistParams.bounds.max))
        }
        func decode(_ th: [Double]) -> (MoistParams, [Double]) {
            var p = MoistParams()
            var vols = sources.map { $0.litres }
            for (i, n) in names.enumerated() {
                if n.hasPrefix("vol:") {
                    let id = String(n.dropFirst(4))
                    if let k = sources.firstIndex(where: { $0.source.id == id }) { vols[k] = exp(th[i]) }
                } else if n == "floor" { p.floorSpread = exp(th[i]) }
                else if n == "rise" { p.rise = exp(th[i]) }
                else if n == "lining" { p.lining = exp(th[i]) }
            }
            for (k, s) in sources.enumerated() { p.volumes[s.source.id] = vols[k] }
            return (p, vols)
        }
        func prior(_ th: [Double]) -> Double {
            var s = 0.0
            for i in 0..<th.count { let d = (th[i] - theta0[i]) / sigma[i]; s += d * d }
            return 0.005 * s
        }

        // Coarse grid for fitting.
        let gC = MoistGrid(input: input, cellSize: max(opt.fitCellSize, opt.cellSize))
        let PC = Problem(grid: gC, sources: sources, startCells: sources.map { $0.loc?.cell(in: gC) },
                         constraintCells: cons.map { $0.loc.cell(in: gC) }, constraints: cons, hours: hours, reach: opt.reach)
        let tBuild = Date()
        var (params, vols) = decode(theta)
        var best = evaluate(PC, params: params, volumes: vols, prior: prior(theta), warm: nil, iterations: opt.fitIterations * 2)
        let before = best.objective
        var evals = 1
        let fitWanted = opt.fit && !sources.isEmpty && cons.contains(where: { $0.useInFit })
        if fitWanted && best.misfit > 1e-6 {
            for step in [0.8, 0.4, 0.2, 0.1] {
                for _ in 0..<2 {
                    var improved = false
                    for k in 0..<theta.count {
                        for dir in [1.0, -1.0] {
                            var t = theta
                            t[k] = min(max(theta[k] + dir * step, lower[k]), upper[k])
                            if t[k] == theta[k] { continue }
                            let (p, v) = decode(t)
                            let e = evaluate(PC, params: p, volumes: v, prior: prior(t), warm: best.w, iterations: opt.fitIterations)
                            evals += 1
                            if e.objective < best.objective - 1e-7 { theta = t; best = e; improved = true; break }
                        }
                    }
                    if !improved || best.misfit < 1e-6 { break }
                }
                if best.misfit < 1e-6 { break }
            }
            (params, vols) = decode(theta)
        }
        let tFit = Date()

        // Which readings does the physics explain?
        var checks: [MoistReadingCheck] = []
        var unexplained: [Int] = []
        for (ci, c) in cons.enumerated() {
            guard case .reading(let ri) = c.origin else { continue }
            let r = input.readings[ri]
            guard let v = r.value else { continue }
            let w = PC.constraintCells[ci].map { best.w[$0] } ?? 0
            let st = scale.state(value: v)
            let wm = scale.wetness(v)
            let ok: Bool
            switch st {
            case .dry: ok = w < MoistScale.dampLevel + 0.02
            case .damp: ok = w >= MoistScale.dampLevel - 0.08
            case .wet: ok = w >= MoistScale.wetLevel - 0.1 || w >= wm - 0.15
            }
            checks.append(MoistReadingCheck(readingId: r.id, n: r.n, measured: st, measuredWetness: wm, physics: w, explained: ok))
            if !ok && st != .dry { unexplained.append(ci) }
        }
        let hints = secondSources(input, problem: PC, best: best, params: params, volumes: vols, unexplained: unexplained, scale: scale)
        let tHints = Date()

        // Fine solve with constraints.
        let g = opt.fitCellSize > opt.cellSize + 1e-9 ? MoistGrid(input: input, cellSize: opt.cellSize) : gC
        let kF = MoistSolver.conductance(g, params: params, hours: hours)
        let startF = sources.map { $0.loc?.cell(in: g) }
        let pin = pins(g, sources: sources, startCells: startF, volumes: vols)
        var lo = Array(repeating: 0.0, count: g.count), hi = Array(repeating: 1.0, count: g.count)
        var prov = Array(repeating: MoistProvenance.estimated, count: g.count)
        var seeds: [Int] = []
        for i in 0..<g.count where pin[i] >= 0 { seeds.append(i) }
        var readingCells: [(ci: Int, cell: Int)] = []
        for (ci, c) in cons.enumerated() where !c.isScoper {
            guard let cell = c.loc.cell(in: g) else { continue }
            lo[cell] = max(lo[cell], c.lo); hi[cell] = min(hi[cell], max(c.hi, lo[cell]))
            readingCells.append((ci, cell))
            seeds.append(cell)
        }
        let scoperCells = applyScoper(g, cons, lo: &lo, hi: &hi, prov: &prov)
        seeds.append(contentsOf: scoperCells)
        // Start from the coarse answer.
        var initial = Array(repeating: 0.0, count: g.count)
        if g !== gC { for i in 0..<g.count { if let c = gC.cellMatching(g.cells[i], in: g) { initial[i] = best.w[c] } } }
        else { initial = best.w }
        let act = MoistSolver.active(g, seeds: seeds, reach: opt.reach)
        let solved = MoistSolver.solve(g, kF, pin: pin, lo: lo, hi: hi, initial: initial, active: act,
                                       maxIterations: opt.maxIterations, tolerance: 2e-4)
        var w = solved.w

        // Pull cells near each reading into agreement with it, and mark them measured.
        let R = max(0.05, opt.readingRadius)
        for (ci, _) in readingCells {
            let c = cons[ci]
            var radius = R
            if case .boundary = c.origin { radius = min(R, 0.2) }   // a site mark is a line, not a patch
            for i in 0..<g.count {
                guard let d = c.loc.distance(to: g.cells[i]), d <= radius else { continue }
                let x = d / radius
                let f = 1 - x * x * (3 - 2 * x)          // smoothstep falloff, 1 at the reading
                let target = min(max(w[i], c.lo), c.hi)
                w[i] += f * (target - w[i])
                if prov[i] != .scoper { prov[i] = .measured }
            }
        }
        // Scoper's marks always win.
        for i in scoperCells { w[i] = min(max(w[i], lo[i]), hi[i]) }
        let tSolve = Date()

        let result = MoistResult(input: input, grid: g, wetness: w, provenance: prov, scale: scale, params: params, hours: hours,
                                 sources: sources, fit: MoistFitReport(fitted: fitWanted, objectiveBefore: before, objective: best.objective,
                                                                       evaluations: evals, checks: checks),
                                 hints: hints, constraints: cons, iterations: solved.iterations)
        result.timings = ["build": tBuild.timeIntervalSince(t0) * 1000, "fit": tFit.timeIntervalSince(tBuild) * 1000,
                          "hints": tHints.timeIntervalSince(tFit) * 1000, "solve": tSolve.timeIntervalSince(tHints) * 1000,
                          "total": tSolve.timeIntervalSince(t0) * 1000]
        return result
    }

    /// Writes the scoper's hard constraints into lo / hi; returns the cells touched (in index order).
    static func applyScoper(_ g: MoistGrid, _ cons: [MoistConstraint], lo: inout [Double], hi: inout [Double], prov: inout [MoistProvenance]) -> [Int] {
        var touched = Array(repeating: false, count: g.count)
        for c in cons where c.isScoper {
            var cells: [Int] = []
            switch c.region {
            case .point:
                if let i = c.loc.cell(in: g) { cells = [i] }
            case .disc(let r):
                for i in 0..<g.count { if let d = c.loc.distance(to: g.cells[i]), d <= r { cells.append(i) } }
                if cells.isEmpty, let i = c.loc.cell(in: g) { cells = [i] }
            case .inside(let poly):
                for i in 0..<g.count where g.cells[i].surface == .floor && MoistGeom.inside(g.cells[i].pos, poly) { cells.append(i) }
            case .band(let poly, let width):
                for i in 0..<g.count where g.cells[i].surface == .floor && !MoistGeom.inside(g.cells[i].pos, poly)
                    && MoistGeom.distanceToPolygonEdge(g.cells[i].pos, poly) <= width { cells.append(i) }
            }
            for i in cells {
                lo[i] = c.lo; hi[i] = c.hi          // later marks override earlier ones and readings
                prov[i] = .scoper
                touched[i] = true
            }
        }
        var out: [Int] = []
        for i in 0..<g.count where touched[i] { out.append(i) }
        return out
    }

    // MARK: Second source

    static func secondSources(_ input: MoistInput, problem P: Problem, best: Evaluation, params: MoistParams, volumes: [Double],
                              unexplained: [Int], scale: MoistScale) -> [MoistSourceHint] {
        guard !unexplained.isEmpty else { return [] }
        // Strongest first, then cluster within 1.5 m.
        let sorted = unexplained.sorted { a, b in
            let va = readingValue(input, P.constraints[a]), vb = readingValue(input, P.constraints[b])
            return va != vb ? va > vb : a < b
        }
        var clusters: [[Int]] = []
        for ci in sorted {
            let p = place(input, P.constraints[ci].loc)
            if let k = clusters.firstIndex(where: { simd_length(place(input, P.constraints[$0[0]].loc) - p) <= 1.5 }) {
                clusters[k].append(ci)
            } else {
                clusters.append([ci])
            }
        }
        var hints: [MoistSourceHint] = []
        let base = best.misfit
        for cluster in clusters.prefix(3) {
            let seed = P.constraints[cluster[0]].loc
            var loc = seed
            if seed.surface == .face {
                loc.surface = .cavity
                loc.side = .cavity
                loc.height = min(seed.height + 0.3, input.options.maxWallHeight - 0.05)
            }
            var improvement = 0.0
            if let cell = loc.cell(in: P.grid), base > 1e-9 {
                var bestMisfit = base
                for litres in [0.5, 2.0, 8.0, 32.0] {
                    let e = evaluate(P, params: params, volumes: volumes, prior: 0, warm: best.w, iterations: input.options.fitIterations,
                                     extra: [(cell, litres)])
                    bestMisfit = min(bestMisfit, e.misfit)
                }
                improvement = max(0, min(1, (base - bestMisfit) / base))
            }
            let ids = cluster.compactMap { ci -> String? in
                if case .reading(let ri) = P.constraints[ci].origin { return input.readings[ri].id }
                return nil
            }
            let names = cluster.compactMap { ci -> String? in
                if case .reading(let ri) = P.constraints[ci].origin { return input.readings[ri].n.map { "\($0)" } ?? input.readings[ri].id }
                return nil
            }
            let roomIdx = seed.room
            let roomName = roomIdx >= 0 ? (input.rooms[roomIdx].name.isEmpty ? input.rooms[roomIdx].id : input.rooms[roomIdx].name) : nil
            var where_ = roomName.map { "in the \($0)" } ?? "nearby"
            var wallId: String? = nil, along: Double? = nil, height: Double? = nil
            if seed.wall >= 0 {
                let w = input.walls[seed.wall]
                wallId = w.id; along = loc.along; height = loc.height
                where_ += String(format: ", inside wall %@ about %.1f m along", w.id, loc.along)
            }
            let subject = names.count == 1 ? "Reading \(names[0]) is" : "Readings \(names.joined(separator: ", ")) are"
            let msg = input.sources.isEmpty
                ? "No water source is marked, but \(subject.lowercased()) wet. A source is likely \(where_)."
                : "\(subject) wetter than the marked source\(input.sources.count == 1 ? "" : "s") can explain. A second source is likely \(where_). Check plumbing, seals and anything above this spot."
            hints.append(MoistSourceHint(readingIds: ids, surface: loc.surface, roomId: roomIdx >= 0 ? input.rooms[roomIdx].id : nil,
                                         wallId: wallId, side: loc.side, pos: loc.pos, along: along, height: height,
                                         improvement: improvement, message: msg))
        }
        return hints
    }

    private static func readingValue(_ input: MoistInput, _ c: MoistConstraint) -> Double {
        if case .reading(let ri) = c.origin { return input.readings[ri].value ?? 0 }
        return 0
    }

    /// A place as a plan point with height folded in, for clustering.
    private static func place(_ input: MoistInput, _ l: MoistLocation) -> MoistVec { l.pos }
}
