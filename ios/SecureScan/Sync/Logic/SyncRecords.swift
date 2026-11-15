//
//  SyncRecords.swift
//  SecureScan
//
//  Rows as SecureSuite returns them (public.scan_jobs, public.jobs), the link
//  file kept in a job folder, and the job picker's search. Pure; compiled
//  into the unit tests.
//

import Foundation

/// A public.scan_jobs row (any subset of its columns).
struct ScanJobRow {
    var id: String
    var orgID: String
    var revision: Int
    var jobID: String?
    var title: String
    var siteAddress: String
    var files: [String: SyncFileEntry]
    var plan: [String: Any]?
    var createdAt: Date?
    var updatedAt: Date?
    var deleted: Bool
    /// From the embedded SecureSuite job, when the list asked for it.
    var jobNumber: String?
    var clientName: String?

    static func from(_ json: [String: Any]) -> ScanJobRow? {
        guard let id = SyncJSON.string(json["id"]), UUID(uuidString: id) != nil else { return nil }
        let job = (json["job"] as? [String: Any]) ?? (json["jobs"] as? [String: Any])
        let deletedAt = json["deleted_at"]
        return ScanJobRow(id: id.lowercased(),
                          orgID: (SyncJSON.string(json["org_id"]) ?? "").lowercased(),
                          revision: SyncJSON.int(json["revision"]) ?? 0,
                          jobID: SyncJSON.string(json["job_id"])?.lowercased(),
                          title: (json["title"] as? String) ?? "",
                          siteAddress: (json["site_address"] as? String) ?? "",
                          files: SyncFileEntry.list(json["files"]),
                          plan: json["plan"] as? [String: Any],
                          createdAt: SyncTime.parse(json["created_at"]),
                          updatedAt: SyncTime.parse(json["updated_at"]),
                          deleted: deletedAt != nil && !(deletedAt is NSNull),
                          jobNumber: job.flatMap { SyncJSON.string($0["job_number"]) },
                          clientName: job?["client_name"] as? String)
    }

    var uuid: UUID? { UUID(uuidString: id) }

    /// A plan worth writing to plan.json (not the `{}` a job without a scan sends).
    var hasPlan: Bool { ScanJobRow.isRealPlan(plan) }

    static func isRealPlan(_ plan: [String: Any]?) -> Bool {
        guard let plan, !plan.isEmpty else { return false }
        return plan["walls"] != nil || plan["rooms"] != nil || plan["markup"] != nil || plan["version"] != nil
    }
}

/// A job on SecureSuite that is not on this phone ("On SecureSuite" in the jobs list).
struct CloudScanJob: Identifiable, Equatable {
    var id: UUID
    var title: String
    var siteAddress: String
    var revision: Int
    var updatedAt: Date?
    var jobNumber: String?
    var clientName: String?

    init?(row: ScanJobRow) {
        guard let id = row.uuid, !row.deleted else { return nil }
        self.id = id
        self.title = row.title
        self.siteAddress = row.siteAddress
        self.revision = row.revision
        self.updatedAt = row.updatedAt
        self.jobNumber = row.jobNumber
        self.clientName = row.clientName
    }

    init(id: UUID, title: String, siteAddress: String, revision: Int, updatedAt: Date?, jobNumber: String?, clientName: String?) {
        self.id = id
        self.title = title
        self.siteAddress = siteAddress
        self.revision = revision
        self.updatedAt = updatedAt
        self.jobNumber = jobNumber
        self.clientName = clientName
    }

    var displayAddress: String {
        let a = siteAddress.isEmpty ? title : siteAddress
        return a.isEmpty ? "Untitled job" : a
    }

