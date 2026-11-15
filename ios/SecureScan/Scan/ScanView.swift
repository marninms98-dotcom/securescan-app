//
//  ScanView.swift
//  SecureScan
//
//  The classic scan: RoomPlan's RoomCaptureView with the one capture screen
//  (CaptureScreen: overlay + HUD) on top. Marking while scanning and after a
//  room is done is the same screen.
//

import SwiftUI

struct ScanView: View {
    @StateObject private var model: ScanModel
    @Environment(\.scenePhase) private var scenePhase
    private let preview: Bool

    init(job: JobMeta, preview: Bool = false, onFinished: @escaping (UUID) -> Void, onDiscarded: @escaping () -> Void) {
        self.preview = preview
        _model = StateObject(wrappedValue: ScanModel(job: job, preview: preview, onFinished: onFinished, onDiscarded: onDiscarded))
    }

    var body: some View {
        CaptureScreen(hud: model.hud) {
            if preview {
                LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            } else {
                CaptureContainer(model: model)
            }
        }
        .statusBarHidden()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { VoiceRecorder.shared.ensureRunning() }
        }
        .modifier(ScanDialogs(model: model))
    }
}

/// Stop / save / discard, and the last-resort problem alert (shared by both scan screens).
struct ScanDialogs: ViewModifier {
    @ObservedObject var model: ScanModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Stop scanning?", isPresented: $model.confirmClose, titleVisibility: .visible) {
                if model.hasAnything { Button("Save what's captured") { model.finish(now: true) } }
                Button("Discard this scan", role: .destructive) { model.discard() }
                Button("Keep scanning", role: .cancel) {}
            } message: {
                Text(model.hasAnything ? "\(model.totalCount) item\(model.totalCount == 1 ? "" : "s") and \(model.roomsDone) room\(model.roomsDone == 1 ? "" : "s") so far." : "Nothing captured yet.")
            }
            .alert("Problem", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.acknowledgeFinalAlert() } })) {
                Button("OK") { model.acknowledgeFinalAlert() }
            } message: {
                Text(model.alert ?? "")
            }
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
