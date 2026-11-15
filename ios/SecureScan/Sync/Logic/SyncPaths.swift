//
//  SyncPaths.swift
//  SecureScan
//
//  Which files of a job folder go to SecureSuite, what kind each one is, and
//  where it lives in the private `scan-files` bucket:
//      <org_id>/<scan_job_id>/<relative path in the job folder>
//  (the bucket's row-level security checks that the first folder is the
//  user's org). Pure; compiled into the unit tests.
//

import Foundation

enum SyncPaths {
    static let bucket = "scan-files"

    /// The object path for a file of a job, or nil when an id is not a UUID or
    /// the relative path is unsafe. Ids are written lower-case, the way
    /// Postgres prints a uuid (the row's `org_id` / `id`).
    static func objectPath(org: String, job: String, relative: String) -> String? {
        guard let rel = normalise(relative),
              let o = UUID(uuidString: org.trimmingCharacters(in: .whitespaces)),
              let j = UUID(uuidString: job.trimmingCharacters(in: .whitespaces)) else { return nil }
        return o.uuidString.lowercased() + "/" + j.uuidString.lowercased() + "/" + rel
    }

    /// "photos//a.jpg" -> "photos/a.jpg"; nil for "", "..", absolute escapes.
    static func normalise(_ rel: String) -> String? {
        let parts = rel.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// Percent-encodes each segment for a URL path (slashes kept).
    static func urlEncoded(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
    }

    /// RFC 3986 unreserved characters, ASCII only.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The link file: which SecureSuite job this scan belongs to.
    static let linkFile = "securesuite.json"

    /// Whether a file of the job folder is uploaded. plan.json travels in the
    /// row's `plan` column; work in progress (a recording being written, the
    /// scan-open marker, temporary files) stays on the phone.
    static func isSyncable(_ rel: String) -> Bool {
        guard let r = normalise(rel) else { return false }
        if r == "plan.json" || r == "scan-open" { return false }
        let name = (r as NSString).lastPathComponent
        if name.hasPrefix(".") || r.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        if r.hasPrefix("tmp/") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !["wav", "tmp", "part", "download", "partial"].contains(ext)
    }

    /// The `kind` recorded in the files manifest.
    static func kind(for rel: String) -> String {
        let r = normalise(rel) ?? rel
        let name = (r as NSString).lastPathComponent
        if r.hasPrefix("conflicts/") || (name.hasPrefix("plan.conflict-") && name.hasSuffix(".json")) { return "conflict" }
        if r.hasPrefix("photos/") { return name.lowercased().hasSuffix("-full.jpg") ? "photo_full" : "photo" }
        if r.hasPrefix("audio/") { return "audio" }
        if r.hasPrefix("rooms/") { return "room" }
        switch r {
        case "voice.json": return "transcript"
        case "readings-raw.json": return "readings"
        case "model.usdz": return "model"
        case "thumb.png": return "thumbnail"
        case "job.json": return "meta"
        case linkFile: return "link"
        case "worldmap.bin": return "worldmap"
        case "revisit-log.json": return "visits"
        default: return "data"
        }
    }

    static func contentType(for rel: String) -> String {
        switch (rel as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "json": return "application/json"
        case "m4a": return "audio/mp4"
        case "usdz": return "model/vnd.usdz+zip"
        case "txt", "md": return "text/plain"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    /// "plan.conflict-20261116-031505.json": the phone's own plan, kept when a merge happened.
    static func planConflictName(_ date: Date) -> String { "plan.conflict-\(stamp(date)).json" }

    /// Where the server's version of a file goes when both sides changed it and
    /// neither can be merged: conflicts/<stamp>/<path> (never inside rooms/ or
    /// photos/, so nothing reads it as a room or a photo).
    static func conflictCopyPath(_ rel: String, date: Date) -> String { "conflicts/\(stamp(date))/\(rel)" }

    /// UTC, sortable: 20261116-031505.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
