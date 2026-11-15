//
//  Revisit.swift
//  SecureScan
//
//  Return visits in AR ("Find my points"), the document side (docs/SPEC.md
//  addendum v1.6): starting a visit, the saved points and what to show for
//  them, writing a re-measurement into a reading's `history`, marking
//  equipment removed and removals done, adding newly logged items, and
//  picking the item the crosshair is aimed at.
//
//  Foundation + simd only - unit tested. The AR screen only calls these.
//

import Foundation
import simd

enum Revisit {

    // MARK: Visits

    static func day(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The visit to record into. A new monitoring visit is started when the
    /// current visit is from an earlier day (a job without `visits` counts as
    /// visit 1 on the day it was created).
    static func startVisitIfNeeded(plan: [String: Any], now: Date, timeZone: TimeZone)
        -> (plan: [String: Any], visit: String, started: Bool) {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var visits = markup["visits"] as? [[String: Any]] ?? []
        let today = day(now, timeZone: timeZone)
        func add(_ n: Int) -> String {
            var id = "v\(n)"
            var k = n
            while visits.contains(where: { ($0["id"] as? String) == id }) { k += 1; id = "v\(k)" }
            visits.append(["id": id, "n": n, "type": "monitoring", "label": "Monitoring visit", "date": today, "by": ""])
            return id
        }
        if visits.isEmpty {
            let created = ISOTime.date(plan["createdAt"] as? String).map { day($0, timeZone: timeZone) } ?? today
            guard created < today else { return (plan, "v1", false) }
            visits = [["id": "v1", "n": 1, "type": "initial", "label": "Initial assessment", "date": created, "by": ""]]
            let id = add(2)
            markup["visits"] = visits
            markup["currentVisit"] = id
            doc["markup"] = markup
            return (doc, id, true)
        }
        let cur = PlanDocument.currentVisit(markup)
        let v = visits.first { ($0["id"] as? String) == cur } ?? visits[visits.count - 1]
        let date = (v["date"] as? String) ?? ""
        guard !date.isEmpty, date < today else { return (plan, (v["id"] as? String) ?? cur, false) }
        let n = (visits.compactMap { PlanDocument.number($0["n"]) }.max().map { Int($0) } ?? visits.count) + 1
        let id = add(n)
        markup["visits"] = visits
        markup["currentVisit"] = id
        doc["markup"] = markup
        return (doc, id, true)
    }

    // MARK: History (v1.6: `history` is authoritative; top level mirrors the latest)

    /// A reading's history, or one visit-1 entry made from the top-level value.
    static func history(_ r: [String: Any]) -> [[String: Any]] {
        if let h = r["history"] as? [[String: Any]], !h.isEmpty { return h }
        guard let v = PlanDocument.number(r["value"]) else { return [] }
        var e: [String: Any] = ["visit": (r["visit"] as? String) ?? "v1", "value": v]
        if let t = r["takenAt"] as? String { e["takenAt"] = t }
        if let p = r["photo"] as? String, !p.isEmpty { e["photo"] = p }
        if let n = r["note"] as? String, !n.isEmpty { e["note"] = n }
        return [e]
    }

    /// Writes this visit's value for a reading: one entry per visit (replaced
    /// if it exists), then the top-level value / takenAt (and photo, when a new
    /// one was taken) mirror the entry. Nil if the reading does not exist.
    static func recordMeasurement(plan: [String: Any], readingId: String, visit: String, value: Double,
                                  takenAt: String, photo: String?, note: String?) -> [String: Any]? {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var readings = markup["readings"] as? [[String: Any]] ?? []
        guard let i = readings.firstIndex(where: { ($0["id"] as? String) == readingId && (($0["kind"] as? String) ?? "reading") == "reading" })
        else { return nil }
        var r = readings[i]
        var h = history(r)
        var e: [String: Any] = ["visit": visit, "value": value, "takenAt": takenAt]
        if let photo, !photo.isEmpty { e["photo"] = photo }
        if let note, !note.isEmpty { e["note"] = note }
        if let j = h.firstIndex(where: { ($0["visit"] as? String) == visit }) { h[j] = e } else { h.append(e) }
        h = sortedByVisit(h, visits: markup["visits"] as? [[String: Any]] ?? [])
        r["history"] = h
        if let last = h.last, (last["visit"] as? String) == visit {
            r["value"] = value
            r["takenAt"] = takenAt
            if let photo, !photo.isEmpty { r["photo"] = photo }
        }
        readings[i] = r
        markup["readings"] = readings
        doc["markup"] = markup
        return doc
    }

    static func sortedByVisit(_ h: [[String: Any]], visits: [[String: Any]]) -> [[String: Any]] {
        let order = Dictionary(visits.enumerated().compactMap { i, v in (v["id"] as? String).map { ($0, i) } },
                               uniquingKeysWith: { a, _ in a })
        return h.enumerated().sorted { a, b in
            let oa = order[(a.element["visit"] as? String) ?? "v1"] ?? (a.offset - 1000)
            let ob = order[(b.element["visit"] as? String) ?? "v1"] ?? (b.offset - 1000)
            return oa == ob ? a.offset < b.offset : oa < ob
        }.map { $0.element }
    }

    static func markEquipmentRemoved(plan: [String: Any], id: String, visit: String, at: String) -> [String: Any]? {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var eq = markup["equipment"] as? [[String: Any]] ?? []
        guard let i = eq.firstIndex(where: { ($0["id"] as? String) == id }) else { return nil }
        eq[i]["removed"] = visit
        eq[i]["removedAt"] = at
        markup["equipment"] = eq
        doc["markup"] = markup
        return doc
    }

    /// "Mark done + photo": status done in this visit, and the frame as the
    /// "after" photo in the removal's `photos`.
    static func markRemovalDone(plan: [String: Any], id: String, visit: String, photo: String?,
                                takenAt: String, cam: PlanVec?) -> [String: Any]? {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var rem = markup["removals"] as? [[String: Any]] ?? []
        guard let i = rem.firstIndex(where: { ($0["id"] as? String) == id }) else { return nil }
        rem[i]["status"] = "done"
        rem[i]["doneVisit"] = visit
        if let photo, !photo.isEmpty {
            var photos = rem[i]["photos"] as? [[String: Any]] ?? []
            var p: [String: Any] = ["visit": visit, "photo": photo, "takenAt": takenAt, "stage": "after"]
            if let cam { p["cam"] = PlanDocument.pt(cam) }
            photos.append(p)
            rem[i]["photos"] = photos
        }
        markup["removals"] = rem
        doc["markup"] = markup
        return doc
    }

    // MARK: New items logged on a return visit

    /// The saved plan's walls, as PlanBuilder walls.
    static func walls(_ plan: [String: Any]) -> [PlanWall] {
        (plan["walls"] as? [[String: Any]] ?? []).compactMap { w in
            guard let id = w["id"] as? String, let a = point(w["a"]), let b = point(w["b"]) else { return nil }
            return PlanWall(id: id, a: a, b: b, height: PlanDocument.number(w["height"]) ?? 2.4, roomIndex: 0)
        }
    }

    /// The saved plan's room outlines.
    static func rooms(_ plan: [String: Any]) -> [[PlanVec]] {
        (plan["rooms"] as? [[String: Any]] ?? []).map { r in
            (r["polygon"] as? [Any] ?? []).compactMap { point($0) }
        }
    }

    static func point(_ any: Any?) -> PlanVec? {
        guard let p = any as? [Any], p.count == 2, let x = PlanDocument.number(p[0]), let y = PlanDocument.number(p[1]) else { return nil }
        return PlanVec(x, y)
    }

    /// Resolves an item logged in this session (world space of THIS session)
    /// against the saved plan through the alignment, with the same resolvers
    /// as the first scan. Returns the plan.json item, or the reason a removal
    /// could not be placed.
    static func itemJSON(for r: PBReading, plan: [String: Any], alignment: PlanTransform, floorY: Double,
                         visit: String) -> Result<[String: Any], RevisitError> {
        let ws = walls(plan)
        let floors: [Double?] = ws.map { _ in floorY }
        var d: [String: Any]
        switch r.kind {
        case "equipment":
            d = PlanDocument.equipmentJSON(PlanBuilder.resolveOnFloor(r, globalFloorY: floorY, transform: alignment), visit: visit)
        case "removal":
            switch PlanBuilder.resolveRemoval(r, walls: ws, wallFloorY: floors, globalFloorY: floorY,
                                              transform: alignment, rooms: rooms(plan)) {
            case .placed(let x): d = PlanDocument.removalJSON(x, visit: visit)
            case .rejected(let why): return .failure(RevisitError(message: why))
            }
        case "affected":
            switch PlanBuilder.affectedArea(r, globalFloorY: floorY, transform: alignment) {
            case .success(let a): d = PlanDocument.affectedJSON(a, visit: visit)
            case .failure(let e): return .failure(e)
            }
        case "floorType":
            guard let z = PlanBuilder.floorZone(r, transform: alignment, rooms: rooms(plan)) else {
                return .failure(RevisitError(message: "You aren't inside a room of the saved plan."))
            }
            d = PlanDocument.floorJSON(z, visit: visit)
        case "source":
            d = PlanDocument.sourceJSON(PlanBuilder.resolve(r, walls: ws, wallFloorY: floors, globalFloorY: floorY, transform: alignment))
        default:
            d = PlanDocument.readingJSON(PlanBuilder.resolve(r, walls: ws, wallFloorY: floors, globalFloorY: floorY, transform: alignment))
        }
        d["visit"] = visit
        return .success(d)
    }

    /// Appends an item to the right markup list, numbering readings and photo
    /// notes after the existing ones of their kind.
    static func addItem(plan: [String: Any], item: [String: Any]) -> [String: Any] {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var x = item
        let list: String
        if x["polygon"] != nil && x["type"] != nil { list = "floors" }
        else if x["polygon"] != nil { list = "affected" }
        else if x["type"] != nil && x["placed"] != nil { list = "equipment" }
        else if x["item"] != nil && x["status"] != nil { list = "removals" }
        else if x["label"] != nil && x["kind"] == nil { list = "sources" }
        else { list = "readings" }
        var arr = markup[list] as? [[String: Any]] ?? []
        if list == "readings" {
            let kind = (x["kind"] as? String) ?? "reading"
            if kind == "reading" || kind == "photo" {
                let maxN = arr.filter { (($0["kind"] as? String) ?? "reading") == kind }
                    .compactMap { PlanDocument.number($0["n"]) }.max() ?? 0
                x["n"] = Int(maxN) + 1
            }
        }
        arr.append(x)
        markup[list] = arr
        doc["markup"] = markup
        return doc
    }

    // MARK: What to show

    struct Marker: Equatable {
        var id: String
        /// reading | boundary | source | equipment | removal
        var kind: String
        var label: String
        var pos: PlanVec                 // plan position (removals: middle of the stretch)
        var height: Double               // metres above floor
        /// reading: last value; status "dry" | "elevated" | "wet" | "reference" | "none"
        var value: Double? = nil
        var status: String = "none"
        var measured = false             // re-measured in this visit
        /// removals: wall stretch and top of the cut (metres)
        var wallId: String? = nil
        var t0: Double? = nil
        var t1: Double? = nil
        var top: Double? = nil
        var done = false
        /// affected areas and flooring removals: the outline on the floor
        var polygon: [PlanVec]? = nil
        /// readings / boundary / source: along their wall (for drawing lines)
        var wallT: Double? = nil
    }

    static func status(_ v: Double?, reference: Bool, damp: Double, wet: Double) -> String {
        if reference { return "reference" }
        guard let v else { return "none" }
        return v < damp ? "dry" : (v < wet ? "elevated" : "wet")
    }

    static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }

