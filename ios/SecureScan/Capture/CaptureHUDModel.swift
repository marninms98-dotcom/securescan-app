//
//  CaptureHUDModel.swift
//  SecureScan
//
//  The state of the one capture screen, shared by every engine: which tool
//  is selected, what the reticle is on, what the primary button says and
//  does, the open tray and its draft (reading value, mark, source cause,
//  room name), the capture stack, the Undo chip, the review drawer. The
//  engine supplies the camera and saves; this class never touches ARKit.
//

import SwiftUI
import UIKit
import simd

enum CaptureTray: Equatable { case reading, mark, source, roomName, review }

@MainActor
final class CaptureHUDModel: ObservableObject {
    let engine: CaptureEngine

    // Tool and aim
    @Published var tool: CaptureTool
    @Published private(set) var aim: Aim = .none
    @Published var tray: CaptureTray?
    @Published var context: WorkContext = .inspect
    // Captured this session
    @Published private(set) var stack = CaptureStack()
    @Published private(set) var thumbs: [String: UIImage] = [:]
    @Published private(set) var undoVisible = false
    @Published private(set) var toast: String?
    /// Bumped on every save: the view flashes / flies a token to the stack.
    @Published private(set) var saveTick = 0
    @Published private(set) var lastSaveWasPhoto = false
    /// The engine's display strings, re-read on every tick.
    @Published private(set) var display = EngineDisplay()

    // Reading tray
    @Published var readingText = ""
    @Published var readingMaterial = "wall"
    @Published var readingReference = false
    /// Review: the reading being edited (nil = a new one).
    @Published var editingId: String?
    private(set) var pendingShot: CaptureShot?

    // Mark tool
    @Published private(set) var markShots: [CaptureShot] = []
    @Published private(set) var markStartShape: MarkShape?
    @Published private(set) var markShape: MarkShape?
    @Published private(set) var markPoints: [MarkPoint] = []
    @Published var markMeaning: MarkMeaning?
    @Published var liningMm = 600
    @Published var floorType = "carpet"
    @Published var underlay = false
    @Published private(set) var markWholeRoom = false
    private var remembered: [String: MarkMeaning] = [:]

    // Equipment
    @Published var equipmentType = "airMover"
    /// The air mover whose airflow is being aimed.
    @Published private(set) var airflowFor: String?

    // Source
    @Published var sourceCause: String?
    @Published var sourceNote = ""

    // Room name
    @Published var roomChoice: String?
    @Published var roomOther = ""
    @Published var roomTyping = false

    // Review
    @Published var reviewSelected: String?

    /// First-run coach lines (off in the Studio).
    var hintsEnabled = true
    var coachHint: String? {
        guard hintsEnabled, tray == nil, !UserDefaults.standard.bool(forKey: "coach." + tool.rawValue) else { return nil }
        return CaptureCopy.coach(tool)
    }

    private var undoTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastLockKey = ""

    init(engine: CaptureEngine) {
        self.engine = engine
        tool = CaptureTool.rail(returnVisit: engine.isReturnVisit, scopeOnSite: engine.isScopeOnSite).first ?? .reading
        display = EngineDisplay(engine)
    }

    var tools: [CaptureTool] { CaptureTool.rail(returnVisit: engine.isReturnVisit, scopeOnSite: engine.isScopeOnSite) }

    // MARK: Tick (~15 Hz, from the view)

    func tick() {
        let d = EngineDisplay(engine)
        if d != display { display = d }
        // While a tray is open the reticle is frozen on the captured point.
        guard tray == nil else { return }
        let a = engine.aimSample().map { AimInterpreter.interpret($0, world: engine.world, snapEnds: tool == .mark) } ?? .none
        if a != aim {
            let key = "\(a.surface?.rawValue ?? "-")|\(a.wall?.id ?? "-")|\(a.snapped)"
            if key != lastLockKey && a.hit != nil && aim.hit != nil { DS.Haptic.lock() }
            lastLockKey = key
            aim = a
        }
    }

    /// Studio and tests: set the aim directly.
    func setAim(_ a: Aim) { aim = a }

    // MARK: Tools

    func select(_ t: CaptureTool) {
        guard t != tool else { return }
        cancelMark()
        airflowFor = nil
        tray = nil
        tool = t
    }

