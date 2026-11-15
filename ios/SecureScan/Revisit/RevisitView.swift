//
//  RevisitView.swift
//  SecureScan
//
//  Return visit and "See scope on site": a short light entry screen (which
//  room, corners A and B on a mini plan, Start), then the camera with the one
//  capture screen. The list fallback for the scope when the camera can't
//  line up.
//

import SwiftUI
import AVFoundation
import ARKit

struct RevisitView: View {
    @StateObject private var model: RevisitModel
    @State private var running = false
    @State private var problem: String?
    @State private var showList = false
    let onClose: () -> Void
    let onPlanInstead: () -> Void
    private let scope: Bool

    /// `scope`: "See scope on site", else the return visit.
    init(folder: JobFolder, scope: Bool = false, onClose: @escaping () -> Void, onPlanInstead: @escaping () -> Void) {
        _model = StateObject(wrappedValue: RevisitModel(folder: folder, purpose: scope ? .scope : .markup))
        self.scope = scope
        self.onClose = onClose
        self.onPlanInstead = onPlanInstead
    }

    var body: some View {
        Group {
            if running {
                RevisitARScreen(model: model, onClose: onClose)
            } else {
                entry
            }
        }
        .fullScreenCover(isPresented: $showList) {
            ScopeListView(model: model, onClose: { showList = false })
        }
        .alert("Return visit", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private var supported: Bool { RevisitARViewController.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    private var entry: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.margin) {
                    Text(scope ? "See what goes where, then mark it placed or done." : "Find your saved points and re-measure them.")
                        .font(DS.Font.body).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: DS.Space.gap) {
                        Text("Tap the room you're in").font(DS.Font.bodyBold)
                        MiniPlanView(model: model, interactive: true, focus: model.picking)
                            .frame(height: 300)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color(.tertiarySystemFill)))
                        HStack(spacing: DS.Space.tight) {
                            Chip("Change corner A", selected: model.picking == 0) { model.picking = 0 }
                            Chip("Change corner B", selected: model.picking == 1) { model.picking = 1 }
                        }
                        if model.hasWorldMap {
                            Label("The app will try to recognise the room by itself first", systemImage: "sparkles")
                                .font(DS.Font.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(DS.Space.margin)
                    .dsCard(.light)
                    if !supported {
                        Label("This iPhone has no LiDAR — use the plan instead", systemImage: "exclamationmark.triangle")
                            .font(DS.Font.callout).foregroundStyle(DS.Color.damp)
                    }
                }
                .padding(DS.Space.margin)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DS.Space.tight) {
                    PrimaryButton("Start", icon: "viewfinder", enabled: supported && model.cornerIdx.count >= 2, action: start)
                    if scope {
                        SecondaryButton("Use the list instead") {
                            guard model.beginVisit() else { problem = "The plan couldn't be updated for this visit."; return }
                            model.refreshMarkers()
                            showList = true
                        }
                    } else {
                        SecondaryButton("Re-measure on the plan", action: onPlanInstead)
                    }
                }
                .padding(.horizontal, DS.Space.margin)
                .padding(.bottom, DS.Space.tight)
                .padding(.top, DS.Space.tight)
                .background(.bar)
            }
            .navigationTitle(scope ? "See scope on site" : "Return visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
    }

    private func start() {
        let cameraOff = "SecureScan can't use the camera. Turn it on in Settings › SecureScan › Camera."
        let go = {
            guard model.beginVisit() else { problem = "The plan couldn't be updated for this visit."; return }
            running = true
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: go()
        case .notDetermined:
            Task { if await AVCaptureDevice.requestAccess(for: .video) { go() } else { problem = cameraOff } }
        default: problem = cameraOff
        }
    }
}

/// The camera and the one capture screen.
struct RevisitARScreen: View {
    @ObservedObject var model: RevisitModel
    let onClose: () -> Void

