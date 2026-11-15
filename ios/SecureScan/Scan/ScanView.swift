//
//  ScanView.swift
//  SecureScan
//
//  Full-screen RoomCaptureView with: room counter, one item counter (opens
//  the list of logged items), Undo last, centre crosshair, Notes (voice),
//  Log, Next room, Finish, Cancel (with confirm), toast, the removal /
//  floor-corner bar, and progress states.
//

import SwiftUI

struct ScanView: View {
    @StateObject private var model: ScanModel
    @ObservedObject private var recorder = VoiceRecorder.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmCancel = false
    private let preview: Bool

    init(job: JobMeta, preview: Bool = false, onFinished: @escaping (UUID) -> Void, onDiscarded: @escaping () -> Void) {
        self.preview = preview
        _model = StateObject(wrappedValue: ScanModel(job: job, preview: preview, onFinished: onFinished, onDiscarded: onDiscarded))
    }

    var body: some View {
        ZStack {
            if preview {
                LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .onAppear {
                        let p = ProcessInfo.processInfo.environment["SECURESCAN_PREVIEW"]
                        if p == "scan-removal" { model.previewRemovalBar() }
                        if p == "scan-log" { model.previewLogSheet() }
                        if p == "scan-choice" { model.previewRoomDone() }
                    }
            } else {
                CaptureContainer(model: model).ignoresSafeArea()
            }

            // Centred on the full screen (not the safe area) = the raycast point.
            Crosshair()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScanOverlay(model: model, flow: model.flow, recorder: recorder, confirmCancel: $confirmCancel)

            // The AR mark-up of the rooms so far, over the (kept-alive) RoomCaptureView.
            if let m = model.markup {
                RevisitARScreen(model: m, flow: m.flow, onClose: { model.closeMarkup() })
                    .transition(.opacity)
            }

            if case .finishing(let text) = model.phase {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(text).font(.title3.bold()).foregroundStyle(.white)
                    Text("Keep the app open — this can take a little while for several rooms.")
                        .font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                }
                .padding(32)
            }
        }
        .statusBarHidden()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.ensureRunning() }
        }
        .sheet(item: $model.pending) { _ in LogSheet(model: model) }
        .confirmationDialog("Stop scanning?", isPresented: $confirmCancel, titleVisibility: .visible) {
            if model.hasAnything {
                Button("Save what's captured") { model.finish(now: true) }
            }
            Button("Discard this scan", role: .destructive) { model.discard() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text(model.hasAnything
                 ? (model.hasAudio ? "Rooms, readings and voice notes captured so far can be saved. Discarding deletes them, including the recordings."
                                   : "Rooms and readings captured so far can be saved.")
                 : "Nothing has been saved yet.")
        }
        .alert("Problem", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.acknowledgeFinalAlert() } })) {
            Button("OK") { model.acknowledgeFinalAlert() }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

/// Everything drawn over the camera (a separate view so each sheet has its own anchor).
private struct ScanOverlay: View {
    @ObservedObject var model: ScanModel
    @ObservedObject var flow: CaptureFlow
    @ObservedObject var recorder: VoiceRecorder
    @Binding var confirmCancel: Bool

    var body: some View {
        VStack(spacing: 12) {
            topBar
            if let toast = model.toast {
                Text(toast)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if case .roomFailed(let msg) = model.phase { failedBanner(msg) }
            Spacer()
            if flow.mode != .idle {
                CaptureFlowBar(flow: flow, onEndHere: { model.endHere() }, onCorner: { model.addCorner() })
            } else if model.phase == .roomDone {
                choiceCard
            } else if model.phase == .preparingMarkup {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Drawing the plan of the rooms so far…").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else {
                bottomBar
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .sheet(isPresented: $flow.showWallDetails, onDismiss: { if flow.showWallDetails == false && flow.mode == .idle { flow.cancel() } }) {
            RemovalDetailsSheet(item: flow.item, lengthText: flow.lengthText,
                                onSave: { item, mm, note in model.saveRemoval(item: item, heightMm: mm, note: note, floorType: nil, underlay: false) },
                                onCancel: { flow.cancel() })
        }
        .background(
            Color.clear.sheet(isPresented: $flow.showFloorDetails) {
                FloorDetailsSheet(summary: flow.wholeRoom ? "Whole room" : "\(flow.cornerCount) corners",
                                  onSave: { type, underlay, note in
                                      model.saveRemoval(item: "flooring", heightMm: 0, note: note, floorType: type, underlay: underlay)
                                  },
                                  onCancel: { flow.cancel() })
            }
        )
        .overlay(
            Color.clear.sheet(isPresented: $model.showItems) { LoggedItemsView(model: model) }
                .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button { confirmCancel = true } label: {
                    Image(systemName: "xmark")
                        .font(.title2.bold())
                        .frame(width: 48, height: 48)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Cancel scan")
                Spacer()
                Text(roomLabel)
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                Spacer()
                Button { model.showItems = true } label: {
                    Label("\(model.totalCount) item\(model.totalCount == 1 ? "" : "s")", systemImage: "list.bullet")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.totalCount) logged items. Show list")
            }
            if model.totalCount > 0 && flow.mode == .idle {
                HStack {
                    Spacer()
                    Button { model.undoLast() } label: {
                        Label("Undo last", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var roomLabel: String {
        switch model.phase {
        case .processingRoom: return "Saving room \(model.currentRoomNumber)…"
        case .roomDone, .preparingMarkup: return "Room \(model.roomsDone) saved"
        default: return "Room \(model.currentRoomNumber) · \(model.roomsDone) done"
        }
    }

    private func failedBanner(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Text(msg).font(.callout).multilineTextAlignment(.center)
            Button("Scan this room again") { model.retryRoom() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// After each room: mark it up in AR now (primary), or move on.
    private var choiceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Room \(model.roomsDone) saved").font(.title3.bold())
            Text("Mark it up while you're standing in it: readings, the moisture line, equipment and removals go straight onto its walls and floor.")
                .font(.callout)
            Button { model.markUp() } label: {
                Label("Mark up this room", systemImage: "hand.point.up.left.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            HStack(spacing: 12) {
                Button { model.scanNextRoom() } label: {
                    Text("Scan next room").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.bordered)
                Button { model.finish(now: true) } label: {
                    Text("Finish").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RecordToggle(recorder: recorder, compact: false) { model.toggleRecording() }
                    .disabled(isFinishing)
                Button { model.beginLog() } label: {
                    Label("Log", systemImage: "drop.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!model.canLog)
            }

            HStack(spacing: 12) {
                Button { model.nextRoom() } label: {
                    Text("Room done")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .disabled(model.phase != .scanning)

                Button { model.finish() } label: {
                    Text("Finish")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isFinishing)
            }
        }
    }

    private var isFinishing: Bool {
        if case .finishing = model.phase { return true }
        return false
    }
}

/// The list of everything logged in this scan, newest first, with delete.
struct LoggedItemsView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.loggedItems.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                }
                ForEach(model.loggedItems, id: \.id) { r in
                    let d = model.describe(r)
                    HStack {
                        Image(systemName: LogKind(rawValue: r.kind)?.icon ?? "square.grid.2x2")
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.title).font(.headline)
                            if !d.detail.isEmpty { Text(d.detail).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(Self.time(r.takenAt)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.delete(r.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("\(model.totalCount) logged item\(model.totalCount == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static func time(_ iso: String) -> String {
        guard let d = ISOTime.date(iso) else { return "" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}

/// Voice-note record toggle with a red dot and the elapsed time while recording.
struct RecordToggle: View {
    @ObservedObject var recorder: VoiceRecorder
    var compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if recorder.isRecording, let start = recorder.startedAt {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(Self.elapsed(ctx.date.timeIntervalSince(start)))
                                .monospacedDigit()
                        }
                        Image(systemName: "stop.fill")
                    }
                } else {
                    Label(compact ? "Record note" : "Notes", systemImage: "mic.fill")
                }
            }
            .font(compact ? .headline : .title3.bold())
            .frame(minWidth: compact ? nil : 104, minHeight: compact ? 32 : 64)
            .padding(.horizontal, compact ? 0 : 8)
        }
        .buttonStyle(.bordered)
        .tint(recorder.isRecording ? .red : .primary)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(recorder.isRecording ? "Stop recording voice note" : "Record voice note")
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 2).frame(width: 34, height: 34)
            Rectangle().fill(Color.white).frame(width: 2, height: 14)
            Rectangle().fill(Color.white).frame(width: 14, height: 2)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}

struct CaptureContainer: UIViewControllerRepresentable {
    let model: ScanModel

    func makeUIViewController(context: Context) -> ScanViewController {
        let vc = ScanViewController()
        vc.model = model
        model.controller = vc
        return vc
    }

    func updateUIViewController(_ vc: ScanViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: ScanViewController, coordinator: ()) {
        vc.shutdown()
    }
}