    // MARK: The primary button

    struct Primary: Equatable {
        var title: String
        var enabled: Bool
        var tint: Color = DS.Color.accent
    }

    var primary: Primary {
        if let t = tray { return trayPrimary(t) }
        // One primary colour everywhere: meaning colours live on chips and world marks.
        if let o = engine.primaryOverride(tool: tool, aim: aim) { return Primary(title: o.title, enabled: o.enabled) }
        if airflowFor != nil { return Primary(title: CaptureCopy.setAirflow, enabled: aim.blocked != CaptureCopy.findingRoom) }
        if tool == .photo { return Primary(title: CaptureCopy.takePhoto, enabled: aim.blocked != CaptureCopy.findingRoom) }
        if let why = aim.blocked { return Primary(title: why, enabled: false) }
        switch tool {
        case .reading: return Primary(title: CaptureCopy.addReading, enabled: true)
        case .source: return Primary(title: CaptureCopy.markSource, enabled: true)
        case .equipment:
            if let u = existingUnit { return Primary(title: EquipmentGuard.action(for: u), enabled: u.type == "airMover") }
            return Primary(title: CaptureCopy.place(equipmentType), enabled: true)
        case .mark: return Primary(title: markTitle, enabled: true)
        case .photo: return Primary(title: CaptureCopy.takePhoto, enabled: true)
        case .remeasure, .done: return Primary(title: "Aim at a saved point", enabled: false)
        }
    }

    private func trayPrimary(_ t: CaptureTray) -> Primary {
        switch t {
        case .reading:
            return Primary(title: editingId == nil ? CaptureCopy.saveReading(readingText) : (readingValue == nil ? "Type the reading" : "Save changes"),
                           enabled: readingValue != nil)
        case .mark:
            return Primary(title: CaptureCopy.saveMark(markMeaning, length: markLength, area: markArea), enabled: markMeaning != nil)
        case .source:
            return Primary(title: sourceCause.map { "Save · \($0 == "Unknown" ? "Unknown cause" : $0)" } ?? "Pick a cause", enabled: sourceCause != nil)
        case .roomName:
            let name = roomTyping ? roomOther.trimmingCharacters(in: .whitespaces) : (roomChoice ?? "")
            return Primary(title: name.isEmpty ? "Pick a name" : "Save · \(name)", enabled: !name.isEmpty)
        case .review:
            return Primary(title: "Done", enabled: true)
        }
    }

    var readingValue: Double? {
        guard !readingText.isEmpty, let v = Double(readingText), v >= 0, v < 1000 else { return nil }
        return v
    }

    private var markTitle: String {
        guard let first = markPoints.first else { return CaptureCopy.startHere }
        let cursor = aim.hit
        if markStartShape == .line {
            return CaptureCopy.endHere(cursor.map { simd_distance(first.world, $0) })
        }
        if markPoints.count >= 3, closesArea {
            return CaptureCopy.closeArea(MarkIntent.area(markPoints))
        }
        let withCursor = markPoints + (cursor.map { [MarkPoint(world: $0, surface: .floor, height: 0, distanceToWall: nil)] } ?? [])
        return CaptureCopy.addCorner(withCursor.count >= 3 ? MarkIntent.area(withCursor) : nil)
    }

    /// The reticle is on the first corner (closing snaps to it).
    var closesArea: Bool {
        guard let f = markPoints.first, let h = aim.hit else { return false }
        return simd_distance(PlanVec(f.world.x, f.world.z), PlanVec(h.x, h.z)) <= MarkIntent.closeDistance
    }

    var markLength: Double? {
        guard markShape == .line, markPoints.count >= 2 else { return nil }
        return simd_distance(PlanVec(markPoints[0].world.x, markPoints[0].world.z), PlanVec(markPoints[1].world.x, markPoints[1].world.z))
    }

    var markArea: Double? { markShape == .area ? MarkIntent.area(markPoints) : nil }

    /// An existing unit of the selected type within 0.5 m of where the reticle meets the floor.
    var existingUnit: EquipmentGuard.Unit? {
        guard let h = aim.hit else { return nil }
        return EquipmentGuard.existing(type: equipmentType, at: PlanVec(h.x, h.z), units: engine.equipmentUnits())
    }

