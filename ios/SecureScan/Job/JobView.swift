//
//  JobView.swift
//  SecureScan
//
//  Job screen: Plan (web editor) / 3D / Files.
//

import SwiftUI
import Combine

@MainActor
final class JobViewModel: ObservableObject {
    let jobID: UUID
    let folder: JobFolder
    @Published var meta: JobMeta?
    /// Bumped whenever plan.json is rewritten by the app; the editor reloads.
    @Published var planVersion = 0
    @Published var busy = false
    @Published var message: String?
    /// Voice recordings of this job (voice.json) and what is happening to them.
    @Published var recordings: [VoiceRecording] = []
    @Published var voiceStatus: String?
    private var voiceBusy = false
    /// Return visits.
    @Published var showRevisit = false
    @Published var requestedTab: Int?
    @Published var visitInfo: PlanDocument.VisitInfo?
    weak var editor: EditorViewController?
    /// Document kinds the editor makes (nil until it has loaded once).
    @Published var documentKinds: Set<String>?
    @Published var makingDocument = false
    /// nil until the editor has loaded: whether it has SecureScan.setPricesVisible.
    @Published var editorHidesPrices: Bool?
    @Published var pricesVisible = PriceLock.pricesVisible
    /// The scope of works on site: items done / scoped (0 total = nothing scoped).
    @Published var scopeDone = 0
    @Published var scopeTotal = 0
    @Published var showScope = false
    /// Items saved during a scan the app was closed in, not yet on the plan.
    @Published var unplacedCount = 0

    init(jobID: UUID) {
        self.jobID = jobID
        self.folder = JobFiles.folder(for: jobID)
        // A folder without job.json (crash mid-create) still gets a usable meta,
        // so the editor has a fallback document and edits can rewrite job.json.
        self.meta = JobFiles.readMeta(folder)
            ?? JobMeta(id: jobID, address: "", jobRef: "", createdAt: Date(), roomCount: 0,
                       totalArea: 0, readingCount: 0, note: nil, demo: nil)
    }

    var hasModel: Bool { folder.hasModel }

    // MARK: Return visits

    var canReturnVisit: Bool { hasPlan && meta?.demo != true || ProcessInfo.processInfo.environment["SECURESCAN_PREVIEW"] == "revisit" }

    func refreshVisitInfo() {
        let url = folder.planURL
        Task {
            let folder = self.folder
            let r = await Task.detached(priority: .utility) { () -> (PlanDocument.VisitInfo?, Int, Int, Int) in
                let doc = (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                // Closed mid-scan: saved items that never reached the plan.
                var unplaced = 0
                if ScanOpenMarker.exists(folder) {
                    let ids = JobFiles.loadRawReadings(folder).map(\.id)
                    unplaced = Recovery.unplaced(rawIds: ids, planIds: doc.map(Recovery.planIds) ?? []).count
                    if unplaced == 0 && doc != nil { ScanOpenMarker.clear(folder) }
                }
                guard let doc else { return (nil, 0, 0, unplaced) }
                let p = ScopeList.progress(ScopeList.items(plan: doc, names: EditorNamesStore.load(folder)))
                return (PlanDocument.visitInfo(doc), p.done, p.total, unplaced)
            }.value
            visitInfo = r.0
            scopeDone = r.1
            scopeTotal = r.2
            unplacedCount = r.3
        }
    }

    /// "See scope on site": take the editor's latest edits first.
    func openScope() {
        Task {
            if let editor { await editor.flushLatestPlan() }
            showScope = true
        }
    }

    /// "Return visit": take the editor's latest edits first, then open the camera screen.
    func openReturnVisit() {
        Task {
            if let editor { await editor.flushLatestPlan() }
            showRevisit = true
        }
    }

    /// The Return visit wrote to plan.json: reload the editor and the 3D view.
    func revisitClosed() {
        planVersion += 1
        refreshVisitInfo()
    }

    /// "Re-measure on the plan": the editor's own re-measure flow.
    func remeasureOnPlan() {
        requestedTab = 0
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await editor?.startRemeasure()
        }
    }

    // MARK: Documents (Inspection report · Quote · Monitoring / Final report)

    var offeredDocuments: [DocumentKind] {
        DocumentKind.offered(visitCount: visitInfo?.n ?? 1, lastVisitType: visitInfo?.type, pricesVisible: pricesVisible)
    }

    /// False when the loaded editor can't make this kind yet, or (prices hidden)
    /// can't hide prices.
    func documentAvailable(_ k: DocumentKind) -> Bool {
        DocumentKind.available(k, editorKinds: documentKinds, editorHidesPrices: editorHidesPrices, pricesVisible: pricesVisible)
    }

