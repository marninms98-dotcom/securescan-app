//
//  JobSummary.swift
//  SecureScan
//
//  What the jobs list shows about a job beyond job.json: its status
//  (Inspecting / Quoted / Drying · day N / Complete) and the last visit
//  date, both derived from plan.json (read-only).
//

import SwiftUI

enum JobStatus: Equatable {
    case notScanned
    case inspecting
    case quoted
    case drying(day: Int)
    case complete

    var title: String {
        switch self {
        case .notScanned: return "New"
        case .inspecting: return "Inspecting"
        case .quoted: return "Quoted"
        case .drying(let d): return "Drying · day \(d)"
        case .complete: return "Complete"
        }
    }

    var color: Color {
        switch self {
        case .notScanned: return DS.Color.grey(6)
        case .inspecting: return DS.Color.accent
        case .quoted: return DS.Color.grey(8)
        case .drying: return DS.Color.equip
        case .complete: return DS.Color.dry
        }
    }
}

struct JobSummary: Equatable {
    var status: JobStatus = .inspecting
    var lastVisit: Date?
    var visitCount = 1
    /// Items that need a quick fix (see ItemsModel.needsFix).
    var toFix = 0

    /// Pure: from a parsed plan.json. `now` for the drying day count.
    static func from(plan: [String: Any]?, created: Date, now: Date = Date()) -> JobSummary {
        var s = JobSummary()
        guard let plan else { s.lastVisit = created; s.status = .notScanned; return s }
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let visits = markup["visits"] as? [[String: Any]] ?? []
        s.visitCount = max(1, visits.count)
        let visitDates = visits.compactMap { v in (v["date"] as? String).flatMap { day($0) } }
        s.lastVisit = visitDates.max() ?? ISOTime.date(plan["updatedAt"] as? String) ?? created

        if (visits.last?["type"] as? String) == "final" {
            s.status = .complete
            return s
        }
        let equipment = markup["equipment"] as? [[String: Any]] ?? []
        let running = equipment.filter { e in
            let removed = e["removed"]
            return removed == nil || removed is NSNull || (removed as? String)?.isEmpty == true
        }
        if !running.isEmpty {
            let starts = running.compactMap { ISOTime.date($0["placedAt"] as? String) }
            let start = starts.min() ?? visitDates.min() ?? created
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start),
                                                       to: Calendar.current.startOfDay(for: now)).day ?? 0
            s.status = .drying(day: max(1, days + 1))
            return s
        }
        let scope = (markup["scope"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let removals = markup["removals"] as? [[String: Any]] ?? []
        s.status = (!scope.isEmpty || !removals.isEmpty) ? .quoted : .inspecting
        return s
    }

    /// "2026-11-19" (a visit date) as a local day.
    static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}

/// Loads summaries for the list off the main thread.
@MainActor
final class JobSummaries: ObservableObject {
    @Published private(set) var byID: [UUID: JobSummary] = [:]
    /// Bumped when 3D thumbnails were (re)rendered, so the cards reload them.
    @Published private(set) var thumbsVersion = 0
    private var rendering = false

    func refresh(_ jobs: [JobMeta]) {
        let list = jobs
        Task {
            let out = await Task.detached(priority: .utility) { () -> [UUID: JobSummary] in
                var d: [UUID: JobSummary] = [:]
                for m in list {
                    let f = JobFiles.folder(for: m.id)
                    let plan = (try? Data(contentsOf: f.planURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                    var s = JobSummary.from(plan: plan, created: m.createdAt)
                    s.toFix = ItemsModel.needsFixCount(folder: f, plan: plan, meta: m)
                    d[m.id] = s
                }
                return d
            }.value
            byID = out
            renderThumbs(list)
        }
    }

    /// Renders the dollhouse thumbnail of every job whose plan changed since
    /// its thumb3d.png (one at a time, in the background).
    private func renderThumbs(_ jobs: [JobMeta]) {
        guard !rendering else { return }
        let folders = jobs.map { JobFiles.folder(for: $0.id) }
        rendering = true
        Task {
            let made = await Task.detached(priority: .utility) { () -> Int in
                var n = 0
                for f in folders where Dollhouse.thumbNeedsRender(f) {
                    if Dollhouse.renderThumb(f) { n += 1 }
                }
                return n
            }.value
            rendering = false
            if made > 0 { thumbsVersion += 1 }
        }
    }
}
