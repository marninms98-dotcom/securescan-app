//
//  MoistureLive.swift
//  SecureScan
//
//  The moisture model (Core/Moisture, docs/MOISTURE.md) in the app, through its
//  API only: MoisturePlan.input -> MoistModel.run -> report -> modelJSON, and
//  MoisturePlan.adding(tweak) for the scoper's corrections.
//
//  - MoistureLive.plan: the capture screen's world and marks as a plan.json-shaped
//    document (world x, z = plan x, y; the plan transform is a rotation + offset,
//    so wall sides agree), so the camera and the job run the same model.
//  - MoistureDraw: a solved model as shapes to draw - wet areas on wall faces and
//    floors split by provenance (measured / estimated / scoper), their wet-dry
//    edges, the second-source hints.
//  - MoistureWords: the state chip, the suggestions' wording, the quote totals.
//  - MoistureMarks: the shapes as overlay marks in the world.
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

// MARK: - The capture world as a plan

enum MoistureLive {
    /// Cells while capturing: 20 cm keeps a solve short on a phone that is also running
    /// the camera and RoomPlan; the job's own solve (after Finish) is at 10 cm.
    static let liveCellSize = 0.20
    static let jobCellSize = 0.10

    static func options(live: Bool) -> MoistOptions {
        var o = MoistOptions()
        if live { o.cellSize = liveCellSize; o.fitCellSize = liveCellSize }
        return o
    }

    private static func pt(_ p: PlanVec) -> [Double] { [MoistNum.r3(p.x), MoistNum.r3(p.y)] }

    /// The world and its marks as a plan.json-shaped document the model reads.
    /// Readings that were measured this visit win over older ones (faded marks are
    /// used only when nothing has been measured yet).
    static func plan(world: CaptureWorld, marks: [OverlayMark], tweaks: [MoistTweak] = []) -> [String: Any] {
        let fy = world.floorY ?? 0
        var walls: [[String: Any]] = []
        for w in world.walls where w.length > 0.05 {
            walls.append(["id": w.id, "a": pt(w.a), "b": pt(w.b), "height": MoistNum.r3(w.height)])
        }
        var openings: [[String: Any]] = []
        for o in world.openings {
            guard let w = world.wall(o.wallId) else { continue }
            let a = w.a + (w.b - w.a) * o.t0, b = w.a + (w.b - w.a) * o.t1
            openings.append(["id": o.id, "type": o.kind, "wallId": o.wallId, "a": pt(a), "b": pt(b),
                             "sill": MoistNum.r3(o.bottom), "height": MoistNum.r3(max(0.1, o.top - o.bottom))])
        }
        var rooms: [[String: Any]] = []
        for (k, r) in world.rooms.enumerated() where r.polygon.count >= 3 {
            rooms.append(["id": "r\(k + 1)", "name": r.name, "polygon": r.polygon.map(pt)])
        }

        func wallFor(_ m: OverlayMark, _ p: WorldVec) -> WorldWall? {
            if let w = world.wall(m.wallId) { return w }
            guard p.y - fy > 0.03 else { return nil }
            return WallSide.wall(at: p, world: world, within: 0.12)
        }
        func place(_ d: inout [String: Any], _ m: OverlayMark, _ p: WorldVec, onWall: Bool = true) {
            d["pos"] = pt(PlanVec(p.x, p.z))
            d["height"] = MoistNum.r3(max(0, p.y - fy))
            if onWall, let w = wallFor(m, p) {
                d["wallId"] = w.id
                d["wallT"] = MoistNum.r3(min(1, max(0, PlanBuilder.projectParam(PlanVec(p.x, p.z), w.a, w.b))))
                if let s = m.side { d["side"] = s }
            }
        }

        let readingMarks = marks.filter { if case .reading = $0.style { return $0.value != nil } else { return false } }
        let current = readingMarks.filter { !$0.faded }
        var readings: [[String: Any]] = []
        for (k, m) in (current.isEmpty ? readingMarks : current).enumerated() {
            guard let p = m.points.first, let v = m.value.flatMap({ Double($0) }) else { continue }
            var d: [String: Any] = ["id": m.id, "kind": "reading", "value": v]
            if let n = m.tag.flatMap({ Int($0.filter(\.isNumber)) }) { d["n"] = n } else { d["n"] = k + 1 }
            if case .reading(_, let reference) = m.style, reference { d["reference"] = true }
            place(&d, m, p)
            d["material"] = d["wallId"] == nil ? "floor" : ((p.y - fy) < 0.15 ? "skirting" : "wall")
            readings.append(d)
        }
        // Moisture lines and tide lines: site marks along a wall.
        for m in marks where !m.faded {
            switch m.style {
            case .moisture, .moistureWash:
                for (i, p) in m.points.enumerated() {
                    var d: [String: Any] = ["id": "\(m.id)-\(i)", "kind": "boundary"]
                    place(&d, m, p)
                    guard d["wallId"] != nil else { continue }
                    readings.append(d)
                }
            default: break
            }
        }
        var sources: [[String: Any]] = []
        for m in marks where m.style == .source {
            guard let p = m.points.first else { continue }
            var d: [String: Any] = ["id": m.id, "label": (m.tag ?? "").components(separatedBy: " · ").first ?? ""]
            place(&d, m, p)
            if d["wallId"] == nil { d["placement"] = "floor" }
            sources.append(d)
        }
        var floors: [[String: Any]] = []
        for m in marks where m.style == .liftFlooring && m.points.count >= 3 {
            floors.append(["id": m.id, "type": m.floorType ?? "carpet", "polygon": m.points.map { pt(PlanVec($0.x, $0.z)) }])
        }
        var markup: [String: Any] = ["readings": readings, "sources": sources, "floors": floors]
        if !tweaks.isEmpty { markup["moistureModel"] = ["version": MoisturePlan.version, "tweaks": tweaks.map(MoisturePlan.json)] as [String: Any] }
        return ["walls": walls, "openings": openings, "rooms": rooms, "markup": markup]
    }

