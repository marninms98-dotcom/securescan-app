//
//  CaptureHUD.swift
//  SecureScan
//
//  The one capture screen (docs/UX2.md), used unchanged over every camera.
//  A framed viewport, like a camera app:
//    top bar (black)   Tips · room + one status line · mic (or the recording timer) · close
//    viewport (3:4)    the camera, the 3D equipment, the world marks, the reticle and its
//                      readout, ONE instruction card at the top, the torch and 0.5x at the
//                      right edge, glass chips and the mode's sub-picker at the bottom
//    bottom (black)    the mode strip (UPPERCASE, the selected one yellow) · capture stack,
//                      the round action, the photo button · outline pills (Room done ·
//                      Finish) with the action's words between them
//    trays             reading, mark, source, room name, review - from the bottom
//  Nothing but world marks, the reticle and in-viewport chips sits on the camera image.
//

import SwiftUI
import UIKit
import simd

/// The camera, framed, with the overlay and the HUD. Engines pass their camera view in.
struct CaptureScreen<Camera: View>: View {
    @ObservedObject var hud: CaptureHUDModel
    private let camera: Camera
    private let timer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    init(hud: CaptureHUDModel, @ViewBuilder camera: () -> Camera) {
        self.hud = hud
        self.camera = camera()
    }

    var body: some View {
        CaptureHUD(hud: hud, camera: AnyView(camera))
            .dsSurface(.camera)
            // The HUD keeps its layout: Dynamic Type is capped at the default size here.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .onReceive(timer) { _ in hud.tick() }
            .onAppear { DS.Haptic.prepare() }
    }
}

struct CaptureHUD: View {
    @ObservedObject var hud: CaptureHUDModel
    let camera: AnyView
    @State private var flash = 0.0
    @State private var fly: CGFloat = 1
    @State private var stackFrame: CGRect = .zero
    @State private var torchOn = false

