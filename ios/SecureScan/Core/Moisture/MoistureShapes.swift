//
//  MoistureShapes.swift
//  SecureScan
//
//  From the solved cells to things that can be drawn and quoted
//  (docs/MOISTURE.md, "Outputs"): the tide line on each wall face, the wet
//  floor outline per room, wet stretches inside each wall, areas and lengths
//  split measured / estimated / set by scoper, strip-out SUGGESTIONS, and a
//  confidence for each area. "Wet" here means at or above the damp threshold
//  (the affected area); `soaked` counts only cells at or above the wet one.
//

import Foundation
import simd

/// An amount split by where it comes from.
struct MoistSplit: Equatable {
    var measured = 0.0
    var estimated = 0.0
    var scoper = 0.0

    var total: Double { measured + estimated + scoper }

    mutating func add(_ p: MoistProvenance, _ x: Double) {
        switch p {
        case .measured: measured += x
        case .estimated: estimated += x
        case .scoper: scoper += x
        }
    }

    static func + (a: MoistSplit, b: MoistSplit) -> MoistSplit {
        MoistSplit(measured: a.measured + b.measured, estimated: a.estimated + b.estimated, scoper: a.scoper + b.scoper)
    }

    /// Rounded to 2 decimals (m² / m).
    var rounded: MoistSplit { MoistSplit(measured: MoistNum.r2(measured), estimated: MoistNum.r2(estimated), scoper: MoistNum.r2(scoper)) }
}

struct MoistConfidence: Equatable {
    enum Level: String { case high, medium, low }
    var score: Double
    var level: Level
    var readings: Int            // readings and site marks on this surface
    var nearestReading: Double?  // mean distance (m) from the wet area to the nearest reading
    var agreement: Double?       // share of those readings the physics explains on its own
}

struct MoistFaceReport: Equatable {
    var wallId: String
    var side: MoistSide
    var roomId: String?
    var lining: String
    var length: Double
    var wetArea: MoistSplit          // m² at damp or wet
    var soakedArea: MoistSplit       // m² at wet
    var skirting: MoistSplit         // lineal m of skirting at damp or wet
    var tideLine: [[MoistVec]]       // segments of (metres along a->b, height m)
    var maxHeight: Double
    var reachesModelTop: Bool        // wet up to the top of the modelled band: measure higher
    var confidence: MoistConfidence
}

struct MoistCavityReport: Equatable {
    var wallId: String
    var runs: [MoistVec]             // (from, to) metres along a->b
    var wetLength: Double
    var maxHeight: Double
    var confidence: MoistConfidence
}

struct MoistCoveringArea: Equatable {
    var covering: MoistCovering
    var area: MoistSplit
}

struct MoistFloorReport: Equatable {
    var roomId: String
    var name: String
    var polygons: [[MoistVec]]       // wet outline(s); fill even-odd (inner rings are dry islands)
    var wetArea: MoistSplit
    var soakedArea: MoistSplit
    var byCovering: [MoistCoveringArea]
    var confidence: MoistConfidence
}

struct MoistTotals: Equatable {
    var wallLining: MoistSplit
    var floor: MoistSplit
    var floorByCovering: [MoistCoveringArea]
    var skirting: MoistSplit
    var cavityLength: Double
}

/// A strip-out SUGGESTION for the scoper to accept or change. Never a decision.
struct MoistSuggestion: Equatable {
    enum Kind: String { case stripLining, removeSkirting, liftFlooring, inspectCavity }
    var kind: Kind
    var wallId: String?
    var side: MoistSide?
    var roomId: String?
    var from: Double?                // metres along the wall
    var to: Double?
    var cutHeightMm: Int?
    var covering: MoistCovering?
    var polygons: [[MoistVec]] = []
    var area: Double = 0             // m²
    var length: Double = 0           // m
    var note: String = ""
}

struct MoistReport: Equatable {
    var faces: [MoistFaceReport]
    var cavities: [MoistCavityReport]
    var floors: [MoistFloorReport]
    var totals: MoistTotals
    var suggestions: [MoistSuggestion]
}

enum MoistShapesMath {
    /// y at x on a polyline sorted by x (clamped at the ends).
    static func interpolate(_ pts: [MoistVec], at x: Double) -> Double {
        guard let first = pts.first, let last = pts.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 1..<pts.count where x <= pts[i].x {
            let a = pts[i - 1], b = pts[i]
            let t = b.x - a.x > 1e-9 ? (x - a.x) / (b.x - a.x) : 0
            return a.y + (b.y - a.y) * t
        }
        return last.y
    }

