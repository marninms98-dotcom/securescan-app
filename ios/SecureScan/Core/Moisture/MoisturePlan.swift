//
//  MoisturePlan.swift
//  SecureScan
//
//  plan.json <-> the moisture model (docs/MOISTURE.md, "plan.json"). Reads the
//  geometry, sources, readings and the optional `markup.moistureModel`
//  (settings + the scoper's tweaks), and writes `markup.moistureModel` back
//  with the fitted parameters and a summary of the last solve, so another
//  phone or the report generator can reproduce or draw the same result.
//  Tolerant of missing fields, like the rest of the plan code.
//

import Foundation
import simd

enum MoisturePlan {

    static let version = 1
    static let engine = "1.0"

    // MARK: Reading plan.json

    static func input(plan: [String: Any], visit explicitVisit: String? = nil, options: MoistOptions = MoistOptions()) -> MoistInput {
        var input = MoistInput()
        input.options = options
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let model = markup["moistureModel"] as? [String: Any] ?? [:]

        for w in plan["walls"] as? [[String: Any]] ?? [] {
            guard let id = w["id"] as? String, let a = MoistNum.point(w["a"]), let b = MoistNum.point(w["b"]) else { continue }
            input.walls.append(MoistWall(id: id, a: a, b: b, height: MoistNum.number(w["height"]).flatMap { (x: Double) -> Double? in x > 0.3 ? x : nil } ?? 2.4))
        }
        for (k, o) in (plan["openings"] as? [[String: Any]] ?? []).enumerated() {
            guard let a = MoistNum.point(o["a"]), let b = MoistNum.point(o["b"]) else { continue }
            let type = (o["type"] as? String) ?? "opening"
            input.openings.append(MoistOpening(id: (o["id"] as? String) ?? "o\(k + 1)", type: type, wallId: o["wallId"] as? String, a: a, b: b,
                                               sill: MoistNum.number(o["sill"]) ?? (type == "window" ? 0.9 : 0),
                                               height: MoistNum.number(o["height"]) ?? (type == "window" ? 1.2 : 2.04)))
        }
        for (k, r) in (plan["rooms"] as? [[String: Any]] ?? []).enumerated() {
            let poly = MoistNum.points(r["polygon"])
            guard poly.count >= 3 else { continue }
            input.rooms.append(MoistRoom(id: (r["id"] as? String) ?? "r\(k + 1)", name: (r["name"] as? String) ?? "", polygon: poly))
        }
        for (k, f) in (markup["floors"] as? [[String: Any]] ?? []).enumerated() {
            let poly = MoistNum.points(f["polygon"])
            guard poly.count >= 3 else { continue }
            input.floors.append(MoistFloorZone(id: (f["id"] as? String) ?? "f\(k + 1)", polygon: poly, covering: MoistCovering.parse(f["type"] as? String)))
        }
        for (k, t) in (markup["floorThresholds"] as? [[String: Any]] ?? []).enumerated() {
            guard let a = MoistNum.point(t["a"]), let b = MoistNum.point(t["b"]) else { continue }
            input.floorThresholds.append(MoistFloorThreshold(id: (t["id"] as? String) ?? "t\(k + 1)", a: a, b: b, type: (t["type"] as? String) ?? "strip"))
        }
        if let th = markup["thresholds"] as? [String: Any] {
            input.thresholds = MoistThresholds(damp: MoistNum.number(th["damp"]) ?? 15, wet: MoistNum.number(th["wet"]) ?? 20)
        }
        for (k, s) in (markup["sources"] as? [[String: Any]] ?? []).enumerated() {
            guard let pos = MoistNum.point(s["pos"]) else { continue }
            let label = (s["label"] as? String) ?? ""
            let type = (s["type"] as? String).flatMap { MoistSourceType(rawValue: $0) } ?? MoistSourceType.infer(label)
            var src = MoistSource(id: (s["id"] as? String) ?? "s\(k + 1)", label: label, type: type, pos: pos,
                                  wallId: s["wallId"] as? String, height: MoistNum.number(s["height"]), side: MoistSide.parse(s["side"]))
            if let i = MoistSourceProfiles.intensity(s["intensity"]) { src.intensity = i; src.intensityFixed = true }
            if (s["placement"] as? String) == "floor" { src.onFloor = true }
            input.sources.append(src)
        }

        // Readings and moisture-line marks for the visit.
        let visit = explicitVisit ?? (model["visit"] as? String)
        var visitOrder: [String: Int] = [:]
        for (i, v) in (markup["visits"] as? [[String: Any]] ?? []).enumerated() {
            if let id = v["id"] as? String, visitOrder[id] == nil { visitOrder[id] = i }
        }
        let all = markup["readings"] as? [[String: Any]] ?? []
        var latestMarkVisit: [String: Int] = [:]     // wall id -> latest visit order with marks
        if visit == nil {
            for r in all where (r["kind"] as? String) == "boundary" {
                guard let wid = r["wallId"] as? String else { continue }
                let o = visitOrder[(r["visit"] as? String) ?? "v1"] ?? 0
                latestMarkVisit[wid] = max(latestMarkVisit[wid] ?? Int.min, o)
            }
        }
        for (k, r) in all.enumerated() {
            let kindName = (r["kind"] as? String) ?? "reading"
            guard kindName == "reading" || kindName == "boundary", let pos = MoistNum.point(r["pos"]) else { continue }
            var reading = MoistReading(id: (r["id"] as? String) ?? "m\(k + 1)", pos: pos)
            reading.kind = kindName == "boundary" ? .boundary : .reading
            reading.n = (r["n"] as? Int) ?? MoistNum.number(r["n"]).map { Int($0) }
            reading.material = (r["material"] as? String) ?? ""
            reading.wallId = r["wallId"] as? String
            reading.height = MoistNum.number(r["height"])
            reading.side = MoistSide.parse(r["side"])
            reading.cam = MoistNum.point(r["cam"])
            reading.reference = (r["reference"] as? Bool) ?? false
            if let wid = reading.wallId, let t = MoistNum.number(r["wallT"]), let w = input.walls.first(where: { $0.id == wid }) {
                reading.pos = w.a + (w.b - w.a) * t
            }
            let itemVisit = (r["visit"] as? String) ?? "v1"
            if reading.kind == .boundary {
                if let v = visit { guard itemVisit == v else { continue } }
                else if let wid = reading.wallId, let latest = latestMarkVisit[wid] { guard (visitOrder[itemVisit] ?? 0) == latest else { continue } }
            } else {
                if let v = visit {
                    if let hist = r["history"] as? [[String: Any]], !hist.isEmpty {
                        guard let e = hist.first(where: { ($0["visit"] as? String) == v }), let x = MoistNum.number(e["value"]) else { continue }
                        reading.value = x
                    } else {
                        guard itemVisit == v, let x = MoistNum.number(r["value"]) else { continue }
                        reading.value = x
                    }
                } else {
                    guard let x = MoistNum.number(r["value"]) else { continue }
                    reading.value = x
                }
            }
            input.readings.append(reading)
        }

        if let h = MoistNum.number(model["hoursSinceEvent"]), h > 0, input.options.hoursSinceEvent == nil { input.options.hoursSinceEvent = h }
        input.tweaks = (model["tweaks"] as? [[String: Any]] ?? []).compactMap(tweak)
        return input
    }

