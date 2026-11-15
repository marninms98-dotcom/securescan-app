//
//  RevisitView.swift
//  SecureScan
//
//  Return visit ("Find my points"): the entry screen (mini plan, room and
//  corner picker, Start / Re-measure on the plan instead) and the AR screen
//  overlay (relocalising, corner taps, alignment check, measuring).
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

    /// `scope`: "See scope on site" (view only), else the return visit / mark-up.
    init(folder: JobFolder, scope: Bool = false, onClose: @escaping () -> Void, onPlanInstead: @escaping () -> Void) {
        _model = StateObject(wrappedValue: RevisitModel(folder: folder, purpose: scope ? .scope : .markup))
        self.scope = scope
        self.onClose = onClose
        self.onPlanInstead = onPlanInstead
    }

    var body: some View {
        Group {
            if running {
                RevisitARScreen(model: model, flow: model.flow, onClose: onClose)
            } else {
                entry
            }
        }
        .fullScreenCover(isPresented: $showList) {
            ScopeListView(model: model, withoutCamera: true, onClose: { showList = false })
        }
        .alert("Return visit", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private var supported: Bool { RevisitARViewController.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    private var entry: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(scope
                         ? "See the scope of works in the room: where the equipment goes and which way it blows, and what gets stripped out. First the app lines the camera up with the saved plan."
                         : "Find your saved points through the camera and re-measure them. First the app lines the camera up with the saved plan.")
                        .font(.callout)
                    if model.hasWorldMap {
                        Label("This job has the first scan's room map, so the app will try to recognise the room by itself first.", systemImage: "sparkles")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("1. Tap the room you are standing in.\n2. Check corners A and B are corners you can see where two walls meet the floor (tap A or B below, then a corner on the plan to change it).")
                        .font(.subheadline)
                    MiniPlanView(model: model, interactive: true)
                        .frame(height: 320)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    Picker("Corner to change", selection: $model.picking) {
                        Text("Change corner A").tag(0)
                        Text("Change corner B").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if !supported {
                        Label("This iPhone can't do return visits in the camera (it needs a LiDAR scanner). Use Re-measure on the plan.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Button(action: start) {
                        Label("Start", systemImage: "viewfinder")
                            .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!supported || model.cornerIdx.count < 2)
                    if scope {
                        Button {
                            // Marking items placed / done records them in this visit, as Start does.
                            guard model.beginVisit() else { problem = "The plan couldn't be updated for this visit."; return }
                            model.refreshMarkers()
                            showList = true
                        } label: {
                            Text("Use the list instead").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: onPlanInstead) {
                            Text("Re-measure on the plan instead").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle(scope ? "See scope on site" : "Return visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) } }
        }
    }

    private func start() {
        let cameraOff = "SecureScan isn't allowed to use the camera. Turn it on in Settings › SecureScan › Camera, or use Re-measure on the plan."
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

/// The saved plan drawn small: rooms (the chosen one highlighted), walls, and
/// corners A / B (C). Tapping picks a room or a corner.
struct MiniPlanView: View {
    @ObservedObject var model: RevisitModel
    var interactive: Bool
    /// Which corner to emphasise (the one being set), nil = none.
    var focus: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(points: model.walls.flatMap { [$0.a, $0.b] } + model.rooms.flatMap { $0 }, size: geo.size)
            Canvas { ctx, _ in
                for (i, poly) in model.rooms.enumerated() where poly.count >= 3 {
                    var path = Path()
                    path.addLines(poly.map(fit.point))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(i == model.roomIndex ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.10)))
                }
                for w in model.walls {
                    var path = Path()
                    path.move(to: fit.point(w.a))
                    path.addLine(to: fit.point(w.b))
                    ctx.stroke(path, with: .color(Color(white: 0.35)), lineWidth: 3)
                }
                for c in model.room {
                    let p = fit.point(c)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.gray))
                }
                for (k, c) in model.cornerPoints.enumerated() {
                    let p = fit.point(c)
                    let r: CGFloat = focus == k ? 16 : 13
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(focus == k ? .orange : .accentColor))
                    ctx.draw(Text(model.cornerNames[k]).font(.headline.bold()).foregroundColor(.white), at: p)
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
        init(points: [PlanVec], size: CGSize) {
            guard let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
                  let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return }
            let pad = 22.0
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

struct RevisitARScreen: View {
    @ObservedObject var model: RevisitModel
    @ObservedObject var flow: CaptureFlow
    let onClose: () -> Void

    var body: some View {
        ZStack {
            RevisitCameraContainer(model: model).ignoresSafeArea()
            Crosshair()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if model.phase == .measuring, !model.reticle.isEmpty {
                Text(model.reticle)
                    .font(.footnote.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: 46)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 10) {
                topBar
                if model.phase == .measuring, flow.mode == .idle, model.moving == nil, model.purpose == .markup {
                    WorkModeBar(model: model)
                }
                if !model.tracking.isNormal, model.phase != .intro {
                    Text(model.tracking.message)
                        .font(.callout.bold())
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                if let t = model.toast {
                    Text(t).font(.headline).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                if model.phase == .measuring, let h = model.hint {
                    Text(h).font(.subheadline.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                }
                Spacer()
                card
            }
            .padding()
        }
        .statusBarHidden()
        .sheet(item: $model.pending) { _ in LogSheet(model: model) }
        .background(Color.clear.sheet(item: $model.editing) { e in MarkerEditSheet(edit: e, model: model) })
        .background(Color.clear.sheet(isPresented: $model.showItems) { MarkupItemsView(model: model) })
        .background(Color.clear.sheet(isPresented: $model.showScopeList) {
            ScopeListView(model: model, withoutCamera: model.phase != .measuring)
        })
        .background(Color.clear.sheet(item: $model.remeasure) { req in RemeasureSheet(request: req, model: model) })
        .background(Color.clear.sheet(isPresented: $flow.showWallDetails) {
            RemovalDetailsSheet(item: flow.item, lengthText: flow.lengthText, suggestedMm: model.suggestedRemovalMm,
                                onSave: { item, mm, note in model.saveRemoval(item: item, heightMm: mm, note: note, floorType: nil, underlay: false) },
                                onCancel: { flow.cancel() })
        })
        .background(Color.clear.sheet(isPresented: $flow.showFloorDetails) {
            FloorDetailsSheet(summary: flow.wholeRoom ? "Whole room" : "\(flow.cornerCount) corners",
                              onSave: { t, u, note in model.saveRemoval(item: "flooring", heightMm: 0, note: note, floorType: t, underlay: u) },
                              onCancel: { flow.cancel() })
        })
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }),
                            titleVisibility: .visible, presenting: model.confirm) { c in
            switch c {
            case .equipmentRemoved: Button("Mark removed today") { model.confirmAction(c) }
            case .removalDone: Button("Mark done and take the after photo") { model.confirmAction(c) }
            case .equipmentPlaced: Button("Mark placed") { model.confirmAction(c) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(model.firstScan ? "Mark-up" : "Return visit", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }

    private var confirmTitle: String {
        switch model.confirm {
        case .equipmentRemoved(_, let name)?: return "\(name) taken away?"
        case .removalDone?: return "Is this removal done? The current camera view is kept as the after photo."
        case .equipmentPlaced(_, let name)?: return "Is \(name) in place, set up as shown?"
        case nil: return ""
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            bar
            if model.phase == .measuring, flow.mode == .idle, model.purpose == .markup {
                HStack {
                    Button { model.showItems = true } label: {
                        Label("\(model.markers.count) item\(model.markers.count == 1 ? "" : "s")", systemImage: "list.bullet")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if model.undoCount > 0 {
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
    }

    private var bar: some View {
        HStack {
            if model.firstScan {
                Button(action: onClose) {
                    Label("Done", systemImage: "checkmark").font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(.thinMaterial, in: Capsule())
                }
                .disabled(model.sweeping || flow.isBusy)
                .accessibilityLabel("Done marking up this room")
            } else {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.title2.bold()).frame(width: 48, height: 48)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Close return visit")
            }
            Spacer()
            Text(model.visitLabel.isEmpty ? "Return visit" : model.visitLabel)
                .font(.headline)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
            Spacer()
            if (model.phase == .measuring || model.phase == .check) && model.sharedSession == nil {
                Button("Realign") { model.realign() }
                    .font(.headline)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder private var card: some View {
        switch model.phase {
        case .intro:
            EmptyView()
        case .relocalizing:
            VStack(spacing: 10) {
                HStack { ProgressView(); Text("Recognising the room from the first scan… move the phone slowly around (up to 10 s).").font(.callout) }
                Button("Use corners instead") { model.useCornersInstead() }.buttonStyle(.bordered)
                if model.purpose == .scope {
                    Button("Use the list instead") { model.refreshMarkers(); model.showScopeList = true }
                }
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .corner(let i):
            VStack(alignment: .leading, spacing: 10) {
                MiniPlanView(model: model, interactive: false, focus: i).frame(height: 150)
                Text("Point the crosshair at corner \(model.cornerNames[min(i, 2)]) — where the two walls meet the floor — then tap Set \(model.cornerNames[min(i, 2)]).")
                    .font(.callout)
                if let m = model.fitMessage { Text(m).font(.callout.bold()).foregroundStyle(.orange) }
                if model.purpose == .scope {
                    Button("Can't line it up? Use the list instead") { model.refreshMarkers(); model.showScopeList = true }
                        .font(.footnote)
                }
                HStack(spacing: 10) {
                    Button { model.setCorner() } label: {
                        Text("Set \(model.cornerNames[min(i, 2)])").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.tracking.isNormal)
                    if i > 0 {
                        Button("Back") { model.undoCorner() }.buttonStyle(.bordered).frame(minHeight: 58)
                    }
                }
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .check:
            VStack(alignment: .leading, spacing: 10) {
                Text("Do the blue lines sit on the walls at floor level?").font(.headline)
                if let m = model.fitMessage { Text(m).font(.callout).foregroundStyle(model.fitAcceptable ? Color.primary : Color.orange) }
                HStack(spacing: 10) {
                    Button { model.looksRight() } label: {
                        Text("Looks right").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.fitAcceptable)
                    Button("Redo corners") { model.realign() }.buttonStyle(.bordered).frame(minHeight: 54)
                }
                if !model.fitAcceptable {
                    HStack {
                        Button("Add a third corner") { model.addThirdCorner() }
                        Spacer()
                        Button("Use it anyway") { model.acceptAnyway() }
                    }
                    .font(.headline)
                }
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .measuring:
            if model.purpose == .scope {
                ScopeControls(model: model)
            } else if flow.mode != .idle {
                CaptureFlowBar(flow: flow, onEndHere: { model.endHere() }, onCorner: { model.addCorner() })
            } else {
                MarkupControls(model: model)
            }
        }
    }
}

/// The fast number sheet for re-measuring a saved point.
struct RemeasureSheet: View {
    let request: RemeasureRequest
    @ObservedObject var model: RevisitModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel") { model.remeasure = nil; dismiss() }
                Spacer()
                Text(request.title).font(.headline)
            }
            if !request.previous.isEmpty {
                Text(request.previous.joined(separator: "   ·   "))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(text.isEmpty ? "– %" : "\(text) %")
                .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
            NumberPad(text: $text)
            Button {
                if let v = Double(text) { model.saveRemeasure(value: v) }
            } label: {
                Text("Save").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .disabled(Double(text) == nil)
        }
        .padding()
        .presentationDetents([.large])
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
