//
//  SyncManifest.swift
//  SecureScan
//
//  The files manifest of a scan job (`scan_jobs.files`: [{path, kind, bytes,
//  sha256, updated_at}]) and the three-way diff that decides, per file, what
//  to upload, what to download, and what changed on both sides. Pure;
//  compiled into the unit tests.
//

import Foundation
import CryptoKit

struct SyncFileEntry: Equatable {
    var path: String
    var kind: String
    var bytes: Int
    var sha256: String
    var updatedAt: String

    var json: [String: Any] {
        ["path": path, "kind": kind, "bytes": bytes, "sha256": sha256, "updated_at": updatedAt]
    }

    init(path: String, kind: String, bytes: Int, sha256: String, updatedAt: String) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.sha256 = sha256
        self.updatedAt = updatedAt
    }

    /// From one element of the row's `files`; nil when path or sha256 is missing or the path is unsafe.
    init?(json: [String: Any]) {
        guard let raw = json["path"] as? String, let path = SyncPaths.normalise(raw),
              let sha = json["sha256"] as? String, !sha.isEmpty else { return nil }
        self.path = path
        self.kind = (json["kind"] as? String) ?? SyncPaths.kind(for: path)
        self.bytes = SyncJSON.int(json["bytes"]) ?? 0
        self.sha256 = sha.lowercased()
        self.updatedAt = (json["updated_at"] as? String) ?? ""
    }

    /// The row's `files` value as entries keyed by path (later duplicates win).
    static func list(_ any: Any?) -> [String: SyncFileEntry] {
        var out: [String: SyncFileEntry] = [:]
        for e in (any as? [Any]) ?? [] {
            if let d = e as? [String: Any], let entry = SyncFileEntry(json: d) { out[entry.path] = entry }
        }
        return out
    }
}

/// Per file: what this phone has (local), what the row lists (remote), and
/// what both agreed on at this phone's last sync (base).
struct SyncDiff: Equatable {
    /// Changed or new here, unchanged there: send ours.
    var upload: [String] = []
    /// New or changed there, unchanged here: fetch theirs.
    var download: [String] = []
    /// Changed on both sides (or no common base): see `ConflictRule`.
    var conflicts: [String] = []
    /// Synced before and since removed on this phone (a deleted photo): left
    /// out of the new manifest. The stored object is never deleted.
    var removedHere: [String] = []

    static func compute(local: [String: String], remote: [String: String], base: [String: String]) -> SyncDiff {
        var d = SyncDiff()
        for path in Set(local.keys).union(remote.keys).sorted() {
            let l = local[path], r = remote[path], b = base[path]
            if let l, let r {
                if l == r { continue }
                if r == b { d.upload.append(path) }
                else if l == b { d.download.append(path) }
                else { d.conflicts.append(path) }
            } else if l != nil {
                d.upload.append(path)
            } else if let r {
                if b == r { d.removedHere.append(path) } else { d.download.append(path) }
            }
        }
        return d
    }

    /// The manifest to write: every local file, plus every listed file this
    /// phone does not have (a download that has not finished must never drop
    /// another phone's photo from the list), minus files removed here.
    static func manifest(local: [String: SyncFileEntry], remote: [String: SyncFileEntry],
                         removedHere: [String]) -> [SyncFileEntry] {
        var out = local
        let removed = Set(removedHere)
        for (p, e) in remote where out[p] == nil && !removed.contains(p) { out[p] = e }
        return out.values.sorted { $0.path < $1.path }
    }

    /// Upload order: small files first, so readings, transcripts and photos
    /// reach SecureSuite before the 3D model and the full-resolution photos.
    static func uploadOrder(_ entries: [SyncFileEntry]) -> [SyncFileEntry] {
        entries.sorted { a, b in a.bytes != b.bytes ? a.bytes < b.bytes : a.path < b.path }
    }
}

/// What to do with a file changed on both phones.
enum ConflictRule: Equatable {
    /// JSON logs merged by id (raw readings, voice index, visit log): nothing dropped.
    case mergeJSON
    /// Derived or per-phone files (list metadata, thumbnail, plan frame…): this phone's copy stays.
    case keepLocal
    /// Everything else (photos, audio, rooms, model): this phone's copy stays
    /// and the server's is saved beside it under conflicts/<stamp>/.
    case keepBoth

    static func rule(for rel: String) -> ConflictRule {
        switch rel {
        case "readings-raw.json", "voice.json", "revisit-log.json": return .mergeJSON
        case "job.json", "thumb.png", "plan-frame.json", "editor-names.json", "needs-fix.json",
             "scan-extras.json", SyncPaths.linkFile:
            return .keepLocal
        default: return .keepBoth
        }
    }
}

enum SyncHash {
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Streams the file in 1 MB chunks (the 3D model can be large).
    static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}

/// Small JSON helpers shared by the sync code.
enum SyncJSON {
    static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// A string for ids and numbers alike (a job number may be text or an integer).
    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    static func object(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Two JSON values hold the same data.
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            if let da = a as? [String: Any], let db = b as? [String: Any] { return NSDictionary(dictionary: da).isEqual(to: db) }
            if let aa = a as? [Any], let ab = b as? [Any] { return NSArray(array: aa).isEqual(to: ab) }
            return canonical(a) == canonical(b)
        default: return false
        }
    }

    /// Sorted-key JSON text (a stable key for any value).
    static func canonical(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject([any]),
              let d = try? JSONSerialization.data(withJSONObject: [any], options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "\(any)" }
        return s
    }
}

/// Timestamps as Postgres and the plan write them.
enum SyncTime {
    /// "2026-11-16T03:04:05.123456+00:00", "...Z", "2026-11-16 03:04:05+00",
    /// without fractions, or a plain date "2026-11-19".
    static func parse(_ any: Any?) -> Date? {
        guard var s = (any as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        if s.contains("T") {
            // Fractional seconds: exactly three digits (ISO8601DateFormatter's comfort zone).
            if let dot = s.firstIndex(of: ".") {
                let start = s.index(after: dot)
                var end = start
                while end < s.endIndex, s[end].isASCII, s[end].isNumber { end = s.index(after: end) }
                var frac = String(s[start..<end])
                if frac.count > 3 { frac = String(frac.prefix(3)) }
                while frac.count < 3 { frac += "0" }
                s = String(s[..<dot]) + "." + frac + String(s[end...])
            }
            // "+00" -> "+00:00"
            if s.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil { s += ":00" }
            // "+0000" -> "+00:00"
            if let r = s.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
                let tz = String(s[r])
                s = String(s[..<r.lowerBound]) + String(tz.prefix(3)) + ":" + String(tz.suffix(2))
            }
            if !s.hasSuffix("Z") && s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil { s += "Z" }
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