    // MARK: Tweaks

    static func tweak(_ d: [String: Any]) -> MoistTweak? {
        guard let kindName = d["kind"] as? String, let kind = MoistTweak.Kind(rawValue: kindName) else { return nil }
        var t = MoistTweak(id: (d["id"] as? String) ?? kindName, kind: kind)
        t.surface = (d["surface"] as? String).flatMap { MoistSurface(rawValue: $0) }
        t.wallId = d["wallId"] as? String
        t.side = MoistSide.parse(d["side"])
        t.points = MoistNum.points(d["points"])
        if t.points.isEmpty, let a = MoistNum.point(d["a"]), let b = MoistNum.point(d["b"]) { t.points = [a, b] }
        if t.points.isEmpty, let p = MoistNum.point(d["pos"]) { t.points = [p] }
        if let r = MoistNum.number(d["radius"]), r > 0 { t.radius = r }
        t.state = (d["state"] as? String).flatMap { MoistState(rawValue: $0) }
        t.sourceId = d["sourceId"] as? String
        t.intensity = MoistSourceProfiles.intensity(d["intensity"])
        t.sourceType = d["type"] as? String
        t.placement = d["placement"] as? String
        t.value = d["value"] as? String
        t.at = d["at"] as? String
        return t
    }

    static func json(_ t: MoistTweak) -> [String: Any] {
        var d: [String: Any] = ["id": t.id, "kind": t.kind.rawValue]
        if let s = t.surface { d["surface"] = s.rawValue }
        if let w = t.wallId { d["wallId"] = w }
        if let s = t.side { d["side"] = s.rawValue }
        if !t.points.isEmpty { d["points"] = t.points.map { [MoistNum.r3($0.x), MoistNum.r3($0.y)] } }
        if t.kind == .brush { d["radius"] = MoistNum.r3(t.radius) }
        if let s = t.state { d["state"] = s.rawValue }
        if let s = t.sourceId { d["sourceId"] = s }
        if let i = t.intensity { d["intensity"] = MoistNum.r3(i) }
        if let s = t.sourceType { d["type"] = s }
        if let s = t.placement { d["placement"] = s }
        if let s = t.value { d["value"] = s }
        if let s = t.at { d["at"] = s }
        return d
    }