    func tapPrimary() {
        guard primary.enabled else { DS.Haptic.warning(); return }
        if let t = tray { saveTray(t); return }
        if let o = engine.primaryOverride(tool: tool, aim: aim) { o.action(); return }
        if let id = airflowFor { setAirflow(id); return }
        switch tool {
        case .reading: beginReading()
        case .photo: takePhoto()
        case .source: beginSource()
        case .equipment: placeEquipment()
        case .mark: markTap()
        case .remeasure, .done: break
        }
    }

    // MARK: Reading

    private func beginReading() {
        guard let s = takeShot(photo: true) else { return }
        pendingShot = s
        editingId = nil
        readingText = ""
        readingMaterial = CaptureCopy.material(aim)
        readingReference = false
        open(.reading)
    }

    func key(_ k: String) {
        switch k {
        case "⌫": if !readingText.isEmpty { readingText.removeLast() }
        case ".": if !readingText.contains(".") && readingText.count < 5 { readingText += readingText.isEmpty ? "0." : "." }
        default:
            guard readingText.count < 5 else { return }
            if readingText == "0" { readingText = k } else { readingText += k }
        }
    }

    // MARK: Re-measure (return visits): the reading tray for a saved point

    /// "Re-measure R3" and the value it had last visit.
    @Published private(set) var remeasureTag: String?
    @Published private(set) var remeasurePrevious: String?

    func beginRemeasure(tag: String, previous: String?) {
        guard let s = takeShot(photo: true) else { engine.trayCancelled(); return }
        pendingShot = s
        editingId = nil
        remeasureTag = tag
        remeasurePrevious = previous
        readingText = ""
        readingMaterial = "wall"
        readingReference = false
        open(.reading)
    }

    /// A status change saved by the engine (done / removed / placed): into the stack with Undo.
    func statusSaved(_ e: CaptureStack.Entry, thumb: UIImage?) {
        stack.add(e)
        if let thumb { thumbs[e.id] = thumb }
        saveTick &+= 1
        DS.Haptic.save()
        showUndo()
    }

    // MARK: Photo

    private func takePhoto() {
        guard let s = takeShot(photo: true) else { return }
        lastSaveWasPhoto = true
        persist(.photo(s, caption: ""))
    }

    // MARK: Source

    private func beginSource() {
        guard let s = takeShot(photo: true) else { return }
        pendingShot = s
        sourceCause = nil
        sourceNote = ""
        open(.source)
    }

    // MARK: Equipment

    private func placeEquipment() {
        if let u = existingUnit {
            // Never a second unit on top of the first: aim its airflow instead.
            if u.type == "airMover" { airflowFor = u.id; showToast("Point the phone the way the air should blow") }
            return
        }
        guard let s = takeShot(photo: true) else { return }
        persist(.equipment(s, type: equipmentType, asset: ""))
    }

    private func setAirflow(_ id: String) {
        guard let s = engine.aimSample() else { return }
        let f = WorldVec(s.forward.x, 0, s.forward.z)
        guard simd_length(f) > 0.2 else { showToast("Hold the phone up and point it the way the air should blow"); DS.Haptic.warning(); return }
        if engine.setAirflow(id: id, direction: simd_normalize(f)) {
            airflowFor = nil
            DS.Haptic.save()
            showToast("Airflow set")
        }
    }

    func skipAirflow() { airflowFor = nil }

    /// The live arrow while aiming the airflow.
    var airflowPreview: (from: WorldVec, dir: WorldVec)? {
        guard let id = airflowFor, let u = engine.equipmentUnits().first(where: { $0.id == id }),
              let s = engine.aimSample() else { return nil }
        let f = WorldVec(s.forward.x, 0, s.forward.z)
        guard simd_length(f) > 0.2 else { return nil }
        return (WorldVec(u.pos.x, engine.world.floorY ?? 0, u.pos.y), simd_normalize(f))
    }

    // MARK: Mark

    private func markTap() {
        let closing = markStartShape == .area && markPoints.count >= 3 && closesArea
        if closing { finishMark(); return }
        guard let s = takeShot(photo: markShots.isEmpty) else { return }
        let p = MarkPoint(aim: aim)
        markShots.append(s)
        markPoints.append(p)
        if markPoints.count == 1 { markStartShape = MarkIntent.startShape(p) }
        DS.Haptic.save()
        if markStartShape == .line && markPoints.count == 2 { finishMark() }
    }

