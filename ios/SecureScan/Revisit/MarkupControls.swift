//
//  MarkupControls.swift
//  SecureScan
//
//  The bottom of the AR mark-up screen (first scan and return visits):
//  a mode strip (Reading · Moisture · Photo · Source · Equipment · Removal)
//  and one big button whose label says exactly what a tap does. In
//  Moisture mode the button is held and swept: a moisture line along the
//  walls, or (Wet floor) the edge of the wet area on the floor. Also the
//  sheet for an item tapped in the camera view, and the list of items.
//

import SwiftUI

struct MarkupControls: View {
    @ObservedObject var model: RevisitModel
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 10) {
            if model.moving != nil {
                HStack {
                    Text("Aim where it should go").font(.callout.bold())
                    Spacer()
                    Button("Cancel move") { model.cancelMove() }.buttonStyle(.bordered)
                }
            } else if model.mode == .moisture {
                moistureOptions
            }
            if model.isLaterVisit, model.mode == .reading, model.moving == nil {
                let p = model.progress
                if p.total > 0 { Text("\(p.done) of \(p.total) points re-measured").font(.subheadline.bold()) }
            }
            bigButton
            modeStrip
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var tint: Color {
        if model.moving != nil { return .orange }
        if model.target != nil { return .green }
        return model.mode == .moisture ? Color(red: 0.17, green: 0.42, blue: 0.85) : .blue
    }

    /// Hold-aware: a press starts a sweep in Moisture mode; a short press is a tap.
    private var bigButton: some View {
        Text(model.actionTitle)
            .font(.title2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(model.sweeping ? 0.75 : 1)))
            .opacity(model.canAct ? 1 : 0.45)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        model.pressBegan()
                    }
                    .onEnded { _ in
                        pressed = false
                        model.pressEnded()
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.actionTitle)
            .accessibilityAction { model.mainAction() }
    }

    private var moistureOptions: some View {
        VStack(spacing: 8) {
            Picker("Draw on", selection: $model.moistureOnFloor) {
                Text("Line on the wall").tag(false)
                Text("Wet floor area").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(model.sweeping || model.floorCornerCount > 0)
            HStack(spacing: 10) {
                if model.floorCornerCount > 0 {
                    Button("Undo corner") { model.undoFloorCorner() }.buttonStyle(.bordered)
                    Button("Close area (\(model.floorCornerCount))") { model.closeFloorArea() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.floorCornerCount < 3)
                } else {
                    Text(model.moistureOnFloor ? "Hold and sweep round the wet edge, or tap each corner."
                                               : "Hold and sweep along the wet edge. A tap adds one point.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.strokeCount > 0 {
                    Button { model.undoStroke() } label: { Label("Undo stroke", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var modeStrip: some View {
        HStack(spacing: 4) {
            ForEach(MarkupMode.allCases) { m in
                Button {
                    model.mode = m
                    model.lastKind = m.kind
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: m.icon).font(.body.weight(.semibold))
                        Text(m.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(model.mode == m ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 10).fill(model.mode == m ? Color.accentColor : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.title) mode")
                .accessibilityAddTraits(model.mode == m ? .isSelected : [])
            }
        }
        .disabled(model.sweeping || model.moving != nil || model.floorCornerCount > 0)
    }
}

/// An item tapped in AR: change it, nudge it, move it or delete it.
struct MarkerEditSheet: View {
    let edit: MarkerEdit
    @ObservedObject var model: RevisitModel
    @State private var text: String
    @State private var material: String
    @State private var label: String
    @State private var confirmDelete = false

    init(edit: MarkerEdit, model: RevisitModel) {
        self.edit = edit
        self.model = model
        _text = State(initialValue: edit.value.map { RevisitModel.fmtValue($0) } ?? "")
        _material = State(initialValue: edit.material)
        _label = State(initialValue: edit.label)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if edit.kind == "reading" {
                        Text(text.isEmpty ? "– %" : "\(text) %")
                            .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                            .frame(maxWidth: .infinity)
                        NumberPad(text: $text)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(LogSheet<RevisitModel>.materials, id: \.self) { m in
                                    Chip(title: m.capitalized, selected: material == m) { material = m }
                                }
                            }
                        }
                    }
                    if edit.kind != "boundary" && edit.kind != "floor" {
                        TextField(edit.kind == "reading" || edit.kind == "removal" ? "Note" : "Label", text: $label)
                            .textFieldStyle(.roundedBorder)
                    }
                    if edit.hasHeight {
                        HStack {
                            Text("Height").font(.headline)
                            Spacer()
                            Button { model.nudge(edit.id, by: -0.05) } label: { Label("5 cm lower", systemImage: "arrow.down") }
                                .buttonStyle(.bordered)
                            Button { model.nudge(edit.id, by: 0.05) } label: { Label("5 cm higher", systemImage: "arrow.up") }
                                .buttonStyle(.bordered)
                        }
                    }
                    if edit.canRemeasure, let m = model.markers.first(where: { $0.id == edit.id }) {
                        Button("Re-measure for this visit") { model.editing = nil; model.beginRemeasure(m) }
                            .buttonStyle(.borderedProminent)
                    }
                    if edit.canMarkRemoved {
                        Button("Mark removed today") { model.editing = nil; model.confirm = .equipmentRemoved(id: edit.id, name: edit.title) }
                            .buttonStyle(.bordered)
                    }
                    if edit.canMarkDone {
                        Button("Mark done + after photo") { model.editing = nil; model.confirm = .removalDone(id: edit.id, name: edit.title) }
                            .buttonStyle(.bordered)
                    }
                    HStack {
                        if edit.movable {
                            Button { model.startMove(edit.id) } label: { Label("Move…", systemImage: "move.3d") }
                                .buttonStyle(.bordered)
                        }
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle(edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveEdit(edit, value: Double(text), material: material, label: label) }
                        .disabled(edit.kind == "reading" && Double(text) == nil)
                }
            }
            .confirmationDialog("Delete \(edit.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteItem(edit.id) }
                Button("Keep", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
    }
}

/// Everything marked up so far (this room / this visit), newest first; tap to edit, swipe to delete.
struct MarkupItemsView: View {
    @ObservedObject var model: RevisitModel

    var body: some View {
        NavigationStack {
            List {
                if model.markers.isEmpty { Text("Nothing marked up yet.").foregroundStyle(.secondary) }
                ForEach(Array(model.markers.reversed()), id: \.id) { m in
                    Button {
                        model.showItems = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.openEditor(m.id) }
                    } label: {
                        HStack {
                            Text(RevisitModel.kindName(m.kind)).font(.headline)
                            Spacer()
                            Text(m.label).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.removeItems([m.id]) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Marked up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showItems = false } } }
        }
    }
}
