//
//  Trays.swift
//  SecureScan
//
//  The trays of the capture screen. Each replaces what used to be a full
//  sheet: compact, docked at the bottom, the camera live above. The tray's
//  save is the screen's one primary button (CaptureHUD adds it below).
//

import SwiftUI
import UIKit

struct TrayContent: View {
    @ObservedObject var hud: CaptureHUDModel
    let tray: CaptureTray

    var body: some View {
        switch tray {
        case .reading: ReadingTray(hud: hud)
        case .mark: MarkTray(hud: hud)
        case .source: SourceTray(hud: hud)
        case .roomName: RoomNameTray(hud: hud)
        case .review: ReviewTray(hud: hud)
        }
    }
}

/// Title line of a tray: what this is, and a close button.
struct TrayHeader: View {
    let title: String
    var detail: String? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.gap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Font.bodyBold).foregroundStyle(.white).lineLimit(1)
                if let detail {
                    Text(detail).font(DS.Font.caption).foregroundStyle(DS.Color.onCameraSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            IconButton("xmark", label: "Close", action: onClose)
        }
    }
}

// MARK: - Reading

struct ReadingTray: View {
    @ObservedObject var hud: CaptureHUDModel

    var body: some View {
        VStack(spacing: DS.Space.gap) {
            HStack(alignment: .center, spacing: DS.Space.gap) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(context).font(DS.Font.caption).foregroundStyle(DS.Color.onCameraSecondary).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(hud.readingText.isEmpty ? "–" : hud.readingText)
                            .font(DS.Font.value(40)).foregroundStyle(valueColour)
                            .contentTransition(.numericText())
                        Text("%").font(DS.Font.value(20)).foregroundStyle(DS.Color.onCameraSecondary)
                    }
                }
                Spacer(minLength: 0)
                Chip("Dry ref", icon: hud.readingReference ? "checkmark" : nil, selected: hud.readingReference) {
                    hud.readingReference.toggle()
                }
                IconButton("xmark", label: "Cancel reading") { hud.closeTray() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.tight) {
                    ForEach(CaptureCopy.materials, id: \.key) { m in
                        Chip(m.name, selected: hud.readingMaterial == m.key) { hud.readingMaterial = m.key }
                    }
                }
            }
            KeyPad { hud.key($0) }
        }
    }

    private var context: String {
        if let t = hud.remeasureTag { return ["Re-measure \(t)", hud.remeasurePrevious].compactMap { $0 }.joined(separator: " · ") }
        if hud.editingId != nil { return "Edit reading" }
        return "New reading · \(CaptureCopy.materialName(hud.readingMaterial))"
    }

    private var valueColour: Color {
        guard let v = hud.readingValue else { return .white }
        switch OverlayBuild.status(v, reference: false) {
        case "wet": return Color(hex: 0xFF8A80)
        case "elevated": return Color(hex: 0xFFD27A)
        default: return Color(hex: 0x8FE3B0)
        }
    }
}

/// 0-9 . ⌫ in two rows of six: big keys, little height.
struct KeyPad: View {
    let press: (String) -> Void
    private let rows = [["1", "2", "3", "4", "5", "6"], ["7", "8", "9", "0", ".", "⌫"]]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { k in
                        Button { press(k) } label: {
                            Group {
                                if k == "⌫" { Image(systemName: "delete.left").font(.system(size: 20, weight: .semibold)) }
                                else { Text(k).font(DS.Font.value(24)) }
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(0.14)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DSPressStyle())
                        .accessibilityLabel(k == "⌫" ? "Delete" : k)
                    }
                }
            }
        }
    }
}

// MARK: - Mark

struct MarkTray: View {
    @ObservedObject var hud: CaptureHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.gap) {
            TrayHeader(title: title, detail: detail) { hud.closeTray() }
            if hud.markNeedsAnswer {
                chipRow {
                    Chip("Skirting run", icon: "line.diagonal", selected: false) { hud.chooseMeaning(.skirting) }
                    Chip("Floor area · add corners", icon: "plus", selected: false) { hud.continueAsArea() }
                }
            } else {
                chipRow {
                    ForEach(hud.markOptions, id: \.self) { m in
                        Chip(m.title, selected: hud.markMeaning == m, dot: m.isRemoval ? DS.Color.remove : DS.Color.source) {
                            hud.chooseMeaning(m)
                        }
                    }
                }
                extras
            }
        }
    }

    private var title: String {
        if hud.markNeedsAnswer { return "Skirting run or floor area?" }
        return hud.markShape == .area ? "Floor area" : "Line along the wall"
    }

    private var detail: String? {
        if let a = hud.markArea { return "\(CaptureCopy.area(a))\(hud.markPoints.count > 2 ? " · \(hud.markPoints.count) corners" : "")" }
        if let l = hud.markLength { return CaptureCopy.length(l) }
        return nil
    }

    @ViewBuilder private var extras: some View {
        switch hud.markMeaning {
        case .wallLining?:
            chipRow {
                ForEach(MarkIntent.liningChoices, id: \.self) { mm in
                    Chip("\(mm) mm", selected: hud.liningMm == mm) { hud.liningMm = mm }
                }
                Chip("Full height", selected: hud.liningMm == hud.fullHeightMm) { hud.liningMm = hud.fullHeightMm }
            }
        case .liftFlooring?:
            chipRow {
                ForEach(MarkIntent.floorTypes, id: \.key) { f in
                    Chip(f.name, selected: hud.floorType == f.key) { hud.floorType = f.key }
                }
                Chip("Underlay", icon: hud.underlay ? "checkmark" : "plus", selected: hud.underlay) { hud.underlay.toggle() }
            }
        default:
            EmptyView()
        }
    }

    private func chipRow<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.tight) { content() }
        }
    }
}

