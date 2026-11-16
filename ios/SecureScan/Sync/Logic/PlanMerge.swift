//
//  PlanMerge.swift
//  SecureScan
//
//  When two phones changed the same job since they last synced. The plan is
//  last-writer-wins (this phone is writing) with every markup item kept:
//
//  * `markup` lists of objects with an "id" (readings, sources, affected,
//    removals, notes, equipment, visits, floors, scope.items, …) are unioned
//    by id. For the same id the newer `updated` / `takenAt` wins when both
//    have one; otherwise the server's copy wins (it was saved first, by a
//    phone that has already synced).
//  * A reading's re-measurements (`history`, one entry per visit) are unioned
//    by visit, so a visit measured on the other phone is never lost; the
//    reading's top-level value mirrors the latest entry again.
//  * Everything else (geometry, address, thresholds, other settings) is this
//    phone's.
//
//  The caller keeps this phone's plan as plan.conflict-<stamp>.json.
//  FileMerge does the same for the JSON logs in the job folder. Pure;
//  compiled into the unit tests.
//

import Foundation

enum PlanMerge {
    struct Stats: Equatable {
        /// Items only the server had, now added here.
        var fromServer = 0
        /// Same id on both sides, the server's copy kept.
        var serverKept = 0
        /// Same id on both sides, this phone's (newer) copy kept.
        var localKept = 0
        /// Re-measurements (history entries) only the server had, added.
        var historyFromServer = 0
    }

    struct Result {
        var plan: [String: Any]
        var stats: Stats
    }

    static func merge(local: [String: Any], server: [String: Any]) -> Result {
        var stats = Stats()
        var out = local
        if let sm = server["markup"] as? [String: Any] {
            let lm = local["markup"] as? [String: Any] ?? [:]
            out["markup"] = mergeObject(lm, sm, &stats)
        }
        if let lu = SyncTime.parse(local["updatedAt"]), let su = SyncTime.parse(server["updatedAt"]), su > lu {
            out["updatedAt"] = server["updatedAt"]
        }
        return Result(plan: out, stats: stats)
    }

    /// Keys only the server has are added; lists of id'd objects are unioned;
    /// nested objects merged the same way; any other value stays this phone's.
    static func mergeObject(_ l: [String: Any], _ s: [String: Any], _ stats: inout Stats) -> [String: Any] {
        var out = l
        for (key, sv) in s {
            guard let lv = l[key], !(lv is NSNull) else {
                out[key] = sv
                if let list = idList(sv) { stats.fromServer += list.count }
                continue
            }
            if let la = idList(lv), let sa = idList(sv) {
                out[key] = mergeList(la, sa, &stats)
            } else if let ld = lv as? [String: Any], let sd = sv as? [String: Any] {
                out[key] = mergeObject(ld, sd, &stats)
            }
        }
        return out
    }

    /// The list when every element is an object with a non-empty string "id" (an empty list counts).
    static func idList(_ value: Any) -> [[String: Any]]? {
        guard let array = value as? [Any] else { return nil }
        var out: [[String: Any]] = []
        for e in array {
            guard let d = e as? [String: Any], let id = d["id"] as? String, !id.isEmpty else { return nil }
            out.append(d)
        }
        return out
    }

    /// This phone's order first, then the server's new items in the server's order.
    static func mergeList(_ l: [[String: Any]], _ s: [[String: Any]], _ stats: inout Stats) -> [[String: Any]] {
        var serverByID: [String: [String: Any]] = [:]
        for d in s { if let id = d["id"] as? String, serverByID[id] == nil { serverByID[id] = d } }
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for d in l {
            guard let id = d["id"] as? String, seen.insert(id).inserted else { continue }
            if let sd = serverByID[id] { out.append(pick(local: d, server: sd, &stats)) } else { out.append(d) }
        }
        for d in s {
            guard let id = d["id"] as? String, seen.insert(id).inserted else { continue }
            out.append(d)
            stats.fromServer += 1
        }
        return out
    }

    /// `updated`, else `takenAt`.
    static func stamp(_ d: [String: Any]) -> Date? {
        SyncTime.parse(d["updated"]) ?? SyncTime.parse(d["takenAt"])
    }

