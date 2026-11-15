//
//  JobView.swift
//  SecureScan
//
//  Job screen: Plan (web editor) · 3D · Items · Files, one bottom dock
//  (state-dependent primary action, Documents, mic). docs/UX2.md.
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
    /// A problem making a document, shown as an alert on the job screen.
    @Published var alertText: String?
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
                alertText = "The plan didn't load, so the \(k.title.lowercased()) couldn't be made. Try again."
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

/// The job screen's sections.
enum JobTab: Int, CaseIterable, Identifiable {
    case plan, model, items, files
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .plan: return "Plan"
        case .model: return "3D"
        case .items: return "Items"
        case .files: return "Files"
        }
    }

    /// SECURESCAN_TAB (automated screenshots): 0-3 or plan / 3d / items / files.
    static func fromEnvironment() -> JobTab {
        let v = (ProcessInfo.processInfo.environment["SECURESCAN_TAB"] ?? "").lowercased()
        if let n = Int(v), let t = JobTab(rawValue: n) { return t }
        return JobTab.allCases.first { $0.title.lowercased() == v } ?? .plan
    }
}

extension JobViewModel {
    /// Job pack, through the editor's own pack builder (it sends `exportPack`).
    func makeJobPack() {
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
                alertText = "The plan didn't load, so the job pack couldn't be made. Try again."
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !(await editor.startJobPack()) {
                alertText = "This version of the plan editor can't make the job pack from here. Use Export on the plan."
            }
        }
    }

    /// The one primary action of the job screen.
    enum DockAction: Equatable {
        case scope(done: Int, total: Int)
        case continueOnSite
        case nextVisit(Int)
        case documentsOnly
    }

    var dockAction: DockAction {
        let scope = hasPlan && scopeTotal > 0
        if scope && scopeDone < scopeTotal { return .scope(done: scopeDone, total: scopeTotal) }
        if canReturnVisit {
            let n = visitInfo?.n ?? 1
            let started = meta?.createdAt ?? Date()
            return Calendar.current.isDateInToday(started) && n == 1 ? .continueOnSite : .nextVisit(n + 1)
        }
        if scope { return .scope(done: scopeDone, total: scopeTotal) }
        return .documentsOnly
    }
}

struct JobView: View {
    @StateObject private var vm: JobViewModel
    @ObservedObject private var recorder = VoiceRecorder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = JobTab.fromEnvironment()
    @State private var showDocuments = false

