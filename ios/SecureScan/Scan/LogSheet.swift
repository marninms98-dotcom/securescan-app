//
//  LogSheet.swift
//  SecureScan
//
//  The fast sheet after tapping "Log" - one tool for every input type, used
//  by the scan screen and by Return visit:
//    Reading / Moisture line / Photo / Source / Equipment / Removal
//  (a 3 + 3 grid of big buttons; the last type used is preselected).
//  Reading: number pad, material chips, Reference toggle, Save.
//  Moisture line: one tap (choosing it saves; when preselected, one Save tap).
//  Photo: caption chips, Save.   Source: tap a label chip to save.
//  Equipment: type chips, optional label, Place.
//  Removal: item chips, then "Start here" (this frame is the start; then
//  "End here" on the screen) or, for flooring, "Mark the floor corners".
//  Flooring also offers "Floor type of this room" chips.
//

import SwiftUI

/// What the sheet needs from its screen (ScanModel, RevisitModel).
@MainActor
protocol LogSheetModel: ObservableObject {
    var lastMaterial: String { get }
    var lastEquipmentType: String { get }
    var lastKind: String { get }
    var lastRemovalItem: String { get }
    var nextReadingNumber: Int { get }
    var nextPhotoNumber: Int { get }
    func saveLog(kind: String, value: Double?, material: String, reference: Bool, note: String)
    func cancelLog()
    /// The pending frame becomes the start of a removal (or the first step of a flooring section).
    func startRemoval(item: String)
}

enum LogKind: String, CaseIterable, Identifiable {
    case reading, boundary, photo, source, equipment, removal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reading: return "Reading"
        case .boundary: return "Moisture line"
        case .photo: return "Photo"
        case .source: return "Source"
        case .equipment: return "Equipment"
        case .removal: return "Removal"
        }
    }
    var icon: String {
        switch self {
        case .reading: return "percent"
        case .boundary: return "square.dashed"
        case .photo: return "camera"
        case .source: return "drop.triangle"
        case .equipment: return "fan"
        case .removal: return "scissors"
        }
    }
    /// Display name of any logged kind (including "floorType").
    static func name(_ kind: String) -> String {
        if kind == "floorType" { return "Floor type" }
        return LogKind(rawValue: kind)?.title ?? "Item"
    }
}

enum RemovalItems {
    static let all: [(key: String, name: String, mm: Int)] = [
        ("plasterboard", "Plasterboard", 600), ("skirting", "Skirting", 100), ("cabinetry", "Cabinetry", 900),
        ("flooring", "Flooring", 0), ("other", "Other", 600),
    ]
    static func name(_ key: String) -> String { all.first { $0.key == key }?.name ?? "Other" }
    static func defaultMm(_ key: String) -> Int { all.first { $0.key == key }?.mm ?? 600 }
    static let heights: [(label: String, mm: Int)] = [("300", 300), ("600", 600), ("1200", 1200), ("Full height", 2400)]
    static let floorTypes = FloorArea.types
}

struct LogSheet<Model: LogSheetModel>: View {
    @ObservedObject var model: Model

    static var materials: [String] { ["skirting", "wall", "floor", "ceiling", "cabinetry"] }
    static var captions: [String] { ["Overview", "Inspection opening", "Damage", "Source", "Other"] }
    static var sourceLabels: [String] { ["Burst pipe", "Flexi hose", "Roof leak", "Shower", "Appliance", "Unknown"] }

    @State private var kind: LogKind
    @State private var text = ""
    @State private var material: String
    @State private var reference = false
    @State private var caption = ""
    @State private var equipmentType: String
    @State private var equipmentLabel = ""
    @State private var removalItem: String

    init(model: Model) {
        self.model = model
        _kind = State(initialValue: LogKind(rawValue: model.lastKind) ?? .reading)
        _material = State(initialValue: model.lastMaterial)
        _equipmentType = State(initialValue: model.lastEquipmentType)
        _removalItem = State(initialValue: model.lastRemovalItem)
    }

