//
//  PlanDocument.swift
//  SecureScan
//
//  Builds / merges the plan.json document (docs/SPEC.md, Contract 1) as plain
//  JSON objects ([String: Any]) rather than Codable structs, so that keys the
//  editor adds (markup, meter, future fields) are never dropped when the app
//  regenerates geometry. Foundation only - unit tested.
//
//  Ownership (SPEC): the app owns walls / openings / rooms' geometry / objects.
//  The editor owns markup, room names, address, jobRef and updatedAt.
//

import Foundation

enum PlanDocument {

    static var defaultThresholds: [String: Any] { ["damp": 15, "wet": 20] }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: Number formatting

    /// Rounds to millimetres and guarantees a finite number (JSON has no NaN).
    static func r3(_ x: Double) -> Double { x.isFinite ? (x * 1000).rounded() / 1000 : 0 }
    static func r4(_ x: Double) -> Double { x.isFinite ? (x * 10000).rounded() / 10000 : 0 }
    static func pt(_ v: PlanVec) -> [Double] { [r3(v.x), r3(v.y)] }

    /// Reads a JSON number whether it arrived as Int, Double or NSNumber.
    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Item JSON

    static func wallJSON(_ w: PlanWall) -> [String: Any] {
        ["id": w.id, "a": pt(w.a), "b": pt(w.b), "height": r3(w.height)]
    }

    static func openingJSON(_ o: PlanOpening) -> [String: Any] {
        ["id": o.id, "type": o.type, "wallId": o.wallId ?? NSNull(),
         "a": pt(o.a), "b": pt(o.b), "height": r3(o.height), "sill": r3(o.sill)]
    }

    static func roomJSON(_ r: PlanRoom, name: String) -> [String: Any] {
        ["id": r.id, "name": name, "polygon": r.polygon.map(pt), "area": (r.area * 100).rounded() / 100]
    }

    static func objectJSON(_ o: PlanObject) -> [String: Any] {
        ["id": o.id, "category": o.category, "center": pt(o.center),
         "size": pt(o.size), "rotation": r4(o.rotation)]
    }