    init(jobID: UUID) {
        _vm = StateObject(wrappedValue: JobViewModel(jobID: jobID))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(JobTab.allCases) { t in Text(t.title).tag(t) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)

            ZStack {
                // The editor stays loaded behind the other sections, so
                // switching back is instant and documents can always be made.
                PlanTab(vm: vm, onClose: { dismiss() })
                    .opacity(tab == .plan ? 1 : 0)
                    .allowsHitTesting(tab == .plan)
                    .accessibilityHidden(tab != .plan)
                switch tab {
                case .plan: EmptyView()
                case .model: ModelTab(vm: vm)
                case .items: ItemsTab(vm: vm)
                case .files: FilesTab(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(vm.meta?.displayAddress ?? "Job")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .onAppear {
            vm.processVoice()
            vm.refreshVisitInfo()
            let env = ProcessInfo.processInfo.environment
            if env["SECURESCAN_PREVIEW"] == "revisit" { vm.showRevisit = true }
            if env["SECURESCAN_PREVIEW"] == "documents" {
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); showDocuments = true }
            }
            if let k = env["SECURESCAN_DOCUMENT"].flatMap(DocumentKind.init(rawValue:)) {
                vm.makeDocument(k)
            }
        }
        .onChange(of: vm.planVersion) { _, _ in vm.refreshVisitInfo() }
        .onChange(of: vm.requestedTab) { _, t in
            if let t, let jt = JobTab(rawValue: t) { tab = jt; vm.requestedTab = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pricesVisibleChanged)) { _ in
            vm.pricesVisible = PriceLock.pricesVisible
        }
        .sheet(isPresented: $showDocuments) {
            DocumentsSheet(vm: vm) { choice in
                showDocuments = false
                // Let the sheet go before the share sheet is presented.
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    switch choice {
                    case .document(let k): vm.makeDocument(k)
                    case .jobPack: vm.makeJobPack()
                    }
                }
            }
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
        .alert("Documents", isPresented: Binding(get: { vm.alertText != nil }, set: { if !$0 { vm.alertText = nil } })) {
            Button("OK") { vm.alertText = nil }
        } message: {
            Text(vm.alertText ?? "")
        }
    }

    // MARK: Bottom dock

    private var dock: some View {
        HStack(spacing: 12) {
            primary
            if vm.dockAction != .documentsOnly {
                IconButton("doc.text", label: "Documents") { showDocuments = true }
                    .disabled(!vm.hasPlan || vm.makingDocument)
            }
            MicButton(recorder: recorder, folder: vm.folder, transcribing: vm.voiceStatus != nil) { vm.toggleRecordNote() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background {
            Rectangle().fill(.bar)
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch vm.dockAction {
        case .scope(let done, let total):
            PrimaryButton("See scope on site · \(done) of \(total)", icon: "arkit") { vm.openScope() }
        case .continueOnSite:
            PrimaryButton("Continue on site", icon: "viewfinder") { vm.openReturnVisit() }
        case .nextVisit(let n):
            PrimaryButton("Start visit \(n)", icon: "viewfinder") { vm.openReturnVisit() }
        case .documentsOnly:
            PrimaryButton("Documents", icon: "doc.text") { showDocuments = true }
        }
    }

    // MARK: … menu

    private var moreMenu: some View {
        Menu {
            if vm.canReturnVisit {
                Button { vm.openReturnVisit() } label: { Label("Return visit", systemImage: "viewfinder") }
            }
            if vm.visitInfo?.isReturn == true {
                Button { vm.remeasureOnPlan() } label: { Label("Re-measure on the plan", systemImage: "square.split.2x2") }
            }
            if vm.hasPlan && vm.scopeTotal > 0 {
                Button { vm.openScope() } label: { Label("See scope on site", systemImage: "arkit") }
            }
            Button { showDocuments = true } label: { Label("Documents", systemImage: "doc.text") }
                .disabled(!vm.hasPlan)
            Divider()
            Button { tab = .items } label: { Label("All items", systemImage: "list.bullet") }
            Button { tab = .files } label: { Label("Job details", systemImage: "info.circle") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }
}

/// The dock's mic: a 44 pt circle; while recording a red capsule with the time.
struct MicButton: View {
    @ObservedObject var recorder: VoiceRecorder
    let folder: JobFolder
    let transcribing: Bool
    let action: () -> Void

    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        Button(action: action) {
            if recorder.isRecordingJob(folder), let start = recorder.startedAt {
                HStack(spacing: 6) {
                    Circle().fill(DS.Color.wet).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(MicButton.elapsed(ctx.date.timeIntervalSince(start)))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                    }
                    Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(DS.Color.wet)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(DS.Color.wet.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            } else if transcribing {
                ProgressView()
                    .frame(width: DS.Size.icon, height: DS.Size.icon)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            } else {
                Image(systemName: "mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: DS.Size.icon, height: DS.Size.icon)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
                    .contentShape(Circle())
            }
        }
        .buttonStyle(DSPressStyle())
        .disabled(recorder.isRecording && !recorder.isRecordingJob(folder))
        .accessibilityLabel(recorder.isRecordingJob(folder) ? "Stop recording voice note" : "Record voice note")
    }
}

/// Documents: what this job can produce, one tap each.
struct DocumentsSheet: View {
    enum Choice { case document(DocumentKind), jobPack }

    @ObservedObject var vm: JobViewModel
    let onChoose: (Choice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Documents")
                .font(DS.Font.bodyBold)
                .padding(.top, 20)
                .padding(.bottom, 4)
            List {
                Section {
                    ForEach(vm.offeredDocuments) { k in
                        let ok = vm.documentAvailable(k)
                        row(icon: k.icon, title: k.title, caption: ok ? Self.caption(k) : "Available after the plan editor update", enabled: ok) {
                            onChoose(.document(k))
                        }
                    }
                }
                Section {
                    row(icon: "shippingbox", title: "Job pack", caption: "Plans, photos, notes and audio", enabled: true) {
                        onChoose(.jobPack)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(16)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemGroupedBackground))
        .presentationBackground(Color(.systemGroupedBackground))
        .presentationDetents([.height(vm.offeredDocuments.count > 2 ? 385 : 318)])
        .presentationDragIndicator(.visible)
    }

    static func caption(_ k: DocumentKind) -> String {
        switch k {
        case .initial: return "Readings, photos and the plan"
        case .quote: return "Priced scope of works"
        case .scope: return "What to remove and dry, no prices"
        case .monitoring: return "Drying progress across visits"
        case .final: return "Final readings and sign-off"
        }
    }

    private func row(icon: String, title: String, caption: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(enabled ? DS.Color.accent : .secondary)
                    .frame(width: 40, height: 40)
                    .background((enabled ? DS.Color.accent : Color.secondary).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Font.body.weight(.medium)).foregroundStyle(enabled ? .primary : .secondary)
                    Text(caption).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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

