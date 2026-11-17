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

/// The card after the shutter.
struct PhotoCard: Identifiable, Equatable {
    var id: String
    var tag: String
    var image: UIImage?
    static func == (a: PhotoCard, b: PhotoCard) -> Bool { a.id == b.id && a.image === b.image }
}

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

    // Photos
    /// The card that springs up after the shutter (2.5 s), then shrinks into the stack.
    @Published var photoCard: PhotoCard?
    /// The full-screen viewer, opened on this photo id ("" = newest).
    @Published var viewerStart: String?
    /// Retake in place: the next photo replaces this item's photo.
    @Published private(set) var retakeFor: String?
    /// 0.5x selected for the Photo tool.
    @Published var zoomUltra = false
    /// 0.5x hand-off in progress: the pose the photo will be pinned at.
    @Published var handoffShot: CaptureShot?
    /// Bumped when the job's photos change (viewer, badge).
    @Published private(set) var photosTick = 0

    /// First-run coach lines (off in the Studio unless a scene asks).
    var hintsEnabled = true
    var coachHint: String? {
        guard hintsEnabled, tray == nil, !UserDefaults.standard.bool(forKey: "coach." + tool.rawValue) else { return nil }
        return CaptureCopy.coach(tool)
    }

    /// "Tips" in the top bar: one line per mode, over the viewport.
    @Published var tipsOpen = false

    /// Strip-out: the kind the user picked on the sub-picker (nil = follow the aim).
    @Published var stripPick: MarkMeaning?
    /// Strip-out: the kind fixed when the first point went down.
    @Published private(set) var stripAtStart: MarkMeaning?

    // Marking by component (docs/MARKING.md; logic in Marking.swift)
    /// The component under the reticle, highlighted before any tap.
    @Published var hover: Component?
    /// Drafts: a skirting run, a wall strip-back, a cabinet, a painted (or whole) floor, a tide line.
    @Published var run: WallRun?
    @Published var strip: StripBack?
    @Published var cabinetPick: String?
    @Published var kickOnly = false
    @Published var floorPaint: FloorPaint?
    @Published var floorWhole: [PlanVec]?
    @Published var tide: TideLine?
    /// Strip-out floor: the material (its pattern) and the underlay toggle (carpet).
    @Published var stripFloorType = "carpet"
    @Published var underlayOn = true
    /// The floor materials are on the sub-picker (after picking Floor).
    @Published var floorTypesShown = false
    /// A glass readout at a world point ("0.6 m to wall end", "600 mm").
    @Published var readout: (point: WorldVec, text: String)?
    /// The one suggestion chip.
    @Published var suggestion: Suggestion?
    var dismissedSuggestions: Set<String> = []
    /// The last wet floor area (for "Lift carpet + underlay in this area").
    var lastWetPolygon: [PlanVec]?
    /// Source tray: suspected / confirmed, on the surface / inside the wall.
    @Published var sourceConfirmed = false
    @Published var sourceInside = false
    /// A finger dragging an air mover's airflow.
    @Published var airflowDrag: (id: String, dir: WorldVec)?
    /// Undo for scrub steps (two-finger tap / Undo pill).
    var markUndo: [MarkSnapshot] = []
    var dragMode: DragMode?
    /// The simulator's demo camera: the finger's last point while looking around.
    var lookLast: CGPoint?

    /// The 3D equipment layer is on screen (the overlay then draws tags only).
    @Published var models3D = false
    /// Two-finger twist on a unit: the yaw added while the fingers are down (radians).
    @Published var twist: (id: String, angle: Double)?

    // The moisture model (docs/MOISTURE.md; logic in MoistureHUD.swift)
    /// The latest solve of the room as captured so far (20 cm cells while capturing).
    @Published var model: MoistureSolve?
    /// Its wash, edges and hints as world marks.
    @Published var modelMarks: [OverlayMark] = []
    /// Moisture > Adjust: brush, tide line, "no spread past here".
    @Published var adjusting = false
    @Published var adjustTool: LiveTweak.Kind = .wet
    /// The scoper's corrections this session (Undo pops them).
    @Published var modelTweaks: [LiveTweak] = []
    /// The stroke under the finger in Adjust.
    @Published var adjustStroke: LiveTweak?
    let modelRunner = MoistureRunner()
    var modelSignature: Int?
    /// Model suggestions already offered (or dismissed) this session.
    var modelOffered: Set<String> = []
    /// The model's suggestions go to the suggestion chip (Studio scenes turn it off to show the state chip).
    var offersModelSuggestions = true

    private var undoTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastLockKey = ""

    init(engine: CaptureEngine) {
        self.engine = engine
        tool = CaptureTool.modes(returnVisit: engine.isReturnVisit, scopeOnSite: engine.isScopeOnSite).first ?? .moisture
        display = EngineDisplay(engine)
    }

    var tools: [CaptureTool] { CaptureTool.modes(returnVisit: engine.isReturnVisit, scopeOnSite: engine.isScopeOnSite) }

    /// Moisture mode: the next tap starts a moisture line / wet area instead of a reading.
    @Published var drawArmed: MarkShape?

    /// The marks the current mode draws.
    var markFamily: MarkFamily { tool.markFamily ?? .stripOut }

    /// The mode is drawing a line or area (strip-out always; moisture once armed or started).
    var drawing: Bool {
        switch tool {
        case .stripOut: return true
        case .moisture: return drawArmed != nil || !markPoints.isEmpty
        default: return false
        }
    }

    // MARK: Tick (~15 Hz, from the view)

    func tick() {
        let d = EngineDisplay(engine)
        if d != display { display = d }
        updateModel()
        // While a tray is open the reticle is frozen on the captured point.
        guard tray == nil else { return }
        let a = engine.aimSample().map { AimInterpreter.interpret($0, world: engine.world, snapEnds: tool.markFamily != nil) } ?? .none
        if a != aim {
            let key = "\(a.surface?.rawValue ?? "-")|\(a.wall?.id ?? "-")|\(a.snapped)"
            if key != lastLockKey && a.hit != nil && aim.hit != nil { DS.Haptic.lock() }
            lastLockKey = key
            aim = a
        }
        updateHover()
    }

    /// The reticle's readout, or nil when the primary button already names the target
    /// (or a tray is open). Drawn by the overlay so it takes part in the label layout.
    var reticleText: String? {
        guard tray == nil, display.showsTools, display.busy == nil, airflowFor == nil, retakeFor == nil else { return nil }
        // A highlighted component carries its own label.
        if hover != nil || drafting { return nil }
        switch tool {
        case .remeasure, .equipment: return nil
        case .stripOut, .moisture:
            // While drawing, the line's or area's own label says it.
            if !markPoints.isEmpty { return nil }
            if tool == .stripOut && markPoints.isEmpty && aim.surface == .floor { return nil }
        case .source: break
        }
        return CaptureCopy.reticle(aim)
    }

    /// Studio and tests: set the aim directly.
    func setAim(_ a: Aim) { aim = a }

    // MARK: Tools

    func select(_ t: CaptureTool) {
        guard t != tool else { return }
        cancelMark()
        airflowFor = nil
        drawArmed = nil
        tray = nil
        tipsOpen = false
        clearMarkingDrafts()
        hover = nil
        floorTypesShown = false
        endAdjust()
        tool = t
    }

    // MARK: The sub-picker (moisture kinds, strip-out kinds, equipment types)

    var subPicker: [(key: String, title: String)] {
        if tool == .stripOut && floorTypesShown { return [(key: "back", title: "‹")] + CaptureCopy.floorMaterials }
        if tool == .moisture && adjusting { return [(key: "back", title: "‹")] + Self.adjustTools }
        return CaptureCopy.subPicker(tool)
    }

    /// The strip-out kind the reticle suggests now.
    var stripAuto: MarkMeaning { MarkIntent.stripKind(aim.hit == nil ? nil : MarkPoint(aim: aim), remembered: remembered) }

    /// The strip-out kind in effect: fixed once drawing started, else picked, else from the aim.
    var stripKind: MarkMeaning { markPoints.isEmpty ? (stripPick ?? stripAuto) : (stripAtStart ?? stripPick ?? stripAuto) }

    var subSelection: String? {
        switch tool {
        case .moisture:
            if adjusting { return adjustTool.rawValue }
            return drawArmed == .line ? "line" : drawArmed == .area ? "area" : "reading"
        case .stripOut: return floorTypesShown ? stripFloorType : stripKind.rawValue
        case .equipment: return equipmentType
        default: return nil
        }
    }

    func pickSub(_ key: String) {
        guard key != subSelection else { return }
        DS.Haptic.selection()
        switch tool {
        case .moisture:
            guard markPoints.isEmpty else { return }
            if adjusting {
                if key == "back" { endAdjust(); return }
                if let k = LiveTweak.Kind(rawValue: key) { adjustTool = k }
                return
            }
            if key == "adjust" { beginAdjust(); return }
            drawArmed = key == "line" ? .line : key == "area" ? .area : nil
        case .stripOut:
            if key == "back" { floorTypesShown = false; return }
            if floorTypesShown { stripFloorType = key; return }
            guard let m = MarkMeaning(rawValue: key) else { return }
            clearMarkingDrafts()
            stripPick = m
            if m == .liftFlooring { floorTypesShown = true }
            if !markPoints.isEmpty {
                stripAtStart = m
                markStartShape = m.isArea ? .area : (markPoints.count <= 2 ? .line : markStartShape)
            }
        case .equipment:
            airflowFor = nil
            equipmentType = key
        default: break
        }
    }

    // MARK: The instruction card, the top bar's lines

    /// The one card at the top of the viewport: a toast, RoomPlan's coaching, a status, or the
    /// first-use line for the mode.
    var cardText: String? {
        if display.busy != nil { return nil }
        if let t = toast { return t }
        if let c = display.coaching { return c }
        guard tray == nil else { return nil }
        if airflowFor != nil { return CaptureCopy.aimAirflow }
        if adjusting { return adjustCard }
        if !markPoints.isEmpty && aim.snapped { return CaptureCopy.snappedEnd }
        if let mc = markingCard { return mc }
        if tool == .moisture && markPoints.isEmpty {
            if drawArmed == .line { return CaptureCopy.wetLineStart }
            if drawArmed == .area { return CaptureCopy.wetAreaStart }
        }
        return coachHint
    }

    /// "Scanning · 3 readings", "Drying setup · 2 units", "Visit 2 · 1 of 3".
    var subtitle: String {
        let marks = engine.overlayMarks()
        var readings = 0, strip = 0
        for m in marks {
            switch m.style {
            case .reading: readings += 1
            case .skirting, .lining, .liftFlooring: strip += 1
            default: break
            }
        }
        return CaptureCopy.subtitle(phase: display.phase, tool: tool, readings: readings, marks: strip,
                                    units: engine.equipmentUnits().count, fixed: engine.isReturnVisit || engine.isScopeOnSite)
    }

    // MARK: The bottom panel's pills and caption

    struct Pill: Identifiable, Equatable {
        var id: String
        var title: String
        var enabled = true
        var prominent = false
    }

    /// Left pill, the action's words in the middle (when they say something the mode doesn't),
    /// right pill.
    var pills: (left: Pill?, caption: String?, right: Pill?) {
        let p = primary
        if retakeFor != nil { return (nil, "Retake photo", Pill(id: "cancelRetake", title: "Cancel")) }
        if airflowFor != nil { return (nil, p.title, Pill(id: "skipAirflow", title: "Skip")) }
        if !markPoints.isEmpty { return (Pill(id: "undoPoint", title: "Undo"), p.title, Pill(id: "cancelMark", title: "Cancel")) }
        if adjusting { return (Pill(id: "undoTweak", title: "Undo", enabled: !modelTweaks.isEmpty), adjustCaption, Pill(id: "endAdjust", title: "Done")) }
        if let mp = markingPills { return mp }
        let q = display.quiet.map { Pill(id: "quiet:" + $0.id, title: $0.title, enabled: $0.enabled, prominent: $0.prominent) }
        let contextual = !p.enabled || engine.primaryOverride(tool: tool, aim: aim) != nil || existingUnit != nil || hover != nil
            || (tool == .moisture && drawArmed != nil) || q.isEmpty
        return (q.first, contextual ? p.title : nil, q.count > 1 ? q.last : nil)
    }

    func tapPill(_ id: String) {
        if tapMarkingPill(id) { return }
        switch id {
        case "cancelRetake": cancelRetake()
        case "skipAirflow": skipAirflow()
        case "undoPoint": undoMarkPoint()
        case "cancelMark": cancelMark()
        case "undoTweak": undoTweak()
        case "endAdjust": endAdjust()
        default:
            if id.hasPrefix("quiet:") { engine.perform(quiet: String(id.dropFirst(6))) }
        }
    }

    /// The centre button is the white "Start" shutter (a scan not started yet).
    var primaryIsStart: Bool { tray == nil && (engine.primaryOverride(tool: tool, aim: aim)?.start ?? false) }


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
        if adjusting { return Primary(title: "Done adjusting", enabled: true) }
        if let m = markingPrimary { return m }
        if let why = aim.blocked { return Primary(title: why, enabled: false) }
        switch tool {
        case .moisture: return Primary(title: drawing ? markTitle : CaptureCopy.addReading, enabled: true)
        case .source: return Primary(title: CaptureCopy.markSource, enabled: true)
        case .equipment:
            if let u = existingUnit { return Primary(title: EquipmentGuard.action(for: u), enabled: u.type == "airMover") }
            return Primary(title: CaptureCopy.place(equipmentType), enabled: true)
        case .stripOut: return Primary(title: markTitle, enabled: true)
        case .remeasure: return Primary(title: "Aim at a saved point", enabled: false)
        }
    }

    /// The symbol on the round action button.
    var primaryIcon: String {
        if let o = engine.primaryOverride(tool: tool, aim: aim) { return o.icon }
        if airflowFor != nil { return "arrow.turn.up.right" }
        if drafting || adjusting { return "checkmark" }
        if let h = hover, h.kind != .waterCandidate, h.kind != .ceiling { return "plus" }
        if aim.blocked != nil { return "scope" }
        switch tool {
        case .moisture: return drawing ? markIcon : "drop.fill"
        case .stripOut: return markIcon
        case .equipment: return existingUnit != nil ? "arrow.turn.up.right" : "plus"
        case .source: return "mappin"
        case .remeasure: return "arrow.triangle.2.circlepath"
        }
    }

    private var markIcon: String {
        if markPoints.isEmpty { return "plus" }
        if markStartShape == .line { return "checkmark" }
        return markPoints.count >= 3 && closesArea ? "checkmark" : "plus"
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
        guard let first = markPoints.first else {
            if tool == .moisture { return drawArmed == .area ? "Start wet area" : "Start line" }
            return CaptureCopy.startHere
        }
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
        if adjusting { endAdjust(); return }
        if drafting { commitMarking(); return }
        if let h = hover {
            if h.kind == .waterCandidate || h.kind == .ceiling { beginSource(at: h.point) } else { selectWhole(h) }
            return
        }
        switch tool {
        case .moisture: if drawing { markTap() } else { beginReading() }
        case .source: beginSource()
        case .equipment: placeEquipment()
        case .stripOut: markTap()
        case .remeasure: break
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

    /// The shutter: always there, in every mode.
    var shutterEnabled: Bool { aim.blocked != CaptureCopy.findingRoom && tray == nil && display.showsTools }

    /// The job's photo count (the shutter's badge).
    var photoCount: Int { engine.jobPhotos().count }

    func shutter() {
        guard shutterEnabled else { DS.Haptic.warning(); return }
        takePhoto()
    }

    private func takePhoto() {
        if zoomUltra, engine.zoomState == .available, retakeFor == nil {
            guard var s = engine.beginHandoff() else { showToast("Camera not ready — try again"); return }
            s.aim = aim
            if let h = aim.hit { s = s.aimed(at: h) }
            handoffShot = s
            return
        }
        guard let s = takeShot(photo: true) else { return }
        lastSaveWasPhoto = true
        if let id = retakeFor, let photo = s.photo {
            retakeFor = nil
            Task {
                guard await engine.replacePhoto(id: id, photo: photo) else { showToast("Couldn't replace that photo"); return }
                saveTick &+= 1
                photosTick &+= 1
                DS.Haptic.save()
                let p = await photo.value
                if let t = p?.thumb { thumbs[id] = t }
                showCard(id: id, image: p?.card)
            }
            return
        }
        persist(.photo(s, caption: ""))
    }

    /// The 0.5x hand-off delivered its photo (or nil = cancelled).
    func finishHandoff(_ photo: CapturedPhoto?) {
        guard var s = handoffShot else { return }
        handoffShot = nil
        engine.endHandoff()
        guard let photo else { return }
        s.photo = Task { photo }
        lastSaveWasPhoto = true
        persist(.photo(s, caption: "0.5×"))
    }

    /// Retake in place, from the review drawer or the viewer: back to the camera, aimed at that pin.
    func beginRetake(_ id: String) {
        cancelMark()
        tray = nil
        viewerStart = nil
        photoCard = nil
        retakeFor = id
    }

    func cancelRetake() { retakeFor = nil }

    func showCard(id: String, image: UIImage?) {
        let tag = stack.entries.first { $0.id == id }?.title ?? "Photo"
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { photoCard = PhotoCard(id: id, tag: tag, image: image ?? thumbs[id]) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.photoCard?.id == id else { return }
            withAnimation(DS.Motion.fly) { self.photoCard = nil }
        }
    }

    /// The capture stack's number: the job's photos while the Photo tool is out, else this session's captures.
    var stackCount: Int { stack.count }

    /// "12 photos" under the room name while the Photo tool is out.
    var photoCountLine: String? {
        guard retakeFor != nil else { return nil }
        let n = engine.jobPhotos().count
        return n == 1 ? "1 photo" : "\(n) photos"
    }

    func openViewer(_ id: String? = nil) {
        guard !engine.jobPhotos().isEmpty else { return }
        photoCard = nil
        viewerStart = id ?? ""
    }

    /// Viewer delete (after its undo window): the item goes, and out of the stack.
    func deletePhoto(_ id: String) {
        stack.remove(id: id)
        engine.remove(ids: [id])
        thumbs[id] = nil
        photosTick &+= 1
    }

    // MARK: Source

    /// The source tray; `at` snaps the pin onto a water-entry candidate (sink, toilet, sill...).
    func beginSource(at p: WorldVec? = nil) {
        guard var s = takeShot(photo: true) else { return }
        if let p { s = s.aimed(at: p) }
        pendingShot = s
        sourceCause = nil
        sourceNote = ""
        sourceConfirmed = false
        // Aimed at a wall away from fixtures: most likely inside the wall (a pipe, the cavity).
        let nearFixture = ComponentIndex.waterCandidates(engine.world).contains { c in
            c.point.map { pt in s.hit.map { simd_distance(pt, $0) < 0.6 } ?? false } ?? false
        }
        sourceInside = p == nil && s.aim.surface == .wall && !nearFixture
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

    /// The airflow points from the unit to the spot on the floor the reticle is on (or, with
    /// nothing under the reticle, the way the phone points).
    private func airflowDirection(_ id: String) -> WorldVec? {
        guard let u = engine.equipmentUnits().first(where: { $0.id == id }) else { return nil }
        if let h = aim.hit {
            let d = WorldVec(h.x - u.pos.x, 0, h.z - u.pos.y)
            if simd_length(d) > 0.25 { return simd_normalize(d) }
        }
        guard let s = engine.aimSample() else { return nil }
        let f = WorldVec(s.forward.x, 0, s.forward.z)
        return simd_length(f) > 0.2 ? simd_normalize(f) : nil
    }

    private func setAirflow(_ id: String) {
        guard let dir = airflowDirection(id) else { showToast("Aim at the floor where the air should go"); DS.Haptic.warning(); return }
        if engine.setAirflow(id: id, direction: dir) {
            airflowFor = nil
            DS.Haptic.save()
            showToast("Airflow set")
        }
    }

    func skipAirflow() { airflowFor = nil }

    /// The live arrow while aiming the airflow.
    var airflowPreview: (from: WorldVec, dir: WorldVec)? {
        guard let id = airflowFor, let u = engine.equipmentUnits().first(where: { $0.id == id }),
              let dir = airflowDirection(id) else { return nil }
        return (WorldVec(u.pos.x, engine.world.floorY ?? 0, u.pos.y), dir)
    }

    // MARK: Mark

    private func markTap() {
        let closing = markStartShape == .area && markPoints.count >= 3 && closesArea
        if closing { finishMark(); return }
        guard let s = takeShot(photo: markShots.isEmpty) else { return }
        let p = MarkPoint(aim: aim)
        markShots.append(s)
        markPoints.append(p)
        if markPoints.count == 1 {
            if tool == .stripOut {
                let k = stripPick ?? MarkIntent.stripKind(p, remembered: remembered)
                stripAtStart = k
                markStartShape = k.isArea ? .area : .line
            } else {
                markStartShape = drawArmed ?? MarkIntent.startShape(p)
            }
        }
        DS.Haptic.lock()
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
        if markPoints.isEmpty { markStartShape = nil; stripAtStart = nil }
        DS.Haptic.undo()
    }

    func cancelMark() {
        drawArmed = nil
        markShots = []
        markPoints = []
        markStartShape = nil
        markShape = nil
        markMeaning = nil
        markWholeRoom = false
        stripAtStart = nil
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

    var canWholeWall: Bool { tool == .stripOut && markPoints.isEmpty && aim.wall != nil }
    var canWholeRoom: Bool {
        guard drawing, markPoints.isEmpty, let h = aim.hit, aim.surface == .floor else { return false }
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
        markMeaning = MarkIntent.defaultMeaning(shape: r.shape, points: r.points, family: markFamily, remembered: remembered)
        if markFamily == .stripOut, !markWholeRoom, let k = stripAtStart ?? stripPick, k.isArea == (r.shape == .area) {
            chooseMeaning(k)
        }
        liningMm = MarkIntent.liningHeightMm(endHeight: r.points.last?.height, fullMm: fullHeightMm)
        // Marks with nothing to set are saved straight away (Undo is there); lining and
        // flooring open the tray for the height / floor type.
        if let m = markMeaning, MarkIntent.savesDirectly(m) { drawArmed = nil; saveTray(.mark); return }
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
        if markShape == .line, m == .wallLining || m == .cabinetry { remembered["stripLine"] = m }
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
        return MarkIntent.options(shape: s, family: markFamily,
                                  default: MarkIntent.defaultMeaning(shape: s, points: markPoints, family: markFamily, remembered: remembered))
    }

    // MARK: Trays

    func open(_ t: CaptureTray) {
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
            if markShape == .line, m == .wallLining || m == .cabinetry { remembered["stripLine"] = m }
            tray = nil
            markShots = []
            markPoints = []
            markStartShape = nil
            markShape = nil
            markMeaning = nil
            markWholeRoom = false
            stripAtStart = nil
            persist(.mark(d))
        case .source:
            guard let c = sourceCause, let s = pendingShot else { return }
            pendingShot = nil
            tray = nil
            persist(.source(s, cause: c, note: sourceNote, confirmed: sourceConfirmed, inside: sourceInside))
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

    func takeShot(photo: Bool) -> CaptureShot? {
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

    func persist(_ d: CaptureDraft) {
        let photoTask: Task<CapturedPhoto?, Never>? = {
            switch d {
            case .reading(let s, _, _, _), .photo(let s, _), .source(let s, _, _, _, _), .equipment(let s, _, _): return s.photo
            case .mark(let m): return m.shots.first?.photo
            }
        }()
        if case .photo = d { lastSaveWasPhoto = true } else { lastSaveWasPhoto = false }
        Task {
            switch await engine.save(d) {
            case .success(let saved):
                UserDefaults.standard.set(true, forKey: "coach." + tool.rawValue)
                suggestAfter(d)
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
                    let p = await photoTask.value
                    if let thumb = p?.thumb { thumbs[id] = thumb }
                    if saved.entry.kind == "photo" {
                        photosTick &+= 1
                        showCard(id: id, image: p?.card)
                    }
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
            markMeaning = MarkIntent.defaultMeaning(shape: shape, points: points, family: markFamily, remembered: remembered)
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

    /// The stack's picture: the newest photo while the Photo tool is out, else the last
    /// capture's photo (a type glyph is shown when the last capture isn't a photo).
    var stackThumb: UIImage? {
        guard let last = stack.last, last.kind == "photo" else { return nil }
        return thumbs[last.id]
    }

    var stackKind: String { stack.last?.kind ?? "" }

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

    func retake(_ id: String) { beginRetake(id) }

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
                let len = CaptureCopy.length(simd_distance(PlanVec(pts[0].x, pts[0].z), PlanVec(h.x, h.z)))
                if tool == .stripOut {
                    // Strip-out draws in its own red while the line is being drawn.
                    let fy = engine.world.floorY ?? min(pts[0].y, h.y)
                    let k = stripKind
                    let base = k == .skirting ? [WorldVec(pts[0].x, fy, pts[0].z), WorldVec(h.x, fy, h.z)] : [pts[0], h]
                    out.append(OverlayMark(id: "draft-line", style: .skirting, points: base, tag: "\(k.tag) · \(len)"))
                } else {
                    out.append(OverlayMark(id: "draft-line", style: .lineDraft, points: [pts[0], h], tag: len))
                }
            } else {
                let fy = engine.world.floorY ?? pts[0].y
                var poly = pts.map { WorldVec($0.x, fy + 0.005, $0.z) }
                if let h = aim.hit { poly.append(WorldVec(h.x, fy + 0.005, h.z)) }
                let a = poly.count >= 3 ? FloorArea.area(poly.map { PlanVec($0.x, $0.z) }) : nil
                var draft = OverlayMark(id: "draft-area", style: .areaDraft, points: poly,
                                        tag: a.map(CaptureCopy.area) ?? CaptureCopy.length(poly.count >= 2 ? simd_distance(PlanVec(poly[0].x, poly[0].z), PlanVec(poly[1].x, poly[1].z)) : 0))
                draft.removal = tool == .stripOut
                out.append(draft)
            }
        }
        if let a = airflowPreview {
            out.append(OverlayMark(id: "draft-airflow", style: .equipment(type: "airMover", planned: false), points: [a.from], airflow: a.dir, tag: "Airflow"))
        }
        return out + markingMarks()
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
        // The moisture model under everything in Moisture mode; the scoper's tide lines then
        // keep their line only (docs/MOISTURE.md).
        if showsModel {
            for i in saved.indices where saved[i].style == .moistureWash { saved[i].lineOnly = true }
            saved = modelMarks + barrierMarks() + saved
        }
        // Nothing shows through a wall; one-sided marks only from their side; cavity marks on the
        // face you're looking at (docs/MARKING.md H).
        if let cam = engine.aimSample()?.camera {
            let w = engine.world
            saved = saved.compactMap { Visibility.prepare($0, camera: cam, world: w) }
        }
        if let r = retakeFor { for i in saved.indices where saved[i].id == r { saved[i].selected = true } }
        if tray == .review, let sel = reviewSelected, let e = stack.entries.first(where: { $0.id == sel }) {
            let ids = Set(e.ids + [e.id])
            for i in saved.indices where ids.contains(saved[i].id) { saved[i].selected = true }
        }
        var all = saved + draftMarks() + (adjusting ? adjustMarks() : [])
        if models3D {
            // Units near enough are 3D models (tags only here); far ones keep the 2D glyph.
            let cam = engine.aimSample()?.camera
            all.removeAll { $0.id == "draft-airflow" }
            for i in all.indices {
                guard case .equipment(let type, _) = all[i].style, let p = all[i].points.first else { continue }
                if let c = cam, simd_distance(c, p) > EquipmentModels.maxDistance { continue }
                all[i].modelHeight = EquipmentModels.height(type)
                all[i].airflow = nil
            }
        }
        return all
    }

    // MARK: 3D equipment

    /// The models to draw: saved units (planned ones translucent), the air mover whose airflow is
    /// being aimed (turning live), a unit being twisted, and the ghost on the reticle before placing.
    func equipmentModels() -> [EquipmentModelState] {
        let cam = engine.aimSample()?.camera
        func sideOn(_ p: WorldVec) -> Float {
            guard let c = cam else { return 0 }
            let v = WorldVec(c.x - p.x, 0, c.z - p.z)
            return Float(atan2(v.z, -v.x))
        }
        var out: [EquipmentModelState] = []
        for m in engine.overlayMarks() {
            guard case .equipment(let type, let planned) = m.style, let p = m.points.first else { continue }
            if let c = cam, simd_distance(c, p) > EquipmentModels.maxDistance { continue }
            var yaw = m.airflow.map(EquipmentModelState.yaw(for:)) ?? sideOn(p)
            var flow = m.airflow != nil && type == "airMover"
            if airflowFor == m.id, let a = airflowPreview { yaw = EquipmentModelState.yaw(for: a.dir); flow = true }
            if let t = twist, t.id == m.id { yaw += Float(t.angle); flow = type == "airMover" }
            if let a = airflowDrag, a.id == m.id { yaw = EquipmentModelState.yaw(for: a.dir); flow = true }
            out.append(EquipmentModelState(id: m.id, type: type, position: SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)),
                                           yaw: yaw, planned: planned, flow: flow))
        }
        if let g = ghost { out.append(g) }
        return out
    }

    /// Equipment mode, nothing placed here yet, the reticle on the floor: the model to be placed.
    var ghost: EquipmentModelState? {
        guard tool == .equipment, tray == nil, airflowFor == nil, retakeFor == nil, existingUnit == nil,
              aim.surface == .floor, aim.blocked == nil, let h = aim.hit else { return nil }
        let cam = engine.aimSample()?.camera
        var yaw: Float = 0
        if let c = cam { let v = WorldVec(c.x - h.x, 0, c.z - h.z); yaw = Float(atan2(v.z, -v.x)) }
        return EquipmentModelState(id: "ghost", type: equipmentType, position: SIMD3<Float>(Float(h.x), Float(h.y), Float(h.z)),
                                   yaw: yaw, ghost: true)
    }

    /// The air mover a two-finger twist turns: the one being aimed, else the one the reticle is on.
    var twistTarget: String? {
        if let id = airflowFor { return id }
        guard tool == .equipment, let u = existingUnit, u.type == "airMover" else { return nil }
        return u.id
    }

    func twistChanged(_ angle: Double) {
        guard let id = twistTarget else { return }
        if twist == nil { DS.Haptic.selection() }
        twist = (id, angle)
    }

    /// The twist ends: the unit's airflow turns by the angle (outlet = airflow).
    func twistEnded() {
        guard let t = twist else { return }
        twist = nil
        guard let m = engine.overlayMarks().first(where: { $0.id == t.id }) else { return }
        let base = m.airflow.map(EquipmentModelState.yaw(for:)) ?? 0
        let yaw = Double(base) + t.angle
        if engine.setAirflow(id: t.id, direction: WorldVec(sin(yaw), 0, cos(yaw))) {
            if airflowFor == t.id { airflowFor = nil }
            DS.Haptic.save()
        }
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
