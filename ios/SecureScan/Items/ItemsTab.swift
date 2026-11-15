//
//  ItemsTab.swift
//  SecureScan
//
//  Job screen › Items: everything captured, grouped by room, with filter
//  chips; tap an item to change its value / material / caption or delete it.
//  "Needs a quick fix" sits at the top when saved items are not on the plan.
//

import SwiftUI

@MainActor
final class ItemsViewModel: ObservableObject {
    @Published var snapshot = ItemsSnapshot()
    @Published var loaded = false
    @Published var thumbs: [String: UIImage] = [:]
    private var loadingThumbs = Set<String>()

    func load(folder: JobFolder, meta: JobMeta?) {
        Task {
            let s = await Task.detached(priority: .userInitiated) { ItemsModel.load(folder: folder, meta: meta) }.value
            snapshot = s
            loaded = true
        }
    }

    func thumb(for item: CapturedItem, folder: JobFolder) -> UIImage? {
        if let t = thumbs[item.id] { return t }
        guard let photo = item.photo, !loadingThumbs.contains(item.id) else { return nil }
        loadingThumbs.insert(item.id)
        let id = item.id
        Task {
            let img = await Task.detached(priority: .utility) { ItemsModel.thumbnail(photo, folder: folder) }.value
            if let img { thumbs[id] = img }
        }
        return nil
    }
}

extension JobViewModel {
    /// Items tab edits: take the editor's latest state, write plan.json (and
    /// readings-raw.json), then reload the editor and the other tabs.
    func editItem(_ item: CapturedItem, value: Double?, material: String?, text: String) {
        let folder = self.folder
        Task {
            if let editor { await editor.flushLatestPlan() }
            await Task.detached(priority: .userInitiated) {
                ItemsModel.edit(folder: folder, item: item, value: value, material: material, text: text)
            }.value
            planVersion += 1
        }
    }

    func deleteItem(id: String, kind: CapturedItem.Kind?) {
        let folder = self.folder
        Task {
            if let editor { await editor.flushLatestPlan() }
            await Task.detached(priority: .userInitiated) { ItemsModel.delete(folder: folder, id: id, kind: kind) }.value
            planVersion += 1
        }
    }
}

struct ItemsTab: View {
    @ObservedObject var vm: JobViewModel
    @StateObject private var model = ItemsViewModel()
    @State private var filter: CapturedItem.Filter = .all
    @State private var editing: CapturedItem?
    @State private var discarding: FixItem?

    private var visible: [CapturedItem] { model.snapshot.items.filter { $0.matches(filter) } }

