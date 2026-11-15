//
//  DS.swift
//  SecureScan
//
//  The design system: the ONLY place colours, type, shapes, spacing and the
//  shared controls live (docs/UX2.md). Every screen uses these and nothing
//  else: one accent, one button shape, one type scale, one material.
//
//  Two surfaces, same controls:
//    * camera  - over the live camera: white text on dark ultra-thin material
//                capsules with a 1 px white 12 % hairline (set by CaptureHUD);
//    * light   - lists and the job screen: system grouped backgrounds.
//  Pick the surface with `.dsSurface(.camera)`; controls adapt by themselves.
//
//  Public API (keep it small and stable - other screens build on it):
//    DS.Color.ink / paper / accent / dry / damp / wet / remove / equip / source,
//      DS.Color.grey(0...9), DS.Color.hairline, DS.Color.status("dry"|"elevated"|"wet"|"reference")
//    DS.Font.title / headline / body / callout / caption, DS.Font.value(size)
//    DS.Radius.control (14) / card (22),  DS.Space.margin (16) / gap (12) / tight (8)
//    DS.Size.primary (60) / chip (36) / icon (44)
//    DS.Motion.tray / fly,  DS.Haptic.lock / save / undo / warning
//    PrimaryButton, SecondaryButton, Chip, IconButton, ToolTab, Tray, CameraCapsule, CameraFill
//    .dsSurface(_:), .dsCapsule(), .dsCard()
//

import SwiftUI
import UIKit

enum DS {

    // MARK: Colour

    enum Color {
        /// Near-black, for text on light chips and the selected chip's label.
        static let ink = SwiftUI.Color(hex: 0x0B0F14)
        static let paper = SwiftUI.Color(hex: 0xFFFFFF)
        /// The one accent (brand colour, replaceable later).
        static let accent = SwiftUI.Color(hex: 0x1F6FEB)
        // Semantic colours: only where the colour means something.
        static let dry = SwiftUI.Color(hex: 0x2E9E5B)
        static let damp = SwiftUI.Color(hex: 0xE0A21A)
        static let wet = SwiftUI.Color(hex: 0xD9453A)
        static let remove = SwiftUI.Color(hex: 0xE5484D)
        static let equip = SwiftUI.Color(hex: 0x12A594)
        static let source = SwiftUI.Color(hex: 0x2F7CF6)
        /// 1 px white 12 % line on materials.
        static let hairline = SwiftUI.Color.white.opacity(0.12)
        /// Secondary text over the camera.
        static let onCameraSecondary = SwiftUI.Color.white.opacity(0.72)
        /// The dark tint laid under every camera material, so white text holds over bright walls.
        static let cameraTint = SwiftUI.Color.black.opacity(0.34)
        /// Destructive text over the camera (remove red, lifted for dark materials).
        static let removeOnCamera = SwiftUI.Color(hex: 0xFF7A7D)

        /// One neutral ramp: 0 = white ... 9 = ink.
        static func grey(_ level: Int) -> SwiftUI.Color {
            let ramp: [UInt32] = [0xFFFFFF, 0xF4F5F7, 0xE6E8EB, 0xCDD1D6, 0xA9AFB7, 0x858C96, 0x626A74, 0x434A53, 0x262C33, 0x0B0F14]
            return SwiftUI.Color(hex: ramp[min(max(level, 0), ramp.count - 1)])
        }

        /// Reading status -> colour ("dry" | "elevated"/"damp" | "wet"; anything else neutral).
        static func status(_ s: String) -> SwiftUI.Color {
            switch s {
            case "dry": return dry
            case "elevated", "damp": return damp
            case "wet": return wet
            default: return grey(5)
            }
        }
    }

    // MARK: Type (SF Pro; nothing below 13 pt)

