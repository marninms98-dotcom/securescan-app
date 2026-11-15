//
//  DemoSeed.swift
//  SecureScan
//
//  Debug builds only (automated screenshots): SECURESCAN_SEED=jobs fills the
//  jobs list with the demo job plus three copies in other states
//  (Inspecting with an item that needs a fix, Quoted, Complete, a two-visit
//  drying job with a long address and big numbers, a job not scanned yet).
//  SECURESCAN_OPEN_REF=<job ref> opens that job.
//

import Foundation
import UIKit

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

        let two = try variant(address: "Unit 4/118 Wanneroo Road, Madeley, WA 6065", ref: "QBE-7731902", created: now - 4 * day, thumb: .flipV) { markup in
            // Drying, second (monitoring) visit today: Monitoring report on offer.
            markup["visits"] = [
                ["id": "v1", "n": 1, "type": "initial", "label": "Initial assessment", "date": dayString(now - 4 * day), "by": ""],
                ["id": "v2", "n": 2, "type": "monitoring", "label": "Monitoring visit", "date": dayString(now), "by": ""],
            ]
            markup["currentVisit"] = "v2"
            markup["equipment"] = (markup["equipment"] as? [[String: Any]] ?? []).map { e in
                var e = e; e["placedAt"] = ISOTime.string(now - 4 * day); return e
            }
        }
        if var m = JobFiles.readMeta(two) {
            m.roomCount = 11; m.totalArea = 186.4; m.readingCount = 142
            try JobFiles.writeMeta(m, two)
        }
        // Not scanned yet: no plan at all.
        var fresh = try JobFiles.create(address: "3 Ocean Reef Rd, Ocean Reef, WA", jobRef: "AAMI-55821", demo: true)
        fresh.createdAt = now + 2
        try JobFiles.writeMeta(fresh, JobFiles.folder(for: fresh.id))

        try variant(address: "7 Marri Rd, Madeley, WA", ref: "HOL-88213", created: now - 2 * day, thumb: .flipH) { markup in
            // Quoted: scope and removals, no drying equipment.
            markup["equipment"] = []
        }
        try variant(address: "22 Hepburn Ave, Hillarys, WA", ref: "SUN-55120", created: now - 12 * day, thumb: .rotate) { markup in
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
    enum Thumb { case same, flipH, flipV, rotate }

    private static func variant(address: String, ref: String, created: Date, thumb: Thumb = .same,
                                change: (inout [String: Any]) -> Void) throws -> JobFolder {
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
        if thumb != .same, let img = UIImage(contentsOfFile: folder.thumbURL.path) {
            let size = img.size
            let out = UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                switch thumb {
                case .flipH: c.translateBy(x: size.width, y: 0); c.scaleBy(x: -1, y: 1)
                case .flipV: c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
                case .rotate: c.translateBy(x: size.width, y: size.height); c.rotate(by: .pi)
                case .same: break
                }
                img.draw(in: CGRect(origin: .zero, size: size))
            }
            try? out.pngData()?.write(to: folder.thumbURL, options: .atomic)
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
