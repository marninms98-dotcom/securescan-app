//
//  LiveScanView.swift
//  SecureScan
//
//  "Scan and mark together (new)": the room is scanned and marked up on one
//  screen. Everything you need is in the bottom third: the tool strip
//  (Inspect: Reading · Moisture · Photo · Source; Scope: Equipment · Wall
//  removal · Floor removal · Photo), one big button that says what a tap
//  does (or why it can't), the Undo chip, Notes, Room done and Finish.
//  The reticle says what it is on before you tap. Items are saved by the
//  same ScanModel as the classic screen (readings-raw.json at every save).
//

import SwiftUI
import simd
import Combine
import RoomPlan

struct LiveScanView: View {
    @StateObject private var model: ScanModel
    @StateObject private var live = LiveScanState()
    @ObservedObject private var recorder = VoiceRecorder.shared
    @State private var work: WorkMode = .inspect
    @State private var tool: MarkupMode = .reading
    @State private var wallItem = "plasterboard"
    @State private var confirmCancel = false
    @State private var captionFor: String?
    /// Bumped when the removal flow changes (it is a separate ObservableObject).
    @State private var flowTick = 0
    let onClassic: () -> Void
    @State private var confirmClassic = false

    init(job: JobMeta, onFinished: @escaping (UUID) -> Void, onDiscarded: @escaping () -> Void, onClassic: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ScanModel(job: job, onFinished: onFinished, onDiscarded: onDiscarded))
        self.onClassic = onClassic
    }

    var body: some View {
        if RoomCaptureSession.isSupported {
            scanBody
        } else {
            // The same gate as the classic scan: RoomPlan needs a LiDAR device.
            VStack(spacing: 16) {
                Label("Scanning needs a LiDAR iPhone", systemImage: "exclamationmark.triangle").font(.title3.bold())
                Text("This device can't run a LiDAR room scan (it needs an iPhone or iPad Pro with LiDAR).")
                    .multilineTextAlignment(.center)
                Button("Close") { model.discard() }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    /// The classic scan has its own camera session: items logged here could
    /// not be placed there, so they are removed (after asking), never moved silently.
    private func requestClassic() {
        if model.totalCount == 0 { onClassic() } else { confirmClassic = true }
    }

    private var scanBody: some View {
        ZStack {
            LiveScanContainer(model: model, live: live).ignoresSafeArea()
            Crosshair()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            // What the reticle is on, just under it.
            if !live.reticle.isEmpty {
                Text(live.reticle)
                    .font(.footnote.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: 46)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 10) {
                topInfo
                Spacer()
                bottom
            }
            .padding()
            if case .finishing(let text) = model.phase {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(text).font(.title3.bold()).foregroundStyle(.white)
                }
            }
        }
        .statusBarHidden()
        .onReceive(model.flow.objectWillChange) { _ in flowTick &+= 1 }
        .sheet(item: $model.pending) { _ in LogSheet(model: model) }
        .background(Color.clear.sheet(isPresented: Binding(get: { model.flow.showWallDetails }, set: { model.flow.showWallDetails = $0 })) {
            RemovalDetailsSheet(item: model.flow.item, lengthText: model.flow.lengthText,
                                suggestedMm: live.floorY.flatMap { fy in model.flow.end?.hit.flatMap { HeightSnap.suggested(endHeightMetres: Double($0.y) - fy) } },
                                onSave: { item, mm, note in model.saveRemoval(item: item, heightMm: mm, note: note, floorType: nil, underlay: false) },
                                onCancel: { model.flow.cancel() })
        })
        .background(Color.clear.sheet(isPresented: Binding(get: { model.flow.showFloorDetails }, set: { model.flow.showFloorDetails = $0 })) {
            FloorDetailsSheet(summary: model.flow.wholeRoom ? "Whole room" : "\(model.flow.cornerCount) corners",
                              onSave: { t, u, note in model.saveRemoval(item: "flooring", heightMm: 0, note: note, floorType: t, underlay: u) },
                              onCancel: { model.flow.cancel() })
        })
        .background(Color.clear.sheet(isPresented: $model.showItems) { LoggedItemsView(model: model) })
        .background(Color.clear.sheet(item: Binding(get: { captionFor.map { CaptionTarget(id: $0) } }, set: { captionFor = $0?.id })) { t in
            CaptionSheet { text in
                model.updateRaw(t.id) { $0.note = text }
                captionFor = nil
            }
        })
        .confirmationDialog("Switch to the classic scan?", isPresented: $confirmClassic, titleVisibility: .visible) {
            Button("Remove \(model.totalCount) item\(model.totalCount == 1 ? "" : "s") and switch", role: .destructive) {
                for r in model.loggedItems { model.delete(r.id) }
                onClassic()
            }
            Button("Stay here", role: .cancel) {}
        } message: {
            Text("The \(model.totalCount) item\(model.totalCount == 1 ? "" : "s") logged here were placed with this screen's camera. The classic scan starts its own camera session, so they can't be placed there reliably. They will be removed and need marking again in the classic scan.")
        }
        .confirmationDialog("Stop scanning?", isPresented: $confirmCancel, titleVisibility: .visible) {
            if model.hasAnything { Button("Save what's captured") { model.finish(now: true) } }
            Button("Discard this scan", role: .destructive) { model.discard() }
            Button("Keep scanning", role: .cancel) {}
        }
        .alert("Problem", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.acknowledgeFinalAlert() } })) {
            Button("OK") { model.acknowledgeFinalAlert() }
        } message: { Text(model.alert ?? "") }
    }

    // MARK: Top: information only (nothing essential up here)

    private var topInfo: some View {
        VStack(spacing: 8) {
            HStack {
                Button { confirmCancel = true } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Stop scanning")
                Spacer()
                Text(roomLabel).font(.headline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            if let c = live.coaching {
                Text(c).font(.callout.bold()).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9), in: Capsule()).foregroundStyle(.white)
            }
            if live.stalled {
                VStack(spacing: 8) {
                    // The classic scan starts a new ScanModel and a new AR session: only
                    // before a room is saved (it would overwrite rooms/1.json, in another world frame).
                    Text(model.roomsDone == 0
                         ? "No walls found yet. Keep moving slowly round the room, or go back to the classic scan (everything logged is kept)."
                         : "No walls found yet. Keep moving slowly round the room.")
                        .font(.callout).multilineTextAlignment(.center)
                    if model.roomsDone == 0 {
                        Button("Use the classic scan") { requestClassic() }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if case .roomFailed(let msg) = model.phase {
                VStack(spacing: 8) {
                    Text(msg).font(.callout).multilineTextAlignment(.center)
                    HStack {
                        Button("Scan this room again") { model.retryRoom() }.buttonStyle(.borderedProminent)
                        if model.roomsDone == 0 {
                            Button("Classic scan") { requestClassic() }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var roomLabel: String {
        switch model.phase {
        case .processingRoom: return "Saving room \(model.currentRoomNumber)…"
        case .roomDone: return "Room \(model.roomsDone) saved"
        default: return "Room \(model.currentRoomNumber) · \(model.totalCount) item\(model.totalCount == 1 ? "" : "s")"
        }
    }

    // MARK: Bottom third: everything you touch

    @ViewBuilder private var bottom: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: 0).id(flowTick)
            if let t = model.toast {
                HStack(spacing: 10) {
                    Text(t).font(.subheadline.bold()).lineLimit(2)
                    if t.hasPrefix("Photo"), let id = model.loggedItems.first?.id {
                        Button("Add caption") { captionFor = id }.font(.subheadline.bold())
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
            }
            if let p = live.preview {
                Text(p).font(.title3.bold()).monospacedDigit()
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            if model.flow.mode != .idle {
                CaptureFlowBar(flow: model.flow, onEndHere: { model.endHere() }, onCorner: { model.addCorner() })
            } else if model.phase == .roomDone {
                roomDoneCard
            } else {
                controls
            }
        }
    }

    private var roomDoneCard: some View {
        VStack(spacing: 12) {
            Text("Room \(model.roomsDone) saved").font(.title3.bold())
            HStack(spacing: 12) {
                Button { model.scanNextRoom() } label: {
                    Text("Scan next room").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                Button { model.finish(now: true) } label: {
                    Text("Finish").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
        }
        .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    // Split into small pieces: as one expression the type checker gave up on it.
    private var controls: some View {
        VStack(spacing: 12) {
            modeRow
            toolRow
            wallRemovalExtras
            mainButton
            bottomRow
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var modeRow: some View {
        HStack(spacing: 12) {
            modePicker
            undoButton
        }
    }

    private var quoteLabel: String { PriceLock.pricesVisible ? "Quote" : "Scope" }

    private var modePicker: some View {
        Picker("Mode", selection: $work) {
            Text("Inspect").tag(WorkMode.inspect)
            Text(quoteLabel).tag(WorkMode.quote)
        }
        .pickerStyle(.segmented)
        .onChange(of: work) { _, newValue in workChanged(newValue) }
        .onChange(of: tool) { _, newValue in toolChanged(newValue) }
    }

    private func workChanged(_ w: WorkMode) {
        if !w.tools.contains(tool) { tool = w.tools.first ?? .reading }
    }

    private func toolChanged(_ t: MarkupMode) {
        live.snapEnds = (t == .wallRemoval || t == .moisture)
    }

    private func undoTapped() {
        model.undoLast()
        live.undoUsed()
    }

    @ViewBuilder private var undoButton: some View {
        if live.undoVisible && model.totalCount > 0 {
            Button(action: undoTapped) {
                Label("Undo", systemImage: "arrow.uturn.backward").font(.subheadline.bold())
                    .frame(minWidth: 88, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    private var toolRow: some View {
        HStack(spacing: 12) {
            ForEach(work.tools) { t in
                toolButton(t)
            }
        }
    }

    private func toolButton(_ t: MarkupMode) -> some View {
        let on: Bool = (tool == t)
        let fg: Color = on ? Color.white : Color.primary
        let bg: Color = on ? Color.accentColor : Color.clear
        return Button(action: { tool = t }) {
            VStack(spacing: 3) {
                Image(systemName: t.icon).font(.body.weight(.semibold))
                Text(t.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 10).fill(bg))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.title)
    }

    @ViewBuilder private var wallRemovalExtras: some View {
        if tool == .wallRemoval && live.onWall {
            Button(action: wholeWall) {
                Label("Whole wall", systemImage: "arrow.left.and.right").font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canLog || model.phase != .scanning)
        }
        if tool == .wallRemoval {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(["plasterboard", "skirting", "cabinetry", "other"], id: \.self) { k in
                        Chip(title: RemovalItems.name(k), selected: wallItem == k) { wallItem = k }
                    }
                }
            }
        }
    }

    private var mainButton: some View {
        Button(action: act) {
            Text(buttonTitle).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 68)
        }
        .buttonStyle(.borderedProminent)
        .disabled(blockedReason != nil || !model.canLog || model.phase != .scanning)
    }

    private var bottomRow: some View {
        HStack(spacing: 12) {
            RecordToggle(recorder: recorder, compact: false) { model.toggleRecording() }
            Button { model.showItems = true } label: {
                Label("\(model.totalCount)", systemImage: "list.bullet").font(.headline).frame(minWidth: 64, minHeight: 64)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(model.totalCount) items. Show list")
            Button { model.nextRoom() } label: {
                Text("Room done").font(.headline).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
            .disabled(model.phase != .scanning)
        }
    }

    /// "Whole wall": a strip-out from end to end of the live wall under the
    /// reticle (both ends stored as world points; processing snaps them).
    private func wholeWall() {
        guard let ends = live.wallEnds, let y = live.reticleY else { return }
        let (a, b) = WallEndSnap.wholeWall(a: ends.0, b: ends.1, y: y)
        model.beginLog()
        guard let p = model.pending else { return }
        let cam = WorldVec(Double(p.capture.cameraPosition.x), Double(p.capture.cameraPosition.y), Double(p.capture.cameraPosition.z))
        func aimed(_ c: FrameCapture, at e: WorldVec) -> FrameCapture {
            var out = c
            out.hit = SIMD3<Float>(e)
            if simd_length(e - cam) > 1e-6 { out.cameraForward = SIMD3<Float>(simd_normalize(e - cam)) }
            return out
        }
        model.pending = PendingLog(id: p.id, seq: p.seq, roomIndex: p.roomIndex, takenAt: p.takenAt,
                                   capture: aimed(p.capture, at: a), photoTask: p.photoTask)
        model.startRemoval(item: wallItem)
        var end = aimed(p.capture, at: b)
        end.image = nil
        model.flow.setEnd(end)
    }

    private var blockedReason: String? {
        tool == .photo ? nil : live.blocked
    }

    private var buttonTitle: String {
        if let why = blockedReason { return why }
        switch tool {
        case .reading: return "Log reading"
        case .moisture: return "Add moisture-line point"
        case .photo: return "Take photo"
        case .source: return "Mark source here"
        case .equipment: return "Place \(PlanDocument.equipmentName(model.lastEquipmentType).lowercased())"
        case .wallRemoval: return "Start \(RemovalItems.name(wallItem).lowercased()) removal here"
        case .floorRemoval: return "Floor removal: first corner"
        default: return "Log"
        }
    }

    /// One tap. Readings and the sheet types open straight on their form;
    /// moisture points and photos save at once.
    private func act() {
        switch tool {
        case .reading:
            if let m = live.suggestedMaterial {
                model.lastMaterial = m
            } else if !["wall", "skirting"].contains(model.lastMaterial) {
                model.lastMaterial = live.lastWallMaterial
            }
            if ["wall", "skirting"].contains(model.lastMaterial) { live.lastWallMaterial = model.lastMaterial }
            model.lastKind = "reading"
            model.beginLog()
        case .moisture:
            model.beginLog()
            model.saveLog(kind: "boundary", value: nil, material: "wall", reference: false, note: "")
        case .photo:
            model.beginLog()
            model.saveLog(kind: "photo", value: nil, material: "wall", reference: false, note: "")
        case .source:
            model.lastKind = "source"
            model.beginLog()
        case .equipment:
            model.lastKind = "equipment"
            model.beginLog()
        case .wallRemoval:
            model.beginLog()
            model.startRemoval(item: wallItem)
        case .floorRemoval:
            model.beginLog()
            model.startRemoval(item: "flooring")
            model.addCorner()
        default:
            model.beginLog()
        }
    }
}

private struct CaptionTarget: Identifiable { let id: String }

/// "Add caption" after a one-tap photo.
private struct CaptionSheet: View {
    let onSave: (String) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                FlowChips(items: ["Overview", "Inspection opening", "Damage", "Source", "Other"]) { onSave($0) }
                TextField("Or type a caption", text: $text).textFieldStyle(.roundedBorder).submitLabel(.done)
                    .onSubmit { onSave(text) }
                Spacer()
            }
            .padding()
            .navigationTitle("Photo caption").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(text) } } }
        }
        .presentationDetents([.medium])
    }
}

struct LiveScanContainer: UIViewControllerRepresentable {
    let model: ScanModel
    let live: LiveScanState

    func makeUIViewController(context: Context) -> LiveScanViewController {
        let vc = LiveScanViewController()
        vc.model = model
        vc.live = live
        model.controller = vc
        return vc
    }

    func updateUIViewController(_ vc: LiveScanViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: LiveScanViewController, coordinator: ()) {
        vc.shutdown()
    }
}