    enum Font {
        static let title = SwiftUI.Font.system(size: 28, weight: .bold)
        static let headline = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 17, weight: .regular)
        static let bodyBold = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let callout = SwiftUI.Font.system(size: 15, weight: .regular)
        static let calloutBold = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 13, weight: .medium)
        static let captionBold = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Value readouts: SF Pro Rounded semibold, monospaced digits.
        static func value(_ size: CGFloat) -> SwiftUI.Font {
            SwiftUI.Font.system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }
    }

    // MARK: Shape, spacing, sizes

    enum Radius {
        static let control: CGFloat = 14
        static let card: CGFloat = 22
    }

    enum Space {
        static let margin: CGFloat = 16
        static let gap: CGFloat = 12
        static let tight: CGFloat = 8
    }

    enum Size {
        static let primary: CGFloat = 60
        static let chip: CGFloat = 36
        static let icon: CGFloat = 44
        static let minTarget: CGFloat = 44
    }

    // MARK: Motion and haptics

    enum Motion {
        /// Trays and selection.
        static let tray = Animation.spring(response: 0.22, dampingFraction: 0.9)
        /// A saved item flying to the capture stack.
        static let fly = Animation.easeInOut(duration: 0.35)
    }

    enum Haptic {
        /// The reticle locked onto something new.
        static func lock() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        static func save() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        static func undo() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    /// Where a control sits: over the camera (dark material) or on a light screen.
    enum Surface { case camera, light }
}

// MARK: - Surface environment

private struct DSSurfaceKey: EnvironmentKey {
    static let defaultValue: DS.Surface = .light
}

extension EnvironmentValues {
    var dsSurface: DS.Surface {
        get { self[DSSurfaceKey.self] }
        set { self[DSSurfaceKey.self] = newValue }
    }
}

extension View {
    /// Camera: dark materials, white text. Light: system backgrounds.
    func dsSurface(_ s: DS.Surface) -> some View {
        environment(\.dsSurface, s).environment(\.colorScheme, s == .camera ? .dark : .light)
    }

    /// A dark material capsule with the hairline (the over-camera look).
    func dsCapsule() -> some View {
        background(CameraFill(shape: Capsule()))
            .overlay(Capsule().strokeBorder(DS.Color.hairline, lineWidth: 1))
    }

    /// A card: 22 pt continuous corners, material on the camera, secondary grouped on light.
    func dsCard(_ surface: DS.Surface = .camera) -> some View {
        modifier(DSCard(surface: surface))
    }
}

private struct DSCard: ViewModifier {
    let surface: DS.Surface
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        if surface == .camera {
            content.background(CameraFill(shape: shape)).overlay(shape.strokeBorder(DS.Color.hairline, lineWidth: 1))
        } else {
            content.background(SwiftUI.Color(.secondarySystemGroupedBackground), in: shape)
        }
    }
}

extension Color {
    /// 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Controls

/// The one primary action of a screen: 60 pt accent capsule, its text is the action.
/// `enabled == false` shows the text as a reason (material, no accent) and ignores taps.
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var enabled = true
    var tint: Color = DS.Color.accent
    let action: () -> Void

    init(_ title: String, icon: String? = nil, enabled: Bool = true, tint: Color = DS.Color.accent, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.enabled = enabled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 17, weight: .semibold)) }
                Text(title).font(DS.Font.bodyBold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(enabled ? Color.white : DS.Color.onCameraSecondary)
            .frame(maxWidth: .infinity, minHeight: DS.Size.primary)
            .padding(.horizontal, 20)
            .background {
                if enabled { Capsule().fill(tint) } else { CameraFill(shape: Capsule()) }
            }
            .overlay(Capsule().strokeBorder(enabled ? Color.white.opacity(0.18) : DS.Color.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle())
        .allowsHitTesting(enabled)
        .accessibilityLabel(title)
    }
}

/// A secondary action: material capsule (camera) or grey fill (light).
struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.dsSurface) private var surface

    init(_ title: String, icon: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(DS.Font.calloutBold).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 16)
            .frame(minHeight: DS.Size.minTarget)
            .background {
                if surface == .camera { CameraFill(shape: Capsule()) } else { Capsule().fill(Color(.tertiarySystemFill)) }
            }
            .overlay(Capsule().strokeBorder(surface == .camera ? DS.Color.hairline : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle())
    }

    private var fg: Color {
        if role == .destructive { return surface == .camera ? DS.Color.removeOnCamera : DS.Color.remove }
        return surface == .camera ? .white : Color(.label)
    }
}