    static func readingJSON(_ r: PlanReading) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.id,
            "kind": r.kind,
            "n": r.n.map { $0 as Any } ?? NSNull(),
            "value": r.value.map { $0 as Any } ?? NSNull(),
            "material": r.material,
            "note": r.note,
            "photo": r.photo.map { $0 as Any } ?? NSNull(),
            "takenAt": r.takenAt,
            "reference": r.reference,
            "source": "ar",
        ]
        if let s = r.status { d["status"] = s }
        applyGeometry(to: &d, from: r)
        return d
    }

    /// An AR-logged water source (markup.sources, addendum v1.4).
    static func sourceJSON(_ r: PlanReading) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.id,
            "label": r.note,
            "photo": r.photo.map { $0 as Any } ?? NSNull(),
            "takenAt": r.takenAt,
            "source": "ar",
        ]
        applyGeometry(to: &d, from: r)
        return d
    }

    /// Equipment types (markup.equipment[].type) and their names.
    static let equipmentTypes: [(key: String, name: String)] = [
        ("airMover", "Air mover"), ("dehumidifier", "Dehumidifier"), ("airScrubber", "Air scrubber"),
        ("heater", "Heater"), ("other", "Other"),
    ]

    static func equipmentName(_ key: String) -> String {
        equipmentTypes.first { $0.key == key }?.name ?? "Equipment"
    }

    /// The visit new items belong to: markup.currentVisit, else the last
    /// visit, else "v1" (addendum v1.6).
    static func currentVisit(_ markup: [String: Any]) -> String {
        if let v = markup["currentVisit"] as? String, !v.isEmpty { return v }
        if let last = (markup["visits"] as? [[String: Any]])?.last?["id"] as? String, !last.isEmpty { return last }
        return "v1"
    }

    /// Drying equipment placed in AR (markup.equipment, addendum v1.6).
    static func equipmentJSON(_ r: PlanReading, visit: String) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.id,
            "type": equipmentTypes.contains { $0.key == r.material } ? r.material : "other",
            "label": r.note,
            "placed": visit,
            "removed": NSNull(),
            "placedAt": r.takenAt,
            "removedAt": NSNull(),
            "note": "",
            "source": "ar",
        ]
        applyFloorGeometry(to: &d, from: r)
        return d
    }

    /// A removal logged in AR (markup.removals): a wall stretch (two taps),
    /// or for flooring a floor section `area` with floorType / underlay (no
    /// wall). The start-tap frame is kept as its "before" photo.
    static func removalJSON(_ x: PlanRemoval, visit: String) -> [String: Any] {
        var d: [String: Any] = [
            "id": x.id,
            "item": x.item,
            "note": x.note,
            "status": "proposed",
            "visit": visit,
            "takenAt": x.takenAt,
            "source": "ar",
        ]
        if x.area == nil { d["heightMm"] = Int(x.heightMm.isFinite ? x.heightMm.rounded() : 0) }
        if let s = x.side { d["side"] = s }
        if let p = x.photo, !p.isEmpty {
            var e: [String: Any] = ["visit": visit, "photo": p, "takenAt": x.takenAt, "stage": "before"]
            if let c = x.cam { e["cam"] = pt(c) }
            d["photos"] = [e]
        }
        applyRemovalGeometry(to: &d, from: x)
        return d
    }

    /// The fields the app owns on an AR removal: where it is.
    static func applyRemovalGeometry(to d: inout [String: Any], from x: PlanRemoval) {
        if let area = x.area {
            d["area"] = area.map(pt)
            d["floorType"] = x.floorType.map { $0 as Any } ?? NSNull()
            d["underlay"] = x.underlay
            for k in ["wallId", "t0", "t1"] { d.removeValue(forKey: k) }
        } else {
            d["wallId"] = x.wallId.map { $0 as Any } ?? NSNull()
            d["t0"] = x.t0.map { r4($0) as Any } ?? NSNull()
            d["t1"] = x.t1.map { r4($0) as Any } ?? NSNull()
        }
        if let c = x.cam { d["cam"] = pt(c) } else { d.removeValue(forKey: "cam") }
    }

    /// A floor-type zone (markup.floors).
    static func floorJSON(_ z: PlanFloorZone, visit: String) -> [String: Any] {
        ["id": z.id, "polygon": z.polygon.map(pt), "type": FloorArea.types.contains(z.type) ? z.type : "other",
         "visit": visit, "source": "ar"]
    }

    /// A wet floor area traced in AR (markup.affected).
    static func affectedJSON(_ a: PlanAffected, visit: String) -> [String: Any] {
        ["id": a.id, "polygon": a.polygon.map(pt), "label": a.label, "visit": visit, "takenAt": a.takenAt, "source": "ar"]
    }

    /// Keeps every area; AR areas matched by id get their outline rewritten;
    /// AR areas missing from the document are added.
    static func mergeAffected(old: [[String: Any]], fresh: [PlanAffected], visit: String) -> [[String: Any]] {
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for var d in old {
            if let id = d["id"] as? String {
                seen.insert(id)
                if (d["source"] as? String) == "ar", let a = byId[id] { d["polygon"] = a.polygon.map(pt) }
            }
            out.append(d)
        }
        for a in fresh where !seen.contains(a.id) { out.append(affectedJSON(a, visit: visit)) }
        return out
    }

    /// Keeps every removal; AR removals matched by id get their geometry
    /// rewritten; AR removals missing from the document are added in `visit`.
    static func mergeRemovals(old: [[String: Any]], fresh: [PlanRemoval], visit: String) -> [[String: Any]] {
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for var d in old {
            if let id = d["id"] as? String {
                seen.insert(id)
                if (d["source"] as? String) == "ar", let x = byId[id] { applyRemovalGeometry(to: &d, from: x) }
            }
            out.append(d)
        }
        for x in fresh where !seen.contains(x.id) { out.append(removalJSON(x, visit: visit)) }
        return out
    }

    struct VisitInfo: Equatable {
        var id: String
        var n: Int
        var type: String           // initial | monitoring | final
        var label: String
        /// Not the first visit: the plan exists, points are re-measured in the editor.
        var isReturn: Bool
    }

    /// The visit being recorded (addendum v1.6), nil for single-visit jobs.
    static func visitInfo(_ plan: [String: Any]) -> VisitInfo? {
        guard let markup = plan["markup"] as? [String: Any],
              let visits = markup["visits"] as? [[String: Any]], !visits.isEmpty else { return nil }
        let cur = currentVisit(markup)
        guard let idx = visits.firstIndex(where: { ($0["id"] as? String) == cur }) else { return nil }
        let v = visits[idx]
        return VisitInfo(id: cur, n: number(v["n"]).map { Int($0) } ?? idx + 1,
                         type: (v["type"] as? String) ?? "", label: (v["label"] as? String) ?? "", isReturn: idx > 0)
    }

    /// Equipment owns only its floor position (and the camera position).
    static func applyFloorGeometry(to d: inout [String: Any], from r: PlanReading) {
        d["pos"] = pt(r.pos)
        if let c = r.cam { d["cam"] = pt(c) } else { d.removeValue(forKey: "cam") }
        if let s = r.side { d["side"] = s }
    }

    /// The fields the app owns on an AR item: where it is (and where the
    /// camera was: "cam", omitted when unknown).
    static func applyGeometry(to d: inout [String: Any], from r: PlanReading) {
        d["pos"] = pt(r.pos)
        d["wallId"] = r.wallId.map { $0 as Any } ?? NSNull()
        d["wallT"] = r.wallT.map { r4($0) as Any } ?? NSNull()
        d["height"] = r.height.map { r3($0) as Any } ?? NSNull()
        if let c = r.cam { d["cam"] = pt(c) } else { d.removeValue(forKey: "cam") }
    }

    // MARK: Documents

    static func newDocument(id: String, address: String, jobRef: String,
                            createdAt: Date, now: Date, geometry g: PlanGeometry) -> [String: Any] {
        let markup: [String: Any] = [
            "sources": g.sources.map(sourceJSON),
            "notes": [[String: Any]](),
            "equipment": g.equipment.map { equipmentJSON($0, visit: "v1") },
            "affected": g.affected.map { affectedJSON($0, visit: "v1") },
            "removals": g.removals.map { removalJSON($0, visit: "v1") },
            "floors": g.floors.map { floorJSON($0, visit: "v1") },
            "readings": g.readings.map(readingJSON),
            "thresholds": defaultThresholds,
        ]
        return [
            "version": 1,
            "id": id,
            "address": address,
            "jobRef": jobRef,
            "createdAt": iso(createdAt),
            "updatedAt": iso(now),
            "walls": g.walls.map(wallJSON),
            "openings": g.openings.map(openingJSON),
            "rooms": g.rooms.map { roomJSON($0, name: $0.name) },
            "objects": g.objects.map(objectJSON),
            "markup": markup,
        ]
    }

    /// "Regenerate plan from scan": replace geometry, keep everything the
    /// editor owns.
    ///  * Room names are kept by room id (r1, r2... are stable: one per saved room).
    ///  * Manual readings (source != "ar") are kept untouched.
    ///  * AR readings are matched by id: only pos / wallId / wallT / height are
    ///    rewritten, so edits to value / note / material / photo / n survive.
    ///  * AR items present in readings-raw.json but missing from the document
    ///    are added back with the next free number of their kind (we cannot
    ///    tell "deleted in the editor" from "never added", and losing a reading
    ///    is worse than re-showing one).
    static func merged(existing: [String: Any], geometry g: PlanGeometry) -> [String: Any] {
        var doc = existing
        doc["walls"] = g.walls.map(wallJSON)
        doc["openings"] = g.openings.map(openingJSON)
        doc["objects"] = g.objects.map(objectJSON)

        var oldNames: [String: String] = [:]
        for room in (existing["rooms"] as? [[String: Any]]) ?? [] {
            if let id = room["id"] as? String, let name = room["name"] as? String, !name.isEmpty {
                oldNames[id] = name
            }
        }
        doc["rooms"] = g.rooms.map { roomJSON($0, name: oldNames[$0.id] ?? $0.name) }

        var markup = (existing["markup"] as? [String: Any]) ?? [:]
        for key in ["sources", "affected", "removals"] where !(markup[key] is [Any]) {
            markup[key] = [[String: Any]]()
        }
        if !(markup["thresholds"] is [String: Any]) { markup["thresholds"] = defaultThresholds }

        markup["readings"] = mergeItems(old: (markup["readings"] as? [[String: Any]]) ?? [],
                                        fresh: g.readings, numbered: true, json: readingJSON)
        markup["sources"] = mergeItems(old: (markup["sources"] as? [[String: Any]]) ?? [],
                                       fresh: g.sources, numbered: false, json: sourceJSON)
        markup["affected"] = mergeAffected(old: (markup["affected"] as? [[String: Any]]) ?? [],
                                           fresh: g.affected, visit: currentVisit(markup))
        markup["removals"] = mergeRemovals(old: (markup["removals"] as? [[String: Any]]) ?? [],
                                           fresh: g.removals, visit: currentVisit(markup))
        if !g.floors.isEmpty || markup["floors"] != nil {
            var floors = (markup["floors"] as? [[String: Any]]) ?? []
            let have = Set(floors.compactMap { $0["id"] as? String })
            let visit = currentVisit(markup)
            for z in g.floors where !have.contains(z.id) { floors.append(floorJSON(z, visit: visit)) }
            markup["floors"] = floors
        }
        if !g.equipment.isEmpty || markup["equipment"] != nil {
            let visit = currentVisit(markup)
            markup["equipment"] = mergeItems(old: (markup["equipment"] as? [[String: Any]]) ?? [],
                                             fresh: g.equipment, numbered: false,
                                             json: { equipmentJSON($0, visit: visit) },
                                             apply: applyFloorGeometry)
        }
        doc["markup"] = markup
        return doc
    }

    /// Keeps every existing item; AR items (source "ar") matched by id get
    /// their geometry rewritten; AR items missing from the document are added
    /// (with the next free number of their kind when `numbered`).
    static func mergeItems(old: [[String: Any]], fresh items: [PlanReading], numbered: Bool,
                           json: (PlanReading) -> [String: Any],
                           apply: (inout [String: Any], PlanReading) -> Void = applyGeometry) -> [[String: Any]] {
        let fresh = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var oldIds = Set<String>()
        var maxN: [String: Int] = [:]                     // per kind
        var out: [[String: Any]] = []
        for var r in old {
            let kind = (r["kind"] as? String) ?? "reading"
            if let n = number(r["n"]) { maxN[kind] = max(maxN[kind] ?? 0, Int(n)) }
            if let id = r["id"] as? String {
                oldIds.insert(id)
                if (r["source"] as? String) == "ar", let pr = fresh[id] {
                    apply(&r, pr)
                }
            }
            out.append(r)
        }
        for pr in items where !oldIds.contains(pr.id) {
            var r = json(pr)
            if numbered && pr.kind != "boundary" {
                let next = (maxN[pr.kind] ?? 0) + 1
                maxN[pr.kind] = next
                r["n"] = next
            }
            out.append(r)
        }
        return out
    }

    /// Replaces NaN / Infinity (which JSON cannot hold, and which a JS document
    /// can contain) with null, recursively, so one bad number never makes every
    /// later save fail.
    static func sanitised(_ value: Any) -> Any {
        if let d = value as? [String: Any] { return d.mapValues { sanitised($0) } }
        if let a = value as? [Any] { return a.map { sanitised($0) } }
        if let n = value as? NSNumber, !n.doubleValue.isFinite { return NSNull() }
        return value
    }

    /// Serialises a document. Slashes are not escaped (keeps data URLs smaller).
    static func data(_ doc: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: doc, options: [.withoutEscapingSlashes])
    }
}
