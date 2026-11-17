//
//  JobsListView.swift
//  SecureScan
//
//  Home: "Jobs" with one card per job (plan thumbnail, address, size,
//  status, last visit), search, the docked "New job" button and Settings.
//

import SwiftUI
import RoomPlan

struct JobsListView: View {
    @ObservedObject private var store = JobStore.shared
    @ObservedObject private var cloud = SyncCenter.shared  // SecureSuite sync hook
    @StateObject private var summaries = JobSummaries()
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var showNewJob = false
    @State private var showSettings = false
    @State private var pendingOpen: UUID?
    @State private var deleteCandidate: JobMeta?
    @State private var errorText: String?
    @State private var didAutoOpen = false
    @State private var creatingDemo = false
    /// Simulator screenshots of the scan screen (no camera).
    @State private var previewScanJob: JobMeta?

    static var lidarSupported: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SECURESCAN_LIDAR"] == "1" { return true }
        #endif
        if SimDemo.active { return true }
        return RoomCaptureSession.isSupported
    }
    private let lidarSupported = JobsListView.lidarSupported

    private var filtered: [JobMeta] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.jobs }
        return store.jobs.filter { $0.address.localizedCaseInsensitiveContains(q) || $0.jobRef.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.jobs.isEmpty && cloud.remoteOnly(localIDs: []).isEmpty {  // SecureSuite sync hook: cloud jobs show in the list
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Jobs")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { id in JobView(jobID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .onAppear(perform: appeared)
            .onChange(of: store.jobs) { _, jobs in summaries.refresh(jobs) }
            .alert("Delete this job?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                   presenting: deleteCandidate) { job in
                Button("Delete", role: .destructive) { store.delete(job.id); deleteCandidate = nil }
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            } message: { _ in
                Text("Its plan, photos and readings are removed from this iPhone.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onAddDemo: {
                showSettings = false
                createDemo()
            })
        }
        .fullScreenCover(item: $previewScanJob) { job in
            ScanView(job: job, preview: true, onFinished: { _ in previewScanJob = nil }, onDiscarded: { previewScanJob = nil })
        }
        .fullScreenCover(isPresented: $showNewJob, onDismiss: {
            store.reload()
            if let id = pendingOpen { pendingOpen = nil; path.append(id) }
        }) {
            NewJobFlow(onComplete: { id in
                pendingOpen = id
                showNewJob = false
            }, onCancel: { showNewJob = false })
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section { searchField }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            ForEach(filtered) { job in
                Section {
                    NavigationLink(value: job.id) {
                        JobCard(job: job, summary: summaries.byID[job.id], thumbsVersion: summaries.thumbsVersion)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deleteCandidate = job } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { deleteCandidate = job } label: {
                            Label("Delete job", systemImage: "trash")
                        }
                    }
                }
            }
            // SecureSuite sync hook: jobs saved from other phones, not on this one.
            CloudJobsSection(localIDs: Set(store.jobs.map(\.id)), search: search) { id in store.reload(); path.append(id) }
            if filtered.isEmpty && !search.isEmpty {
                Section {
                    Text("No job matches “\(search)”.")
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            if !lidarSupported {
                Section {
                } footer: {
                    Text("This iPhone has no LiDAR, so it opens jobs but can't scan.")
                        .font(DS.Font.caption)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
    }

    /// In the list (iOS 26 would put a system search bar at the bottom, under New job).
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search address or claim", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(DS.Font.body)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "house")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No jobs yet")
                .font(DS.Font.headline)
            Text(lidarSupported ? "Start one when you're on site." : "This iPhone has no LiDAR, so it can't scan.")
                .font(DS.Font.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var dock: some View {
        Group {
            if lidarSupported {
                PrimaryButton("New job", icon: "plus") { showNewJob = true }
            } else {
                PrimaryButton(creatingDemo ? "Making demo job…" : "Try a demo job", icon: "sparkles") { createDemo() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: Launch hooks

    private func appeared() {
        store.reload()
        summaries.refresh(store.jobs)
        #if DEBUG
        if DemoSeed.requested {
            Task {
                do { try await Task.detached(priority: .userInitiated) { try DemoSeed.seedIfNeeded() }.value }
                catch { errorText = "Couldn't make the demo jobs: \(error.localizedDescription)" }
                store.reload()
                summaries.refresh(store.jobs)
                if let ref = DemoSeed.openRef, let job = store.jobs.first(where: { $0.jobRef == ref }) { path.append(job.id) }
            }
            return
        }
        #endif
        openDemoIfRequested()
        // Simulator screenshots only.
        let pv = ProcessInfo.processInfo.environment["SECURESCAN_PREVIEW"]
        if pv == "settings" { showSettings = true }
        if pv == "newscan" || pv == "newjob" { showNewJob = true }
    }

    /// Automated screenshots only: launching with SECURESCAN_DEMO=1 opens the
    /// demo job, creating it when there is none.
    private func openDemoIfRequested() {
        guard !didAutoOpen, ProcessInfo.processInfo.environment["SECURESCAN_DEMO"] == "1" || SimDemo.active else { return }
        didAutoOpen = true
        let demo = store.jobs.first(where: { $0.jobRef == "DEMO" })
            ?? store.jobs.first(where: { $0.demo == true && $0.jobRef != "STRESS" })
        if (ProcessInfo.processInfo.environment["SECURESCAN_PREVIEW"] ?? "").hasPrefix("scan"), let demo {
            previewScanJob = demo
        } else if ProcessInfo.processInfo.environment["SECURESCAN_DEMO_VARIANT"] == "stress" {
            createDemo(stress: true)
        } else if let demo {
            path.append(demo.id)
        } else {
            createDemo()
        }
    }

    private func createDemo(stress: Bool = false) {
        guard !creatingDemo else { return }
        creatingDemo = true
        Task {
            defer { creatingDemo = false }
            do {
                let marks = SimDemo.active
                let meta = try await Task.detached(priority: .userInitiated) { () throws -> JobMeta in
                    let m = try JobProcessor.createDemoJob(stress: stress)
                    if marks { SimDemo.addMarks(JobFiles.folder(for: m.id)) }
                    return m
                }.value
                store.reload()
                path.append(meta.id)
            } catch {
                errorText = "Couldn't create the demo job: \(error.localizedDescription)"
            }
        }
    }
}

/// One job in the list.
struct JobCard: View {
    let job: JobMeta
    let summary: JobSummary?
    /// Changes when thumbnails are re-rendered (forces the image to reload).
    var thumbsVersion = 0

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayAddress)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(facts)
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                ViewThatFits(in: .horizontal) {
                    statusLine(withRef: true)
                    statusLine(withRef: false)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    /// The 3D dollhouse (thumb3d.png), else the plan drawing, else a placeholder.
    private var thumbnail: some View {
        let folder = JobFiles.folder(for: job.id)
        let dollhouse = UIImage(contentsOfFile: Dollhouse.thumbURL(folder).path)
        return ZStack {
            if let dollhouse {
                Color(uiColor: Dollhouse.canvas)
                Image(uiImage: dollhouse).resizable().scaledToFill()
            } else if let img = UIImage(contentsOfFile: folder.thumbURL.path) {
                Color.white
                Image(uiImage: img).resizable().scaledToFit().padding(5)
            } else {
                Color(uiColor: Dollhouse.canvas)
                Image(systemName: "cube.transparent").font(.system(size: 24)).foregroundStyle(.tertiary)
            }
        }
        .id(thumbsVersion)
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            // Cloud state on the thumbnail's corner (like a photo library badge).
            ThumbSyncBadge(jobID: job.id) {
                SyncGlyph(jobID: job.id)  // SecureSuite sync hook
            }
            .padding(5)
        }
    }

    private var facts: String {
        if job.roomCount == 0 && !JobFiles.folder(for: job.id).hasPlan { return "Not scanned yet" }
        var parts: [String] = []
        parts.append(job.roomCount == 1 ? "1 room" : "\(job.roomCount) rooms")
        if job.totalArea > 0 { parts.append(String(format: "%.0f m²", job.totalArea)) }
        parts.append(job.readingCount == 1 ? "1 reading" : "\(job.readingCount) readings")
        return parts.joined(separator: " · ")
    }

    private func statusLine(withRef: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let summary { StatusBadge(status: summary.status) }
            if let n = summary?.toFix, n > 0 {
                StatusBadge(title: "\(n) to fix", color: DS.Color.damp)
            }
            Text(dateLine(withRef: withRef))
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func dateLine(withRef: Bool) -> String {
        var s = JobCard.day(summary?.lastVisit ?? job.createdAt)
        if withRef && !job.jobRef.isEmpty && job.jobRef != "DEMO" { s += " · " + job.jobRef }
        return s
    }

    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A white disc behind the sync glyph, shown only when the job has a sync state.
struct ThumbSyncBadge<Glyph: View>: View {
    let jobID: UUID
    @ViewBuilder let glyph: () -> Glyph
    @ObservedObject private var center = SyncCenter.shared

    var body: some View {
        if center.status(jobID) != .off {
            glyph()
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(.systemBackground)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

/// The job's state, as a small tinted capsule.
struct StatusBadge: View {
    let title: String
    let color: Color

    init(status: JobStatus) { title = status.title; color = status.color }
    init(title: String, color: Color) { self.title = title; self.color = color }

    var body: some View {
        Text(title)
            .font(DS.Font.captionBold)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.12), in: Capsule())
    }
}