    /// "Add corners": a line in progress becomes an area.
    func continueAsArea() {
        markStartShape = .area
        if tray == .mark {
            // From the "Skirting run or floor area?" question: keep drawing.
            tray = nil
            markShape = nil
            markMeaning = nil
        }
    }

    /// "Close area" chip (3+ corners).
    func closeArea() { if markPoints.count >= 3 { finishMark() } }

    /// "Finish as line" chip (an area with two corners).
    func finishAsLine() { if markPoints.count >= 2 { finishMark() } }

    func undoMarkPoint() {
        guard !markShots.isEmpty else { return }
        markShots.removeLast()
        markPoints.removeLast()
        if markPoints.isEmpty { markStartShape = nil }
        DS.Haptic.undo()
    }

    func cancelMark() {
        markShots = []
        markPoints = []
        markStartShape = nil
        markShape = nil
        markMeaning = nil
        markWholeRoom = false
        if tray == .mark { tray = nil }
    }

    /// "Whole wall": the wall under the reticle, end to end, at the reticle's height.
    func wholeWall() {
        guard let w = aim.wall, let h = aim.hit, let s = takeShot(photo: true) else { return }
        let ends = WallEndSnap.wholeWall(a: WorldVec(w.a.x, h.y, w.a.y), b: WorldVec(w.b.x, h.y, w.b.y), y: h.y)
        markShots = [s.aimed(at: ends.0), s.aimed(at: ends.1)]
        var pa = MarkPoint(aim: aim), pb = MarkPoint(aim: aim)
        pa.world = ends.0
        pb.world = ends.1
        markPoints = [pa, pb]
        markStartShape = .line
        finishMark()
    }

    /// "Whole room": the room the reticle is in.
    func wholeRoom() {
        guard let h = aim.hit, let room = engine.world.room(containing: PlanVec(h.x, h.z)), let s = takeShot(photo: true) else { return }
        let fy = engine.world.floorY ?? h.y
        markShots = room.polygon.map { s.aimed(at: WorldVec($0.x, fy, $0.y)) }
        markPoints = room.polygon.map { MarkPoint(world: WorldVec($0.x, fy, $0.y), surface: .floor, height: 0, distanceToWall: 0) }
        markStartShape = .area
        markWholeRoom = true
        finishMark()
    }

    var canWholeWall: Bool { tool == .mark && markPoints.isEmpty && aim.wall != nil }
    var canWholeRoom: Bool {
        guard tool == .mark, markPoints.isEmpty, let h = aim.hit, aim.surface == .floor else { return false }
        return engine.world.room(containing: PlanVec(h.x, h.z)) != nil
    }

    private func finishMark() {
        guard let r = MarkIntent.shape(markPoints) else {
            showToast("Tap a second point")
            DS.Haptic.warning()
            return
        }
        // Keep the shots that survived cleaning (same order).
        var kept: [CaptureShot] = []
        for p in r.points { if let i = markPoints.firstIndex(of: p) { kept.append(markShots[i]) } }
        markShots = kept.count == r.points.count ? kept : Array(markShots.prefix(r.points.count))
        markPoints = r.points
        markShape = r.shape
        markMeaning = MarkIntent.defaultMeaning(shape: r.shape, points: r.points, context: context, remembered: remembered)
        liningMm = MarkIntent.liningHeightMm(endHeight: r.points.last?.height, fullMm: fullHeightMm)
        open(.mark)
    }

    var fullHeightMm: Int {
        let h = markPoints.compactMap(\.wallId).first.flatMap { id in engine.world.walls.first { $0.id == id }?.height } ?? 2.4
        return Int((h * 1000).rounded())
    }

    /// The tray's question: two floor points away from walls.
    var markNeedsAnswer: Bool { tray == .mark && markMeaning == nil }

    /// "Skirting" from the question: the line snaps onto the nearest wall's base.
    func chooseMeaning(_ m: MarkMeaning) {
        if m == .skirting, markPoints.allSatisfy({ !$0.nearFloorLine }) { snapLineToWall() }
        markMeaning = m
        if let shape = markShape, let key = MarkIntent.memoryKey(shape: shape, points: markPoints), m != .skirting { remembered[key] = m }
    }