    // MARK: Writing markup.moistureModel

    /// The `markup.moistureModel` object after a solve. Keeps unknown keys of `previous`.
    static func modelJSON(_ result: MoistResult, report: MoistReport, previous: [String: Any]? = nil, solvedAt: String? = nil) -> [String: Any] {
        var m = previous ?? [:]
        m["version"] = version
        m["tweaks"] = result.input.tweaks.map(json)
        var vols: [String: Any] = [:]
        for s in result.sources { vols[s.source.id] = MoistNum.r3(result.params.volumes[s.source.id] ?? s.litres) }
        m["params"] = ["floorSpread": MoistNum.r3(result.params.floorSpread), "rise": MoistNum.r3(result.params.rise),
                       "lining": MoistNum.r3(result.params.lining), "volumes": vols] as [String: Any]
        func split(_ s: MoistSplit) -> [String: Any] {
            ["measured": MoistNum.r2(s.measured), "estimated": MoistNum.r2(s.estimated), "scoper": MoistNum.r2(s.scoper), "total": MoistNum.r2(s.total)]
        }
        func pts(_ p: [MoistVec]) -> [[Double]] { p.map { [MoistNum.r3($0.x), MoistNum.r3($0.y)] } }
        func conf(_ c: MoistConfidence) -> [String: Any] { ["score": c.score, "level": c.level.rawValue, "readings": c.readings] }
        var solved: [String: Any] = [
            "engine": engine,
            "inputsHash": inputsHash(result.input),
            "cellSize": result.grid.h,
            "hours": MoistNum.r2(result.hours),
            "fitted": result.fit.fitted,
            "secondSourceLikely": result.secondSourceLikely,
        ]
        if let at = solvedAt { solved["at"] = at }
        let t = report.totals
        solved["totals"] = [
            "wallLiningM2": split(t.wallLining), "floorM2": split(t.floor), "skirtingLm": split(t.skirting),
            "cavityLm": t.cavityLength,
            "floorByCovering": t.floorByCovering.map { ["covering": $0.covering.rawValue, "m2": split($0.area)] as [String: Any] },
        ] as [String: Any]
        solved["faces"] = report.faces.filter { $0.wetArea.total > 0 }.map { f -> [String: Any] in
            var d: [String: Any] = ["wallId": f.wallId, "side": f.side.rawValue, "lining": f.lining, "wetM2": split(f.wetArea),
                                    "skirtingLm": split(f.skirting), "maxHeight": f.maxHeight, "tideLine": f.tideLine.map(pts),
                                    "reachesModelTop": f.reachesModelTop, "confidence": conf(f.confidence)]
            if let r = f.roomId { d["roomId"] = r }
            return d
        }
        solved["cavities"] = report.cavities.map { c -> [String: Any] in
            ["wallId": c.wallId, "runs": pts(c.runs), "wetLm": c.wetLength, "maxHeight": c.maxHeight, "confidence": conf(c.confidence)]
        }
        solved["floors"] = report.floors.map { f -> [String: Any] in
            ["roomId": f.roomId, "polygons": f.polygons.map(pts), "wetM2": split(f.wetArea),
             "byCovering": f.byCovering.map { ["covering": $0.covering.rawValue, "m2": split($0.area)] as [String: Any] },
             "confidence": conf(f.confidence)]
        }
        solved["hints"] = result.hints.map { h -> [String: Any] in
            var d: [String: Any] = ["readingIds": h.readingIds, "surface": h.surface.rawValue, "pos": [MoistNum.r3(h.pos.x), MoistNum.r3(h.pos.y)],
                                    "improvement": MoistNum.r2(h.improvement), "message": h.message]
            if let w = h.wallId { d["wallId"] = w }
            if let a = h.along { d["along"] = MoistNum.r3(a) }
            if let z = h.height { d["height"] = MoistNum.r3(z) }
            if let r = h.roomId { d["roomId"] = r }
            return d
        }
        solved["suggestions"] = report.suggestions.map { s -> [String: Any] in
            var d: [String: Any] = ["kind": s.kind.rawValue, "suggestion": true]
            if let w = s.wallId { d["wallId"] = w }
            if let x = s.side { d["side"] = x.rawValue }
            if let r = s.roomId { d["roomId"] = r }
            if let f = s.from { d["from"] = f }
            if let t = s.to { d["to"] = t }
            if let c = s.cutHeightMm { d["cutHeightMm"] = c }
            if let c = s.covering { d["covering"] = c.rawValue }
            if !s.polygons.isEmpty { d["polygons"] = s.polygons.map(pts) }
            if s.area > 0 { d["m2"] = s.area }
            if s.length > 0 { d["lm"] = s.length }
            if !s.note.isEmpty { d["note"] = s.note }
            return d
        }
        m["solved"] = solved
        return m
    }

