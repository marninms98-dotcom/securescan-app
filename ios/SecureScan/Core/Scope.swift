//
//  Scope.swift
//  SecureScan
//
//  The scope of works as the crew sees it on site: every removal (X1, X2…
//  on walls, F1, F2… on the floor, numbered by the same rule as the
//  editor's removalRefs) and every piece of equipment, with a plain
//  description, whether it is done / placed, and where it is. No prices.
//  Also the air mover's airflow direction ("dir", a plan angle) from where
//  the phone points. Foundation + simd only - unit tested.
//

import Foundation
import simd

struct ScopeItem: Equatable, Identifiable {
    enum Kind: String { case wall, floor, equipment }
    var id: String
    var kind: Kind
    var tag: String                 // X1 · F1 · AM-03
    var title: String               // "X1 · remove plasterboard, wall w3, 2.20 × 1.20 m"
    var done: Bool
    var pos: PlanVec                // centre (wall: middle of the stretch)
    var height = 0.0                // metres above the floor (wall: middle of the band)
    var wallId: String? = nil
    var t0: Double? = nil
    var t1: Double? = nil
    var top: Double? = nil          // wall: top of the cut (m)
    var polygon: [PlanVec]? = nil   // floor
    var equipmentType: String? = nil
    var dir: Double? = nil          // air movers: plan angle of the airflow

    /// The one thing the crew does with it.
    var actionTitle: String {
        switch kind {
        case .equipment: return done ? "\(tag) is placed" : "Mark placed: \(tag)"
        case .wall, .floor: return done ? "\(tag) is done" : "Mark done + after photo"
        }
    }
}

enum ScopeList {
    static let itemNames: [String: String] = ["plasterboard": "plasterboard", "skirting": "skirting", "cabinetry": "cabinetry",
                                              "flooring": "flooring", "other": "lining"]
    static let equipmentNames: [String: String] = ["airMover": "air mover", "dehumidifier": "dehumidifier",
                                                   "airScrubber": "air scrubber", "heater": "heater", "other": "equipment"]

    /// A finite JSON number (JSON booleans are not numbers), as the editor's Number.isFinite.
    static func finiteNumber(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    /// The editor's isPt: an array of at least two finite numbers.
    static func isPt(_ any: Any?) -> Bool {
        guard let p = any as? [Any], p.count >= 2 else { return false }
        return finiteNumber(p[0]) != nil && finiteNumber(p[1]) != nil
    }

    static func pt(_ any: Any?) -> PlanVec? {
        guard isPt(any), let p = any as? [Any], let x = finiteNumber(p[0]), let y = finiteNumber(p[1]) else { return nil }
        return PlanVec(x, y)
    }

    /// The editor's `!x.wallId`: absent, null, "", 0 or false.
    static func noWallId(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return true }
        if let s = v as? String { return s.isEmpty }
        if let n = v as? NSNumber { return n.doubleValue == 0 || n.doubleValue.isNaN }
        return false
    }

    /// The editor's isFloorRemoval: no wallId, and an `area` of 3+ points.
    static func isFloorRemoval(_ x: [String: Any]) -> Bool {
        guard noWallId(x["wallId"]), let area = x["area"] as? [Any], area.count >= 3 else { return false }
        return area.allSatisfy { isPt($0) }
    }