    private func snapLineToWall() {
        let fy = engine.world.floorY ?? markPoints.first?.world.y ?? 0
        for i in markPoints.indices {
            let p = markPoints[i].plan
            guard let n = engine.world.nearestWall(to: p, maxDistance: 1.5) else { continue }
            let q = n.wall.a + (n.wall.b - n.wall.a) * n.t
            let w = WorldVec(q.x, fy + 0.05, q.y)
            markPoints[i].world = w
            markPoints[i].surface = .wall
            markPoints[i].height = 0.05
            markPoints[i].distanceToWall = 0
            markPoints[i].wallId = n.wall.id
            if markShots.indices.contains(i) { markShots[i] = markShots[i].aimed(at: w) }
        }
    }

    var markOptions: [MarkMeaning] {
        guard let s = markShape else { return [] }
        return MarkIntent.options(shape: s, default: MarkIntent.defaultMeaning(shape: s, points: markPoints, context: context, remembered: remembered))
    }

    // MARK: Trays

    private func open(_ t: CaptureTray) {
        withAnimation(DS.Motion.tray) { tray = t }
    }

    func closeTray() {
        let t = tray
        withAnimation(DS.Motion.tray) { tray = nil }
        engine.trayCancelled()
        remeasureTag = nil
        switch t {
        case .mark?: cancelMark()
        case .reading?, .source?: pendingShot = nil; editingId = nil
        case .review?: reviewSelected = nil
        default: break
        }
    }

    private func saveTray(_ t: CaptureTray) {
        switch t {
        case .reading:
            guard let v = readingValue else { return }
            if let id = editingId {
                engine.edit(id: id, .reading(value: v, material: readingMaterial))
                stack.update(id: id) { e in e.title = e.title.components(separatedBy: " · ").first.map { "\($0) · \(CaptureCopy.number(v))%" } ?? e.title }
                editingId = nil
                tray = .review
                DS.Haptic.save()
                return
            }
            guard let s = pendingShot else { return }
            pendingShot = nil
            tray = nil
            remeasureTag = nil
            persist(.reading(s, value: v, material: readingMaterial, reference: readingReference))
        case .mark:
            guard let m = markMeaning, !markShots.isEmpty else { return }
            let d = MarkDraft(meaning: m, shots: markShots, heightMm: m == .wallLining ? liningMm : MarkIntent.defaultHeightMm(m),
                              floorType: m == .liftFlooring ? floorType : nil, underlay: m == .liftFlooring && underlay,
                              wholeRoom: markWholeRoom, length: markLength, area: markArea)
            if let shape = markShape, let key = MarkIntent.memoryKey(shape: shape, points: markPoints), m != .skirting { remembered[key] = m }
            tray = nil
            markShots = []
            markPoints = []
            markStartShape = nil
            markShape = nil
            markMeaning = nil
            markWholeRoom = false
            persist(.mark(d))
        case .source:
            guard let c = sourceCause, let s = pendingShot else { return }
            pendingShot = nil
            tray = nil
            persist(.source(s, cause: c, note: sourceNote))
        case .roomName:
            let name = roomTyping ? roomOther.trimmingCharacters(in: .whitespaces) : (roomChoice ?? "")
            guard !name.isEmpty else { return }
            engine.renameRoom(name)
            roomTyping = false
            tray = nil
            DS.Haptic.save()
        case .review:
            closeTray()
        }
    }

    /// The engine asks for the room's name ("Room done").
    func askRoomName() {
        let sections = engine.roomSections()
        roomChoice = RoomNaming.preselected(sectionLabels: sections) ?? (engine.roomName.hasPrefix("Room ") ? nil : engine.roomName)
        roomOther = ""
        roomTyping = false
        cancelMark()
        open(.roomName)
    }

    var roomChips: [String] { RoomNaming.chipList(sectionLabels: engine.roomSections()) }

    // MARK: Saving

    private func takeShot(photo: Bool) -> CaptureShot? {
        guard var s = engine.shot(photo: photo) else {
            showToast("Camera not ready — try again")
            DS.Haptic.warning()
            return nil
        }
        s.aim = aim
        // The reticle's (snapped) point is what the user saw.
        if let h = aim.hit { s = s.aimed(at: h); s.aim = aim }
        return s
    }

