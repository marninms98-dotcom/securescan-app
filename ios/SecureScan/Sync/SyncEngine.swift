//
//  SyncEngine.swift
//  SecureScan
//
//  Moves jobs between this phone and SecureSuite (docs/SYNC.md):
//
//    public.scan_jobs   one row per job (id = the app's job id): title,
//                       site_address, job_id (the linked SecureSuite job),
//                       plan (plan.json), files (the manifest), revision
//    storage scan-files <org_id>/<job id>/<path in the job folder>
//
//  One job sync:
//    1. read the row (no plan). None yet: create it (SecureSuite fills
//       org_id), then go round again.
//    2. if the row's revision moved since this phone last synced, take what
//       the other phones did first: files new or changed there are
//       downloaded, files changed on both sides are merged (JSON logs) or
//       kept side by side, and the plan is taken (nothing changed here) or
//       merged item by item with this phone's plan kept as
//       plan.conflict-<stamp>.json. Never while the job is open on screen.
//    3. upload the files whose sha256 differs from the row's manifest (small
//       first; each finished upload is remembered, so a sync cut off half way
//       carries on where it stopped).
//    4. write the row (plan, files, link, title) only if the revision is
//       still the one read in 1 (`revision=eq.N`); if another phone wrote in
//       between, go round again.
//  Nothing here ever deletes a row or a stored file.
//

import Foundation

struct SyncOutcome {
    var status: SyncStatus
    var changedLocally = false
}

private let secureSuiteJobColumns = "id,job_number,status,type,client_name,site_address,site_suburb,created_at"

