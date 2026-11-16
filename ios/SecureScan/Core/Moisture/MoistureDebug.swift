//
//  MoistureDebug.swift
//  SecureScan
//
//  Text pictures of a solved model, for tests and logs (no phone needed):
//  each wall as three bands (face a, cavity, face b) and the floor as a map.
//
//    ' ' dry   '.' a trace   'o' damp   'O' wet   '#' soaked   'x' opening / no cell
//

import Foundation

enum MoistDebug {

    static func glyph(_ w: Double) -> Character {
        w < 0.05 ? " " : w < MoistScale.dampLevel ? "." : w < MoistScale.wetLevel ? "o" : w < 0.7 ? "O" : "#"
    }

    static func provenanceGlyph(_ p: MoistProvenance, _ w: Double) -> Character {
        guard w >= MoistScale.dampLevel else { return w < 0.05 ? " " : "." }
        switch p { case .measured: return "M"; case .estimated: return "e"; case .scoper: return "S" }
    }

    /// One wall: face a (top), cavity, face b, each drawn top row first.
    static func wall(_ r: MoistResult, id: String, provenance: Bool = false) -> String {
        guard let L = r.grid.layout(wall: id) else { return "wall \(id): not in the model\n" }
        let w = r.input.walls[L.wall]
        var out = String(format: "Wall %@  %.2f m, %ld x %ld cells of %.2f x %.2f m\n", w.id, w.length, L.cols, L.rows, L.colWidth, r.grid.h)
        for side in [MoistSide.a, MoistSide.cavity, MoistSide.b] {
            let name = side == .cavity ? "cavity" : "face \(side.rawValue)"
            let room = side == .cavity ? -1 : (L.faceRoom[side == .a ? 0 : 1].first { $0 >= 0 } ?? -1)
            out += "  \(name)\(room >= 0 ? " (" + (r.input.rooms[room].name.isEmpty ? r.input.rooms[room].id : r.input.rooms[room].name) + ")" : "")\n"
            for row in stride(from: L.rows - 1, through: 0, by: -1) {
                var line = String(format: "  %4ld |", Int(((Double(row) + 0.5) * r.grid.h * 1000).rounded()))
                for c in 0..<L.cols {
                    let i = L.cell(side, c, row)
                    line.append(i < 0 ? "x" : provenance ? provenanceGlyph(r.provenance[i], r.wetness[i]) : glyph(r.wetness[i]))
                }
                out += line + "|\n"
            }
        }
        return out
    }

    /// The floor (all rooms, or the bounding box of the given rooms). One character per cell.
    static func floor(_ r: MoistResult, rooms ids: [String]? = nil, provenance: Bool = false) -> String {
        let g = r.grid
        guard g.nx > 0 else { return "no floor\n" }
        var i0 = g.nx, i1 = -1, j0 = g.ny, j1 = -1
        var map = Array(repeating: Character("?"), count: g.nx * g.ny)
        let roomIdx = Set((ids ?? r.input.rooms.map { $0.id }).compactMap { id in r.input.rooms.firstIndex { $0.id == id } })
        for i in 0..<g.count where g.cells[i].surface == .floor {
            let c = g.cells[i]
            map[c.row * g.nx + c.col] = provenance ? provenanceGlyph(r.provenance[i], r.wetness[i]) : glyph(r.wetness[i])
            if roomIdx.contains(c.room) { i0 = min(i0, c.col); i1 = max(i1, c.col); j0 = min(j0, c.row); j1 = max(j1, c.row) }
        }
        guard i1 >= i0, j1 >= j0 else { return "no floor cells\n" }
        var out = String(format: "Floor  x %.2f..%.2f m, y %.2f..%.2f m, %.2f m cells ('?' = outside the rooms)\n",
                         g.origin.x + Double(i0) * g.h, g.origin.x + Double(i1 + 1) * g.h,
                         g.origin.y + Double(j0) * g.h, g.origin.y + Double(j1 + 1) * g.h, g.h)
        for j in j0...j1 {
            var line = "  |"
            for i in i0...i1 { line.append(map[j * g.nx + i]) }
            out += line + "|\n"
        }
        return out
    }

