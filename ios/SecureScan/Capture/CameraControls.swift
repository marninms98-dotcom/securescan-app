//
//  CameraControls.swift
//  SecureScan
//
//  The capture screen's controls, after the iOS Camera app, on its black panels:
//    * ModeStrip    - UPPERCASE tracked words, the selected one yellow and centred;
//                     swipe sideways or tap a neighbour; a selection tick per step
//    * ActionButton - the round centre button: 80 pt white ring, 64 pt accent disc with
//                     the mode's glyph; the white "Start" shutter before a scan starts
//    * PhotoButton  - 52 pt glass circle with a camera: the photo, in every mode
//    * OutlinePill / OutlineCircle - secondary controls on black (1 pt white 45 %)
//

import SwiftUI
import UIKit

struct ModeStrip: View {
    let modes: [CaptureTool]
    let selected: CaptureTool
    let onSelect: (CaptureTool) -> Void
    @State private var drag: CGFloat = 0
    @State private var landing: Int?

    static let font = UIFont.systemFont(ofSize: 13, weight: .semibold)
    static let tracking: CGFloat = 1.1

    static func width(_ t: CaptureTool) -> CGFloat {
        ceil((t.title.uppercased() as NSString).size(withAttributes: [.font: font, .kern: tracking]).width)
    }

    var body: some View {
        let layout = ModeStripLayout(widths: modes.map(Self.width))
        let index = modes.firstIndex(of: selected) ?? 0
        GeometryReader { geo in
            HStack(spacing: layout.gap) {
                ForEach(Array(modes.enumerated()), id: \.element) { i, m in
                    let on = i == (landing ?? index)
                    Button {
                        guard m != selected else { return }
                        DS.Haptic.selection()
                        onSelect(m)
                    } label: {
                        Text(m.title.uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(Self.tracking)
                            .foregroundStyle(on ? DS.Color.modeOn : Color.white.opacity(0.55))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: layout.widths[i], height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.title) mode")
                    .accessibilityAddTraits(m == selected ? .isSelected : [])
                }
            }
            .fixedSize()
            .offset(x: layout.offset(selected: index, in: geo.size.width) + drag)
            .frame(width: geo.size.width, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        drag = v.translation.width
                        let l = layout.landing(from: index, drag: drag)
                        if l != (landing ?? index) { DS.Haptic.selection() }
                        landing = l
                    }
                    .onEnded { v in
                        let target = layout.landing(from: index, drag: v.predictedEndTranslation.width)
                        if target != (landing ?? index) { DS.Haptic.selection() }
                        withAnimation(DS.Motion.tray) { drag = 0 }
                        landing = nil
                        if target != index { onSelect(modes[target]) }
                    }
            )
        }
        .frame(height: 28)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .animation(DS.Motion.tray, value: selected)
    }
}

/// The round centre button: the mode's action (or the white Start shutter).
struct ActionButton: View {
    let icon: String
    let title: String
    let enabled: Bool
    var start = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.white.opacity(enabled ? 0.95 : 0.35), lineWidth: 4).frame(width: 80, height: 80)
                if start {
                    Circle().fill(Color.white).frame(width: 64, height: 64)
                } else {
                    Circle().fill(enabled ? DS.Color.accent : Color.white.opacity(0.14)).frame(width: 64, height: 64)
                    Image(systemName: icon).font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.5))
                }
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .allowsHitTesting(enabled)
        .accessibilityLabel(start ? "Start scan" : title)
    }
}

/// The photo button: a camera in a glass circle. The job's photo count is in the viewer.
struct PhotoButton: View {
    let retaking: Bool
    let ultra: Bool
    let enabled: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(retaking ? DS.Color.damp : Color.white.opacity(0.12))
                Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                Image(systemName: retaking ? "arrow.triangle.2.circlepath.camera" : "camera")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(retaking ? DS.Color.ink : .white)
                if ultra && !retaking {
                    Text(".5×").font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Color.modeOn).offset(y: 17)
                }
            }
            .frame(width: 52, height: 52)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Circle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(retaking ? "Retake photo" : "Take photo. \(count) photos in this job")
    }
}

/// A shutter's press: a quick shrink, like the Camera app.
struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A secondary control on the black panels: an outline pill (or, prominent, a filled accent pill).
struct OutlinePill: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background { if prominent { Capsule().fill(DS.Color.accent) } }
            .overlay { if !prominent { Capsule().strokeBorder(DS.Color.outline, lineWidth: 1) } }
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle())
    }
}

/// A 36 pt outline circle on the black top bar (close, mic); 44 pt target.
struct OutlineCircle: View {
    let icon: String
    let label: String
    let action: () -> Void

    init(_ icon: String, label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(DS.Color.outline, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(label)
    }
}