    /// A cheap fingerprint of what the model depends on in the capture world: re-solve only
    /// when it changes (the full inputsHash is checked again before the solve).
    static func signature(world: CaptureWorld, marks: [OverlayMark], tweaks: Int) -> Int {
        var h = Hasher()
        h.combine(world.walls.count)
        for w in world.walls { h.combine(w.id); h.combine(Int(w.a.x * 100)); h.combine(Int(w.a.y * 100)); h.combine(Int(w.b.x * 100)); h.combine(Int(w.b.y * 100)) }
        h.combine(world.rooms.count)
        for m in marks {
            switch m.style {
            case .reading, .source, .moisture, .moistureWash, .liftFlooring:
                h.combine(m.id); h.combine(m.value); h.combine(m.side); h.combine(m.faded); h.combine(m.points.count)
                if let p = m.points.first { h.combine(Int(p.x * 100)); h.combine(Int(p.y * 100)); h.combine(Int(p.z * 100)) }
            default: break
            }
        }
        h.combine(tweaks)
        return h.finalize()
    }
}

// MARK: - A solved model as shapes

struct MoistureDraw: Equatable {
    struct Area: Equatable {
        var provenance: MoistProvenance
        /// Closed loops: faces in (metres along a -> b, height); floors in plan (x, y).
        var loops: [[MoistVec]]
    }
    struct Edge: Equatable {
        var provenance: MoistProvenance
        var points: [MoistVec]
    }
    struct Face: Equatable {
        var wallId: String
        var side: MoistSide
        var areas: [Area]
        var edges: [Edge]
    }
    struct Floor: Equatable {
        var roomId: String
        var areas: [Area]
        var edges: [Edge]
    }
    struct Hint: Equatable {
        var pos: MoistVec
        var height: Double
        var wallId: String?
        var side: MoistSide?
        var message: String
    }

    var faces: [Face] = []
    var floors: [Floor] = []
    var hints: [Hint] = []

    static let provenances: [MoistProvenance] = [.measured, .estimated, .scoper]