    private var value: Double? {
        guard !text.isEmpty, let v = Double(text), v >= 0, v < 1000 else { return nil }
        return v
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { model.cancelLog() }
                Spacer()
            }
            kindPicker
            switch kind {
            case .reading: readingForm
            case .boundary: boundaryForm
            case .photo: photoForm
            case .source: sourceForm
            case .equipment: equipmentForm
            case .removal: removalForm
            }
        }
        .padding()
        // Moisture line is one tap: choosing it saves straight away.
        .onChange(of: kind) { _, newValue in
            if newValue == .boundary {
                model.saveLog(kind: "boundary", value: nil, material: "wall", reference: false, note: "")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Six big buttons in two rows of three, each at least 56 pt tall.
    private var kindPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(LogKind.allCases) { k in
                Button { kind = k } label: {
                    VStack(spacing: 4) {
                        Image(systemName: k.icon).font(.title3)
                        Text(k.title).font(.subheadline.weight(.semibold))
                            .lineLimit(2).multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(kind == k ? Color.accentColor : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(kind == k ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == k ? .isSelected : [])
            }
        }
    }

    private func bigButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
    }

    // MARK: Reading

    private var readingForm: some View {
        VStack(spacing: 12) {
            Text(text.isEmpty ? "– %" : "\(text) %")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .accessibilityLabel(text.isEmpty ? "No value" : "\(text) percent")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.materials, id: \.self) { m in
                        Chip(title: m.capitalized, selected: material == m) { material = m }
                    }
                }
            }
            Toggle("Reference (dry) reading", isOn: $reference)
                .font(.headline)
            NumberPad(text: $text)
            bigButton("Save reading \(model.nextReadingNumber)", enabled: value != nil) {
                model.saveLog(kind: "reading", value: value, material: material, reference: reference, note: "")
            }
        }
    }

    // MARK: Moisture line

    private var boundaryForm: some View {
        VStack(spacing: 14) {
            Text("A point on the top edge of the wet area. Log one at each spot along the wall; they join into a line.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            bigButton("Save moisture-line point") {
                model.saveLog(kind: "boundary", value: nil, material: "wall", reference: false, note: "")
            }
        }
    }

    // MARK: Water source

    private var sourceForm: some View {
        VStack(spacing: 14) {
            Text("Where the water came from. Tap a label to save, or save without one.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            FlowChips(items: Self.sourceLabels) { label in
                model.saveLog(kind: "source", value: nil, material: "wall", reference: false, note: label)
            }
            Spacer(minLength: 0)
            bigButton("Save source") {
                model.saveLog(kind: "source", value: nil, material: "wall", reference: false, note: "")
            }
        }
    }

    // MARK: Equipment

    private var equipmentForm: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(PlanDocument.equipmentTypes.map { $0.key }, id: \.self) { key in
                    Chip(title: PlanDocument.equipmentName(key), selected: equipmentType == key) { equipmentType = key }
                }
            }
            TextField("Label or asset no. (optional)", text: $equipmentLabel)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .textInputAutocapitalization(.characters)
            Spacer(minLength: 0)
            bigButton("Place \(PlanDocument.equipmentName(equipmentType).lowercased())") {
                model.saveLog(kind: "equipment", value: nil, material: equipmentType, reference: false,
                              note: equipmentLabel.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: Removal

    private var removalForm: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(RemovalItems.all.map { $0.key }, id: \.self) { key in
                    Chip(title: RemovalItems.name(key), selected: removalItem == key) { removalItem = key }
                }
            }
            if removalItem == "flooring" {
                Text("Tap each corner of the section on the floor, then Done. Or use the whole room.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or just tag this room's floor type:").font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(RemovalItems.floorTypes, id: \.self) { t in
                                Chip(title: t.capitalized, selected: false) {
                                    model.saveLog(kind: "floorType", value: nil, material: t, reference: false, note: "")
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                bigButton("Mark the floor corners") { model.startRemoval(item: removalItem) }
            } else {
                Text("The crosshair is on the START of the stretch. Tap Start here, then point at the end of the same wall and tap End here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                bigButton("Start here") { model.startRemoval(item: removalItem) }
            }
        }
    }

    // MARK: Photo note

    private var photoForm: some View {
        VStack(spacing: 14) {
            TextField("Caption", text: $caption)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            FlowChips(items: Self.captions) { c in
                caption = caption.isEmpty || Self.captions.contains(caption) ? c : caption + " — " + c
            }
            Spacer(minLength: 0)
            bigButton("Save photo P\(model.nextPhotoNumber)") {
                model.saveLog(kind: "photo", value: nil, material: "wall", reference: false,
                              note: caption.trimmingCharacters(in: .whitespaces))
            }
        }
    }
}

/// After "End here": item and height of a wall removal.
struct RemovalDetailsSheet: View {
    @State var item: String
    @State private var mm: Int
    @State private var note = ""
    let lengthText: String?
    let onSave: (String, Int, String) -> Void
    let onCancel: () -> Void

    init(item: String, lengthText: String?, onSave: @escaping (String, Int, String) -> Void, onCancel: @escaping () -> Void) {
        _item = State(initialValue: item)
        _mm = State(initialValue: RemovalItems.defaultMm(item))
        self.lengthText = lengthText
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                if let lengthText { Text(lengthText).font(.headline).foregroundStyle(.secondary) }
            }
            Text("Remove").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(RemovalItems.all.map { $0.key }.filter { $0 != "flooring" }, id: \.self) { key in
                    Chip(title: RemovalItems.name(key), selected: item == key) {
                        item = key
                        mm = RemovalItems.defaultMm(key)
                    }
                }
            }
            Text("Height").font(.headline)
            HStack {
                ForEach(RemovalItems.heights.map { $0.mm }, id: \.self) { h in
                    Chip(title: RemovalItems.heights.first { $0.mm == h }?.label ?? "\(h)", selected: mm == h) { mm = h }
                }
                if !RemovalItems.heights.contains(where: { $0.mm == mm }) {
                    Chip(title: "\(mm)", selected: true) {}
                }
            }
            TextField("Note (optional)", text: $note).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            Button { onSave(item, mm, note.trimmingCharacters(in: .whitespaces)) } label: {
                Text("Save removal").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .presentationDetents([.medium, .large])
    }
}