    /// The same item on both sides.
    static func pick(local l: [String: Any], server s: [String: Any], _ stats: inout Stats) -> [String: Any] {
        if NSDictionary(dictionary: l).isEqual(to: s) { return l }
        var localNewer = false
        if let lt = stamp(l), let st = stamp(s) { localNewer = lt > st }
        var chosen = localNewer ? l : s
        if localNewer { stats.localKept += 1 } else { stats.serverKept += 1 }
        if let lh = l["history"] as? [[String: Any]], let sh = s["history"] as? [[String: Any]] {
            let primary = localNewer ? lh : sh
            let other = localNewer ? sh : lh
            let merged = mergeHistory(primary: primary, other: other)
            if !SyncJSON.same(merged, primary) {
                stats.historyFromServer += max(0, merged.count - primary.count)
                chosen["history"] = merged
                mirrorLatest(&chosen, history: merged)
            }
        }
        return chosen
    }

    /// One entry per visit: the chosen side's entries, the other side's
    /// visits added, the newer `takenAt` winning for a visit on both.
    static func mergeHistory(primary: [[String: Any]], other: [[String: Any]]) -> [[String: Any]] {
        func key(_ e: [String: Any]) -> String {
            if let v = e["visit"] as? String, !v.isEmpty { return "v:" + v }
            return "t:" + ((e["takenAt"] as? String) ?? SyncJSON.canonical(e))
        }
        var out = primary
        var index: [String: Int] = [:]
        for (i, e) in out.enumerated() { index[key(e)] = i }
        for e in other {
            let k = key(e)
            if let i = index[k] {
                if let ot = SyncTime.parse(e["takenAt"]), let pt = SyncTime.parse(out[i]["takenAt"]), ot > pt { out[i] = e }
            } else {
                index[k] = out.count
                out.append(e)
            }
        }
        return out
    }

    /// value / takenAt / photo / note mirror the latest history entry (SPEC v1.6).
    static func mirrorLatest(_ item: inout [String: Any], history: [[String: Any]]) {
        var latest: [String: Any]?
        var latestDate: Date?
        for e in history {
            let d = SyncTime.parse(e["takenAt"])
            if latest == nil || (d != nil && (latestDate == nil || d! >= latestDate!)) { latest = e; latestDate = d }
        }
        guard let latest else { return }
        for k in ["value", "takenAt", "photo", "note"] where latest[k] != nil { item[k] = latest[k] }
    }

    /// Every markup item id per list key, for "nothing was dropped" checks.
    static func itemIDs(_ plan: [String: Any]) -> Set<String> {
        var out = Set<String>()
        func walk(_ obj: [String: Any], _ prefix: String) {
            for (k, v) in obj {
                if let list = idList(v) { for d in list { if let id = d["id"] as? String { out.insert(prefix + k + ":" + id) } } }
                else if let o = v as? [String: Any] { walk(o, prefix + k + ".") }
            }
        }
        walk(plan["markup"] as? [String: Any] ?? [:], "")
        return out
    }
}

/// The JSON logs kept beside the plan, merged without dropping anything.
enum FileMerge {
    /// nil when either side is not JSON (the caller then keeps both files).
    static func merge(path: String, local: Data, server: Data) -> Data? {
        guard let l = try? JSONSerialization.jsonObject(with: local),
              let s = try? JSONSerialization.jsonObject(with: server) else { return nil }
        let merged: Any
        switch path {
        case "readings-raw.json": merged = mergeWrapped(l, s, listKey: "readings", idKey: "id")
        case "voice.json": merged = mergeWrapped(l, s, listKey: "recordings", idKey: "file")
        default:
            if let la = l as? [Any], let sa = s as? [Any] { merged = union(la, sa, idKey: "id") }
            else if l is [String: Any], s is [String: Any] { merged = mergeWrapped(l, s, listKey: "items", idKey: "id") }
            else { return nil }
        }
        guard JSONSerialization.isValidJSONObject(merged) else { return nil }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    }

    /// {version, <listKey>: [...]}: the list unioned, the rest this phone's.
    static func mergeWrapped(_ l: Any, _ s: Any, listKey: String, idKey: String) -> Any {
        guard var ld = l as? [String: Any], let sd = s as? [String: Any] else { return l }
        let la = ld[listKey] as? [Any] ?? []
        let sa = sd[listKey] as? [Any] ?? []
        ld[listKey] = union(la, sa, idKey: idKey)
        return ld
    }

    /// This phone's entries first (they win for the same key), then the
    /// server's others. Entries without the key are compared whole.
    static func union(_ l: [Any], _ s: [Any], idKey: String) -> [Any] {
        func key(_ e: Any) -> String {
            if let d = e as? [String: Any], let k = SyncJSON.string(d[idKey]) { return "k:" + k }
            return "j:" + SyncJSON.canonical(e)
        }
        var seen = Set<String>()
        var out: [Any] = []
        for e in l + s where seen.insert(key(e)).inserted { out.append(e) }
        return out
    }
}
