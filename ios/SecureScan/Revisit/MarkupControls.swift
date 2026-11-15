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
            } else {
                switch model.mode {
                case .moisture: moistureOptions
                case .equipment:
                    choiceRow(PlanDocument.equipmentTypes.filter { $0.key != "other" }.map { ($0.key, $0.name) },
                              selected: model.lastEquipmentType) { model.lastEquipmentType = $0 }
                case .wallRemoval:
                    choiceRow(RemovalItems.all.filter { $0.key != "flooring" }.map { ($0.key, $0.name) },
                              selected: model.wallRemovalItem) { model.wallRemovalItem = $0 }
                    if model.reticleWall != nil {
                        Button { model.wholeWall() } label: {
                            Label("Whole wall", systemImage: "arrow.left.and.right").font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.canAct)
                    }
                case .remeasure:
                    let p = model.progress
                    if p.total > 0 { Text("\(p.done) of \(p.total) points re-measured").font(.subheadline.bold()) }
                default: EmptyView()
                }
            }
            if model.aimingDir != nil {
                HStack {
                    Text("Point the phone the way the air should blow").font(.callout.bold())
                    Spacer()
                    Button("Skip") { model.skipDirection() }.buttonStyle(.bordered)
                }
            }
            if model.undoChipVisible {
                HStack {
                    Spacer()
                    Button { model.undoLast() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward").font(.subheadline.bold())
                            .frame(minWidth: 88, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            bigButton
            modeStrip
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Self.accent(model.workMode).opacity(0.8), lineWidth: 2))
    }

    static func accent(_ w: WorkMode) -> Color {
        switch w {
        case .inspect: return Color(red: 0.17, green: 0.42, blue: 0.85)
        case .quote: return Color(red: 0.85, green: 0.47, blue: 0.10)
        case .monitor: return Color(red: 0.10, green: 0.55, blue: 0.50)
        }
    }

    private func choiceRow(_ items: [(String, String)], selected: String, pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    LegacyChip(title: items[i].1, selected: selected == items[i].0) { pick(items[i].0) }
                }
            }
        }
        .disabled(model.sweeping || model.flow.isBusy)
    }

    private var tint: Color {
        if model.moving != nil { return .orange }
        if model.target != nil { return .green }
        return Self.accent(model.workMode)
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
            ForEach(model.workMode.tools) { m in
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
                    .background(RoundedRectangle(cornerRadius: 10).fill(model.mode == m ? Self.accent(model.workMode) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.title) mode")
                .accessibilityAddTraits(model.mode == m ? .isSelected : [])
            }
        }
        .disabled(model.sweeping || model.moving != nil || model.floorCornerCount > 0)
    }
}

/// The top of the mark-up screen: Inspect · Quote · Monitor, its one-line
/// prompt, and in Quote mode the running tally (opens the items list).
struct WorkModeBar: View {
    @ObservedObject var model: RevisitModel

    var body: some View {
        VStack(spacing: 6) {
            Picker("Mode", selection: Binding(get: { model.workMode }, set: { model.setWorkMode($0) })) {
                ForEach(model.workModes) { Text($0.label(pricesVisible: model.pricesVisible)).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.sweeping || model.flow.isBusy || model.moving != nil)
            Text(model.workMode.promptText(pricesVisible: model.pricesVisible))
                .font(.footnote)
                .multilineTextAlignment(.center)
            if model.workMode == .quote {
                Button { model.showItems = true } label: {
                    Label(model.quoteTally.text, systemImage: "sum")
                        .font(.footnote.bold())
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(MarkupControls.accent(.quote).opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scope so far: \(model.quoteTally.text). Show items")
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                                    LegacyChip(title: LogSheet<RevisitModel>.materialTitle(m), selected: material == m) { material = m }
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
                    if edit.isAirMover {
                        Button { model.reAimAirflow(edit.id) } label: { Label("Re-aim airflow", systemImage: "wind") }
                            .buttonStyle(.bordered)
                    }
                    if edit.planned {
                        Button("Mark placed") { model.editing = nil; model.confirm = .equipmentPlaced(id: edit.id, name: edit.title) }
                            .buttonStyle(.bordered)
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

/// "See scope on site": the bottom strip. Aim at an item: its plain
/// description and the one thing to do with it. No prices, no re-scoping.
struct ScopeControls: View {
    @ObservedObject var model: RevisitModel

    var body: some View {
        let p = ScopeList.progress(model.scopeItems)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.showScopeList = true } label: {
                    Label("\(p.done) of \(p.total) done", systemImage: "checklist")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(MarkupControls.accent(.quote).opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Edit scope") { model.editScope() }.font(.footnote)
            }
            Text(model.aimedScope?.title ?? "Aim the crosshair at a red band, a floor section or a ghost marker.")
                .font(.headline)
                .lineLimit(2)
            Button { model.mainAction() } label: {
                Text(model.actionTitle).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.aimedScope.map { $0.done ? Color.gray : Color.green } ?? MarkupControls.accent(.quote))
            .disabled(!model.canAct || model.aimedScope == nil || model.aimedScope?.done == true)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// The scope as a list: in AR (from the chip) or as the fallback without the
/// camera, where items are marked placed / done without a photo.
struct ScopeListView: View {
    @ObservedObject var model: RevisitModel
    var withoutCamera = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                if withoutCamera {
                    Text("The camera couldn't line up with the saved scan, so here is the scope as a list. Mark things placed or done here; the after photos can be added later.")
                        .font(.callout)
                    MiniPlanView(model: model, interactive: false).frame(height: 220)
                }
                if model.scopeItems.isEmpty { Text("Nothing has been scoped for this job yet.").foregroundStyle(.secondary) }
                ForEach(model.scopeItems) { it in
                    HStack {
                        Image(systemName: it.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(it.done ? Color.green : Color.secondary)
                        Text(it.title).font(.callout)
                        Spacer()
                        if !it.done && withoutCamera {
                            Button(it.kind == .equipment ? "Placed" : "Done") { model.markFromList(it) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Scope of works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if let onClose { onClose() } else { model.showScopeList = false } }
                }
            }
        }
    }
}