    /// Makes the document through the editor (opening the Plan tab so it is
    /// loaded and on screen for the PDF layout), then the share sheet.
    func makeDocument(_ k: DocumentKind) {
        guard !makingDocument else { return }
        makingDocument = true
        requestedTab = 0
        Task {
            defer { makingDocument = false }
            for _ in 0..<50 {
                if let e = editor, e.ready { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let editor, editor.ready else {
                message = "The plan editor didn't load, so the \(k.title.lowercased()) couldn't be made."
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await editor.exportDocument(k)
        }
    }

    // MARK: Voice notes

    /// Job screen "Record note" button.
    func toggleRecordNote() {
        let recorder = VoiceRecorder.shared
        if recorder.isRecordingJob(folder) {
            recorder.stop()
            processVoice()
        } else if !recorder.isRecording {
            // A problem (microphone off...) is shown by JobView's alert.
            Task { await recorder.start(folder: folder) }
        }
    }

    /// Finishes cut-off recordings, then transcribes every recording that is
    /// waiting, merging the notes into plan.json (the editor reloads).
    func processVoice() {
        guard !voiceBusy else { return }
        voiceBusy = true
        let folder = self.folder
        Task {
            await VoiceRecorder.shared.waitForConversions()
            let active = VoiceRecorder.shared.activeFileFor(folder)
            await Task.detached(priority: .userInitiated) {
                VoiceProcessor.recover(folder: folder, activeFile: active)
            }.value
            recordings = JobFiles.loadVoice(folder)
            let pending = recordings.filter { $0.state == "saved" }
            for (i, rec) in pending.enumerated() {
                voiceStatus = pending.count == 1 ? "Transcribing voice note…" : "Transcribing voice note \(i + 1) of \(pending.count)…"
                let result = await VoiceProcessor.transcribe(folder: folder, recording: rec)
                // Take the editor's latest edits first, then merge and reload it.
                if let editor { await editor.flushLatestPlan() }
                let box = TranscriptBox(result)
                let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                    do { try VoiceProcessor.apply(folder: folder, recording: rec, result: box.value); return nil }
                    catch { return error.localizedDescription }
                }.value
                if let failure { message = "Voice note \(rec.number): \(failure)" }
                planVersion += 1
                recordings = JobFiles.loadVoice(folder)
            }
            let pendingFiles = Set(pending.map { $0.file })
            if let failed = recordings.last(where: { r in r.state == "failed" && pendingFiles.contains(r.file) }),
               let e = failed.error {
                message = "Voice note \(failed.number) wasn't transcribed: \(e)"
            }
            voiceStatus = nil
            voiceBusy = false
        }
    }

    /// Files tab "Transcribe again".
    func transcribeAgain(_ rec: VoiceRecording) {
        JobFiles.updateVoice(folder) { list in
            if let i = list.firstIndex(where: { $0.file == rec.file }) { list[i].state = "saved"; list[i].error = nil }
        }
        recordings = JobFiles.loadVoice(folder)
        processVoice()
    }
    var hasPlan: Bool { folder.hasPlan }

    /// The editor saved: keep the list metadata's address / job ref in step.
    func editorSaved(address: String?, jobRef: String?) {
        guard var m = meta else { return }
        var changed = false
        if let a = address, a != m.address { m.address = a; changed = true }
        if let j = jobRef, j != m.jobRef { m.jobRef = j; changed = true }
        guard changed else { return }
        meta = m
        try? JobFiles.writeMeta(m, folder)
    }

    /// Files > "Regenerate plan from scan".
    func regenerate() {
        guard !busy else { return }
        busy = true
        message = nil
        let folder = self.folder
        let needsModel = !hasModel && meta?.demo != true
        Task {
            // Capture the editor's latest state first so no markup is lost.
            if let editor { await editor.flushLatestPlan() }
            // `let`: a captured `var` in the @Sendable closure below is a compile error.
            let note: String?
            if needsModel { note = await JobProcessor.exportModelFromSavedRooms(folder: folder) } else { note = nil }
            do {
                let m = try await Task.detached(priority: .userInitiated) {
                    try JobProcessor.buildPlan(folder: folder, modelNote: note)
                }.value
                meta = m
                ScanOpenMarker.clear(folder)
                planVersion += 1
                message = "Plan rebuilt: \(m.roomCount) room\(m.roomCount == 1 ? "" : "s"), markup kept."
            } catch {
                message = "Couldn't regenerate: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

/// Hands a transcription result to a background task.
final class TranscriptBox: @unchecked Sendable {
    let value: Result<[GroupedNote], Error>
    init(_ value: Result<[GroupedNote], Error>) { self.value = value }
}

struct JobView: View {
    @StateObject private var vm: JobViewModel
    @ObservedObject private var recorder = VoiceRecorder.shared
    @Environment(\.dismiss) private var dismiss
    /// SECURESCAN_TAB (0 Plan, 1 3D, 2 Files) picks the starting tab for automated screenshots.
    @State private var tab = Int(ProcessInfo.processInfo.environment["SECURESCAN_TAB"] ?? "0") ?? 0

    init(jobID: UUID) {
        _vm = StateObject(wrappedValue: JobViewModel(jobID: jobID))
    }

    var body: some View {
        TabView(selection: $tab) {
            PlanTab(vm: vm, onClose: { dismiss() })
                .tabItem { Label("Plan", systemImage: "square.split.2x2") }
                .tag(0)
            ModelTab(vm: vm)
                .tabItem { Label("3D", systemImage: "cube") }
                .tag(1)
            FilesTab(vm: vm)
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(2)
        }
        .navigationTitle(vm.meta?.displayAddress ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RecordToggle(recorder: recorder, compact: true) { vm.toggleRecordNote() }
                    .disabled(recorder.isRecording && !recorder.isRecordingJob(vm.folder))
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                if vm.unplacedCount > 0 {
                    HStack(spacing: 10) {
                        Text(Recovery.banner(unplaced: vm.unplacedCount)).font(.footnote.bold())
                        Spacer()
                        Button("Place them") { vm.regenerate() }
                            .font(.footnote.bold())
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.busy)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }
                if vm.hasPlan && vm.scopeTotal > 0 {
                    Button { vm.openScope() } label: {
                        Label("See scope on site · \(vm.scopeDone) of \(vm.scopeTotal) done", systemImage: "arkit")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MarkupControls.accent(.quote))
                    .padding(.horizontal)
                }
                if vm.hasPlan { DocumentBar(vm: vm) }
                if let status = vm.voiceStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(status).font(.footnote)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                }
                if let v = vm.visitInfo, v.isReturn, tab != 0 {
                    HStack(spacing: 10) {
                        Text("Visit \(v.n) · \(v.label.isEmpty ? v.type.capitalized : v.label)").font(.footnote.bold())
                        Spacer()
                        Button("Return visit") { vm.openReturnVisit() }.font(.footnote.bold())
                        Button("On the plan") { vm.remeasureOnPlan() }.font(.footnote)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }
            }
        }
        .onAppear {
            vm.processVoice()
            vm.refreshVisitInfo()
            if ProcessInfo.processInfo.environment["SECURESCAN_PREVIEW"] == "revisit" { vm.showRevisit = true }
            if let k = ProcessInfo.processInfo.environment["SECURESCAN_DOCUMENT"].flatMap(DocumentKind.init(rawValue:)) {
                vm.makeDocument(k)
            }
        }
        .onChange(of: vm.planVersion) { _, _ in vm.refreshVisitInfo() }
        .onChange(of: vm.requestedTab) { _, t in
            if let t { tab = t; vm.requestedTab = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pricesVisibleChanged)) { _ in
            vm.pricesVisible = PriceLock.pricesVisible
        }
        .fullScreenCover(isPresented: $vm.showScope) {
            RevisitView(folder: vm.folder, scope: true,
                        onClose: { vm.showScope = false; vm.revisitClosed() },
                        onPlanInstead: { vm.showScope = false })
        }
        .fullScreenCover(isPresented: $vm.showRevisit) {
            RevisitView(folder: vm.folder,
                        onClose: { vm.showRevisit = false; vm.revisitClosed() },
                        onPlanInstead: { vm.showRevisit = false; vm.remeasureOnPlan() })
        }
        // Leaving the job stops its "Record note" recording (and transcribes it).
        .onDisappear { if recorder.isRecordingJob(vm.folder) { vm.toggleRecordNote() } }
        .alert("Voice note", isPresented: Binding(get: { recorder.problem != nil }, set: { if !$0 { recorder.problem = nil } })) {
            Button("OK") { recorder.problem = nil }
        } message: {
            Text(recorder.problem ?? "")
        }
    }
}

struct PlanTab: View {
    @ObservedObject var vm: JobViewModel
    let onClose: () -> Void

    var body: some View {
        if EditorViewController.editorURL == nil {
            ContentUnavailableView {
                Label("Plan editor missing", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This build of SecureScan doesn't include web/editor.html, so the plan can't be shown. The job's files are safe — rebuild the app with editor.html present (see README).")
            }
        } else {
            EditorContainer(vm: vm, onClose: onClose)
        }
    }
}

struct EditorContainer: UIViewControllerRepresentable {
    @ObservedObject var vm: JobViewModel
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> EditorViewController {
        let vc = EditorViewController(folder: vm.folder, fallbackMeta: vm.meta)
        vc.loadedVersion = vm.planVersion
        vc.onClose = onClose
        let model = vm
        vc.onSaved = { address, jobRef in model.editorSaved(address: address, jobRef: jobRef) }
        vm.editor = vc
        vc.onReady = { kinds, hides in
            model.documentKinds = kinds
            model.editorHidesPrices = hides
        }
        return vc
    }

    func updateUIViewController(_ vc: EditorViewController, context: Context) {
        if vc.loadedVersion != vm.planVersion {
            vc.loadedVersion = vm.planVersion
            vc.sendPlan()
        }
    }
}

/// Top of the job screen: what do you want out of this job.
struct DocumentBar: View {
    @ObservedObject var vm: JobViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(vm.offeredDocuments) { k in
                let ok = vm.documentAvailable(k)
                Button { vm.makeDocument(k) } label: {
                    VStack(spacing: 2) {
                        Label(k.title, systemImage: k.icon)
                            .font(.footnote.bold())
                            .lineLimit(1).minimumScaleFactor(0.75)
                        if !ok { Text("after update").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .opacity(ok ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .disabled(vm.makingDocument)
                .accessibilityLabel(ok ? "Make the \(k.title.lowercased())" : "\(k.title), available after the editor update")
            }
        }
        .padding(.horizontal)
    }
}
