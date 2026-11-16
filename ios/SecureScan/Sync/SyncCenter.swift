//
//  SyncCenter.swift
//  SecureScan
//
//  The app's view of SecureSuite sync: who is signed in, each job's status,
//  the org's jobs that are not on this phone, and the schedule. Runs on the
//  main actor and never blocks it: all file and network work is in
//  SyncEngine. Without a configuration (empty build settings, the CI
//  simulator) it does nothing and the app is local only.
//
//  When it syncs: on launch and whenever the app comes back to the
//  foreground; a few seconds after the editor saves; when a job screen
//  closes; when the network comes back; and every minute while the app is
//  open (a cheap check: file sizes and dates, plus the org's revision list
//  every two minutes). Failures retry with backoff (15 s doubling to 15 min).
//  Going to the background asks iOS for time to finish the current upload;
//  anything left continues the next time the app is opened.
//

import SwiftUI
import Network
import UIKit

extension Notification.Name {
    /// A sync changed files of a job on this phone (the job list and an open job screen reload).
    static let syncChangedJob = Notification.Name("SecureScan.syncChangedJob")
}

@MainActor
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    let config: SyncConfig?
    /// Debug builds only: SECURESCAN_FAKE_CLOUD shows sync screens without a backend.
    let fake: FakeCloudMode?
    private let client: SupabaseClient?

    @Published private(set) var signedIn = false
    @Published private(set) var profile: SyncProfile?
    @Published private(set) var statuses: [UUID: SyncStatus] = [:]
    @Published private(set) var notes: [UUID: String] = [:]
    @Published private(set) var cloudJobs: [CloudScanJob] = []
    /// Job id -> "Downloading 3 of 12".
    @Published private(set) var downloading: [UUID: String] = [:]
    @Published private(set) var downloadProblem: [UUID: String] = [:]
    @Published private(set) var online = true
    /// The first-launch sign-in screen.
    @Published var showSignIn = false
    /// The job whose "Link SecureSuite job" picker is open.
    @Published var linkingJob: UUID?
    /// Bumped when a link changes (views re-read securesuite.json).
    @Published private(set) var linkVersion = 0

    var isConfigured: Bool { config != nil || fake != nil }
    /// Signed in and able to search SecureSuite jobs.
    var canLink: Bool { isConfigured && signedIn }

    static let skippedKey = "secureSuiteSkippedSignIn"
    private static let orgKey = "secureSuiteOrgID"

    private var started = false
    private var openJobs: [UUID: Int] = [:]
    private var soon: [UUID: Date] = [:]
    private var attempts: [UUID: Int] = [:]
    private var nextTry: [UUID: Date] = [:]
    private var lastPass = Date.distantPast
    private var lastRemote = Date.distantPast
    private var forceRemote = false
    private var pass: Task<Void, Never>?
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        #if DEBUG
        fake = FakeCloud.mode
        #else
        fake = nil
        #endif
        config = SyncConfig.fromInfo(Bundle.main.infoDictionary)
        client = config.map { SupabaseClient(config: $0) }
    }

    // MARK: Start

    /// Called once by the root view.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if let fake {
            FakeCloud.apply(fake, to: self)
            return
        }
        #endif
        guard config != nil else { return }
        profile = SyncProfileStore.load()
        Task {
            let session = await SyncAuth.shared.current()
            signedIn = session != nil
            if session == nil {
                if !UserDefaults.standard.bool(forKey: Self.skippedKey) { showSignIn = true }
            } else {
                await loadProfile()
            }
            seedStatuses()
            kick(remote: true)
        }
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in SyncCenter.shared.networkChanged(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "com.secureworkswa.securescan.sync.network"))
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in SyncCenter.shared.tick() }
        }
    }

    // MARK: Status for the UI

    func status(_ id: UUID) -> SyncStatus {
        #if DEBUG
        if fake != nil { return FakeCloud.status(for: id) }
        #endif
        guard config != nil else { return .off }
        // Demo jobs never leave the phone.
        if JobStore.shared.jobs.first(where: { $0.id == id })?.demo == true { return .off }
        guard signedIn else { return .signedOut }
        let s = statuses[id] ?? .pending
        if !online {
            switch s {
            case .synced, .archived, .removed: return s
            default: return .offline
            }
        }
        return s
    }

    /// The Files tab's second line.
    func detail(_ id: UUID) -> String? {
        let s = status(id)
        if case .error(let reason) = s, let t = nextTry[id], t > Date() {
            return reason + " · retrying " + SyncBackoff.words(t.timeIntervalSinceNow)
        }
        if case .synced = s, let note = notes[id] { return note }
        return s.detail()
    }

    func link(for id: UUID) -> SecureSuiteLink? {
        _ = linkVersion
        #if DEBUG
        if fake != nil { return FakeCloud.link(for: id) }
        #endif
        return SyncLinks.load(id)
    }

    /// Cloud jobs not on this phone, filtered by the jobs list search.
    func remoteOnly(localIDs: Set<UUID>, search: String = "") -> [CloudScanJob] {
        cloudJobs.filter { !localIDs.contains($0.id) && $0.matches(search) }
    }

    private func seedStatuses() {
        let ids = JobFiles.listMetas().filter { $0.demo != true }.map(\.id)
        var out: [UUID: SyncStatus] = [:]
        var n: [UUID: String] = [:]
        for id in ids {
            let s = SyncStateStore.load(id)
            if s.archived == true { out[id] = .archived }
            else if s.removed == true { out[id] = .removed }
            else if s.lastRevision != nil { out[id] = .synced(s.lastSyncedAt) }
            if let note = s.note { n[id] = note }
        }
        statuses = out
        notes = n
    }

    // MARK: Account

    /// nil on success, else one plain line for the sign-in screen.
    func signIn(email: String, password: String) async -> String? {
        if let problem = SyncWords.validateSignIn(email: email, password: password) { return problem }
        #if DEBUG
        if let fake { return FakeCloud.signIn(fake, center: self) }
        #endif
        guard let client else { return SyncWords.signIn(.notConfigured) }
        do {
            _ = try await SyncAuth.shared.signIn(client: client, email: email.trimmingCharacters(in: .whitespaces), password: password)
            signedIn = true
            UserDefaults.standard.set(false, forKey: Self.skippedKey)
            await loadProfile()
            showSignIn = false
            seedStatuses()
            kick(remote: true)
            return nil
        } catch {
            return SyncWords.signIn(SyncError.wrap(error))
        }
    }

    func skipSignIn() {
        UserDefaults.standard.set(true, forKey: Self.skippedKey)
        showSignIn = false
    }

    func signOut() {
        pass?.cancel()
        let c = client
        Task { await SyncAuth.shared.signOut(client: c) }
        signedOut()
    }

    private func signedOut() {
        signedIn = false
        profile = nil
        SyncProfileStore.save(nil)
        cloudJobs = []
        attempts = [:]
        nextTry = [:]
    }

    /// Fake-cloud screenshots only.
    func setFake(signedIn: Bool, profile: SyncProfile?, cloudJobs: [CloudScanJob], showSignIn: Bool) {
        self.signedIn = signedIn
        self.profile = profile
        self.cloudJobs = cloudJobs
        self.showSignIn = showSignIn
    }

    private func loadProfile() async {
        guard let client else { return }
        do {
            let p = try await SyncEngine.shared.profile(client: client)
            // Another organisation: what this phone knew about the old one no longer applies.
            let old = UserDefaults.standard.string(forKey: Self.orgKey)
            if !p.orgID.isEmpty {
                if let old, old != p.orgID { SyncStateStore.removeAll() }
                UserDefaults.standard.set(p.orgID, forKey: Self.orgKey)
            }
            profile = p
            SyncProfileStore.save(p)
        } catch {
            if SyncError.wrap(error) == .notSignedIn { signedOut(); return }
            if profile == nil, let s = await SyncAuth.shared.current() {
                profile = SyncProfile(userID: s.userID, email: s.email, name: "", role: "", orgID: "")
            }
        }
    }

    // MARK: Hooks from the app

    /// The editor (or anything else) saved this job.
    func jobChanged(_ id: UUID) {
        guard config != nil else { return }
        soon[id] = Date().addingTimeInterval(6)
    }

    func jobOpened(_ id: UUID) {
        openJobs[id, default: 0] += 1
    }

    func jobClosed(_ id: UUID) {
        let n = (openJobs[id] ?? 1) - 1
        openJobs[id] = n > 0 ? n : nil
        guard config != nil else { return }
        soon[id] = Date().addingTimeInterval(1)
        if statuses[id] == .waitingForClose { forceRemote = true }
    }

    func appBecameActive() {
        guard config != nil, started else { return }
        kick(remote: true)
    }

    func appWentToBackground() {
        guard config != nil, signedIn else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SecureSuite sync") {
                MainActor.assumeIsolated { SyncCenter.shared.backgroundTimeUp() }
            }
        }
        if pass == nil { runPass(remote: false) }
    }

    private func backgroundTimeUp() {
        pass?.cancel()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func retryNow(_ id: UUID) {
        nextTry[id] = nil
        attempts[id] = nil
        soon[id] = Date()
        tick()
    }

    // MARK: Links

    func setLink(_ job: SecureSuiteJob?, for id: UUID) {
        #if DEBUG
        if fake != nil { FakeCloud.setLink(job, for: id); linkVersion += 1; return }
        #endif
        SyncLinks.save(job.map { SecureSuiteLink(job: $0) }, for: id)
        linkVersion += 1
        jobChanged(id)
    }

    func recentSecureSuiteJobs() async throws -> [SecureSuiteJob] {
        #if DEBUG
        if fake != nil { try? await Task.sleep(nanoseconds: 300_000_000); return FakeCloud.secureSuiteJobs }
        #endif
        guard let client else { throw SyncError.notConfigured }
        return try await SyncEngine.shared.recentSecureSuiteJobs(client: client)
    }

    func searchSecureSuiteJobs(_ query: String) async throws -> [SecureSuiteJob] {
        #if DEBUG
        if fake != nil { return FakeCloud.secureSuiteJobs.filter { JobPickerFilter.matches(query, job: $0) } }
        #endif
        guard let client else { throw SyncError.notConfigured }
        return try await SyncEngine.shared.searchSecureSuiteJobs(query, client: client)
    }

    // MARK: Cloud jobs

    func refreshCloudJobsIfStale() {
        guard config != nil, signedIn, Date().timeIntervalSince(lastRemote) > 30 else { return }
        kick(remote: true)
    }

    /// Downloads a job that is only on SecureSuite; true when it is ready to open.
    func openCloudJob(_ id: UUID) async -> Bool {
        if FileManager.default.fileExists(atPath: JobFiles.folder(for: id).url.path) { return true }
        guard let client, signedIn, downloading[id] == nil else { return false }
        downloadProblem[id] = nil
        downloading[id] = "Opening…"
        defer { downloading[id] = nil }
        do {
            try await SyncEngine.shared.download(id, client: client) { text in
                Task { @MainActor in
                    if SyncCenter.shared.downloading[id] != nil { SyncCenter.shared.downloading[id] = text }
                }
            }
            statuses[id] = .synced(Date())
            JobStore.shared.reload()
            return true
        } catch {
            let e = SyncError.wrap(error)
            if e == .notSignedIn { signedOut() }
            downloadProblem[id] = e == .offline ? "No connection. Try again when online." : SyncWords.sync(e)
            return false
        }
    }

    // MARK: Schedule

    private func networkChanged(_ ok: Bool) {
        let cameBack = ok && !online
        online = ok
        if cameBack { kick(remote: true) }
    }

    func kick(remote: Bool) {
        if remote { forceRemote = true }
        lastPass = .distantPast
        tick()
    }

    private func tick() {
        guard config != nil, signedIn, online, pass == nil else { return }
        let now = Date()
        let remoteDue = forceRemote || now.timeIntervalSince(lastRemote) > 120
        let due = remoteDue
            || now.timeIntervalSince(lastPass) > 60
            || soon.values.contains { $0 <= now }
            || nextTry.values.contains { $0 <= now }
        if due { runPass(remote: remoteDue) }
    }

    private func runPass(remote: Bool) {
        guard let client, pass == nil else { return }
        let now = Date()
        lastPass = now
        forceRemote = false
        soon = soon.filter { $0.value > now }
        let open = Set(openJobs.keys)
        let waiting = nextTry.filter { $0.value > now }
        pass = Task {
            await passBody(client: client, remote: remote, open: open, waiting: waiting)
            pass = nil
            endBackgroundTask()
        }
    }

    private func passBody(client: SupabaseClient, remote: Bool, open: Set<UUID>, waiting: [UUID: Date]) async {
        var revisions: [UUID: Int] = [:]
        if remote {
            do {
                let rows = try await SyncEngine.shared.cloudJobs(client: client)
                lastRemote = Date()
                cloudJobs = rows.compactMap(CloudScanJob.init(row:))
                for r in rows { if let id = r.uuid { revisions[id] = r.revision } }
            } catch {
                switch SyncError.wrap(error) {
                case .notSignedIn: signedOut(); return
                case .offline: online = false; return
                case .cancelled: return
                default: break   // the per-job syncs below still run and show their own reason
                }
            }
        }
        let remoteKnown = remote && lastRemote > lastPass.addingTimeInterval(-1)
        let ids = await Task.detached(priority: .utility) {
            JobFiles.listMetas().filter { $0.demo != true }.map(\.id)
        }.value
        var changed = false
        for id in ids {
            if Task.isCancelled { break }
            if waiting[id] != nil { continue }
            let needs = await SyncEngine.shared.needsSync(id, remoteRevision: revisions[id], remoteKnown: remoteKnown)
            if !needs {
                if statuses[id] == nil || statuses[id] == .pending || statuses[id] == .offline {
                    let s = SyncStateStore.load(id)
                    statuses[id] = s.lastRevision == nil ? .pending : .synced(s.lastSyncedAt)
                }
                continue
            }
            statuses[id] = .syncing(nil)
            do {
                let outcome = try await SyncEngine.shared.sync(id, client: client, jobOpen: open.contains(id)) { text in
                    Task { @MainActor in
                        if case .syncing = SyncCenter.shared.statuses[id] { SyncCenter.shared.statuses[id] = .syncing(text) }
                    }
                }
                attempts[id] = nil
                nextTry[id] = nil
                statuses[id] = outcome.status
                if let note = SyncStateStore.load(id).note { notes[id] = note }
                if outcome.changedLocally {
                    changed = true
                    NotificationCenter.default.post(name: .syncChangedJob, object: id)
                }
            } catch {
                let e = SyncError.wrap(error)
                switch e {
                case .offline:
                    online = false
                    statuses[id] = .offline
                    return
                case .notSignedIn:
                    signedOut()
                    return
                case .cancelled:
                    statuses[id] = .pending
                    return
                default:
                    let n = (attempts[id] ?? 0) + 1
                    attempts[id] = n
                    nextTry[id] = Date().addingTimeInterval(SyncBackoff.delay(attempt: n) * Double.random(in: 0.85...1.15))
                    statuses[id] = .error(SyncWords.sync(e))
                }
            }
        }
        if changed { JobStore.shared.reload() }
    }
}