    /// Suggested cut: 300 mm above the tide line, rounded up to 600 / 900 / 1200.
    static func cutHeightMm(tide: Double) -> Int {
        let need = (tide + 0.3) * 1000
        for c in [600, 900, 1200] where Double(c) >= need - 1e-6 { return c }
        return 1200
    }

    /// Contiguous runs of true values: (first, last) indices.
    static func runs(_ flags: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = -1
        for (i, f) in flags.enumerated() {
            if f && start < 0 { start = i }
            if !f && start >= 0 { out.append((start, i - 1)); start = -1 }
        }
        if start >= 0 { out.append((start, flags.count - 1)) }
        return out
    }

    /// Iso-lines of a grid of values at cell centres (marching squares), as closed loops in grid units
    /// (cell (i, j) centre = (i + 0.5, j + 0.5)). Values outside the grid count as 0.
    static func contours(_ v: [Double], nx: Int, ny: Int, iso: Double) -> [[MoistVec]] {
        guard nx > 0, ny > 0 else { return [] }
        let W = nx + 2, H = ny + 2                      // padded with a ring of zeros
        func val(_ i: Int, _ j: Int) -> Double {        // padded indices
            let x = i - 1, y = j - 1
            return x >= 0 && y >= 0 && x < nx && y < ny ? v[y * nx + x] : 0
        }
        func centre(_ i: Int, _ j: Int) -> MoistVec { MoistVec(Double(i) - 0.5, Double(j) - 0.5) }
        // Edge keys: horizontal edge (i,j)-(i+1,j) = 2*(j*W+i); vertical (i,j)-(i,j+1) = 2*(j*W+i)+1.
        func point(_ key: Int) -> MoistVec {
            let k = key / 2, i = k % W, j = k / W
            let (i2, j2) = key % 2 == 0 ? (i + 1, j) : (i, j + 1)
            let a = val(i, j), b = val(i2, j2)
            let t = abs(b - a) > 1e-12 ? min(1, max(0, (iso - a) / (b - a))) : 0.5
            return centre(i, j) + (centre(i2, j2) - centre(i, j)) * t
        }
        var segs: [(Int, Int)] = []
        for j in 0..<(H - 1) {
            for i in 0..<(W - 1) {
                let a = val(i, j) >= iso, b = val(i + 1, j) >= iso, c = val(i + 1, j + 1) >= iso, d = val(i, j + 1) >= iso
                let top = 2 * (j * W + i), bottom = 2 * ((j + 1) * W + i), left = 2 * (j * W + i) + 1, right = 2 * (j * W + i + 1) + 1
                let k = (a ? 1 : 0) | (b ? 2 : 0) | (c ? 4 : 0) | (d ? 8 : 0)
                if k == 0 || k == 15 { continue }
                if k == 5 || k == 10 {
                    let mid = (val(i, j) + val(i + 1, j) + val(i + 1, j + 1) + val(i, j + 1)) / 4 >= iso
                    if (k == 5) == mid { segs.append((top, right)); segs.append((bottom, left)) }
                    else { segs.append((top, left)); segs.append((right, bottom)) }
                    continue
                }
                var e: [Int] = []
                if a != b { e.append(top) }
                if b != c { e.append(right) }
                if c != d { e.append(bottom) }
                if d != a { e.append(left) }
                if e.count == 2 { segs.append((e[0], e[1])) }
            }
        }
        // Chain: every edge key is shared by exactly two segments.
        var byKey: [Int: [Int]] = [:]
        for (s, seg) in segs.enumerated() { byKey[seg.0, default: []].append(s); byKey[seg.1, default: []].append(s) }
        var used = Array(repeating: false, count: segs.count)
        var loops: [[MoistVec]] = []
        for s0 in 0..<segs.count where !used[s0] {
            used[s0] = true
            var keys = [segs[s0].0]
            var cur = segs[s0].1
            var guardCount = 0
            while cur != keys[0] && guardCount < segs.count + 2 {
                guardCount += 1
                keys.append(cur)
                guard let next = byKey[cur]?.first(where: { !used[$0] }) else { break }
                used[next] = true
                cur = segs[next].0 == cur ? segs[next].1 : segs[next].0
            }
            if keys.count >= 3 { loops.append(keys.map(point)) }
        }
        return loops
    }

