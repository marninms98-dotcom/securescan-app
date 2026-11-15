//
//  DSShim.swift
//  SecureScan
//
//  TEMPORARY stand-in for ios/SecureScan/UI/DS.swift (docs/UX2.md "Design
//  system") until the real one is merged. Delete when DS.swift lands.
//

import SwiftUI

enum DS {
    enum Color {
        static let ink = SwiftUI.Color(red: 0x0B / 255, green: 0x0F / 255, blue: 0x14 / 255)
        static let paper = SwiftUI.Color.white
        static let accent = SwiftUI.Color(red: 0x1F / 255, green: 0x6F / 255, blue: 0xEB / 255)
        static let dry = SwiftUI.Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)
        static let damp = SwiftUI.Color(red: 0xE0 / 255, green: 0xA2 / 255, blue: 0x1A / 255)
        static let wet = SwiftUI.Color(red: 0xD9 / 255, green: 0x45 / 255, blue: 0x3A / 255)
        static let remove = SwiftUI.Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
        static let equip = SwiftUI.Color(red: 0x12 / 255, green: 0xA5 / 255, blue: 0x94 / 255)
        static let source = SwiftUI.Color(red: 0x2F / 255, green: 0x7C / 255, blue: 0xF6 / 255)
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 28, weight: .bold)
        static let headline = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 17)
        static let callout = SwiftUI.Font.system(size: 15)
        static let caption = SwiftUI.Font.system(size: 13)
        static func value(_ size: CGFloat = 17) -> SwiftUI.Font { .system(size: size, weight: .semibold, design: .rounded) }
    }

    enum Radius {
        static let control: CGFloat = 14
        static let card: CGFloat = 22
    }
}

/// Capsule, 60 pt, accent fill. One per screen.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(DS.Color.accent.opacity(enabled ? 1 : 0.4), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Capsule on material.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DS.Color.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The 44 pt circle (also used as a Menu label).
struct IconButtonLabel: View {
    let systemImage: String
    var tint: Color = .primary
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Circle())
    }
}

struct IconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) { IconButtonLabel(systemImage: systemImage, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

/// 36 pt chip; selected = filled.
struct ChipButton: View {
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(selected ? AnyShapeStyle(DS.Color.ink) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(selected ? 0 : 0.1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