    /// The ids of the plan's walls as the editor's geometry keeps them: both
    /// ends points and more than 1 cm apart.
    static func planWallIds(_ plan: [String: Any]) -> Set<String> {
        var ids = Set<String>()
        for case let w as [String: Any] in plan["walls"] as? [Any] ?? [] {
            guard let id = w["id"] as? String, let a = pt(w["a"]), let b = pt(w["b"]), simd_distance(a, b) > 0.01 else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// X1, X2… for removals on a wall of the plan, F1, F2… for floor
    /// sections, in document order (the editor's removalRefs rule, exactly:
    /// a removal whose wallId names a missing or degenerate wall gets no tag,
    /// even with an area; every removal counts in order, with an id or not).
    static func refs(plan: [String: Any]) -> [String: String] {
        let wallIds = planWallIds(plan)
        var out: [String: String] = [:]
        var i = 0, j = 0
        for case let x as [String: Any] in (plan["markup"] as? [String: Any])?["removals"] as? [Any] ?? [] {
            let id = x["id"] as? String
            if let w = x["wallId"] as? String, wallIds.contains(w) { i += 1; if let id { out[id] = "X\(i)" } }
            else if isFloorRemoval(x) { j += 1; if let id { out[id] = "F\(j)" } }
        }
        return out
    }

    /// Equipment the scope proposes but nobody has put down yet.
    static func isPlanned(_ e: [String: Any]) -> Bool { (e["status"] as? String) == "planned" }

    static func m2(_ v: Double) -> String { String(format: "%.2f", v) }

    /// `names`: the editor's wall names and removal tags cached after its last load
    /// (SecureScan.wallNames() / removalRefs()); the Swift port is the fallback.
    static func items(plan: [String: Any], names: EditorNames? = nil) -> [ScopeItem] {
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let walls = Dictionary(Revisit.walls(plan).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ported = refs(plan: plan)
        let tags = names.map { n in n.removalRefs.isEmpty ? ported : ported.merging(n.removalRefs) { _, editor in editor } } ?? ported
        var out: [ScopeItem] = []
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            guard let id = x["id"] as? String, let tag = tags[id] else { continue }
            let item = (x["item"] as? String) ?? "other"
            let done = (x["status"] as? String) == "done"
            if tag.hasPrefix("X"), let wid = x["wallId"] as? String, let w = walls[wid] {
                let t0 = PlanDocument.number(x["t0"]) ?? 0, t1 = PlanDocument.number(x["t1"]) ?? 1
                let a = min(t0, t1), b = max(t0, t1)
                let len = (b - a) * w.length
                let top = min(max((PlanDocument.number(x["heightMm"]) ?? 600) / 1000, 0.05), w.height)
                let what = itemNames[item] ?? "lining"
                let size = item == "skirting" ? "\(m2(len)) m" : "\(m2(len)) × \(m2(top)) m"
                out.append(ScopeItem(id: id, kind: .wall, tag: tag, title: "\(tag) · remove \(what), \(EditorNames.wallLabel(wid, names)), \(size)",
                                     done: done, pos: w.a + (w.b - w.a) * ((a + b) / 2), height: top / 2,
                                     wallId: wid, t0: a, t1: b, top: top))
            } else if tag.hasPrefix("F") {
                let poly = (x["area"] as? [Any] ?? []).compactMap { pt($0) }
                let type = (x["floorType"] as? String).map { $0 + ((x["underlay"] as? Bool) == true ? " + underlay" : "") } ?? "flooring"
                let centre = poly.reduce(PlanVec(0, 0), +) / Double(max(poly.count, 1))
                out.append(ScopeItem(id: id, kind: .floor, tag: tag, title: "\(tag) · lift \(type), \(m2(FloorArea.area(poly))) m²",
                                     done: done, pos: centre, polygon: poly))
            }
        }
        var perType: [String: Int] = [:]
        for e in markup["equipment"] as? [[String: Any]] ?? [] {
            guard let id = e["id"] as? String, let pos = Revisit.point(e["pos"]) else { continue }
            if let r = e["removed"], !(r is NSNull) { continue }          // taken away: no longer scope
            let type = (e["type"] as? String) ?? "other"
            perType[type, default: 0] += 1
            let label = (e["label"] as? String) ?? ""
            let tag = label.isEmpty ? "\(QuoteTally.short[type] ?? "EQ")-\(perType[type] ?? 1)" : label
            let name = equipmentNames[type] ?? "equipment"
            out.append(ScopeItem(id: id, kind: .equipment, tag: tag, title: "\(tag) · \(name)", done: !isPlanned(e),
                                 pos: pos, height: 0.15, equipmentType: type, dir: PlanDocument.number(e["dir"])))
        }
        return out
    }

    static func progress(_ items: [ScopeItem]) -> (done: Int, total: Int) {
        (items.filter(\.done).count, items.count)
    }

    /// "Mark placed": the planned equipment is now on site in `visit`.
    static func markPlaced(plan: [String: Any], id: String, visit: String, at: String) -> [String: Any]? {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var eq = markup["equipment"] as? [[String: Any]] ?? []
        guard let i = eq.firstIndex(where: { ($0["id"] as? String) == id }) else { return nil }
        eq[i]["status"] = "placed"
        eq[i]["placed"] = visit
        eq[i]["placedAt"] = at
        markup["equipment"] = eq
        doc["markup"] = markup
        return doc
    }
}

enum Airflow {
    /// The plan angle the phone points along (horizontal part of the camera's
    /// forward axis), nil when it points nearly straight down or up.
    static func planAngle(forward: WorldVec, transform: PlanTransform) -> Double? {
        let d = transform.direction(forward)
        let len = simd_length(forward)
        guard len > 1e-9, simd_length(d) / len > 0.2 else { return nil }
        return atan2(d.y, d.x)
    }

    /// Unit world direction (horizontal) of a plan angle.
    static func worldDirection(_ dir: Double, transform: PlanTransform) -> WorldVec {
        let w = transform.world(PlanVec(cos(dir), sin(dir)) + transform.offset, y: 0)
        return WorldVec(w.x, 0, w.z)
    }
}

/// Names the editor gives things, cached per job after each editor load so the
/// AR screens say "wall B" and "X1" exactly like the documents.
struct EditorNames: Codable, Equatable {
    var wallNames: [String: String] = [:]      // wallId -> "Wall B"
    var removalRefs: [String: String] = [:]    // removal id -> "X1"

    /// From SecureScan.wallNames() ({ id: "Wall B" }) and removalRefs() ([{ id, tag }]).
    static func parse(wallNames: Any?, removalRefs: Any?) -> EditorNames {
        var n = EditorNames()
        if let d = wallNames as? [String: Any] {
            for (k, v) in d { if let s = v as? String, !s.isEmpty { n.wallNames[k] = s } }
        }
        for e in removalRefs as? [[String: Any]] ?? [] {
            if let id = e["id"] as? String, let tag = e["tag"] as? String, !tag.isEmpty { n.removalRefs[id] = tag }
        }
        return n
    }

    /// "wall B" (the editor's name, lower-case first letter) or "wall w3".
    static func wallLabel(_ id: String, _ names: EditorNames?) -> String {
        guard let name = names?.wallNames[id], let first = name.first else { return "wall \(id)" }
        return first.lowercased() + name.dropFirst()
    }
}