    /// The wet areas and edges of a solved model.
    static func build(_ r: MoistResult) -> MoistureDraw {
        var out = MoistureDraw()
        let g = r.grid
        let wd = MoistScale.dampLevel
        for L in g.walls {
            let w = r.input.walls[L.wall]
            let topZ = Double(L.rows) * g.h
            for side in [MoistSide.a, MoistSide.b] {
                var any = false
                var all = Array(repeating: 0.0, count: L.cols * L.rows)
                var prov = Array(repeating: MoistProvenance.estimated, count: L.cols * L.rows)
                var wet = Array(repeating: false, count: L.cols * L.rows)
                for c in 0..<L.cols {
                    for row in 0..<L.rows {
                        let i = L.cell(side, c, row)
                        guard i >= 0 else { continue }
                        all[row * L.cols + c] = r.wetness[i]
                        prov[row * L.cols + c] = r.provenance[i]
                        if r.wetness[i] >= wd { wet[row * L.cols + c] = true; any = true }
                    }
                }
                guard any else { continue }
                func toFace(_ p: MoistVec) -> MoistVec {
                    MoistVec(min(w.length, max(0, p.x * L.colWidth)), min(topZ, max(0, p.y * g.h)))
                }
                let areas = areasFor(values: all, wet: wet, prov: prov, nx: L.cols, ny: L.rows, map: toFace)
                // The wet-dry edge, without the floor junction (the face meets the floor there).
                let loops = MoistShapesMath.contours(all, nx: L.cols, ny: L.rows, iso: wd).map { MoistShapesMath.smooth($0).map(toFace) }
                let edges = split(loops, skip: { a, b in a.y < 0.03 && b.y < 0.03 }) { p in
                    let c = min(L.cols - 1, max(0, Int(p.x / L.colWidth)))
                    let row0 = min(L.rows - 1, max(0, Int(p.y / g.h)))
                    for row in stride(from: row0, through: 0, by: -1) where wet[row * L.cols + c] { return prov[row * L.cols + c] }
                    return prov[row0 * L.cols + c]
                }
                out.faces.append(Face(wallId: w.id, side: side, areas: areas, edges: edges))
            }
        }
        for (ri, room) in r.input.rooms.enumerated() where g.nx > 0 {
            var all = Array(repeating: 0.0, count: g.nx * g.ny)
            var prov = Array(repeating: MoistProvenance.estimated, count: g.nx * g.ny)
            var wet = Array(repeating: false, count: g.nx * g.ny)
            var any = false
            for i in 0..<g.count where g.cells[i].surface == .floor && g.cells[i].room == ri {
                let c = g.cells[i]
                let k = c.row * g.nx + c.col
                all[k] = r.wetness[i]
                prov[k] = r.provenance[i]
                if r.wetness[i] >= wd { wet[k] = true; any = true }
            }
            guard any else { continue }
            let toPlan: (MoistVec) -> MoistVec = { g.origin + $0 * g.h }
            let areas = areasFor(values: all, wet: wet, prov: prov, nx: g.nx, ny: g.ny, map: toPlan)
            let loops = MoistShapesMath.contours(all, nx: g.nx, ny: g.ny, iso: wd).map { MoistShapesMath.smooth($0).map(toPlan) }
            // Without the runs along the room's own walls.
            let edges = split(loops, skip: { a, b in
                MoistGeom.distanceToPolygonEdge(a, room.polygon) < 0.12 && MoistGeom.distanceToPolygonEdge(b, room.polygon) < 0.12
            }) { p in
                let i = Int(floor((p.x - g.origin.x) / g.h)), j = Int(floor((p.y - g.origin.y) / g.h))
                var best = MoistProvenance.estimated, bd = Double.infinity
                for dj in -1...1 { for di in -1...1 {
                    let x = i + di, y = j + dj
                    guard x >= 0, y >= 0, x < g.nx, y < g.ny, wet[y * g.nx + x] else { continue }
                    let c = g.origin + MoistVec(Double(x) + 0.5, Double(y) + 0.5) * g.h
                    let d = simd_length(c - p)
                    if d < bd { bd = d; best = prov[y * g.nx + x] }
                } }
                return best
            }
            out.floors.append(Floor(roomId: room.id, areas: areas, edges: edges))
        }
        out.hints = r.hints.map { h in
            Hint(pos: h.pos, height: h.height ?? 0, wallId: h.wallId, side: h.side, message: h.message)
        }
        return out
    }