    /// "SW-2418 · Dana Whitfield", or nil when the scan is not linked.
    var linkLine: String? {
        let parts = [jobNumber, clientName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func matches(_ query: String) -> Bool {
        JobPickerFilter.matches(query, fields: [title, siteAddress, jobNumber ?? "", clientName ?? ""])
    }
}

/// A SecureSuite job (public.jobs).
struct SecureSuiteJob: Identifiable, Equatable {
    var id: String
    var jobNumber: String
    var status: String
    var type: String
    var clientName: String
    var siteAddress: String
    var siteSuburb: String
    var createdAt: Date?

    static func from(_ json: [String: Any]) -> SecureSuiteJob? {
        guard let id = SyncJSON.string(json["id"]) else { return nil }
        return SecureSuiteJob(id: id.lowercased(),
                              jobNumber: SyncJSON.string(json["job_number"]) ?? "",
                              status: (json["status"] as? String) ?? "",
                              type: (json["type"] as? String) ?? "",
                              clientName: (json["client_name"] as? String) ?? "",
                              siteAddress: (json["site_address"] as? String) ?? "",
                              siteSuburb: (json["site_suburb"] as? String) ?? "",
                              createdAt: SyncTime.parse(json["created_at"]))
    }

    /// "12 Smith St, Wangara" (the suburb only when the address doesn't already say it).
    var addressLine: String {
        let a = siteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = siteSuburb.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return a }
        if a.isEmpty { return s }
        if a.localizedCaseInsensitiveContains(s) { return a }
        return a + ", " + s
    }

    var displayNumber: String { jobNumber.isEmpty ? "No job number" : jobNumber }
    var statusTitle: String { SyncText.title(status) }
    var tone: JobStatusTone { JobStatusTone.of(status) }
}

/// How a SecureSuite job status is coloured (the view maps it to DS colours).
enum JobStatusTone: Equatable {
    case active, quoted, done, waiting, closed, neutral

    static func of(_ status: String) -> JobStatusTone {
        let s = status.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        switch s {
        case "active", "in_progress", "scheduled", "booked", "drying", "monitoring", "makesafe", "make_safe", "accepted", "approved":
            return .active
        case "quote", "quoted", "quote_sent", "estimate", "scoping":
            return .quoted
        case "complete", "completed", "done", "invoiced", "paid", "closed_won":
            return .done
        case "on_hold", "hold", "waiting", "pending", "awaiting_approval":
            return .waiting
        case "cancelled", "canceled", "lost", "archived", "closed", "closed_lost":
            return .closed
        default:
            return .neutral
        }
    }
}

/// securesuite.json in the job folder: the SecureSuite job this scan belongs to.
struct SecureSuiteLink: Codable, Equatable {
    var jobID: String
    var jobNumber: String
    var clientName: String
    var siteAddress: String

    init(jobID: String, jobNumber: String, clientName: String, siteAddress: String) {
        self.jobID = jobID.lowercased()
        self.jobNumber = jobNumber
        self.clientName = clientName
        self.siteAddress = siteAddress
    }

    init(job: SecureSuiteJob) {
        self.init(jobID: job.id, jobNumber: job.jobNumber, clientName: job.clientName, siteAddress: job.addressLine)
    }

    /// "SW-2418 · Dana Whitfield".
    var title: String {
        [jobNumber, clientName].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("Linked job")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

enum JobPickerFilter {
    /// Every word of the query appears in one of the fields (case and accents ignored).
    static func matches(_ query: String, fields: [String]) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
        guard !words.isEmpty else { return true }
        let hay = fields.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy { hay.contains(String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }

    static func matches(_ query: String, job: SecureSuiteJob) -> Bool {
        matches(query, fields: [job.jobNumber, job.clientName, job.siteAddress, job.siteSuburb])
    }

    /// The recent jobs that match, plus the server's search results, once each, most recent first.
    static func combine(recent: [SecureSuiteJob], found: [SecureSuiteJob], query: String) -> [SecureSuiteJob] {
        var seen = Set<String>()
        var out: [SecureSuiteJob] = []
        for j in recent where matches(query, job: j) && seen.insert(j.id).inserted { out.append(j) }
        for j in found where seen.insert(j.id).inserted { out.append(j) }
        return sortRecentFirst(out)
    }

    static func sortRecentFirst(_ jobs: [SecureSuiteJob]) -> [SecureSuiteJob] {
        jobs.enumerated().sorted { a, b in
            switch (a.element.createdAt, b.element.createdAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The query for a PostgREST `ilike` filter: the characters that are
    /// filter syntax (, ( ) * " \ % :) become spaces; words joined by one space.
    static func serverTerm(_ query: String) -> String {
        let syntax = CharacterSet(charactersIn: ",()*\"\\%:+")
        let cleaned = query.unicodeScalars.map { syntax.contains($0) ? " " : String($0) }.joined()
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// `or=(client_name.ilike.*term*,…)` with the term percent-encoded.
    static func orFilter(term: String, columns: [String]) -> String {
        let enc = term.addingPercentEncoding(withAllowedCharacters: SyncPaths.unreserved) ?? term
        return "or=(" + columns.map { "\($0).ilike.*\(enc)*" }.joined(separator: ",") + ")"
    }
}