actor SyncEngine {
    static let shared = SyncEngine()

    private var inFlight = Set<UUID>()

    // MARK: Token

    /// Runs `body` with a valid access token; after a 401 refreshes once and tries again.
    private func withToken<T>(_ client: SupabaseClient, _ body: (String) async throws -> T) async throws -> T {
        let token = try await SyncAuth.shared.validToken(client: client)
        do {
            return try await body(token)
        } catch SyncError.http(let code, _) where code == 401 {
            let again = try await SyncAuth.shared.forceRefresh(client: client)
            return try await body(again)
        }
    }

    // MARK: Who and what

    func profile(client: SupabaseClient) async throws -> SyncProfile {
        guard let s = await SyncAuth.shared.current() else { throw SyncError.notSignedIn }
        let uid = s.userID.lowercased()
        let rows = try await withToken(client) { t in
            try await client.rows("GET", "users?select=*&id=eq.\(uid)", token: t)
        }
        return SyncProfile.from(row: rows.first ?? [:], userID: s.userID, email: s.email)
    }

    /// The org's scan jobs, newest change first (no plan, no files: this runs every few minutes).
    func cloudJobs(client: SupabaseClient) async throws -> [ScanJobRow] {
        let base = "scan_jobs?deleted_at=is.null&order=updated_at.desc&limit=300&select=id,title,site_address,job_id,revision,updated_at,created_at"
        return try await withToken(client) { (t: String) async throws -> [ScanJobRow] in
            do {
                return try await client.rows("GET", base + ",job:jobs(job_number,client_name)", token: t).compactMap(ScanJobRow.from)
            } catch SyncError.http(let code, _) where code == 400 || code == 300 {
                // The embed is not available: the list without job numbers.
                return try await client.rows("GET", base, token: t).compactMap(ScanJobRow.from)
            }
        }
    }

    func recentSecureSuiteJobs(client: SupabaseClient) async throws -> [SecureSuiteJob] {
        try await withToken(client) { t in
            try await client.rows("GET", "jobs?select=\(secureSuiteJobColumns)&order=created_at.desc&limit=200", token: t)
                .compactMap(SecureSuiteJob.from)
        }
    }

    func searchSecureSuiteJobs(_ query: String, client: SupabaseClient) async throws -> [SecureSuiteJob] {
        let term = JobPickerFilter.serverTerm(query)
        guard term.count >= 2 else { return [] }
        let head = "jobs?select=\(secureSuiteJobColumns)&order=created_at.desc&limit=50&"
        return try await withToken(client) { (t: String) async throws -> [SecureSuiteJob] in
            do {
                let filter = JobPickerFilter.orFilter(term: term, columns: ["job_number", "client_name", "site_address", "site_suburb"])
                return try await client.rows("GET", head + filter, token: t).compactMap(SecureSuiteJob.from)
            } catch SyncError.http(let code, _) where code == 400 {
                // job_number is a number column (ilike needs text): search the text columns.
                let filter = JobPickerFilter.orFilter(term: term, columns: ["client_name", "site_address", "site_suburb"])
                return try await client.rows("GET", head + filter, token: t).compactMap(SecureSuiteJob.from)
            }
        }
    }

    private func secureSuiteJob(id: String, client: SupabaseClient) async -> SecureSuiteJob? {
        let rows = try? await withToken(client) { t in
            try await client.rows("GET", "jobs?select=\(secureSuiteJobColumns)&id=eq.\(id)", token: t)
        }
        return rows?.first.flatMap(SecureSuiteJob.from)
    }

    // MARK: Is there anything to do?

    /// Cheap: file sizes and dates (hashes are cached) and the revision from
    /// the org list. No network.
    func needsSync(_ id: UUID, remoteRevision: Int?, remoteKnown: Bool) -> Bool {
        let folder = JobFiles.folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.url.path) else { return false }
        if JobFiles.readMeta(folder)?.demo == true { return false }
        var state = SyncStateStore.load(id)
        if state.archived == true || state.removed == true { return false }
        if Self.scanInProgress(folder) { return false }
        if state.lastRevision == nil { return true }
        if remoteKnown && remoteRevision != state.lastRevision { return true }
        if remoteKnown && !(state.missing ?? []).isEmpty { return true }
        let local = scan(folder, &state)
        let planSHA = hashOf("plan.json", folder.planURL, &state)
        SyncStateStore.save(state, id)
        if planSHA != state.planSHA { return true }
        if local.mapValues(\.sha256) != state.synced { return true }
        if SyncLinks.load(id)?.jobID != state.pushedJobID { return true }
        let meta = JobFiles.readMeta(folder)
        if Self.title(meta) != state.pushedTitle || (meta?.address ?? "") != state.pushedAddress { return true }
        return false
    }

    /// A scan screen is open on this job (or was, within the last 3 hours): leave it alone.
    static func scanInProgress(_ folder: JobFolder) -> Bool {
        let url = ScanOpenMarker.url(folder)
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return Date().timeIntervalSince(date) < 3 * 3600
    }

    static func title(_ m: JobMeta?) -> String {
        guard let m else { return "Untitled job" }
        var t = m.displayAddress
        if !m.jobRef.isEmpty { t += " · " + m.jobRef }
        return t
    }

    // MARK: Sync one job

    func sync(_ id: UUID, client: SupabaseClient, jobOpen: Bool,
              progress: @escaping @Sendable (String) -> Void) async throws -> SyncOutcome {
        guard !inFlight.contains(id) else { return SyncOutcome(status: .syncing(nil)) }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let folder = JobFiles.folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.url.path) else { return SyncOutcome(status: .synced(nil)) }
        var changed = false
        for _ in 0..<4 {
            try Task.checkCancellation()
            let pass = try await syncOnce(id, folder: folder, client: client, jobOpen: jobOpen, progress: progress)
            if pass.changedLocally { changed = true }
            if let status = pass.status { return SyncOutcome(status: status, changedLocally: changed) }
        }
        throw SyncError.busy
    }

    private struct Pass {
        /// nil = go round again.
        var status: SyncStatus?
        var changedLocally = false
    }

    private func syncOnce(_ id: UUID, folder: JobFolder, client: SupabaseClient, jobOpen: Bool,
                          progress: @escaping @Sendable (String) -> Void) async throws -> Pass {
        var state = SyncStateStore.load(id)
        let idText = id.uuidString.lowercased()
        let meta = JobFiles.readMeta(folder)
        let title = Self.title(meta)
        let address = meta?.address ?? ""

        progress("Checking SecureSuite")
        let rows = try await withToken(client) { t in
            try await client.rows("GET", "scan_jobs?id=eq.\(idText)&select=id,org_id,revision,files,job_id,title,site_address,deleted_at",
                                  token: t)
        }

        // 1. No row yet: create it.
        guard let row = rows.first.flatMap(ScanJobRow.from) else {
            if state.lastRevision != nil {
                // It was there and is gone: an admin removed it. Keep this copy, stop sending.
                state.removed = true
                SyncStateStore.save(state, id)
                return Pass(status: .removed)
            }
            let planData = try? Data(contentsOf: folder.planURL)
            let link = SyncLinks.load(id)
            var body: [String: Any] = ["id": idText, "title": title, "site_address": address,
                                       "plan": SyncJSON.object(planData) ?? [String: Any](), "files": [Any]()]
            body["job_id"] = link.map { $0.jobID as Any } ?? NSNull()
            progress("Adding the job to SecureSuite")
            do {
                let created = try await withToken(client) { t in
                    try await client.rows("POST", "scan_jobs?select=id,org_id,revision", token: t, body: body,
                                          prefer: "return=representation")
                }
                guard let c = created.first.flatMap(ScanJobRow.from) else { throw SyncError.badResponse }
                state.lastRevision = c.revision
                state.orgID = c.orgID
                state.planSHA = planData.map(SyncHash.sha256)
                state.pushedJobID = link?.jobID
                state.pushedTitle = title
                state.pushedAddress = address
                SyncStateStore.save(state, id)
            } catch SyncError.http(let code, _) where code == 409 {
                // Made by an earlier try whose answer was lost: carry on with it.
            }
            return Pass(status: nil)
        }

        if row.deleted {
            state.archived = true
            SyncStateStore.save(state, id)
            return Pass(status: .archived)
        }
        let org = row.orgID
        guard UUID(uuidString: org) != nil else { throw SyncError.badResponse }
        if let old = state.orgID, old != org { state.uploaded = [:] }
        state.orgID = org
        let remoteMoved = state.lastRevision != row.revision
        if remoteMoved && jobOpen {
            SyncStateStore.save(state, id)
            return Pass(status: .waitingForClose)
        }

        var changedLocally = false
        let now = Date()
        var local = scan(folder, &state)
        var diff = SyncDiff.compute(local: local.mapValues(\.sha256), remote: row.files.mapValues(\.sha256), base: state.synced)
        if jobOpen && !diff.conflicts.isEmpty {
            SyncStateStore.save(state, id)
            return Pass(status: .waitingForClose)
        }

        // 2. What the other phones did.
        if !jobOpen && (remoteMoved || !diff.download.isEmpty || !diff.conflicts.isEmpty) {
            let todo = diff.download + diff.conflicts
            let fresh = Set(diff.download)
            for (i, path) in todo.enumerated() {
                try Task.checkCancellation()
                progress("Downloading \(i + 1) of \(todo.count)")
                guard let object = SyncPaths.objectPath(org: org, job: idText, relative: path) else { continue }
                let tmp: URL
                do {
                    tmp = try await withToken(client) { t in try await client.download(objectPath: object, token: t) }
                } catch SyncError.http(let code, _) where code == 404 {
                    continue   // listed but not stored: left in the list, tried again later
                }
                defer { try? FileManager.default.removeItem(at: tmp) }
                let dest = folder.url.appendingPathComponent(path)
                if fresh.contains(path) {
                    try Self.place(tmp, at: dest)
                    changedLocally = true
                    continue
                }
                switch ConflictRule.rule(for: path) {
                case .mergeJSON:
                    if let l = try? Data(contentsOf: dest), let s = try? Data(contentsOf: tmp),
                       let merged = FileMerge.merge(path: path, local: l, server: s) {
                        try merged.write(to: dest, options: .atomic)
                    } else {
                        try Self.place(tmp, at: folder.url.appendingPathComponent(SyncPaths.conflictCopyPath(path, date: now)))
                    }
                    changedLocally = true
                case .keepLocal:
                    break
                case .keepBoth:
                    try Self.place(tmp, at: folder.url.appendingPathComponent(SyncPaths.conflictCopyPath(path, date: now)))
                    changedLocally = true
                }
            }

            if remoteMoved {
                progress("Merging the plan")
                let planRows = try await withToken(client) { t in
                    try await client.rows("GET", "scan_jobs?id=eq.\(idText)&select=plan", token: t)
                }
                let serverPlan = planRows.first?["plan"] as? [String: Any]
                if ScanJobRow.isRealPlan(serverPlan), let serverPlan {
                    let localData = try? Data(contentsOf: folder.planURL)
                    let localPlan = SyncJSON.object(localData)
                    let localSHA = hashOf("plan.json", folder.planURL, &state)
                    let localChanged = state.planSHA == nil || localSHA != state.planSHA
                    if !ScanJobRow.isRealPlan(localPlan) || !localChanged {
                        // Nothing new here: theirs.
                        try PlanDocument.data(serverPlan).write(to: folder.planURL, options: .atomic)
                        state.planSHA = hashOf("plan.json", folder.planURL, &state)
                        changedLocally = true
                    } else if let localPlan, let localData, !SyncJSON.same(localPlan, serverPlan) {
                        // Both changed: every item kept, this phone's plan saved beside it.
                        let merged = PlanMerge.merge(local: localPlan, server: serverPlan)
                        try localData.write(to: folder.url.appendingPathComponent(SyncPaths.planConflictName(now)), options: .atomic)
                        try PlanDocument.data(merged.plan).write(to: folder.planURL, options: .atomic)
                        state.note = "Merged with changes from another phone · your version kept as a copy"
                        changedLocally = true
                    }
                }
            }
            local = scan(folder, &state)
            diff = SyncDiff.compute(local: local.mapValues(\.sha256), remote: row.files.mapValues(\.sha256), base: state.synced)
        }

        // 3. What this phone did.
        var uploads: [SyncFileEntry] = []
        for path in diff.upload + diff.conflicts {
            guard let e = local[path], row.files[path]?.sha256 != e.sha256, state.uploaded[path] != e.sha256 else { continue }
            uploads.append(e)
        }
        uploads = SyncDiff.uploadOrder(uploads)
        for (i, e) in uploads.enumerated() {
            try Task.checkCancellation()
            progress("Uploading \(i + 1) of \(uploads.count)")
            guard let object = SyncPaths.objectPath(org: org, job: idText, relative: e.path) else { continue }
            let file = folder.url.appendingPathComponent(e.path)
            let type = SyncPaths.contentType(for: e.path)
            try await withToken(client) { t in
                try await client.upload(file: file, objectPath: object, contentType: type, token: t)
            }
            state.uploaded[e.path] = e.sha256
            SyncStateStore.save(state, id)
        }

        // 4. The row.
        let manifest = SyncDiff.manifest(local: local, remote: row.files, removedHere: diff.removedHere)
        var listed: [String: String] = [:]
        for e in manifest { listed[e.path] = e.sha256 }
        let manifestChanged = listed != row.files.mapValues(\.sha256)
        let planData = try? Data(contentsOf: folder.planURL)
        let planSHA = hashOf("plan.json", folder.planURL, &state)
        let planChanged = planSHA != state.planSHA
        let linkID = SyncLinks.load(id)?.jobID
        let linkChanged = linkID != row.jobID
        let titleChanged = title != row.title || address != row.siteAddress
        if manifestChanged || planChanged || linkChanged || titleChanged {
            var body: [String: Any] = ["files": manifest.map(\.json)]
            if planChanged { body["plan"] = SyncJSON.object(planData) ?? [String: Any]() }
            if linkChanged { body["job_id"] = linkID.map { $0 as Any } ?? NSNull() }
            if titleChanged {
                body["title"] = title
                body["site_address"] = address
            }
            progress("Saving to SecureSuite")
            let updated = try await withToken(client) { t in
                try await client.rows("PATCH", "scan_jobs?id=eq.\(idText)&revision=eq.\(row.revision)&select=id,org_id,revision",
                                      token: t, body: body, prefer: "return=representation")
            }
            guard let u = updated.first.flatMap(ScanJobRow.from) else {
                // Another phone saved in between: round again (its changes come first).
                SyncStateStore.save(state, id)
                return Pass(status: nil, changedLocally: changedLocally)
            }
            state.lastRevision = u.revision
        } else {
            state.lastRevision = row.revision
        }
        state.planSHA = planSHA
        state.synced = local.mapValues(\.sha256)
        state.uploaded = [:]
        state.pushedJobID = linkID
        state.pushedTitle = title
        state.pushedAddress = address
        state.missing = manifest.filter { local[$0.path] == nil }.map(\.path)
        state.lastSyncedAt = Date()
        SyncStateStore.save(state, id)
        return Pass(status: .synced(state.lastSyncedAt), changedLocally: changedLocally)
    }

    // MARK: Download a job that is only on SecureSuite

    func download(_ id: UUID, client: SupabaseClient, progress: @escaping @Sendable (String) -> Void) async throws {
        let final = JobFiles.folder(for: id)
        let fm = FileManager.default
        if fm.fileExists(atPath: final.url.path) { return }
        guard !inFlight.contains(id) else { throw SyncError.local("Already downloading") }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let idText = id.uuidString.lowercased()
        progress("Opening")
        let rows = try await withToken(client) { t in
            try await client.rows("GET", "scan_jobs?id=eq.\(idText)&select=*", token: t)
        }
        guard let row = rows.first.flatMap(ScanJobRow.from), !row.deleted else {
            throw SyncError.local("This job is no longer on SecureSuite")
        }
        // Built beside the jobs (a name the jobs list ignores), moved in when complete.
        let incoming = JobFiles.root.appendingPathComponent(".incoming-\(id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: incoming)
        try fm.createDirectory(at: incoming.appendingPathComponent("rooms", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: incoming.appendingPathComponent("photos", isDirectory: true), withIntermediateDirectories: true)
        do {
            let files = SyncDiff.uploadOrder(Array(row.files.values))
            for (i, e) in files.enumerated() {
                try Task.checkCancellation()
                progress("Downloading \(i + 1) of \(files.count)")
                guard let object = SyncPaths.objectPath(org: row.orgID, job: idText, relative: e.path) else { continue }
                do {
                    let tmp = try await withToken(client) { t in try await client.download(objectPath: object, token: t) }
                    try Self.place(tmp, at: incoming.appendingPathComponent(e.path))
                } catch SyncError.http(let code, _) where code == 404 {
                    continue
                }
            }
            let staged = JobFolder(url: incoming)
            if row.hasPlan, let plan = row.plan {
                try PlanDocument.data(plan).write(to: staged.planURL, options: .atomic)
            }
            if JobFiles.readMeta(staged) == nil {
                let plan = row.plan
                let rooms = (plan?["rooms"] as? [Any])?.count ?? 0
                let readings = ((plan?["markup"] as? [String: Any])?["readings"] as? [Any])?.count ?? 0
                let meta = JobMeta(id: id, address: row.siteAddress.isEmpty ? row.title : row.siteAddress,
                                   jobRef: (plan?["jobRef"] as? String) ?? "", createdAt: row.createdAt ?? Date(),
                                   roomCount: rooms, totalArea: 0, readingCount: readings, note: nil, demo: nil)
                try JobFiles.writeMeta(meta, staged)
            }
            let linkURL = incoming.appendingPathComponent(SyncPaths.linkFile)
            if let jid = row.jobID, !fm.fileExists(atPath: linkURL.path) {
                let job = await secureSuiteJob(id: jid, client: client)
                let link = job.map { SecureSuiteLink(job: $0) }
                    ?? SecureSuiteLink(jobID: jid, jobNumber: "", clientName: "", siteAddress: row.siteAddress)
                let e = JSONEncoder()
                e.outputFormatting = [.prettyPrinted, .sortedKeys]
                try e.encode(link).write(to: linkURL, options: .atomic)
            }
            try Task.checkCancellation()
            if fm.fileExists(atPath: final.url.path) { try? fm.removeItem(at: incoming); return }
            try fm.moveItem(at: incoming, to: final.url)
        } catch {
            try? fm.removeItem(at: incoming)
            throw error
        }

        // In step with the row from the start.
        var state = JobSyncState()
        state.lastRevision = row.revision
        state.orgID = row.orgID
        let local = scan(final, &state)
        state.planSHA = hashOf("plan.json", final.planURL, &state)
        state.synced = local.mapValues(\.sha256)
        state.pushedJobID = row.jobID
        state.pushedTitle = row.title
        state.pushedAddress = row.siteAddress
        state.missing = row.files.keys.filter { local[$0] == nil }.sorted()
        state.lastSyncedAt = Date()
        SyncStateStore.save(state, id)
    }

    // MARK: Files

    /// Every syncable file of the job folder with its sha256 (cached by size and date).
    private func scan(_ folder: JobFolder, _ state: inout JobSyncState) -> [String: SyncFileEntry] {
        let root = folder.url.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var out: [String: SyncFileEntry] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return out }
        var seen: Set<String> = ["plan.json"]
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(prefix) else { continue }
            let rel = String(full.dropFirst(prefix.count))
            guard SyncPaths.isSyncable(rel), let sha = hashOf(rel, url, &state) else { continue }
            seen.insert(rel)
            let mtime = v.contentModificationDate ?? Date()
            out[rel] = SyncFileEntry(path: rel, kind: SyncPaths.kind(for: rel), bytes: v.fileSize ?? 0,
                                     sha256: sha, updatedAt: SyncTime.string(mtime))
        }
        state.hashes = state.hashes.filter { seen.contains($0.key) }
        return out
    }

    private func hashOf(_ rel: String, _ url: URL, _ state: inout JobSyncState) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              v.isRegularFile == true else { return nil }
        let size = v.fileSize ?? 0
        let mtime = v.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let c = state.hashes[rel], c.size == size, c.mtime == mtime { return c.sha }
        guard let sha = try? SyncHash.sha256(fileAt: url) else { return nil }
        state.hashes[rel] = HashCacheEntry(size: size, mtime: mtime, sha: sha)
        return sha
    }

    static func place(_ tmp: URL, at dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }
}