    /// One fill per provenance. Each mask keeps its own wetness; a wet cell of another
    /// provenance is mirrored about the damp level, so neighbouring fills meet half way
    /// between the cells instead of overlapping or leaving a gap.
    static func areasFor(values: [Double], wet: [Bool], prov: [MoistProvenance], nx: Int, ny: Int,
                         map: (MoistVec) -> MoistVec) -> [Area] {
        let wd = MoistScale.dampLevel
        var out: [Area] = []
        for p in provenances {
            guard (0..<values.count).contains(where: { wet[$0] && prov[$0] == p }) else { continue }
            let v = (0..<values.count).map { k -> Double in
                if prov[k] == p || !wet[k] { return values[k] }
                return 2 * wd - values[k]
            }
            let loops = MoistShapesMath.contours(v, nx: nx, ny: ny, iso: wd)
                .map { MoistShapesMath.smooth($0).map(map) }
                .filter { $0.count >= 3 && MoistGeom.area($0) > 1e-4 }
            if !loops.isEmpty { out.append(Area(provenance: p, loops: loops)) }
        }
        return out
    }

    /// Loops cut into open runs of one provenance, leaving out the segments `skip` says.
    static func split(_ loops: [[MoistVec]], skip: (MoistVec, MoistVec) -> Bool, provenance: (MoistVec) -> MoistProvenance) -> [Edge] {
        var out: [Edge] = []
        for loop in loops where loop.count >= 3 {
            var runs: [Edge] = []
            var cur: Edge? = nil
            var cutAtStart = false
            for k in 0..<loop.count {
                let a = loop[k], b = loop[(k + 1) % loop.count]
                if skip(a, b) {
                    if k == 0 { cutAtStart = true }
                    if let c = cur, c.points.count >= 2 { runs.append(c) }
                    cur = nil
                    continue
                }
                let p = provenance((a + b) / 2)
                if var c = cur, c.provenance == p {
                    c.points.append(b)
                    cur = c
                } else {
                    if let c = cur, c.points.count >= 2 { runs.append(c) }
                    cur = Edge(provenance: p, points: [a, b])
                }
            }
            if let c = cur, c.points.count >= 2 { runs.append(c) }
            // The loop's last run continues into its first: one line.
            if !cutAtStart, runs.count >= 2, let f = runs.first, let l = runs.last, f.provenance == l.provenance,
               let le = l.points.last, let fs = f.points.first, simd_length(le - fs) < 1e-9 {
                var j = l
                j.points += f.points.dropFirst()
                runs.removeFirst()
                runs[runs.count - 1] = j
            }
            out += runs
        }
        return out
    }
}

// MARK: - A solve, kept

/// One solve of the model and everything the screens draw from it.
final class MoistureSolve {
    let result: MoistResult
    let report: MoistReport
    let draw: MoistureDraw
    let inputsHash: String
    let cellSize: Double
    let millis: Double

    init(result: MoistResult, report: MoistReport, draw: MoistureDraw, inputsHash: String, cellSize: Double, millis: Double) {
        self.result = result; self.report = report; self.draw = draw; self.inputsHash = inputsHash
        self.cellSize = cellSize; self.millis = millis
    }

    /// Solve a plan (pure; call off the main thread).
    static func solve(plan: [String: Any], options: MoistOptions) -> MoistureSolve {
        let input = MoisturePlan.input(plan: plan, options: options)
        let t0 = Date()
        let r = MoistModel.run(input)
        let rep = r.report()
        let d = MoistureDraw.build(r)
        return MoistureSolve(result: r, report: rep, draw: d, inputsHash: MoisturePlan.inputsHash(input), cellSize: options.cellSize,
                             millis: Date().timeIntervalSince(t0) * 1000)
    }

    var readingCount: Int { result.input.readings.filter { $0.kind == .reading }.count }
    var words: MoistureWords.State { MoistureWords.state(self) }
}