    var body: some View {
        CaptureScreen(hud: model.hud) {
            RevisitCameraContainer(model: model)
        }
        .statusBarHidden()
        .onAppear { model.onClose = onClose }
        .alert("Return visit", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }
}

/// The saved plan drawn small: rooms (the chosen one highlighted), walls, and
/// corners A / B (C). Tapping picks a room or a corner.
struct MiniPlanView: View {
    @ObservedObject var model: RevisitModel
    var interactive: Bool
    /// Which corner to emphasise (the one being set), nil = none.
    var focus: Int? = nil
    @Environment(\.dsSurface) private var surface

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(points: model.walls.flatMap { [$0.a, $0.b] } + model.rooms.flatMap { $0 }, size: geo.size,
                          pad: geo.size.width < 200 ? 12 : 22)
            let line: Color = surface == .camera ? .white.opacity(0.85) : DS.Color.grey(7)
            Canvas { ctx, _ in
                for (i, poly) in model.rooms.enumerated() where poly.count >= 3 {
                    var path = Path()
                    path.addLines(poly.map(fit.point))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(i == model.roomIndex ? DS.Color.accent.opacity(0.22) : Color.gray.opacity(0.10)))
                }
                for w in model.walls {
                    var path = Path()
                    path.move(to: fit.point(w.a))
                    path.addLine(to: fit.point(w.b))
                    ctx.stroke(path, with: .color(line), lineWidth: geo.size.width < 200 ? 2 : 3)
                }
                for (k, c) in model.cornerPoints.enumerated() {
                    let p = fit.point(c)
                    let r: CGFloat = geo.size.width < 200 ? (focus == k ? 10 : 8) : (focus == k ? 16 : 13)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(focus == k ? DS.Color.accent : DS.Color.grey(6)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(.white), lineWidth: 2)
                    ctx.draw(Text(model.cornerNames[k]).font(DS.Font.captionBold).foregroundColor(.white), at: p)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { e in
                guard interactive else { return }
                model.tapPlan(fit.plan(e.location))
            })
        }
        .accessibilityLabel("Plan of the job with the corners to point at")
    }

    struct Fit {
        var minX = 0.0, minY = 0.0, scale = 1.0, ox = 0.0, oy = 0.0
        init(points: [PlanVec], size: CGSize, pad: Double = 22) {
            guard let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
                  let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return }
            let w = max(x1 - x0, 0.5), h = max(y1 - y0, 0.5)
            scale = min((Double(size.width) - 2 * pad) / w, (Double(size.height) - 2 * pad) / h)
            minX = x0; minY = y0
            ox = (Double(size.width) - w * scale) / 2
            oy = (Double(size.height) - h * scale) / 2
        }
        func point(_ p: PlanVec) -> CGPoint { CGPoint(x: ox + (p.x - minX) * scale, y: oy + (p.y - minY) * scale) }
        func plan(_ p: CGPoint) -> PlanVec { PlanVec((Double(p.x) - ox) / scale + minX, (Double(p.y) - oy) / scale + minY) }
    }
}

/// The scope as a list, when the camera can't line up: mark placed / done without a photo.
struct ScopeListView: View {
    @ObservedObject var model: RevisitModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MiniPlanView(model: model, interactive: false).frame(height: 220)
                }
                Section("Scope of works") {
                    if model.scopeItems.isEmpty { Text("Nothing scoped yet").foregroundStyle(.secondary) }
                    ForEach(model.scopeItems) { it in
                        HStack(spacing: DS.Space.gap) {
                            Image(systemName: it.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20)).foregroundStyle(it.done ? DS.Color.dry : Color.secondary)
                            Text(it.title).font(DS.Font.callout)
                            Spacer()
                            if !it.done {
                                Chip(it.kind == .equipment ? "Placed" : "Done") { model.markFromList(it) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scope of works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
    }
}

struct RevisitCameraContainer: UIViewControllerRepresentable {
    let model: RevisitModel

    func makeUIViewController(context: Context) -> RevisitARViewController {
        let vc = RevisitARViewController()
        vc.model = model
        model.controller = vc
        return vc
    }

    func updateUIViewController(_ vc: RevisitARViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: RevisitARViewController, coordinator: ()) {
        vc.detach()
    }
}