    /// One Chaikin pass on a closed loop.
    static func smooth(_ loop: [MoistVec]) -> [MoistVec] {
        guard loop.count >= 3 else { return loop }
        var out: [MoistVec] = []
        out.reserveCapacity(loop.count * 2)
        for i in 0..<loop.count {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            out.append(a * 0.75 + b * 0.25)
            out.append(a * 0.25 + b * 0.75)
        }
        return out
    }

    /// Drops points closer than `tol` to the last kept one and rounds to mm.
    static func tidy(_ loop: [MoistVec], tol: Double = 0.03) -> [MoistVec] {
        var out: [MoistVec] = []
        for p in loop where out.isEmpty || simd_length(p - out[out.count - 1]) >= tol { out.append(MoistVec(MoistNum.r3(p.x), MoistNum.r3(p.y))) }
        return out
    }
}

extension MoistResult {

    private var wd: Double { MoistScale.dampLevel }

    /// Readings / site marks (as constraints) and their fit checks, for confidence.
    private func evidence(_ match: (MoistLocation) -> Bool) -> (locs: [MoistLocation], explained: [Bool]) {
        var locs: [MoistLocation] = []
        var explained: [Bool] = []
        for c in constraints where !c.isScoper && match(c.loc) {
            locs.append(c.loc)
            if case .reading(let ri) = c.origin, let ch = fit.checks.first(where: { $0.readingId == input.readings[ri].id }) {
                explained.append(ch.explained)
            }
        }
        return (locs, explained)
    }

    func confidence(cells: [Int], evidence locs: [MoistLocation], explained: [Bool], reachFactor: Double = 1) -> MoistConfidence {
        guard !cells.isEmpty else { return MoistConfidence(score: 1, level: .high, readings: locs.count, nearestReading: nil, agreement: nil) }
        var cover = 0.0, dsum = 0.0, dn = 0
        for i in cells {
            if provenance[i] == .scoper { cover += 1; continue }
            var d = Double.infinity
            for l in locs {
                if let x = l.distance(to: grid.cells[i]) { d = min(d, x) }
                else if grid.cells[i].surface == .cavity, l.wall == grid.cells[i].wall, l.surface == .face {
                    // A reading on either face says something about the cavity behind it.
                    let da = l.along - grid.cells[i].along, dz = l.height - grid.cells[i].z
                    d = min(d, (da * da + dz * dz).squareRoot() + 0.3)
                }
            }
            if d.isFinite { cover += exp(-d / 1.0) * reachFactor; dsum += d; dn += 1 }
        }
        let coverage = cover / Double(cells.count)
        let agreement = explained.isEmpty ? nil : Double(explained.filter { $0 }.count) / Double(explained.count)
        var score = 0.6 * coverage + 0.4 * (agreement ?? 0.5)
        if locs.isEmpty && !cells.contains(where: { provenance[$0] == .scoper }) { score = min(score, 0.3) }
        score = MoistNum.r2(max(0, min(1, score)))
        let level: MoistConfidence.Level = score >= 0.66 ? .high : score >= 0.4 ? .medium : .low
        return MoistConfidence(score: score, level: level, readings: locs.count, nearestReading: dn > 0 ? MoistNum.r2(dsum / Double(dn)) : nil,
                               agreement: agreement.map { MoistNum.r2($0) })
    }

