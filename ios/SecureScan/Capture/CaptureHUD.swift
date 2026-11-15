//
//  CaptureHUD.swift
//  SecureScan
//
//  The one capture screen (docs/UX2.md), used unchanged over every camera:
//    top bar      close · room/phase capsule (coaching on its second line) · mic
//    reticle      28 pt ring + centre dot; a label above says what it is on
//    stack/undo   last capture's thumbnail with a count · Undo for 6 s
//    tool rail    five tools, never scrolls
//    primary      ONE button; its text is what the tap does (or why it can't)
//    quiet row    Room done / Next room · Finish (scan phases only)
//    trays        reading, mark, source, room name, review - bottom 42 % at most
//

import SwiftUI
import UIKit
import simd

/// Overlay + HUD, ticking the model. Engines put this over their camera view.
struct CaptureScreen: View {
    @ObservedObject var hud: CaptureHUDModel
    private let timer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            OverlayRenderer(hud: hud)
            CaptureHUD(hud: hud)
        }
        .dsSurface(.camera)
        .onReceive(timer) { _ in hud.tick() }
    }
}

struct CaptureHUD: View {
    @ObservedObject var hud: CaptureHUDModel
    @State private var flash = 0.0
    @State private var fly: CGFloat = 1
    @State private var stackFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if hud.tray == nil && hud.display.showsTools && hud.display.busy == nil {
                    // The raycast point is the centre of the whole screen, not of the safe area.
                    ReticleView(aim: hud.aim, label: reticleLabel, snapped: hud.aim.snapped)
                        .position(Self.screenCentre(geo))
                        .allowsHitTesting(false)
                }
                VStack(spacing: 0) {
                    topBar.padding(.horizontal, DS.Space.margin).padding(.top, 4)
                    if let t = hud.toast {
                        CameraCapsule(text: t).padding(.top, 10).transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    bottom(geo)
                }
                flyingToken(geo)
                Color.white.opacity(flash).ignoresSafeArea().allowsHitTesting(false)
                if let busy = hud.display.busy { busyOverlay(busy) }
            }
            .coordinateSpace(name: "hud")
            .ignoresSafeArea(.keyboard)
        }
        .animation(DS.Motion.tray, value: hud.tray)
        .animation(.easeInOut(duration: 0.2), value: hud.toast)
        .animation(.easeInOut(duration: 0.2), value: hud.undoVisible)
        .onChange(of: hud.saveTick) { _, _ in saved() }
    }

    static func screenCentre(_ geo: GeometryProxy) -> CGPoint {
        CGPoint(x: geo.size.width / 2 + (geo.safeAreaInsets.trailing - geo.safeAreaInsets.leading) / 2,
                y: geo.size.height / 2 + (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2)
    }

    /// What the reticle is on. While a line or area is drawn the shape carries its own
    /// length / area capsule; aiming at saved points (re-measure, done) the button says it.
    private var reticleLabel: String? {
        if hud.tool == .remeasure || hud.tool == .done { return nil }
        if hud.tool == .mark, !hud.markPoints.isEmpty, hud.markStartShape == .area { return nil }
        return CaptureCopy.reticle(hud.aim)
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            HStack {
                IconButton("xmark", label: "Close") { hud.engine.requestClose() }
                Spacer()
                recordButton
            }
            phaseCapsule.padding(.horizontal, DS.Size.icon + DS.Space.gap)
        }
    }

    @ViewBuilder private var phaseCapsule: some View {
        let content = VStack(spacing: 1) {
            Text(CaptureCopy.phase(hud.display.phase, room: hud.display.room))
                .font(DS.Font.calloutBold).lineLimit(1).minimumScaleFactor(0.85)
            if let c = hud.display.coaching {
                Text(c).font(DS.Font.caption).foregroundStyle(DS.Color.onCameraSecondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: DS.Size.icon)
        .dsCapsule()
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
                    Circle().fill(DS.Color.wet).frame(width: 9, height: 9)
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(Readout.elapsed(ctx.date.timeIntervalSince(start))).font(DS.Font.calloutBold).monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: DS.Size.icon)
                .dsCapsule()
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Stop recording")
        } else {
            IconButton("mic.fill", label: "Record voice notes") { hud.engine.toggleRecording() }
        }
    }

    // MARK: Bottom

    @ViewBuilder private func bottom(_ geo: GeometryProxy) -> some View {
        if let t = hud.tray {
            Tray {
                TrayContent(hud: hud, tray: t)
                primaryButton
            }
            .frame(maxHeight: geo.size.height * 0.42 + geo.safeAreaInsets.bottom, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let custom = hud.engine.customTray() {
            Tray { custom; primaryButton }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(spacing: DS.Space.gap) {
                if hud.display.showsTools {
                    stackRow
                    toolOptions
                    rail
                }
                primaryButton
                quietRow
            }
            .padding(.horizontal, DS.Space.margin)
            .padding(.bottom, 4)
        }
    }

    private var primaryButton: some View {
        let p = hud.primary
        return PrimaryButton(p.title, enabled: p.enabled, tint: p.tint) { hud.tapPrimary() }
    }

    private var stackRow: some View {
        HStack(alignment: .bottom) {
            if hud.stack.count > 0 {
                StackButton(count: hud.stack.count, thumb: hud.stackThumb, kind: hud.stack.last?.kind ?? "",
                            needsFix: hud.stack.needsFixCount > 0) { hud.openReview() }
                    .background(GeometryReader { g in Color.clear.onAppear { stackFrame = g.frame(in: .named("hud")) }
                        .onChange(of: g.frame(in: .named("hud"))) { _, f in stackFrame = f } })
            }
            Spacer()
            if hud.undoVisible && hud.stack.count > 0 {
                SecondaryButton("Undo", icon: "arrow.uturn.backward") { hud.undo() }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder private var toolOptions: some View {
        let chips = optionChips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.tight) {
                    ForEach(chips) { c in
                        Chip(c.title, icon: c.icon, selected: c.selected, dot: c.dot, action: c.action)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
        }
    }

    private struct OptionChip: Identifiable {
        var id: String
        var title: String
        var icon: String? = nil
        var selected = false
        var dot: Color? = nil
        var action: () -> Void
    }

    private var optionChips: [OptionChip] {
        switch hud.tool {
        case .mark:
            if hud.markPoints.isEmpty {
                var out: [OptionChip] = []
                if hud.canWholeWall { out.append(OptionChip(id: "wall", title: "Whole wall", icon: "arrow.left.and.right") { hud.wholeWall() }) }
                if hud.canWholeRoom { out.append(OptionChip(id: "room", title: "Whole room", icon: "square.dashed") { hud.wholeRoom() }) }
                return out
            }
            var out = [OptionChip(id: "undo", title: "Undo point", icon: "arrow.uturn.backward") { hud.undoMarkPoint() }]
            if hud.markStartShape == .line {
                out.append(OptionChip(id: "area", title: "Add corners", icon: "plus") { hud.continueAsArea() })
            } else {
                if hud.markPoints.count >= 3 { out.append(OptionChip(id: "close", title: "Close area", icon: "checkmark") { hud.closeArea() }) }
                if hud.markPoints.count == 2 { out.append(OptionChip(id: "line", title: "Finish as line", icon: "line.diagonal") { hud.finishAsLine() }) }
            }
            out.append(OptionChip(id: "cancel", title: "Cancel", icon: "xmark") { hud.cancelMark() })
            return out
        case .equipment:
            if hud.airflowFor != nil {
                return [OptionChip(id: "skip", title: "Skip airflow", icon: "forward") { hud.skipAirflow() }]
            }
            return CaptureCopy.equipment.map { e in
                OptionChip(id: e.key, title: e.name, selected: hud.equipmentType == e.key) { hud.equipmentType = e.key }
            }
        case .photo:
            guard let on = hud.engine.ultraWide else { return [] }
            return [OptionChip(id: "wide", title: on ? "0.5×" : "1×", icon: "camera.aperture", selected: on) { hud.engine.setUltraWide(!on) }]
        default:
            return []
        }
    }

    private var rail: some View {
        HStack(spacing: 4) {
            ForEach(hud.tools, id: \.self) { t in
                ToolTab(t.title, icon: t.icon, selected: hud.tool == t) {
                    withAnimation(DS.Motion.tray) { hud.select(t) }
                }
            }
        }
        .padding(4)
        .background(CameraFill(shape: RoundedRectangle(cornerRadius: DS.Radius.control + 4, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control + 4, style: .continuous).strokeBorder(DS.Color.hairline, lineWidth: 1))
    }

    @ViewBuilder private var quietRow: some View {
        let q = hud.display.quiet
        if !q.isEmpty {
            HStack {
                ForEach(Array(q.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Spacer() }
                    SecondaryButton(a.title) { hud.engine.perform(quiet: a.id) }
                        .disabled(!a.enabled)
                        .opacity(a.enabled ? 1 : 0.5)
                }
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

    @ViewBuilder private func flyingToken(_ geo: GeometryProxy) -> some View {
        if fly < 1, stackFrame != .zero {
            let from = Self.screenCentre(geo)
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

// MARK: - Reticle

struct ReticleView: View {
    let aim: Aim
    let label: String?
    let snapped: Bool

    var body: some View {
        let locked = aim.hit != nil
        ZStack {
            if let label {
                CameraCapsule(text: label, font: DS.Font.captionBold)
                    .fixedSize()
                    .offset(y: -36)
            }
            Circle()
                .stroke(Color.black.opacity(0.35), lineWidth: 4)
                .frame(width: 28, height: 28)
            Circle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: locked ? [] : [4, 4]))
                .frame(width: 28, height: 28)
            Circle().fill(Color.white).frame(width: 4, height: 4)
                .shadow(color: .black.opacity(0.5), radius: 1)
            if snapped {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(DS.Color.ink)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white))
                    .offset(x: 15, y: -15)
            }
        }
        .frame(width: 220, height: 100)
        .animation(.easeOut(duration: 0.15), value: locked)
        .animation(.easeOut(duration: 0.15), value: snapped)
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
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.ink.opacity(0.6))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: StackButton.glyph(kind)).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white, lineWidth: 2)
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .topTrailing) {
                if let badge = CaptureCopy.stackBadge(count) {
                    Text(badge).font(DS.Font.captionBold).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(needsFix ? DS.Color.damp : DS.Color.accent))
                        .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1.5))
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel("\(count) captured. Review")
    }

    static func glyph(_ kind: String) -> String {
        switch kind {
        case "reading", "remeasure": return "humidity"
        case "photo": return "camera.fill"
        case "mark": return "pencil.and.outline"
        case "equipment": return "fan.fill"
        case "source": return "drop.fill"
        case "done": return "checkmark"
        default: return "square.stack"
        }
    }
}