    /// A one-screen summary: fit, hints, totals and suggestions.
    static func summary(_ r: MoistResult, _ rep: MoistReport) -> String {
        var s = String(format: "Moisture model: %ld cells, %ld iterations, hours %.0f, fitted %@ (objective %.4f -> %.4f, %ld solves)\n",
                       r.grid.count, r.iterations, r.hours, r.fit.fitted ? "yes" : "no", r.fit.objectiveBefore, r.fit.objective, r.fit.evaluations)
        s += String(format: "  params: floor x%.2f, rise x%.2f, lining x%.2f; work %.1f M link visits\n",
                    r.params.floorSpread, r.params.rise, r.params.lining, Double(r.work) / 1e6)
        for src in r.sources {
            s += String(format: "  source %@ (%@, %@): %.2f L\n", src.source.id, src.source.type.rawValue,
                        src.loc?.surface.rawValue ?? "not placed", r.params.volumes[src.source.id] ?? src.litres)
        }
        for c in r.fit.checks {
            s += String(format: "  reading %@: measured %@ (w %.2f), physics %.2f %@\n", c.n.map { "\($0)" } ?? c.readingId,
                        c.measured.rawValue, c.measuredWetness, c.physics, c.explained ? "ok" : "NOT EXPLAINED")
        }
        for h in r.hints { s += "  HINT: \(h.message) (explains \(Int((h.improvement * 100).rounded()))%)\n" }
        let t = rep.totals
        s += String(format: "  wall lining wet %.2f m² (measured %.2f, estimated %.2f, scoper %.2f)\n",
                    t.wallLining.total, t.wallLining.measured, t.wallLining.estimated, t.wallLining.scoper)
        s += String(format: "  floor wet %.2f m² (measured %.2f, estimated %.2f, scoper %.2f)\n", t.floor.total, t.floor.measured, t.floor.estimated, t.floor.scoper)
        for c in t.floorByCovering { s += String(format: "    %@ %.2f m²\n", c.covering.rawValue, c.area.total) }
        s += String(format: "  skirting %.2f lm, cavity %.2f lm\n", t.skirting.total, t.cavityLength)
        for f in rep.faces where f.wetArea.total > 0 {
            s += String(format: "  face %@/%@ (%@): wet %.2f m², tide max %.0f mm, skirting %.2f lm, confidence %@ %.2f\n",
                        f.wallId, f.side.rawValue, f.lining, f.wetArea.total, f.maxHeight * 1000, f.skirting.total, f.confidence.level.rawValue, f.confidence.score)
        }
        for f in rep.floors {
            s += String(format: "  floor %@: wet %.2f m² in %ld outline(s), confidence %@ %.2f\n",
                        f.name.isEmpty ? f.roomId : f.name, f.wetArea.total, f.polygons.count, f.confidence.level.rawValue, f.confidence.score)
        }
        for x in rep.suggestions {
            s += "  SUGGEST \(x.kind.rawValue) \(x.wallId ?? x.roomId ?? "")\(x.side.map { "/" + $0.rawValue } ?? "")"
            if let f = x.from, let t = x.to { s += String(format: " %.2f-%.2f m", f, t) }
            if let c = x.cutHeightMm { s += " cut \(c) mm" }
            if x.area > 0 { s += String(format: " %.2f m²", x.area) }
            if let c = x.confidence { s += " (confidence \(c.level.rawValue))" }
            s += "\n"
        }
        s += "  timings ms: " + r.timings.keys.sorted().map { String(format: "%@ %.1f", $0, r.timings[$0] ?? 0) }.joined(separator: ", ") + "\n"
        return s
    }
}