    func report() -> MoistReport {
        let g = grid
        var faces: [MoistFaceReport] = []
        var cavities: [MoistCavityReport] = []
        var suggestions: [MoistSuggestion] = []
        var lining = MoistSplit(), skirting = MoistSplit(), cavityLength = 0.0

        for L in g.walls {
            let w = input.walls[L.wall]
            let setup = g.setups[L.wall]
            for (k, side) in [MoistSide.a, MoistSide.b].enumerated() {
                var wetCells: [Int] = []
                var area = MoistSplit(), soaked = MoistSplit(), skirt = MoistSplit()
                var tops: [Double?] = Array(repeating: nil, count: L.cols)
                var any = false
                var maxH = 0.0
                var reachesTop = false
                for c in 0..<L.cols {
                    var top: Double? = nil
                    for r in 0..<L.rows {
                        let i = L.cell(side, c, r)
                        guard i >= 0 else { continue }
                        any = true
                        let x = wetness[i]
                        guard x >= wd else { continue }
                        wetCells.append(i)
                        area.add(provenance[i], g.cells[i].area)
                        if x >= MoistScale.wetLevel { soaked.add(provenance[i], g.cells[i].area) }
                        if r == 0 { skirt.add(provenance[i], L.colWidth) }
                        let up = L.cell(side, c, r + 1)
                        var z: Double
                        if up >= 0 {
                            let y = wetness[up]
                            z = g.cells[i].z + (y < wd && x - y > 1e-9 ? g.h * (x - wd) / (x - y) : g.h * 0.5)
                        } else {
                            z = Double(r + 1) * g.h
                            if r == L.rows - 1 { reachesTop = true }
                        }
                        z = min(z, Double(L.rows) * g.h)
                        top = max(top ?? 0, z)
                    }
                    tops[c] = top
                    if let t = top { maxH = max(maxH, t) }
                }
                guard any else { continue }
                var segments: [[MoistVec]] = []
                for (a, b) in MoistShapesMath.runs(tops.map { $0 != nil }) {
                    var seg: [MoistVec] = []
                    seg.append(MoistVec(MoistNum.r3(Double(a) * L.colWidth), MoistNum.r3(tops[a]!)))
                    for c in a...b { seg.append(MoistVec(MoistNum.r3((Double(c) + 0.5) * L.colWidth), MoistNum.r3(tops[c]!))) }
                    seg.append(MoistVec(MoistNum.r3(Double(b + 1) * L.colWidth), MoistNum.r3(tops[b]!)))
                    segments.append(seg)
                    // Suggestions for this run.
                    let tide = (a...b).map { tops[$0]! }.max() ?? 0
                    let from = max(0, Double(a) * L.colWidth - 0.3), to = min(w.length, Double(b + 1) * L.colWidth + 0.3)
                    if setup.lining(side).name == "tiled" {
                        suggestions.append(MoistSuggestion(kind: .inspectCavity, wallId: w.id, side: side, roomId: roomId(L.faceRoom[k][a]),
                                                           from: MoistNum.r2(from), to: MoistNum.r2(to), length: MoistNum.r2(to - from),
                                                           note: "Tiled face: confirm behind the tiles (inspection hole or the other side) before removing tiles."))
                    } else {
                        let cut = MoistShapesMath.cutHeightMm(tide: tide)
                        suggestions.append(MoistSuggestion(kind: .stripLining, wallId: w.id, side: side, roomId: roomId(L.faceRoom[k][a]),
                                                           from: MoistNum.r2(from), to: MoistNum.r2(to), cutHeightMm: cut,
                                                           area: MoistNum.r2((to - from) * Double(cut) / 1000), length: MoistNum.r2(to - from),
                                                           note: tide + 0.3 > 1.2 + 1e-9
                                                               ? "Moisture reaches the top of the modelled band: measure higher before setting the cut."
                                                               : "Tide line \(Int((tide * 1000).rounded())) mm + 300 mm, rounded up."))
                    }
                }
                // Skirting runs.
                var base: [Bool] = []
                for c in 0..<L.cols { let i = L.cell(side, c, 0); base.append(i >= 0 && wetness[i] >= wd) }
                for (a, b) in MoistShapesMath.runs(base) {
                    let from = Double(a) * L.colWidth, to = Double(b + 1) * L.colWidth
                    suggestions.append(MoistSuggestion(kind: .removeSkirting, wallId: w.id, side: side, roomId: roomId(L.faceRoom[k][a]),
                                                       from: MoistNum.r2(from), to: MoistNum.r2(to), length: MoistNum.r2(to - from)))
                }
                let ev = evidence { $0.surface == .face && $0.wall == L.wall && $0.side == side }
                let roomIdx = L.faceRoom[k].first { $0 >= 0 } ?? -1
                faces.append(MoistFaceReport(wallId: w.id, side: side, roomId: roomId(roomIdx), lining: setup.lining(side).name,
                                             length: MoistNum.r3(w.length), wetArea: area.rounded, soakedArea: soaked.rounded,
                                             skirting: skirt.rounded, tideLine: segments, maxHeight: MoistNum.r3(maxH),
                                             reachesModelTop: reachesTop,
                                             confidence: confidence(cells: wetCells, evidence: ev.locs, explained: ev.explained)))
                lining = lining + area
                skirting = skirting + skirt
            }
            // Inside the wall.
            var colWet: [Bool] = []
            var cavCells: [Int] = []
            var maxH = 0.0
            for c in 0..<L.cols {
                var wet = false
                for r in 0..<L.rows {
                    let i = L.cell(.cavity, c, r)
                    guard i >= 0, wetness[i] >= wd else { continue }
                    wet = true
                    cavCells.append(i)
                    maxH = max(maxH, Double(r + 1) * g.h)
                }
                colWet.append(wet)
            }
            let runs = MoistShapesMath.runs(colWet)
            if !runs.isEmpty {
                let rs = runs.map { MoistVec(MoistNum.r2(Double($0.0) * L.colWidth), MoistNum.r2(Double($0.1 + 1) * L.colWidth)) }
                let len = rs.reduce(0) { $0 + ($1.y - $1.x) }
                cavityLength += len
                let ev = evidence { $0.wall == L.wall && $0.surface != .floor }
                cavities.append(MoistCavityReport(wallId: w.id, runs: rs, wetLength: MoistNum.r2(len), maxHeight: MoistNum.r2(maxH),
                                                  confidence: confidence(cells: cavCells, evidence: ev.locs, explained: ev.explained, reachFactor: 0.6)))
                let facesSuggested = suggestions.contains { $0.wallId == w.id && $0.kind == .stripLining }
                if !facesSuggested {
                    for r in rs {
                        suggestions.append(MoistSuggestion(kind: .inspectCavity, wallId: w.id, side: .cavity, from: r.x, to: r.y,
                                                           length: MoistNum.r2(r.y - r.x),
                                                           note: "Estimated wet inside the wall: check with an inspection hole or readings on both faces."))
                    }
                }
            }
        }

        // Floors, room by room.
        var floors: [MoistFloorReport] = []
        var floorTotal = MoistSplit()
        var byCov: [MoistCovering: MoistSplit] = [:]
        for (ri, room) in input.rooms.enumerated() {
            var vals = Array(repeating: 0.0, count: g.nx * g.ny)
            var wetCells: [Int] = []
            var area = MoistSplit(), soaked = MoistSplit()
            var cov: [MoistCovering: MoistSplit] = [:]
            for i in 0..<g.count where g.cells[i].surface == .floor && g.cells[i].room == ri {
                let c = g.cells[i]
                vals[c.row * g.nx + c.col] = wetness[i]
                guard wetness[i] >= wd else { continue }
                wetCells.append(i)
                area.add(provenance[i], c.area)
                if wetness[i] >= MoistScale.wetLevel { soaked.add(provenance[i], c.area) }
                cov[c.covering ?? .other, default: MoistSplit()].add(provenance[i], c.area)
            }
            guard !wetCells.isEmpty else { continue }
            let loops = MoistShapesMath.contours(vals, nx: g.nx, ny: g.ny, iso: wd).map { loop in
                MoistShapesMath.tidy(MoistShapesMath.smooth(loop.map { g.origin + $0 * g.h }))
            }.filter { $0.count >= 3 }
            let covs = MoistCovering.allCases.compactMap { c in cov[c].map { MoistCoveringArea(covering: c, area: $0.rounded) } }
            for c in MoistCovering.allCases { if let s = cov[c] { byCov[c] = (byCov[c] ?? MoistSplit()) + s } }
            floorTotal = floorTotal + area
            let ev = evidence { $0.surface == .floor && $0.room == ri }
            floors.append(MoistFloorReport(roomId: room.id, name: room.name, polygons: loops, wetArea: area.rounded, soakedArea: soaked.rounded,
                                           byCovering: covs, confidence: confidence(cells: wetCells, evidence: ev.locs, explained: ev.explained)))
            for ca in covs where ca.covering == .carpet {
                suggestions.append(MoistSuggestion(kind: .liftFlooring, roomId: room.id, covering: .carpet, polygons: loops,
                                                   area: ca.area.total, note: "Lift carpet and underlay over the wet area to dry the floor beneath."))
            }
        }
        let totals = MoistTotals(wallLining: lining.rounded, floor: floorTotal.rounded,
                                 floorByCovering: MoistCovering.allCases.compactMap { c in byCov[c].map { MoistCoveringArea(covering: c, area: $0.rounded) } },
                                 skirting: skirting.rounded, cavityLength: MoistNum.r2(cavityLength))
        return MoistReport(faces: faces, cavities: cavities, floors: floors, totals: totals, suggestions: suggestions)
    }

    private func roomId(_ i: Int) -> String? { i >= 0 && i < input.rooms.count ? input.rooms[i].id : nil }
}
