//
//  SyncStore.swift
//  SecureScan
//
//  What this phone remembers about each job's sync, kept outside the job
//  folder (Application Support/SecureScanSync/<job id>.json) so it never
//  travels with the job; the link to a SecureSuite job (securesuite.json in
//  the job folder, so it does travel); the signed-in profile.
//

import Foundation

struct HashCacheEntry: Codable, Equatable {
    var size: Int
    var mtime: Double
    var sha: String
}

struct JobSyncState: Codable {
    /// The row's revision when this phone last synced (nil = never).
    var lastRevision: Int?
    var orgID: String?
    /// sha256 of plan.json as last sent or received.
    var planSHA: String?
    /// path -> sha256 both sides agreed on at the last sync.
    var synced: [String: String] = [:]
    /// Objects already in storage with this content (an upload finished but
    /// the row was not written yet): not sent again after a crash.
    var uploaded: [String: String] = [:]
    /// path -> (size, mtime, sha) so unchanged files are not hashed again.
    var hashes: [String: HashCacheEntry] = [:]
    var lastSyncedAt: Date?
    /// The SecureSuite job id last written to the row.
    var pushedJobID: String?
    var pushedTitle: String?
    var pushedAddress: String?
    /// One line about the last merge ("Merged with changes from another phone").
    var note: String?
    var archived: Bool?
    var removed: Bool?
    /// Files the row lists that are not on this phone yet (a download to try again).
    var missing: [String]?

    init() {}

    /// Tolerant: a field added later decodes as its default instead of losing the whole state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastRevision = try c.decodeIfPresent(Int.self, forKey: .lastRevision)
        orgID = try c.decodeIfPresent(String.self, forKey: .orgID)
        planSHA = try c.decodeIfPresent(String.self, forKey: .planSHA)
        synced = try c.decodeIfPresent([String: String].self, forKey: .synced) ?? [:]
        uploaded = try c.decodeIfPresent([String: String].self, forKey: .uploaded) ?? [:]
        hashes = try c.decodeIfPresent([String: HashCacheEntry].self, forKey: .hashes) ?? [:]
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        pushedJobID = try c.decodeIfPresent(String.self, forKey: .pushedJobID)
        pushedTitle = try c.decodeIfPresent(String.self, forKey: .pushedTitle)
        pushedAddress = try c.decodeIfPresent(String.self, forKey: .pushedAddress)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed)
        missing = try c.decodeIfPresent([String].self, forKey: .missing)
    }
}

enum SyncStateStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SecureScanSync", isDirectory: true)
    }

    static func url(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".json") }

    static func load(_ id: UUID) -> JobSyncState {
        guard let data = try? Data(contentsOf: url(id)) else { return JobSyncState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(JobSyncState.self, from: data)) ?? JobSyncState()
    }

    static func save(_ s: JobSyncState, _ id: UUID) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(s) { try? data.write(to: url(id), options: .atomic) }
    }

    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    /// A different organisation signed in: nothing this phone knew about the old one applies.
    static func removeAll() { try? FileManager.default.removeItem(at: dir) }
}

enum SyncLinks {
    static func url(_ id: UUID) -> URL { JobFiles.folder(for: id).url.appendingPathComponent(SyncPaths.linkFile) }

    static func load(_ id: UUID) -> SecureSuiteLink? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(SecureSuiteLink.self, from: data)
    }

    /// nil removes the link.
    static func save(_ link: SecureSuiteLink?, for id: UUID) {
        guard let link else { try? FileManager.default.removeItem(at: url(id)); return }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(link) else { return }
        try? FileManager.default.createDirectory(at: JobFiles.folder(for: id).url, withIntermediateDirectories: true)
        try? data.write(to: url(id), options: .atomic)
    }
}

enum SyncProfileStore {
    private static let key = "secureSuiteProfile"

    static func load() -> SyncProfile? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SyncProfile.self, from: data)
    }

    static func save(_ p: SyncProfile?) {
        guard let p, let data = try? JSONEncoder().encode(p) else { UserDefaults.standard.removeObject(forKey: key); return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