    var body: some View {
        // The outer reader sees the safe area (the island, the home indicator); the inner one
        // lays the screen out edge to edge.
        GeometryReader { outer in
            ZStack {
                content(insets: outer.safeAreaInsets)
                if let busy = hud.display.busy { busyOverlay(busy) }
                if let start = hud.viewerStart {
                    PhotoViewer(hud: hud, startId: start).transition(.opacity)
                }
                if hud.handoffShot != nil {
                    UltraWideCaptureView { hud.finishHandoff($0) }.transition(.opacity)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    private func content(insets: EdgeInsets) -> some View {
        GeometryReader { geo in
            let f = CaptureFrame.layout(width: geo.size.width, height: geo.size.height,
                                        safeTop: insets.top, safeBottom: insets.bottom)
            let vp = CGSize(width: geo.size.width, height: f.viewport)
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, DS.Space.margin)
                        .frame(height: CaptureFrame.barRow)
                        .frame(maxHeight: f.top, alignment: .bottom)
                    viewport(vp)
                    bottomPanel(width: geo.size.width)
                        .frame(height: f.bottom, alignment: .top)
                }
                flyingToken(CGPoint(x: vp.width / 2, y: f.top + vp.height / 2))
                if hud.display.busy == nil { trays(height: geo.size.height, bottomInset: insets.bottom) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "hud")
        }
        .ignoresSafeArea()
        .animation(DS.Motion.tray, value: hud.tray)
        .animation(.easeInOut(duration: 0.2), value: hud.viewerStart)
        .animation(.easeInOut(duration: 0.2), value: hud.cardText)
        .animation(.easeInOut(duration: 0.2), value: hud.undoVisible)
        .animation(.easeInOut(duration: 0.2), value: hud.tipsOpen)
        .onChange(of: hud.saveTick) { _, _ in saved() }
    }

    // MARK: Top bar (black)

    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                OutlinePill("Tips", icon: "lightbulb") { hud.tipsOpen.toggle(); DS.Haptic.selection() }
                Spacer()
                recordButton
                OutlineCircle("xmark", label: "Close") { hud.engine.requestClose() }
            }
            // Clear of the side buttons (the recording timer is wider than the mic).
            title.padding(.horizontal, hud.display.recordingSince == nil ? 104 : 136)
        }
    }

    @ViewBuilder private var title: some View {
        let room = hud.display.room
        let content = VStack(spacing: 1) {
            Text(room.isEmpty ? hud.display.phase : room)
                .font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            if !room.isEmpty || hud.engine.isReturnVisit || hud.engine.isScopeOnSite {
                Text(room.isEmpty ? (hud.engine.isScopeOnSite ? "See scope on site" : "Return visit") : hud.subtitle)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.72)).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        if hud.engine.isReturnVisit || hud.engine.isScopeOnSite {
            content
        } else {
            Menu {
                if hud.engine.canRenameRoom {
                    Button { hud.askRoomName() } label: { Label("Rename room", systemImage: "pencil") }
                }
                Picker("Marking for", selection: $hud.context) {
                    Text("Inspect").tag(WorkContext.inspect)
                    Text(PriceLock.pricesVisible ? "Quote" : "Scope").tag(WorkContext.scope)
                }
            } label: { content }
        }
    }

    @ViewBuilder private var recordButton: some View {
        if let start = hud.display.recordingSince {
            Button { hud.engine.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Circle().fill(DS.Color.wet).frame(width: 8, height: 8)
                        .background(Circle().fill(DS.Color.wet.opacity(0.25)).frame(width: 14, height: 14))
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Readout.elapsed(ctx.date.timeIntervalSince(start))).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .overlay(Capsule().strokeBorder(DS.Color.outline, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Stop recording")
        } else {
            OutlineCircle("mic", label: "Record voice notes") { hud.engine.toggleRecording() }
        }
    }

    // MARK: The viewport

    private func viewport(_ size: CGSize) -> some View {
        ZStack {
            camera
            OverlayRenderer(hud: hud, pass: .under)
            EquipmentLayer(hud: hud).allowsHitTesting(false)
            OverlayRenderer(hud: hud, pass: .over)
            if hud.tray == nil && hud.display.showsTools && hud.display.busy == nil {
                ReticleView(aim: hud.aim).allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                if hud.tipsOpen { tipsCard } else if let t = hud.cardText { InstructionCard(text: t).transition(.opacity) }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.horizontal, DS.Space.margin)
            if hud.tray == nil && hud.display.showsTools {
                edgeControls
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    photoCardRow
                    chipsRow
                    subPicker
                }
                .padding(.bottom, 12)
            }
            Color.white.opacity(flash).allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(RotationGesture()
            .onChanged { a in hud.twistChanged(-a.radians) }
            .onEnded { _ in hud.twistEnded() },
            including: hud.twistTarget != nil ? .all : .subviews)
    }

    private var tipsCard: some View {
        Button { hud.tipsOpen = false } label: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CaptureCopy.tips(hud.tools), id: \.title) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(t.title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(DS.Color.ink.opacity(0.55)).frame(width: 92, alignment: .leading)
                        Text(t.line).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.95)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel("Tips. Tap to close")
    }

    /// Torch and 0.5x at the right edge, mid-height.
    private var edgeControls: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                if hud.engine.hasTorch {
                    Button {
                        torchOn = Torch.set(!torchOn) ? !torchOn : Torch.isOn
                        DS.Haptic.selection()
                    } label: {
                        Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(torchOn ? DS.Color.ink : .white)
                            .frame(width: 44, height: 44)
                            .background { if torchOn { Circle().fill(Color.white) } else { CameraFill(shape: Circle()) } }
                            .overlay(Circle().strokeBorder(DS.Color.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(DSPressStyle())
                    .accessibilityLabel(torchOn ? "Torch off" : "Torch on")
                }
                if hud.engine.zoomState != .unavailable && hud.retakeFor == nil {
                    ZoomToggle(state: hud.engine.zoomState, ultra: $hud.zoomUltra, vertical: true) { hud.showToast($0) }
                }
            }
            .padding(.trailing, 12)
        }
    }

    @ViewBuilder private var photoCardRow: some View {
        if let card = hud.photoCard {
            HStack {
                PhotoCardView(card: card, onOpen: { hud.openViewer(card.id) }, onRetake: { hud.beginRetake(card.id) })
                Spacer()
            }
            .padding(.horizontal, DS.Space.margin)
        }
    }

    // MARK: Glass chips and the sub-picker (bottom of the viewport)

    private struct OptionChip: Identifiable {
        var id: String
        var title: String
        var icon: String? = nil
        var action: () -> Void
    }

    private var optionChips: [OptionChip] {
        var out: [OptionChip] = []
        guard hud.retakeFor == nil, hud.airflowFor == nil else { return out }
        switch hud.tool {
        case .moisture, .stripOut:
            if hud.markPoints.isEmpty {
                if hud.canWholeWall { out.append(OptionChip(id: "wall", title: "Whole wall", icon: "arrow.left.and.right") { hud.wholeWall() }) }
                if hud.canWholeRoom { out.append(OptionChip(id: "room", title: "Whole room", icon: "square.dashed") { hud.wholeRoom() }) }
            } else if hud.markStartShape == .area {
                if hud.markPoints.count >= 3 { out.append(OptionChip(id: "close", title: "Close area", icon: "checkmark") { hud.closeArea() }) }
                if hud.markPoints.count == 2 && hud.tool == .stripOut { out.append(OptionChip(id: "line", title: "Finish as line", icon: "line.diagonal") { hud.finishAsLine() }) }
            } else if hud.tool == .stripOut {
                out.append(OptionChip(id: "corners", title: "Add corners", icon: "plus") { hud.continueAsArea() })
            }
        default: break
        }
        if hud.undoVisible && hud.stack.count > 0 && hud.markPoints.isEmpty {
            out.append(OptionChip(id: "undo", title: "Undo", icon: "arrow.uturn.backward") { hud.undo() })
        }
        return out
    }

    @ViewBuilder private var chipsRow: some View {
        let chips = optionChips
        if !chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chips) { c in
                    Button(action: c.action) {
                        HStack(spacing: 6) {
                            if let i = c.icon { Image(systemName: i).font(.system(size: 12, weight: .semibold)) }
                            Text(c.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .dsCapsule()
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(DSPressStyle())
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var subPicker: some View {
        let items = hud.subPicker
        if !items.isEmpty {
            let sel = hud.subSelection
            let locked = hud.tool == .moisture && !hud.markPoints.isEmpty
            HStack(spacing: 2) {
                ForEach(items, id: \.key) { it in
                    let on = it.key == sel
                    Button { hud.pickSub(it.key) } label: {
                        Text(it.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).fixedSize()
                            .foregroundStyle(on ? DS.Color.ink : Color.white.opacity(0.75))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background { if on { Capsule().fill(Color.white.opacity(0.92)) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(DSPressStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .dsCapsule()
            .opacity(locked ? 0.5 : 1)
            .allowsHitTesting(!locked)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
        }
    }

    // MARK: Bottom panel (black)

    @ViewBuilder private func bottomPanel(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if hud.tray != nil || hud.engine.customTray() != nil {
                // A tray sits over the panel: nothing peeks out above it.
                EmptyView()
            } else if hud.display.showsTools {
                ModeStrip(modes: hud.tools, selected: hud.tool) { t in withAnimation(DS.Motion.tray) { hud.select(t) } }
                    .frame(height: 28)
                    .padding(.top, 8)
                controlsRow.padding(.top, 4)
                pillsRow(width: width).padding(.top, 10)
            } else if hud.engine.customTray() == nil {
                PrimaryButton(hud.primary.title, enabled: hud.primary.enabled) { hud.tapPrimary() }
                    .padding(.horizontal, DS.Space.margin)
                    .padding(.top, 20)
                pillsRow(width: width).padding(.top, 10)
            }
        }
    }

    /// Capture stack · the round action · the photo button.
    private var controlsRow: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.clear.frame(width: 52, height: 52)
                if hud.stackCount > 0 {
                    StackButton(count: hud.stackCount, thumb: hud.stackThumb, kind: hud.stackKind,
                                needsFix: hud.stack.needsFixCount > 0) { hud.openReview() }
                        .background(GeometryReader { g in Color.clear.onAppear { stackFrame = g.frame(in: .named("hud")) }
                            .onChange(of: g.frame(in: .named("hud"))) { _, f in stackFrame = f } })
                }
            }
            Spacer(minLength: 0)
            ActionButton(icon: hud.primaryIcon, title: hud.primary.title, enabled: hud.primary.enabled, start: hud.primaryIsStart) { hud.tapPrimary() }
            Spacer(minLength: 0)
            PhotoButton(retaking: hud.retakeFor != nil, ultra: hud.zoomUltra && hud.engine.zoomState == .available,
                        enabled: hud.shutterEnabled, count: hud.photoCount) { hud.shutter() }
        }
        .padding(.horizontal, 34)
        .frame(height: 80)
    }

    private func pillsRow(width: CGFloat) -> some View {
        let p = hud.pills
        return ZStack {
            HStack {
                if let l = p.left { pill(l) }
                Spacer()
                if let r = p.right { pill(r) }
            }
            if let c = p.caption {
                Text(c)
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(hud.primary.enabled ? 0.92 : 0.6))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: max(80, width - 2 * (p.left == nil && p.right == nil ? 24 : 128)))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
    }

    private func pill(_ p: CaptureHUDModel.Pill) -> some View {
        OutlinePill(p.title, icon: p.prominent ? "checkmark" : nil, prominent: p.prominent) { hud.tapPill(p.id) }
            .disabled(!p.enabled)
            .opacity(p.enabled ? 1 : 0.45)
    }

    // MARK: Trays

    @ViewBuilder private func trays(height: CGFloat, bottomInset: CGFloat) -> some View {
        let maxH = height * 0.42 + bottomInset
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let t = hud.tray {
                Tray {
                    TrayContent(hud: hud, tray: t)
                    PrimaryButton(hud.primary.title, enabled: hud.primary.enabled, tint: hud.primary.tint) { hud.tapPrimary() }
                    Color.clear.frame(height: max(0, bottomInset - 8))
                }
                .frame(maxHeight: maxH, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let custom = hud.engine.customTray() {
                Tray {
                    custom
                    PrimaryButton(hud.primary.title, enabled: hud.primary.enabled, tint: hud.primary.tint) { hud.tapPrimary() }
                    Color.clear.frame(height: max(0, bottomInset - 8))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Feedback

    private func saved() {
        if hud.lastSaveWasPhoto {
            flash = 0.85
            withAnimation(.easeOut(duration: 0.3)) { flash = 0 }
        }
        fly = 0
        withAnimation(DS.Motion.fly) { fly = 1 }
    }

    @ViewBuilder private func flyingToken(_ from: CGPoint) -> some View {
        if fly < 1, stackFrame != .zero {
            let to = CGPoint(x: stackFrame.midX, y: stackFrame.midY)
            let p = CGPoint(x: from.x + (to.x - from.x) * fly, y: from.y + (to.y - from.y) * fly)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)
                .frame(width: 44 - 20 * fly, height: 44 - 20 * fly)
                .shadow(radius: 4)
                .position(p)
                .allowsHitTesting(false)
        }
    }

    private func busyOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(text).font(DS.Font.headline).foregroundStyle(.white)
                Text("Keep the app open").font(DS.Font.callout).foregroundStyle(DS.Color.onCameraSecondary)
            }
            .padding(28)
            .dsCard()
        }
    }
}

// MARK: - The instruction card

/// The one card at the top of the viewport: light, dark text (coaching, a status, a first-use tip).
struct InstructionCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(DS.Color.ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.94)))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Reticle

/// 34 pt: a 2 pt white ring with a faint dark outer ring and a 5 pt centre dot. Dashed while
/// nothing is under it. Its readout is drawn by the overlay (it takes part in the label layout).
struct ReticleView: View {
    let aim: Aim

    var body: some View {
        let locked = aim.hit != nil
        ZStack {
            // Dark either side of the white ring, so it holds on a white wall.
            Circle().stroke(Color.black.opacity(0.45), lineWidth: 4.5).frame(width: 32, height: 32)
            Circle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: locked ? [] : [4, 4]))
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            Circle().fill(Color.white).frame(width: 5, height: 5)
                .shadow(color: .black.opacity(0.4), radius: 1)
        }
        .scaleEffect(aim.snapped ? 0.85 : 1)
        .animation(.easeOut(duration: 0.15), value: locked)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: aim.snapped)
    }
}

// MARK: - Capture stack

struct StackButton: View {
    let count: Int
    let thumb: UIImage?
    let kind: String
    let needsFix: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.16))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: StackButton.glyph(kind)).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .topTrailing) {
                if let badge = CaptureCopy.stackBadge(count) {
                    Text(badge).font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(DS.Color.ink)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(needsFix ? DS.Color.damp : Color.white))
                        .offset(x: 9, y: -8)
                }
            }
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel("\(count) captured. Review")
    }

    static func glyph(_ kind: String) -> String {
        switch kind {
        case "reading", "remeasure": return "drop.fill"
        case "photo": return "camera.fill"
        case "mark": return "scissors"
        case "equipment": return "fan.fill"
        case "source": return "mappin"
        case "done": return "checkmark"
        default: return "square.stack"
        }
    }
}
