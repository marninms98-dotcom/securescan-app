//
//  LiveScanView.swift
//  SecureScan
//
//  "Scan and mark together": the room is scanned on our own ARSCNView and
//  marked on the same one capture screen as the classic scan (same HUD, same
//  overlay, same ScanModel). If no walls are found a while into the first
//  room, a quiet button offers the classic scan.
//

import SwiftUI
import RoomPlan

struct LiveScanView: View {
    @StateObject private var model: ScanModel
    @State private var stalled = false
    @State private var confirmClassic = false
    let onClassic: () -> Void

    init(job: JobMeta, onFinished: @escaping (UUID) -> Void, onDiscarded: @escaping () -> Void, onClassic: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ScanModel(job: job, onFinished: onFinished, onDiscarded: onDiscarded))
        self.onClassic = onClassic
    }

    var body: some View {
        if RoomCaptureSession.isSupported {
            scanBody
        } else {
            VStack(spacing: DS.Space.margin) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36, weight: .semibold)).foregroundStyle(DS.Color.damp)
                Text("Scanning needs a LiDAR iPhone").font(DS.Font.headline)
                PrimaryButton("Close") { model.discard() }
            }
            .padding(DS.Space.margin)
        }
    }

    private var scanBody: some View {
        CaptureScreen(hud: model.hud) {
            ZStack(alignment: .bottom) {
                LiveScanContainer(model: model, onStalled: { s in if stalled != s { stalled = s } })
                if stalled && model.roomsDone == 0 {
                    SecondaryButton("No walls yet — use the classic scan", icon: "arrow.uturn.left") { requestClassic() }
                        .dsSurface(.camera)
                        .padding(.bottom, 120)
                }
            }
        }
        .statusBarHidden()
        .modifier(ScanDialogs(model: model))
        .confirmationDialog("Switch to the classic scan?", isPresented: $confirmClassic, titleVisibility: .visible) {
            Button("Remove \(model.totalCount) item\(model.totalCount == 1 ? "" : "s") and switch", role: .destructive) {
                for r in model.loggedItems { model.delete(r.id) }
                onClassic()
            }
            Button("Stay here", role: .cancel) {}
        } message: {
            Text("Items marked here can't be carried over to the classic scan's camera.")
        }
    }

    /// The classic scan has its own camera session: items marked here could
    /// not be placed there, so they are removed (after asking), never moved silently.
    private func requestClassic() {
        if model.totalCount == 0 { onClassic() } else { confirmClassic = true }
    }
}

struct LiveScanContainer: UIViewControllerRepresentable {
    let model: ScanModel
    let onStalled: (Bool) -> Void

    func makeUIViewController(context: Context) -> LiveScanViewController {
        let vc = LiveScanViewController()
        vc.model = model
        vc.onStalled = onStalled
        model.controller = vc
        return vc
    }

    func updateUIViewController(_ vc: LiveScanViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: LiveScanViewController, coordinator: ()) {
        vc.shutdown()
    }
}