    /// Everything to draw through the camera for `visit`.
    static func markers(plan: [String: Any], visit: String) -> [Marker] {
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let thr = markup["thresholds"] as? [String: Any] ?? [:]
        let damp = PlanDocument.number(thr["damp"]) ?? 15, wet = PlanDocument.number(thr["wet"]) ?? 20
        let visits = (markup["visits"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let curIdx = visits.firstIndex(of: visit) ?? 0
        let previous = curIdx > 0 ? visits[curIdx - 1] : nil
        var out: [Marker] = []
        for r in markup["readings"] as? [[String: Any]] ?? [] {
            guard let id = r["id"] as? String, let pos = point(r["pos"]) else { continue }
            let kind = (r["kind"] as? String) ?? "reading"
            let height = PlanDocument.number(r["height"]) ?? 0
            if kind == "reading" {
                let h = history(r)
                let mine = h.first { ($0["visit"] as? String) == visit }
                let last = mine ?? h.last
                let value = PlanDocument.number(last?["value"]) ?? PlanDocument.number(r["value"])
                let reference = (r["reference"] as? Bool) ?? false
                let n = PlanDocument.number(r["n"]).map { String(Int($0)) } ?? "?"
                var mk = Marker(id: id, kind: "reading", label: value.map { "\(n)\(reference ? "R" : "") · \(fmt($0))%" } ?? n,
                                  pos: pos, height: height, value: value,
                                  status: status(value, reference: reference, damp: damp, wet: wet),
                                  measured: mine != nil && curIdx > 0 || (mine != nil && h.count > 1))
                mk.wallId = r["wallId"] as? String
                mk.wallT = PlanDocument.number(r["wallT"])
                out.append(mk)
            } else if kind == "boundary" {
                let v = (r["visit"] as? String) ?? "v1"
                if v == previous || v == visit {
                    var mk = Marker(id: id, kind: "boundary", label: "", pos: pos, height: height,
                                    measured: v == visit, wallId: r["wallId"] as? String)
                    mk.wallT = PlanDocument.number(r["wallT"])
                    out.append(mk)
                }
            } else if kind == "photo" {
                let n = PlanDocument.number(r["n"]).map { "P\(Int($0))" } ?? "P"
                out.append(Marker(id: id, kind: "photo", label: n, pos: pos, height: height))
            }
        }
        for s in markup["sources"] as? [[String: Any]] ?? [] {
            guard let id = s["id"] as? String, let pos = point(s["pos"]) else { continue }
            let label = (s["label"] as? String) ?? ""
            out.append(Marker(id: id, kind: "source", label: label.isEmpty ? "Source" : label,
                              pos: pos, height: PlanDocument.number(s["height"]) ?? 0.3))
        }
        for e in markup["equipment"] as? [[String: Any]] ?? [] {
            guard let id = e["id"] as? String, let pos = point(e["pos"]) else { continue }
            if let removed = e["removed"], !(removed is NSNull) { continue }
            let name = PlanDocument.equipmentName((e["type"] as? String) ?? "other")
            let label = (e["label"] as? String) ?? ""
            out.append(Marker(id: id, kind: "equipment", label: label.isEmpty ? name : "\(name) · \(label)", pos: pos, height: 0.15))
        }
        for a in markup["affected"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? String else { continue }
            let poly = (a["polygon"] as? [Any] ?? []).compactMap { point($0) }
            guard poly.count >= 3 else { continue }
            let label = (a["label"] as? String) ?? ""
            out.append(Marker(id: id, kind: "affected", label: label.isEmpty ? "Wet area" : label,
                              pos: poly.reduce(PlanVec(0, 0), +) / Double(poly.count), height: 0, polygon: poly))
        }
        let ws = Dictionary(walls(plan).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            if let id = x["id"] as? String, x["wallId"] == nil || x["wallId"] is NSNull {
                let poly = (x["area"] as? [Any] ?? []).compactMap { point($0) }
                if poly.count >= 3 {
                    out.append(Marker(id: id, kind: "removal", label: "Remove flooring",
                                      pos: poly.reduce(PlanVec(0, 0), +) / Double(poly.count), height: 0,
                                      done: (x["status"] as? String) == "done", polygon: poly))
                }
                continue
            }
            guard let id = x["id"] as? String, let wid = x["wallId"] as? String, let w = ws[wid] else { continue }
            let t0 = PlanDocument.number(x["t0"]) ?? 0, t1 = PlanDocument.number(x["t1"]) ?? 1
            let item = (x["item"] as? String) ?? "other"
            let mm = PlanDocument.number(x["heightMm"]) ?? 600
            let top = item == "flooring" ? 0.05 : min(max(mm / 1000, 0.05), w.height)
            let mid = w.a + (w.b - w.a) * ((t0 + t1) / 2)
            out.append(Marker(id: id, kind: "removal", label: "Remove \(item)", pos: mid, height: top / 2,
                              wallId: wid, t0: t0, t1: t1, top: top, done: (x["status"] as? String) == "done"))
        }
        return out
    }

    /// Readings re-measured in this visit / all readings.
    static func progress(_ markers: [Marker]) -> (done: Int, total: Int) {
        let r = markers.filter { $0.kind == "reading" }
        return (r.filter(\.measured).count, r.count)
    }

    // MARK: World <-> plan

    static func world(_ p: PlanVec, height: Double, alignment: PlanTransform, floorY: Double) -> WorldVec {
        alignment.world(p, y: floorY + height)
    }

    struct Candidate {
        var id: String
        var kind: String
        var world: WorldVec
        var radius: Double
    }

    /// The candidate the camera ray points at: perpendicular distance within
    /// its radius, in front of the camera (0.2 ... maxRange m); the closest to
    /// the ray relative to its radius wins.
    static func target(_ candidates: [Candidate], origin: WorldVec, direction: WorldVec, maxRange: Double = 8) -> Candidate? {
        let len = simd_length(direction)
        guard len > 1e-9 else { return nil }
        let d = direction / len
        var best: (Candidate, Double)? = nil
        for c in candidates {
            let v = c.world - origin
            let t = simd_dot(v, d)
            guard t >= 0.2, t <= maxRange else { continue }
            let perp = simd_length(v - d * t)
            guard perp <= c.radius else { continue }
            let score = perp / c.radius
            if score < (best?.1 ?? .infinity) { best = (c, score) }
        }
        return best?.0
    }

    /// Signed horizontal angle (degrees) from where the camera looks to the
    /// target: positive = turn right, negative = turn left.
    static func turnHint(camera: WorldVec, forward: WorldVec, target: WorldVec) -> Double {
        let f = PlanVec(forward.x, forward.z), v = PlanVec(target.x - camera.x, target.z - camera.z)
        guard simd_length(f) > 1e-9, simd_length(v) > 1e-9 else { return 0 }
        let fn = simd_normalize(f)
        let right = PlanVec(-fn.y, fn.x)
        return atan2(simd_dot(v, right), simd_dot(v, fn)) * 180 / .pi
    }
}

struct RevisitError: Error, Equatable {
    var message: String
}