/// A choice: 36 pt capsule. Selected = white fill / ink text (camera), ink fill / white text (light).
struct Chip: View {
    let title: String
    var icon: String? = nil
    var selected = false
    /// A coloured dot before the title (semantic colour of the choice).
    var dot: Color? = nil
    let action: () -> Void
    @Environment(\.dsSurface) private var surface

    init(_ title: String, icon: String? = nil, selected: Bool = false, dot: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.dot = dot
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(DS.Font.calloutBold).lineLimit(1).fixedSize()
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 14)
            .frame(height: DS.Size.chip)
            .background { background }
            .overlay(Capsule().strokeBorder(selected || surface == .light ? Color.clear : DS.Color.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .frame(minHeight: DS.Size.minTarget)       // 44 pt target, 36 pt visual
        }
        .buttonStyle(DSPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fg: Color {
        if surface == .camera { return selected ? DS.Color.ink : .white }
        return selected ? .white : Color(.label)
    }

    @ViewBuilder private var background: some View {
        if surface == .camera {
            if selected { Capsule().fill(Color.white).shadow(color: .black.opacity(0.28), radius: 3, y: 1) } else { CameraFill(shape: Capsule()) }
        } else {
            Capsule().fill(selected ? DS.Color.ink : Color(.tertiarySystemFill))
        }
    }
}

/// A 44 pt circular icon button (material on the camera).
struct IconButton: View {
    let icon: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void
    @Environment(\.dsSurface) private var surface

    init(_ icon: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint == nil ? (surface == .camera ? Color.white : Color(.label)) : Color.white)
                .frame(width: DS.Size.icon, height: DS.Size.icon)
                .background {
                    if let tint { Circle().fill(tint) }
                    else if surface == .camera { CameraFill(shape: Circle()) }
                    else { Circle().fill(Color(.tertiarySystemFill)) }
                }
                .overlay(Circle().strokeBorder(surface == .camera && tint == nil ? DS.Color.hairline : Color.clear, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(label)
    }
}

/// One tool on the capture screen's rail: icon over a label; selected = white fill, ink content.
struct ToolTab: View {
    let title: String
    let icon: String
    var selected = false
    var badge: String? = nil
    let action: () -> Void

    init(_ title: String, icon: String, selected: Bool = false, badge: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                Text(title).font(DS.Font.captionBold).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 3)
            .foregroundStyle(selected ? DS.Color.ink : Color.white.opacity(0.7))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(selected ? Color.white : Color.clear)
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge).font(DS.Font.captionBold).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(DS.Color.accent))
                        .offset(x: -4, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The tray: docked at the bottom, 22 pt top corners, material, never above 42 % of the screen.
/// Content is laid out by the caller; the tray adds the margins and the grabber.
struct Tray<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: DS.Space.gap) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 8)
            content
        }
        .padding(.horizontal, DS.Space.margin)
        .padding(.bottom, DS.Space.tight)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                UnevenRoundedRectangle(topLeadingRadius: DS.Radius.card, topTrailingRadius: DS.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                UnevenRoundedRectangle(topLeadingRadius: DS.Radius.card, topTrailingRadius: DS.Radius.card, style: .continuous)
                    .fill(Color.black.opacity(0.42))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: DS.Radius.card, topTrailingRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Color.hairline, lineWidth: 1)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// A small text capsule over the camera (labels, the reticle readout, toasts).
struct CameraCapsule: View {
    let text: String
    var icon: String? = nil
    var dot: Color? = nil
    var font: Font = DS.Font.calloutBold

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
            Text(text).font(font).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .dsCapsule()
    }
}

/// A trailing fade for horizontally scrolling chip rows (shows there is more).
struct FadeEdge: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
        }
    }
}

/// The over-camera material: ultra-thin blur plus the dark tint (one look everywhere).
struct CameraFill<S: Shape>: View {
    let shape: S
    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(DS.Color.cameraTint)
        }
    }
}

/// Press feedback shared by every control: a slight dim and scale.
struct DSPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