/// After the floor corners (or Whole room): floor type and underlay.
struct FloorDetailsSheet: View {
    @State private var type = "vinyl"
    @State private var underlay = false
    @State private var note = ""
    let summary: String
    let onSave: (String, Bool, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Text(summary).font(.headline).foregroundStyle(.secondary)
            }
            Text("Remove flooring").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(RemovalItems.floorTypes, id: \.self) { t in
                    Chip(title: t.capitalized, selected: type == t) { type = t }
                }
            }
            Toggle("Underlay too", isOn: $underlay).font(.headline)
            TextField("Note (optional)", text: $note).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            Button { onSave(type, underlay, note.trimmingCharacters(in: .whitespaces)) } label: {
                Text("Save flooring removal").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .presentationDetents([.medium, .large])
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Wrapping rows of chips (simple: three per row; short fixed captions).
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack { ForEach(row, id: \.self) { i in Chip(title: i, selected: false) { onTap(i) } } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Big phone-style number pad.
struct NumberPad: View {
    @Binding var text: String
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(keys, id: \.self) { k in
                Button { press(k) } label: {
                    Text(k)
                        .font(.title.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k == "⌫" ? "Delete" : k)
            }
        }
    }

    private func press(_ k: String) {
        switch k {
        case "⌫": if !text.isEmpty { text.removeLast() }
        case ".": if !text.contains(".") && text.count < 5 { text += text.isEmpty ? "0." : "." }
        default:
            if text.count >= 5 { return }
            if let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 1 { return }
            text = (text == "0") ? k : text + k
        }
    }
}