/// Runs the model off the main thread: debounced, and never twice for the same inputs.
/// `schedule` replaces any pending request; the newest result is delivered on the main queue.
final class MoistureRunner {
    private let queue = DispatchQueue(label: "securescan.moisture", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var lastHash: String?
    private var lastSolve: MoistureSolve?
    var debounce: TimeInterval
    private var solveCount = 0

    init(debounce: TimeInterval = 0.4) { self.debounce = debounce }

    /// The newest solve.
    var last: MoistureSolve? { lock.lock(); defer { lock.unlock() }; return lastSolve }
    /// Solves done (for tests and the log).
    var solves: Int { lock.lock(); defer { lock.unlock() }; return solveCount }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == generation }

    private func cached(_ hash: String) -> MoistureSolve? {
        lock.lock(); defer { lock.unlock() }
        return hash == lastHash ? lastSolve : nil
    }

    private func keep(_ s: MoistureSolve) {
        lock.lock(); defer { lock.unlock() }
        solveCount += 1
        lastHash = s.inputsHash
        lastSolve = s
    }

    /// Solve `plan` after the debounce unless its inputs are unchanged since the last solve.
    /// A newer request replaces a pending one; `done` runs on the main queue.
    func schedule(plan: [String: Any], options: MoistOptions, done: @escaping (MoistureSolve) -> Void) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, self.current(gen) else { return }
            let hash = MoisturePlan.inputsHash(MoisturePlan.input(plan: plan, options: options))
            let s = self.cached(hash) ?? {
                let s = MoistureSolve.solve(plan: plan, options: options)
                self.keep(s)
                return s
            }()
            DispatchQueue.main.async { if self.current(gen) { done(s) } }
        }
    }

    /// The same, now and on the calling thread (Studio, tests).
    @discardableResult
    func solveNow(plan: [String: Any], options: MoistOptions) -> MoistureSolve {
        lock.lock(); generation += 1; lock.unlock()
        let hash = MoisturePlan.inputsHash(MoisturePlan.input(plan: plan, options: options))
        if let s = cached(hash) { return s }
        let s = MoistureSolve.solve(plan: plan, options: options)
        keep(s)
        return s
    }
}

// MARK: - Words

enum MoistureWords {
    struct State: Equatable {
        /// "Model · 9 readings · fits well"
        var text: String
        /// A second source is likely: the chip says so and points at the spot.
        var secondSource: Bool
    }

    /// How well the physics explains the readings on its own.
    static func fit(_ r: MoistResult) -> String {
        let checks = r.fit.checks
        guard !checks.isEmpty else { return "no readings yet" }
        let share = Double(checks.filter(\.explained).count) / Double(checks.count)
        if share >= 0.8 { return "fits well" }
        if share >= 0.5 { return "fits roughly" }
        return "fits poorly"
    }

    static func state(_ s: MoistureSolve) -> State {
        if !s.result.hints.isEmpty { return State(text: "Another source likely — look here", secondSource: true) }
        let n = s.readingCount
        let readings = n == 1 ? "1 reading" : "\(n) readings"
        if s.result.sources.isEmpty && n == 0 { return State(text: "Model · mark a source or take readings", secondSource: false) }
        return State(text: "Model · \(readings) · \(fit(s.result))", secondSource: false)
    }

    /// "Likely" when the area it comes from is well backed, else "Possible".
    static func confidenceWord(_ c: MoistConfidence?) -> String {
        guard let c else { return "Possible" }
        return c.level == .high ? "Likely" : "Possible"
    }

    /// A model suggestion as the suggestion chip says it (one line).
    static func suggestion(_ s: MoistSuggestion) -> String? {
        let word = confidenceWord(s.confidence)
        switch s.kind {
        case .stripLining:
            guard let mm = s.cutHeightMm else { return nil }
            return "\(word): strip wall to \(mm) · \(String(format: "%.1f m", s.length))"
        case .removeSkirting:
            return "\(word): skirting · \(String(format: "%.1f m", s.length))"
        case .liftFlooring:
            let what = s.covering.map { $0 == .other ? "flooring" : $0.rawValue } ?? "flooring"
            return "\(word): lift \(what) · \(String(format: "%.1f m²", s.area))"
        case .inspectCavity:
            return nil
        }
    }

    // MARK: The quote's totals (Items tab)

