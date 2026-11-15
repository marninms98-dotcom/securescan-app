//
//  JobsListView.swift
//  SecureScan
//
//  Home screen: saved jobs, search, swipe-delete (with confirm), New scan,
//  Create demo job.
//

import SwiftUI
import RoomPlan

struct JobsListView: View {
    @ObservedObject private var store = JobStore.shared
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var showNewJob = false
    @State private var pendingOpen: UUID?
    @State private var deleteCandidate: JobMeta?
    @State private var errorText: String?
    @State private var didAutoOpen = false
    /// Simulator screenshots of the scan screen (no camera).
    @State private var previewScanJob: JobMeta?

    private let lidarSupported = RoomCaptureSession.isSupported

    private var filtered: [JobMeta] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.jobs }
        return store.jobs.filter { $0.address.localizedCaseInsensitiveContains(q) || $0.jobRef.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.jobs.isEmpty {
                    emptyState
                } else {
                    List {
                        if !lidarSupported { unsupportedBanner }
                        ForEach(filtered) { job in
                            NavigationLink(value: job.id) { JobRow(job: job) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { deleteCandidate = job } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search address")
                }
            }
            .navigationTitle("Jobs")
            .navigationDestination(for: UUID.self) { id in JobView(jobID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { createDemo() } label: { Label("Create demo job", systemImage: "wand.and.stars") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if lidarSupported {
                    Button { showNewJob = true } label: {
                        Label("New scan", systemImage: "viewfinder")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                    .background(.bar)
                }
            }
            .onAppear {
                store.reload()
                openDemoIfRequested()
            }
            .alert("Delete this job?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                   presenting: deleteCandidate) { job in
                Button("Delete", role: .destructive) { store.delete(job.id); deleteCandidate = nil }
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            } message: { job in
                Text("\(job.displayAddress) — the plan, 3D model, readings and photos will be removed from this iPhone.")
            }
            .alert("Problem", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No jobs yet", systemImage: "house")
        } description: {
            Text(lidarSupported
                 ? "Tap New scan, walk each room with the phone, and log moisture readings as you go."
                 : "This device can't run a LiDAR room scan (it needs an iPhone or iPad Pro with LiDAR). You can still try the app with a demo job.")
        } actions: {
            Button("Create demo job") { createDemo() }
                .buttonStyle(.bordered)
        }
    }

    private var unsupportedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scanning needs a LiDAR iPhone", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("This device can open saved jobs but can't scan. Use a demo job to try the plan, 3D and files screens.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Create demo job") { createDemo() }
        }
        .padding(.vertical, 6)
    }

    /// Automated screenshots only: launching with SECURESCAN_DEMO=1 opens the
    /// first job, creating the demo job when there is none.
    private func openDemoIfRequested() {
        guard !didAutoOpen, ProcessInfo.processInfo.environment["SECURESCAN_DEMO"] == "1" else { return }
        didAutoOpen = true
        if (ProcessInfo.processInfo.environment["SECURESCAN_PREVIEW"] ?? "").hasPrefix("scan"),
           let demo = store.jobs.first(where: { $0.demo == true && $0.jobRef != "STRESS" }) {
            previewScanJob = demo
        } else if ProcessInfo.processInfo.environment["SECURESCAN_DEMO_VARIANT"] == "stress" {
            createDemo(stress: true)
        } else if let first = store.jobs.first(where: { $0.jobRef != "STRESS" }) {
            path.append(first.id)
        } else {
            createDemo()
        }
    }

    private func createDemo(stress: Bool = false) {
        Task {
            do {
                let meta = try await Task.detached(priority: .userInitiated) { try JobProcessor.createDemoJob(stress: stress) }.value
                store.reload()
                path.append(meta.id)
            } catch {
                errorText = "Couldn't create the demo job: \(error.localizedDescription)"
            }
        }
    }
}

struct JobRow: View {
    let job: JobMeta
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = UIImage(contentsOfFile: JobFiles.folder(for: job.id).thumbURL.path) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: "square.dashed").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayAddress).font(.headline).lineLimit(2)
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(job.roomCount == 1 ? "1 room" : "\(job.roomCount) rooms")
        if job.totalArea > 0 { parts.append(String(format: "%.1f m²", job.totalArea)) }
        if job.readingCount > 0 { parts.append("\(job.readingCount) readings") }
        if !job.jobRef.isEmpty { parts.append(job.jobRef) }
        if job.demo == true { parts.append("demo") }
        return parts.joined(separator: " · ")
    }
}
