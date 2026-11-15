//
//  DemoSeed.swift
//  SecureScan
//
//  Debug builds only (automated screenshots): SECURESCAN_SEED=jobs fills the
//  jobs list with the demo job plus three copies in other states
//  (Inspecting with an item that needs a fix, Quoted, Complete).
//  SECURESCAN_OPEN_REF=<job ref> opens that job.
//

import Foundation

#if DEBUG
enum DemoSeed {
    static var requested: Bool { ProcessInfo.processInfo.environment["SECURESCAN_SEED"] == "jobs" }
    static var openRef: String? { ProcessInfo.processInfo.environment["SECURESCAN_OPEN_REF"] }

    /// Creates the seed jobs unless they are already there.
    static func seedIfNeeded() throws {
        let existing = JobFiles.listMetas()
        if existing.contains(where: { $0.jobRef == "CLM-20417" }) { return }
        if !existing.contains(where: { $0.jobRef == "DEMO" }) { _ = try JobProcessor.createDemoJob() }
        let day: TimeInterval = 86_400
        let now = Date()

        try variant(address: "7 Marri Rd, Madeley, WA", ref: "HOL-88213", created: now - 2 * day) { markup in
            // Quoted: scope and removals, no drying equipment.
            markup["equipment"] = []
        }
        try variant(address: "22 Hepburn Ave, Hillarys, WA", ref: "SUN-55120", created: now - 12 * day) { markup in
            markup["visits"] = [
                ["id": "v1", "n": 1, "type": "initial", "label": "Initial assessment", "date": dayString(now - 12 * day), "by": ""],
                ["id": "v2", "n": 2, "type": "monitoring", "label": "Monitoring visit", "date": dayString(now - 9 * day), "by": ""],
                ["id": "v3", "n": 3, "type": "final", "label": "Final visit", "date": dayString(now - 5 * day), "by": ""],
            ]
            markup["currentVisit"] = "v3"
            markup["equipment"] = (markup["equipment"] as? [[String: Any]] ?? []).map { e in
                var e = e; e["removed"] = "v3"; e["removedAt"] = ISOTime.string(now - 5 * day); return e
            }
        }
        let fix = try variant(address: "14 Kingsway, Wangara, WA", ref: "CLM-20417", created: now + 1) { markup in
            // Inspecting: readings only so far.
            markup["equipment"] = []
            markup["removals"] = []
            markup["scope"] = nil
        }
        // One skirting removal the plan could not place: shown under "Needs a quick fix".
        let all = JobFiles.loadRawReadings(fix)
        var raw = all.filter { $0.kind != "removal" }
        if var r = all.first(where: { $0.kind == "removal" }) ?? all.first {
            r.id = "fix-skirting-1"
            r.kind = "removal"
            r.material = "skirting"
            r.seq = (raw.map(\.seq).max() ?? 0) + 1
            raw.append(r)
            try JobFiles.saveRawReadings(raw, fix)
            if var m = JobFiles.readMeta(fix) {
                m.note = "1 removal could not be placed and is not on the plan."
                try JobFiles.writeMeta(m, fix)
            }
        }
    }

    @discardableResult
    private static func variant(address: String, ref: String, created: Date, change: (inout [String: Any]) -> Void) throws -> JobFolder {
        var meta = try JobProcessor.createDemoJob()
        let folder = JobFiles.folder(for: meta.id)
        meta.address = address
        meta.jobRef = ref
        meta.createdAt = created
        meta.demo = true
        meta.note = nil
        try JobFiles.writeMeta(meta, folder)
        if let data = try? Data(contentsOf: folder.planURL),
           var doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            doc["address"] = address
            doc["jobRef"] = ref
            doc["createdAt"] = ISOTime.string(created)
            doc["updatedAt"] = ISOTime.string(created)
            var markup = doc["markup"] as? [String: Any] ?? [:]
            change(&markup)
            doc["markup"] = markup
            try PlanDocument.data(doc).write(to: folder.planURL, options: .atomic)
        }
        return folder
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
#endif