// MARK: - Source

struct SourceTray: View {
    @ObservedObject var hud: CaptureHUDModel
    @FocusState private var noteFocused: Bool
    @State private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.gap) {
            TrayHeader(title: "What caused it?", detail: "Pick one — Unknown is fine") { hud.closeTray() }
            if writing {
                TextField("", text: $hud.sourceNote, prompt: Text("Note (optional)").foregroundStyle(DS.Color.onCameraSecondary))
                    .font(DS.Font.body)
                    .foregroundStyle(.white)
                    .focused($noteFocused)
                    .submitLabel(.done)
                    .onSubmit { writing = false }
                    .padding(.horizontal, 14)
                    .frame(height: DS.Size.minTarget)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(0.12)))
                    .onAppear { noteFocused = true }
            } else {
                FlowLayout(spacing: DS.Space.tight) {
                    ForEach(CaptureCopy.causes, id: \.self) { c in
                        Chip(c, selected: hud.sourceCause == c) { hud.sourceCause = c }
                    }
                    Chip(hud.sourceNote.isEmpty ? "Add note" : "Note added", icon: hud.sourceNote.isEmpty ? "plus" : "checkmark") { writing = true }
                }
            }
        }
    }
}

// MARK: - Room name

struct RoomNameTray: View {
    @ObservedObject var hud: CaptureHUDModel
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.gap) {
            TrayHeader(title: "Name this room", detail: hud.engine.roomSections().count > 1 ? "Looks like more than one space" : nil) { hud.closeTray() }
            if hud.roomTyping {
                TextField("", text: $hud.roomOther, prompt: Text("Room name").foregroundStyle(DS.Color.onCameraSecondary))
                    .font(DS.Font.body).foregroundStyle(.white)
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit { hud.tapPrimary() }
                    .padding(.horizontal, 14)
                    .frame(height: DS.Size.minTarget)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(0.12)))
                    .onAppear { typing = true }
            } else {
                FlowLayout(spacing: DS.Space.tight) {
                    ForEach(hud.roomChips, id: \.self) { n in
                        Chip(n, selected: hud.roomChoice == n) { hud.roomChoice = n }
                    }
                    Chip("Other…", icon: "keyboard") { hud.roomTyping = true }
                }
            }
        }
    }
}

// MARK: - Review drawer

struct ReviewTray: View {
    @ObservedObject var hud: CaptureHUDModel

    var body: some View {
        let entries = hud.stack.reviewOrder
        VStack(alignment: .leading, spacing: DS.Space.gap) {
            TrayHeader(title: "\(entries.count) captured", detail: entries.first(where: { $0.id == hud.reviewSelected })?.needsFix ?? fixLine) { hud.closeTray() }
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.tight) {
                        ForEach(entries) { e in
                            ReviewCard(entry: e, thumb: hud.thumbs[e.id], selected: hud.reviewSelected == e.id) {
                                withAnimation(DS.Motion.tray) { hud.reviewSelected = e.id }
                            }
                            .id(e.id)
                        }
                    }
                }
                    .onAppear { if let s = hud.reviewSelected { reader.scrollTo(s) } }
            }
            if let sel = entries.first(where: { $0.id == hud.reviewSelected }) { actions(sel) }
        }
    }

    private var fixLine: String? {
        let n = hud.stack.needsFixCount
        return n == 0 ? "Tap one to change it" : (n == 1 ? "1 needs a quick fix" : "\(n) need a quick fix")
    }

    @ViewBuilder private func actions(_ e: CaptureStack.Entry) -> some View {
        HStack(spacing: DS.Space.tight) {
            if e.needsFix != nil {
                SecondaryButton("Redraw", icon: "pencil") { hud.delete(e.id); hud.closeTray(); hud.select(.mark) }
                Spacer(minLength: 0)
            } else {
                if e.kind == "reading" { SecondaryButton("Edit value", icon: "number") { hud.editReading(e.id) } }
                if e.kind == "photo" { SecondaryButton("Retake", icon: "camera") { hud.retake(e.id) } }
                Spacer(minLength: 0)
            }
            SecondaryButton("Delete", icon: "trash", role: .destructive) { hud.delete(e.id) }
        }
    }
}

struct ReviewCard: View {
    let entry: CaptureStack.Entry
    let thumb: UIImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.35))
                    if let thumb {
                        Image(uiImage: thumb).resizable().scaledToFill().frame(width: 124, height: 64).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: StackButton.glyph(entry.kind)).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    }
                    if entry.needsFix != nil {
                        Image(systemName: "exclamationmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(DS.Color.ink)
                            .frame(width: 20, height: 20).background(Circle().fill(DS.Color.damp))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
                    }
                }
                .frame(width: 124, height: 64)
                Text(entry.title).font(DS.Font.calloutBold).foregroundStyle(.white).lineLimit(1).monospacedDigit()
                Text(entry.needsFix != nil ? "Needs a quick fix" : entry.detail)
                    .font(DS.Font.caption).foregroundStyle(entry.needsFix != nil ? Color(hex: 0xFFD27A) : DS.Color.onCameraSecondary).lineLimit(1)
            }
            .padding(8)
            .frame(width: 140, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(selected ? Color.white : DS.Color.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(DSPressStyle())
    }

    private var tint: Color {
        switch entry.kind {
        case "reading", "remeasure": return DS.Color.dry
        case "mark": return DS.Color.remove
        case "equipment": return DS.Color.equip
        case "source": return DS.Color.source
        default: return DS.Color.grey(6)
        }
    }
}

// MARK: - Wrapping layout for chip groups

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