    private func persist(_ d: CaptureDraft) {
        let photoTask: Task<CapturedPhoto?, Never>? = {
            switch d {
            case .reading(let s, _, _, _), .photo(let s, _), .source(let s, _, _), .equipment(let s, _, _): return s.photo
            case .mark(let m): return m.shots.first?.photo
            }
        }()
        if case .photo = d { lastSaveWasPhoto = true } else { lastSaveWasPhoto = false }
        Task {
            switch await engine.save(d) {
            case .success(let saved):
                UserDefaults.standard.set(true, forKey: "coach." + tool.rawValue)
                stack.add(saved.entry)
                saveTick &+= 1
                DS.Haptic.save()
                showUndo()
                if let id = saved.airflowFor {
                    airflowFor = id
                    showToast("Point the phone the way the air should blow")
                }
                if let photoTask, saved.entry.hasPhoto {
                    let id = saved.entry.id
                    if let thumb = await photoTask.value?.thumb { thumbs[id] = thumb }
                }
            case .failure(let p):
                DS.Haptic.warning()
                showToast(p.sentence)
            }
        }
    }

    /// Studio: a stack entry with a thumbnail, without an engine save.
    func studioAdd(_ e: CaptureStack.Entry, thumb: UIImage? = nil) {
        stack.add(e)
        if let thumb { thumbs[e.id] = thumb }
    }

    func studioMark(points: [MarkPoint], shape: MarkShape?, start: MarkShape?) {
        markPoints = points
        markShots = points.map { CaptureShot(id: CaptureIDs.new("st-"), takenAt: "", camera: .zero, forward: WorldVec(0, 0, -1), hit: $0.world) }
        markShape = shape
        markStartShape = start ?? shape
        if let shape {
            markMeaning = MarkIntent.defaultMeaning(shape: shape, points: points, context: context, remembered: remembered)
            liningMm = MarkIntent.liningHeightMm(endHeight: points.last?.height)
        }
    }

    func studioPending(_ s: CaptureShot) { pendingShot = s }
    func studioAirflow(_ id: String?) { airflowFor = id }
    func studioUndo(_ on: Bool) { undoVisible = on }

    // MARK: Undo, stack, review