    struct Total: Equatable {
        var title: String
        var unit: String
        var measured: Double
        var estimated: Double
        var total: Double { measured + estimated }
        /// "4.2 m² · 2.6 measured, 1.6 estimated"
        var detail: String {
            let f: (Double) -> String = { String(format: "%.1f", $0) }
            if estimated < 0.05 { return "measured" }
            if measured < 0.05 { return "estimated" }
            return "\(f(measured)) measured · \(f(estimated)) estimated"
        }
        var value: String { String(format: "%.1f %@", total, unit) }
    }

    /// Lining m², floor m², skirting lm; the scoper's corrections count as measured.
    static func totals(_ t: MoistTotals) -> [Total] {
        func row(_ title: String, _ unit: String, _ s: MoistSplit) -> Total {
            Total(title: title, unit: unit, measured: s.measured + s.scoper, estimated: s.estimated)
        }
        return [row("Wall lining", "m²", t.wallLining), row("Floor", "m²", t.floor), row("Skirting", "lm", t.skirting)]
    }

    /// The same from plan.json's markup.moistureModel.solved.totals (no solve needed).
    static func totals(json: [String: Any]?) -> [Total]? {
        guard let t = json?["totals"] as? [String: Any] else { return nil }
        func split(_ k: String) -> MoistSplit {
            let d = t[k] as? [String: Any] ?? [:]
            return MoistSplit(measured: MoistNum.number(d["measured"]) ?? 0, estimated: MoistNum.number(d["estimated"]) ?? 0,
                              scoper: MoistNum.number(d["scoper"]) ?? 0)
        }
        return totals(MoistTotals(wallLining: split("wallLiningM2"), floor: split("floorM2"), floorByCovering: [],
                                  skirting: split("skirtingLm"), cavityLength: MoistNum.number(t["cavityLm"]) ?? 0))
    }
}

// MARK: - Overlay marks in the world

enum MoistureMarks {
    static let prefix = "model-"

    /// The model's wet areas and edges as world marks (faces 1 cm off their side of the wall,
    /// floors just above the floor), and the second-source hints.
    static func marks(_ d: MoistureDraw, world: CaptureWorld) -> [OverlayMark] {
        let fy = world.floorY ?? 0
        var out: [OverlayMark] = []
        func provName(_ p: MoistProvenance) -> String { p.rawValue }
        for f in d.faces {
            guard let w = world.wall(f.wallId), w.length > 1e-6 else { continue }
            let side = f.side == .b ? WallSide.b : WallSide.a
            func facePt(_ q: MoistVec, _ off: Double) -> WorldVec {
                WallSide.facePoint(w, t: q.x / w.length, height: q.y, floorY: fy, side: side, offset: off)
            }
            for a in f.areas {
                for (k, loop) in a.loops.enumerated() {
                    var m = OverlayMark(id: "\(prefix)fa-\(f.wallId)-\(side)-\(a.provenance.rawValue)-\(k)", style: .modelArea(provName(a.provenance)),
                                        points: loop.map { facePt($0, 0.012) })
                    m.wallId = f.wallId; m.side = side
                    out.append(m)
                }
            }
            for (k, e) in f.edges.enumerated() {
                var m = OverlayMark(id: "\(prefix)fe-\(f.wallId)-\(side)-\(k)", style: .modelEdge(provName(e.provenance)), points: e.points.map { facePt($0, 0.014) })
                m.wallId = f.wallId; m.side = side
                out.append(m)
            }
        }
        for f in d.floors {
            for a in f.areas {
                for (k, loop) in a.loops.enumerated() {
                    out.append(OverlayMark(id: "\(prefix)la-\(f.roomId)-\(a.provenance.rawValue)-\(k)", style: .modelArea(provName(a.provenance)),
                                           points: loop.map { WorldVec($0.x, fy + 0.006, $0.y) }))
                }
            }
            for (k, e) in f.edges.enumerated() {
                out.append(OverlayMark(id: "\(prefix)le-\(f.roomId)-\(k)", style: .modelEdge(provName(e.provenance)),
                                       points: e.points.map { WorldVec($0.x, fy + 0.008, $0.y) }))
            }
        }
        for (k, h) in d.hints.enumerated() {
            out.append(hintMark(h, index: k, world: world))
        }
        return out
    }