    /// Adds or replaces a tweak in `markup.moistureModel` of a plan.
    static func adding(_ t: MoistTweak, to plan: [String: Any]) -> [String: Any] {
        var plan = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var model = markup["moistureModel"] as? [String: Any] ?? ["version": version]
        var list = model["tweaks"] as? [[String: Any]] ?? []
        list.removeAll { ($0["id"] as? String) == t.id }
        list.append(json(t))
        model["tweaks"] = list
        markup["moistureModel"] = model
        plan["markup"] = markup
        return plan
    }

    // MARK: Hash

    /// FNV-1a 64 of a canonical description of everything the solve depends on.
    static func inputsHash(_ input: MoistInput) -> String {
        var s = "v\(version)|\(engine)|"
        func n(_ x: Double) -> String { String(format: "%.3f", x) }
        func p(_ v: MoistVec) -> String { n(v.x) + "," + n(v.y) }
        for w in input.walls { s += "W\(w.id):\(p(w.a)):\(p(w.b)):\(n(w.height))|" }
        for o in input.openings { s += "O\(o.type):\(o.wallId ?? ""):\(p(o.a)):\(p(o.b)):\(n(o.sill)):\(n(o.height))|" }
        for r in input.rooms { s += "R\(r.id):\(r.name):" + r.polygon.map(p).joined(separator: ";") + "|" }
        for f in input.floors { s += "F\(f.covering.rawValue):" + f.polygon.map(p).joined(separator: ";") + "|" }
        for t in input.floorThresholds { s += "T\(t.type):\(p(t.a)):\(p(t.b))|" }
        for x in input.sources {
            s += "S\(x.id):\(x.type.rawValue):\(p(x.pos)):\(x.wallId ?? ""):\(x.height.map(n) ?? ""):\(x.side?.rawValue ?? ""):\(x.onFloor):\(n(x.intensity)):\(x.intensityFixed)|"
        }
        for r in input.readings {
            s += "M\(r.id):\(r.kind.rawValue):\(r.value.map(n) ?? ""):\(p(r.pos)):\(r.wallId ?? ""):\(r.height.map(n) ?? ""):\(r.side?.rawValue ?? ""):\(r.material):\(r.reference)|"
        }
        s += "TH\(n(input.thresholds.damp)):\(n(input.thresholds.wet))|"
        for t in input.tweaks { s += "K" + String(describing: json(t).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }) + "|" }
        let o = input.options
        s += "OPT\(n(o.cellSize)):\(n(o.fitCellSize)):\(n(o.maxWallHeight)):\(o.hoursSinceEvent.map(n) ?? ""):\(o.fit):\(n(o.reach))"
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
}
