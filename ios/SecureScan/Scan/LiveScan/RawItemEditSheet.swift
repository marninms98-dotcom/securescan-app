//
//  RawItemEditSheet.swift
//  SecureScan
//
//  Tap an item in the scan screens' list: change the value, material or
//  caption / label, or delete it - the same sheet as the mark-up list, for
//  items still in readings-raw.json (and in plan.json once a mark-up built it).
//

import SwiftUI

extension ScanModel {
    /// Writes the change to readings-raw.json and, when plan.json exists, to the plan item too.
    func editItem(_ id: String, value: Double?, material: String?, note: String) {
        updateRaw(id) { r in
            r.note = note
            if r.kind == "reading" { r.value = value; if let material { r.material = material } }
        }
        guard !preview, let data = try? Data(contentsOf: folder.planURL),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let f = MarkupEdit.find(doc, id: id) else { return }
        var set: [String: Any] = [["sources", "equipment", "affected"].contains(f.list) ? "label" : "note": note]
        if f.list == "readings", (f.item["kind"] as? String ?? "reading") == "reading" {
            set["value"] = value.map { $0 as Any } ?? NSNull()
            if let material { set["material"] = material }
        }
        if let out = MarkupEdit.update(doc, id: id, set: set),
           let clean = PlanDocument.sanitised(out) as? [String: Any],
           let bytes = try? PlanDocument.data(clean) {
            try? bytes.write(to: folder.planURL, options: .atomic)
        }
    }
}

struct RawItemEditSheet: View {
    @ObservedObject var model: ScanModel
    let item: RawReading
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var material: String
    @State private var note: String
    @State private var confirmDelete = false

    init(model: ScanModel, item: RawReading) {
        self.model = model
        self.item = item
        _text = State(initialValue: item.value.map { ScanModel.format($0) } ?? "")
        _material = State(initialValue: item.material)
        _note = State(initialValue: item.note)
    }

    private var isReading: Bool { item.kind == "reading" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isReading {
                        Text(text.isEmpty ? "– %" : "\(text) %")
                            .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                            .frame(maxWidth: .infinity)
                        NumberPad(text: $text)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(LogSheet<ScanModel>.materials, id: \.self) { m in
                                    LegacyChip(title: LogSheet<ScanModel>.materialTitle(m), selected: material == m) { material = m }
                                }
                            }
                        }
                    }
                    if item.kind != "boundary" {
                        TextField(item.kind == "photo" ? "Caption" : (isReading || item.kind == "removal" ? "Note" : "Label"), text: $note)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle(model.describe(item).title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.editItem(item.id, value: Double(text), material: isReading ? material : nil, note: note)
                        dismiss()
                    }
                    .disabled(isReading && Double(text) == nil)
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.delete(item.id); dismiss() }
                Button("Keep", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
    }
}