    static func hintMark(_ h: MoistureDraw.Hint, index k: Int, world: CaptureWorld) -> OverlayMark {
        let fy = world.floorY ?? 0
        var p = WorldVec(h.pos.x, fy + max(0.02, h.height), h.pos.y)
        var m = OverlayMark(id: "\(prefix)hint-\(k)", style: .modelHint, points: [p], tag: "Look here")
        if let w = world.wall(h.wallId) {
            let t = PlanBuilder.projectParam(PlanVec(h.pos.x, h.pos.y), w.a, w.b)
            let side = h.side == .b ? WallSide.b : (h.side == .cavity ? WallSide.cavity : WallSide.a)
            p = WallSide.facePoint(w, t: t, height: max(0.1, h.height), floorY: fy, side: side == WallSide.cavity ? WallSide.a : side, offset: 0.02)
            m.points = [p]
            m.wallId = w.id
            m.side = side
        }
        return m
    }
}

// MARK: - The scoper's corrections, made in the camera

/// A correction made in the camera ("Adjust"), kept in the session's world so it can be
/// written to any plan: the live world (identity) or plan.json (the scan's or the visit's
/// world-to-plan transform, the plan's walls).
struct LiveTweak: Codable, Equatable {
    enum Kind: String, Codable { case wet, dry, tide, barrier }
    var id: String
    var kind: Kind
    /// On a wall face (else the floor).
    var onWall: Bool
    /// World points (x, y, z); heights are `y - floorY`.
    var points: [WorldVec]
    var floorY: Double
    /// Where the scoper stood (world x, z): which face of the wall.
    var from: PlanVec
    var wallId: String?
    var radius: Double = 0.25

    /// The model's tweak against `walls` (in the target plan's frame), mapping world (x, z) with `toPlan`.
    func tweak(walls: [WorldWall], toPlan: (PlanVec) -> PlanVec = { $0 }) -> MoistTweak? {
        guard !points.isEmpty else { return nil }
        let plan = points.map { toPlan(PlanVec($0.x, $0.z)) }
        var t: MoistTweak
        switch kind {
        case .wet, .dry: t = MoistTweak(id: id, kind: .brush)
        case .tide: t = MoistTweak(id: id, kind: .tideLine)
        case .barrier: t = MoistTweak(id: id, kind: .barrier)
        }
        if kind == .barrier || !onWall {
            guard kind != .tide else { return nil }
            t.surface = .floor
            t.points = kind == .barrier ? [plan[0], plan[plan.count - 1]] : plan.map { MoistVec($0.x, $0.y) }
            if kind == .barrier && simd_length(plan[0] - plan[plan.count - 1]) < 0.1 { return nil }
        } else {
            let c = plan.reduce(PlanVec(0, 0), +) / Double(plan.count)
            let wall = walls.first { $0.id == wallId } ?? walls.min { a, b in
                PlanBuilder.distanceToSegment(c, a.a, a.b) < PlanBuilder.distanceToSegment(c, b.a, b.b)
            }
            guard let w = wall, w.length > 1e-6, PlanBuilder.distanceToSegment(c, w.a, w.b) < 0.4 else { return nil }
            t.surface = .face
            t.wallId = w.id
            t.side = WallSide.side(of: toPlan(from), wall: w) == WallSide.b ? .b : .a
            var pts = zip(points, plan).map { p, q in
                MoistVec(MoistNum.r3(PlanBuilder.projectParam(q, w.a, w.b) * w.length), MoistNum.r3(max(0, p.y - floorY)))
            }
            if kind == .tide {
                pts.sort { $0.x < $1.x }
                if pts.count == 1 || (pts.last!.x - pts.first!.x) < 0.2 {
                    let h = pts.map(\.y).reduce(0, +) / Double(pts.count), x = pts[0].x
                    pts = [MoistVec(max(0, x - 0.3), h), MoistVec(min(w.length, x + 0.3), h)]
                }
            }
            t.points = pts
        }
        if kind == .wet || kind == .dry { t.state = kind == .wet ? .wet : .dry; t.radius = radius }
        return t
    }
}