    private func showUndo() {
        undoVisible = true
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoVisible = false
        }
    }

    func undo() {
        guard let e = stack.popLast() else { return }
        engine.remove(ids: e.ids)
        thumbs[e.id] = nil
        undoVisible = false
        DS.Haptic.undo()
        showToast("Removed \(e.title)")
    }

    var stackThumb: UIImage? { stack.lastPhoto.flatMap { thumbs[$0.id] } }

    func openReview() {
        guard stack.count > 0 else { return }
        cancelMark()
        reviewSelected = stack.reviewOrder.first?.id
        open(.review)
    }

    func delete(_ id: String) {
        guard let e = stack.remove(id: id) else { return }
        engine.remove(ids: e.ids)
        thumbs[e.id] = nil
        DS.Haptic.undo()
        reviewSelected = stack.reviewOrder.first?.id
        if stack.count == 0 { tray = nil }
    }

    func editReading(_ id: String) {
        guard let e = stack.entries.first(where: { $0.id == id }) else { return }
        editingId = id
        readingText = e.title.components(separatedBy: " · ").dropFirst().first?.replacingOccurrences(of: "%", with: "") ?? ""
        readingMaterial = "wall"
        open(.reading)
    }

    func retake(_ id: String) {
        delete(id)
        tray = nil
        tool = .photo
    }

    func caption(_ id: String, _ text: String) {
        engine.edit(id: id, .caption(text))
        stack.update(id: id) { $0.detail = text }
    }

    // MARK: Overlay drafts

    /// In-progress shapes, the frozen reading pin, the live airflow arrow.
    func draftMarks() -> [OverlayMark] {
        var out: [OverlayMark] = []
        if tray == .reading, editingId == nil, let h = pendingShot?.hit {
            out.append(OverlayMark(id: "draft-reading", style: .readingDraft, points: [h],
                                   value: readingText.isEmpty ? "–" : readingText, tag: nil))
        }
        if tray == .source, let h = pendingShot?.hit {
            out.append(OverlayMark(id: "draft-source", style: .source, points: [h], tag: sourceCause.map { $0 == "Unknown" ? "Source" : "\($0) leak" } ?? "Source"))
        }
        if !markPoints.isEmpty {
            let pts = markPoints.map(\.world)
            if let shape = markShape {
                out.append(finishedMarkPreview(shape: shape, pts: pts))
            } else if markStartShape == .line, let h = aim.hit {
                out.append(OverlayMark(id: "draft-line", style: .lineDraft, points: [pts[0], h],
                                       tag: CaptureCopy.length(simd_distance(PlanVec(pts[0].x, pts[0].z), PlanVec(h.x, h.z)))))
            } else {
                let fy = engine.world.floorY ?? pts[0].y
                var poly = pts.map { WorldVec($0.x, fy + 0.005, $0.z) }
                if let h = aim.hit { poly.append(WorldVec(h.x, fy + 0.005, h.z)) }
                let a = poly.count >= 3 ? FloorArea.area(poly.map { PlanVec($0.x, $0.z) }) : nil
                out.append(OverlayMark(id: "draft-area", style: .areaDraft, points: poly,
                                       tag: a.map(CaptureCopy.area) ?? CaptureCopy.length(poly.count >= 2 ? simd_distance(PlanVec(poly[0].x, poly[0].z), PlanVec(poly[1].x, poly[1].z)) : 0)))
            }
        }
        if let a = airflowPreview {
            out.append(OverlayMark(id: "draft-airflow", style: .equipment(type: "airMover", planned: false), points: [a.from], airflow: a.dir, tag: "Airflow"))
        }
        return out
    }

    private func finishedMarkPreview(shape: MarkShape, pts: [WorldVec]) -> OverlayMark {
        let fy = engine.world.floorY ?? (pts.map(\.y).min() ?? 0)
        let m = markMeaning
        switch (shape, m) {
        case (.area, _):
            let poly = pts.map { WorldVec($0.x, fy + 0.005, $0.z) }
            let a = CaptureCopy.area(FloorArea.area(poly.map { PlanVec($0.x, $0.z) }))
            let tag = m == .liftFlooring ? "\(MarkIntent.floorTypes.first { $0.key == floorType }?.name ?? "Flooring") · \(a)" : "Wet floor · \(a)"
            return OverlayMark(id: "draft-mark", style: m == .liftFlooring ? .liftFlooring : .wetFloor, points: poly, tag: tag)
        case (.line, .skirting?):
            return OverlayMark(id: "draft-mark", style: .skirting, points: pts.map { WorldVec($0.x, fy, $0.z) },
                               tag: "Skirting · \(CaptureCopy.length(markLength ?? 0))")
        case (.line, .wallLining?), (.line, .cabinetry?):
            return OverlayMark(id: "draft-mark", style: .lining, points: pts.map { WorldVec($0.x, fy, $0.z) },
                               top: Double(m == .cabinetry ? 900 : liningMm) / 1000,
                               tag: "\(m?.tag ?? "") · \(CaptureCopy.length(markLength ?? 0))")
        case (.line, .moistureLine?):
            return OverlayMark(id: "draft-mark", style: .moisture, points: pts, tag: "Moisture line")
        default:
            return OverlayMark(id: "draft-mark", style: .lineDraft, points: pts, tag: CaptureCopy.length(markLength ?? 0))
        }
    }

    /// The saved marks with the review's selection highlighted.
    func allMarks() -> [OverlayMark] {
        var saved = engine.overlayMarks()
        if tray == .review, let sel = reviewSelected, let e = stack.entries.first(where: { $0.id == sel }) {
            let ids = Set(e.ids + [e.id])
            for i in saved.indices where ids.contains(saved[i].id) { saved[i].selected = true }
        }
        return saved + draftMarks()
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

/// The engine's strings, compared each tick so the view updates only on change.
struct EngineDisplay: Equatable {
    var room = ""
    var phase = ""
    var coaching: String?
    var quiet: [QuietAction] = []
    var showsTools = true
    var busy: String?
    var recordingSince: Date?

    init() {}

    @MainActor init(_ e: CaptureEngine) {
        room = e.roomName
        phase = e.phaseText
        coaching = e.coaching
        quiet = e.quietActions
        showsTools = e.showsTools
        busy = e.busyText
        recordingSince = e.recordingSince
    }
}