    var body: some View {
        VStack(spacing: 0) {
            chips
            if model.loaded && model.snapshot.items.isEmpty && model.snapshot.fixes.isEmpty {
                ContentUnavailableView {
                    Label("Nothing captured yet", systemImage: "tray")
                } description: {
                    Text("Readings, photos and marks appear here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { model.load(folder: vm.folder, meta: vm.meta) }
        .onChange(of: vm.planVersion) { _, _ in model.load(folder: vm.folder, meta: vm.meta) }
        .sheet(item: $editing) { item in
            ItemEditSheet(item: item, thumb: model.thumbs[item.id], thresholds: (model.snapshot.damp, model.snapshot.wet),
                          onSave: { value, material, text in vm.editItem(item, value: value, material: material, text: text) },
                          onDelete: { vm.deleteItem(id: item.id, kind: item.kind) })
        }
        .confirmationDialog("Discard this item?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                            titleVisibility: .visible, presenting: discarding) { fix in
            Button("Discard", role: .destructive) { vm.deleteItem(id: fix.id, kind: nil) }
        } message: { _ in
            Text("It is removed from this job.")
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CapturedItem.Filter.allCases) { f in
                    let n = f == .all ? model.snapshot.items.count : model.snapshot.items.filter { $0.matches(f) }.count
                    Chip(n > 0 && f != .all ? "\(f.rawValue) \(n)" : f.rawValue, selected: filter == f) {
                        withAnimation(DS.Motion.tray) { filter = f }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var list: some View {
        List {
            if !model.snapshot.fixes.isEmpty && filter == .all { fixSection }
            ForEach(groups, id: \.id) { g in
                Section {
                    ForEach(g.items) { item in row(item) }
                } header: {
                    HStack {
                        Text(g.name)
                        Spacer()
                        Text("\(g.items.count)").monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private struct RoomGroup { var id: String; var name: String; var items: [CapturedItem] }

    private var groups: [RoomGroup] {
        let items = visible
        var out: [RoomGroup] = []
        for r in model.snapshot.rooms {
            let mine = items.filter { $0.roomID == r.id && $0.kind != .note }
            if !mine.isEmpty { out.append(RoomGroup(id: r.id, name: r.name, items: mine)) }
        }
        let known = Set(model.snapshot.rooms.map(\.id))
        let loose = items.filter { $0.kind != .note && ($0.roomID == nil || !known.contains($0.roomID!)) }
        if !loose.isEmpty { out.append(RoomGroup(id: "_none", name: model.snapshot.rooms.isEmpty ? "Items" : "Not in a room", items: loose)) }
        let notes = items.filter { $0.kind == .note }
        if !notes.isEmpty { out.append(RoomGroup(id: "_notes", name: "Site notes", items: notes)) }
        return out
    }

    // MARK: Needs a quick fix

    private var fixSection: some View {
        Section {
            ForEach(model.snapshot.fixes) { fix in
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DS.Color.damp)
                        .frame(width: 56, height: 56)
                        .background(DS.Color.damp.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fix.title).font(DS.Font.body.weight(.medium)).lineLimit(1)
                        Text(fix.detail).font(DS.Font.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { discarding = fix } label: { Label("Discard", systemImage: "trash") }
                }
            }
            HStack {
                Spacer()
                if model.snapshot.fixesFromInterruptedScan {
                    SecondaryButton(vm.busy ? "Placing…" : "Place them on the plan", icon: "wand.and.stars") { vm.regenerate() }
                        .disabled(vm.busy)
                } else {
                    SecondaryButton("Draw on the plan", icon: "pencil.and.outline") { vm.requestedTab = 0 }
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
        } header: {
            Text("Needs a quick fix")
        }
    }

    // MARK: Rows

    private func row(_ item: CapturedItem) -> some View {
        Button { if item.editable { editing = item } } label: {
            HStack(spacing: 12) {
                ItemThumb(item: item, image: model.thumb(for: item, folder: vm.folder))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(item.kind == .note ? 2 : 1)
                    Text(item.detail)
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.kind == .reading, let v = item.value {
                    ValueBadge(value: v, reference: item.reference, damp: model.snapshot.damp, wet: model.snapshot.wet)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { vm.deleteItem(id: item.id, kind: item.kind) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// Reading status colour (thresholds from the plan; a display aid only).
enum ReadingColor {
    static func color(_ v: Double, damp: Double, wet: Double) -> Color {
        v >= wet ? DS.Color.wet : (v >= damp ? DS.Color.damp : DS.Color.dry)
    }
}

struct ValueBadge: View {
    let value: Double
    var reference = false
    let damp: Double
    let wet: Double

    var body: some View {
        let c = ReadingColor.color(value, damp: damp, wet: wet)
        Text("\(ItemsModel.fmt(value)) %")
            .font(DS.Font.value(15))
            .monospacedDigit()
            .foregroundStyle(reference ? c : .white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(reference ? AnyShapeStyle(Color.clear) : AnyShapeStyle(c), in: Capsule())
            .overlay(Capsule().strokeBorder(c, lineWidth: reference ? 1.5 : 0))
    }
}

struct ItemThumb: View {
    let item: CapturedItem
    let image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                tint.opacity(0.14)
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
    }

    private var symbol: String {
        switch item.kind {
        case .reading: return "percent"
        case .boundary: return "point.topleft.down.to.point.bottomright.curvepath"
        case .photo: return "camera.fill"
        case .source: return "drop.fill"
        case .equipment: return "fan.fill"
        case .removal: return "scissors"
        case .affected: return "humidity.fill"
        case .floor: return "square.grid.3x3.fill"
        case .note: return "waveform"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .reading, .boundary, .source, .affected: return DS.Color.source
        case .equipment: return DS.Color.equip
        case .removal: return DS.Color.remove
        case .photo, .floor, .note: return .secondary
        }
    }
}

/// Edit one item: value + material (readings), caption / label / note, delete.
struct ItemEditSheet: View {
    let item: CapturedItem
    let thumb: UIImage?
    let thresholds: (Double, Double)
    let onSave: (Double?, String?, String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var valueText: String
    @State private var material: String
    @State private var text: String
    @State private var confirmDelete = false
    @FocusState private var valueFocused: Bool

    static let materials = ["wall", "skirting", "floor", "ceiling", "cabinetry", "other"]

    init(item: CapturedItem, thumb: UIImage?, thresholds: (Double, Double),
         onSave: @escaping (Double?, String?, String) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.thumb = thumb
        self.thresholds = thresholds
        self.onSave = onSave
        self.onDelete = onDelete
        _valueText = State(initialValue: item.value.map { ItemsModel.fmt($0) } ?? "")
        _material = State(initialValue: item.material)
        _text = State(initialValue: item.text)
    }

    private var isReading: Bool { item.kind == .reading }
    private var value: Double? { Double(valueText.replacingOccurrences(of: ",", with: ".")) }

    private var textLabel: String {
        switch item.kind {
        case .photo: return "Caption"
        case .source: return "Cause"
        case .equipment: return "Asset number"
        case .affected: return "Label"
        case .note: return "Note"
        default: return "Note"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let thumb {
                    Section {
                        Image(uiImage: thumb).resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 180)
                            .clipped()
                            .listRowInsets(EdgeInsets())
                    }
                }
                if isReading {
                    Section("Value") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            TextField("0", text: $valueText)
                                .keyboardType(.decimalPad)
                                .focused($valueFocused)
                                .font(DS.Font.value(34))
                                .foregroundStyle(value.map { ReadingColor.color($0, damp: thresholds.0, wet: thresholds.1) } ?? .primary)
                            Text("%").font(DS.Font.headline).foregroundStyle(.secondary)
                        }
                    }
                    Section("Material") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.materials, id: \.self) { m in
                                    Chip(m == "cabinetry" ? "Cabinet" : m.capitalized, selected: material == m) { material = m }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if item.kind != .boundary {
                    Section(textLabel) {
                        TextField(textLabel, text: $text, axis: .vertical)
                            .lineLimit(item.kind == .note ? 6 : 2)
                    }
                }
                Section {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(item.kind == .note ? "Site note" : item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(isReading ? value : nil, isReading ? material : nil, text)
                        dismiss()
                    }
                    .disabled(isReading && value == nil)
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(); dismiss() }
            }
        }
        .presentationDetents(isReading || thumb != nil ? Set<PresentationDetent>([.large]) : Set<PresentationDetent>([.medium, .large]))
    }
}