/// Root hook: starts sync, follows the app's foreground/background, shows the
/// first-launch sign-in screen (only when sync is configured).
struct SyncRootModifier: ViewModifier {
    @ObservedObject private var center = SyncCenter.shared
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear { center.start() }
            .onChange(of: phase) { _, p in
                if p == .active { center.appBecameActive() }
                if p == .background { center.appWentToBackground() }
            }
            .fullScreenCover(isPresented: $center.showSignIn) {
                SignInView(onDone: { center.showSignIn = false })
            }
    }
}

/// Job screen hook: tells sync the job is open (its plan is not rewritten
/// under the editor) and hosts the "Link SecureSuite job" picker.
struct SyncJobScreenModifier: ViewModifier {
    let jobID: UUID
    @ObservedObject private var center = SyncCenter.shared

    func body(content: Content) -> some View {
        content
            .onAppear { center.jobOpened(jobID) }
            .onDisappear { center.jobClosed(jobID) }
            .sheet(isPresented: Binding(get: { center.linkingJob == jobID }, set: { if !$0 { center.linkingJob = nil } })) {
                SecureSuiteJobPicker(current: center.link(for: jobID),
                                     onPick: { job in center.setLink(job, for: jobID); center.linkingJob = nil },
                                     onUnlink: { center.setLink(nil, for: jobID); center.linkingJob = nil },
                                     onCancel: { center.linkingJob = nil })
            }
    }
}

extension View {
    /// SecureSuite sync for the whole app (one line in SecureScanApp).
    func secureSuiteSync() -> some View { modifier(SyncRootModifier()) }

    /// SecureSuite sync for one job screen (one line in JobView).
    func secureSuiteJobScreen(_ jobID: UUID) -> some View { modifier(SyncJobScreenModifier(jobID: jobID)) }
}
