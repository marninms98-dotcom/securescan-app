//
//  RevisitModel.swift
//  SecureScan
//
//  Return visit in AR ("Find my points"): state of the screen.
//  The maths and every document change are Core functions (Alignment,
//  Revisit, PlanBuilder resolvers); this class only sequences them:
//    intro -> (relocalising with the saved world map | corner A, B[, C])
//          -> check (plan outline on the floor) -> measuring
//  Everything logged is merged into plan.json at once and appended to
//  revisit-log.json (raw, in this session's world space, with the alignment),
//  so a crash or lost tracking loses nothing. Logging is paused whenever
//  tracking is not normal or the alignment has not been confirmed.
//

import Foundation
import SwiftUI
import simd
import ARKit
import UIKit

enum TrackingStatus: Equatable {
    case normal
    case relocalizing
    case limited(String)
    case notAvailable

    var isNormal: Bool { self == .normal }
    var message: String {
        switch self {
        case .normal: return ""
        case .relocalizing: return "Finding the saved room… move the phone slowly."
        case .limited(let why): return "Tracking is limited (\(why)). Move slowly and point at walls with some detail. Logging is paused."
        case .notAvailable: return "Starting the camera…"
        }
    }
}

struct RemeasureRequest: Identifiable {
    let id: String               // reading id
    let title: String            // "Point 3 · Wall A"
    let previous: [String]       // "Visit 1: 24.5%"
    let pending: PendingLog
}

enum RevisitConfirm: Identifiable {
    case equipmentRemoved(id: String, name: String)
    case removalDone(id: String, name: String)
    case equipmentPlaced(id: String, name: String)
    var id: String {
        switch self {
        case .equipmentRemoved(let id, _): return "e-" + id
        case .removalDone(let id, _): return "r-" + id
        case .equipmentPlaced(let id, _): return "p-" + id
        }
    }
}

/// The sheet for an item tapped in AR: edit, nudge, move or delete it.
struct MarkerEdit: Identifiable {
    let id: String
    let list: String               // readings | sources | equipment | removals | affected | floors
    let kind: String               // reading | boundary | photo | source | equipment | removal | affected | floor
    let title: String
    var value: Double?
    var material: String
    var label: String
    var hasHeight: Bool
    var movable: Bool
    var canRemeasure: Bool
    var canMarkRemoved: Bool
    var canMarkDone: Bool
    var isAirMover = false
    var planned = false
}

@MainActor
final class RevisitModel: ObservableObject, LogSheetModel {

    enum Phase: Equatable {
        case intro
        case relocalizing
        case corner(Int)       // which corner is being set (0 = A, 1 = B, 2 = C)
        case check
        case measuring
    }

    let folder: JobFolder
    @Published private(set) var plan: [String: Any] = [:]
    @Published var phase: Phase = .intro
    @Published var roomIndex = 0
    /// Plan polygon indices (in the chosen room) of corners A, B (and C).
    @Published var cornerIdx: [Int] = []
    @Published var picking = 0
    @Published private(set) var hits: [WorldVec] = []
    @Published var fitMessage: String?
    @Published private(set) var fitAcceptable = false
    @Published private(set) var visit = "v1"
    @Published private(set) var visitLabel = ""
    @Published private(set) var tracking: TrackingStatus = .notAvailable
    @Published private(set) var markers: [Revisit.Marker] = []
    @Published private(set) var target: Revisit.Candidate?
    @Published private(set) var hint: String?
    @Published var toast: String?
    @Published var pending: PendingLog?
    @Published var remeasure: RemeasureRequest?
    @Published var confirm: RevisitConfirm?
    @Published var alert: String?
    @Published var lastMaterial = "wall"
    @Published var lastEquipmentType = "airMover"
    @Published var lastKind = "reading"
    @Published var lastRemovalItem = "plasterboard"
    @Published private(set) var autoAligned = false
    // AR mark-up
    @Published var mode: MarkupMode = .reading
    /// Inspect · Quote · Monitor: which tools the strip shows (presentation only).
    @Published private(set) var workMode: WorkMode = .inspect
    /// Quote mode: wall removal item chosen on the strip.
    @Published var wallRemovalItem = "plasterboard"
    @Published private(set) var quoteTally = QuoteTally()
    /// markup: the mark-up tools; scope: "See scope on site" (view only).
    enum Purpose { case markup, scope }
    @Published private(set) var purpose: Purpose
    /// Read once: "Show prices" (the AR screens never show money either way).
    let pricesVisible = PriceLock.pricesVisible
    @Published private(set) var scopeItems: [ScopeItem] = []
    @Published private(set) var aimedScope: ScopeItem?
    @Published var showScopeList = false
    /// An air mover whose airflow is being aimed (Scope mode, or "Re-aim airflow").
    @Published private(set) var aimingDir: String?
    /// The Log sheet's "Photo" chip: link the AR frame to the item (default on).
    var attachPhoto = true
    /// What the reticle is on ("Wall · 1.20 m · Kitchen"); empty = nothing under it.
    @Published private(set) var reticle = ""
    /// The plan wall under the reticle (for "Whole wall" and end snapping), nil when not on a wall.
    @Published private(set) var reticleWall: PlanWall?
    private var reticleY: Double?
    @Published private(set) var undoChipVisible = false
    private var undoWindow = UndoWindow()
    @Published var moistureOnFloor = false
    @Published private(set) var sweeping = false
    @Published private(set) var floorCornerCount = 0
    @Published var editing: MarkerEdit?
    @Published private(set) var moving: String?
    @Published private(set) var undoCount = 0
    @Published private(set) var strokeCount = 0
    @Published var showItems = false
    let flow = CaptureFlow()

    /// Set when marking up during the first scan: every item also goes into
    /// the scan's readings-raw.json (in the scan's world space) so the final
    /// plan build places it like anything logged on the scan screen.
    private(set) weak var scan: ScanModel?
    let firstScan: Bool
    /// RoomPlan's running ARSession, drawn on directly (same world frame).
    let sharedSession: ARSession?
    let start: MarkupStart?
    let roomNumber: Int
    private var sweepTimer: Timer?
    private var sweepPoses: [FrameCapture] = []
    private var pressStarted: Date?
    private var floorCorners: [FrameCapture] = []
    private var undoStack: [[String]] = []
    private var strokeStack: [[String]] = []
    private var previewShown = false

    weak var controller: RevisitARViewController?
    private(set) var alignment: PlanTransform?
    private(set) var floorY = 0.0
    private var seq = 1000
    private var relocaliseDeadline: Date?
    let hasWorldMap: Bool
    let savedFrame: PlanFrame?

    init(folder: JobFolder, firstScan scan: ScanModel? = nil, session: ARSession? = nil,
         start: MarkupStart? = nil, roomNumber: Int = 0, purpose: Purpose = .markup) {
        self.folder = folder
        self.purpose = purpose
        self.scan = scan
        self.firstScan = scan != nil
        self.sharedSession = session
        self.start = start
        self.roomNumber = roomNumber
        self.hasWorldMap = FileManager.default.fileExists(atPath: folder.worldMapURL.path)
        self.savedFrame = JobFiles.loadFrame(folder)
        reloadPlan()
        chooseRoom(Self.largestRoom(rooms))
        if let scan {
            visit = PlanDocument.currentVisit(plan["markup"] as? [String: Any] ?? [:])
            visitLabel = "Room \(roomNumber) · mark-up"
            lastMaterial = scan.lastMaterial
            lastEquipmentType = scan.lastEquipmentType
            lastRemovalItem = scan.lastRemovalItem
            mode = MarkupMode(kind: scan.lastKind)
            if mode == .wallRemoval && scan.lastRemovalItem != "flooring" { wallRemovalItem = scan.lastRemovalItem }
            workMode = WorkMode.containing(mode, laterVisit: false)
        }
        quoteTally = QuoteTally.from(plan: plan)
    }

    var workModes: [WorkMode] { WorkMode.offered(laterVisit: isLaterVisit) }

    func setWorkMode(_ w: WorkMode) {
        workMode = w
        if !w.tools.contains(mode), let first = w.tools.first { mode = first }
        floorCorners = []
        floorCornerCount = 0
        controller?.clearPreview()
    }

    /// Called once the visit is known (return visits start in Monitor when there is a previous visit).
    func chooseDefaultWorkMode() {
        let w = WorkMode.defaultMode(laterVisit: isLaterVisit)
        workMode = w
        mode = w.tools.first ?? .reading
    }

    // MARK: Plan

    var rooms: [[PlanVec]] { Revisit.rooms(plan) }
    var walls: [PlanWall] { Revisit.walls(plan) }
    var room: [PlanVec] { rooms.indices.contains(roomIndex) ? rooms[roomIndex] : [] }
    var cornerPoints: [PlanVec] { cornerIdx.compactMap { room.indices.contains($0) ? room[$0] : nil } }

    func reloadPlan() {
        if let data = try? Data(contentsOf: folder.planURL),
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            plan = doc
        }
    }

    static func largestRoom(_ rooms: [[PlanVec]]) -> Int {
        rooms.indices.max { FloorArea.area(rooms[$0]) < FloorArea.area(rooms[$1]) } ?? 0
    }

    func chooseRoom(_ i: Int) {
        guard rooms.indices.contains(i) else { return }
        roomIndex = i
        if let p = Corners.defaultPair(rooms[i]) { cornerIdx = [p.0, p.1] } else { cornerIdx = [] }
        picking = 0
    }

    /// A tap on the mini plan (plan coordinates): a corner of the chosen room
    /// replaces the corner being picked; elsewhere selects that room.
    func tapPlan(_ p: PlanVec) {
        if let c = Corners.nearest(to: p, in: room, maxDistance: 0.6) {
            if cornerIdx.count <= picking { cornerIdx.append(c) } else { cornerIdx[picking] = c }
            if cornerIdx.count >= 2, cornerIdx[0] == cornerIdx[1] { cornerIdx.remove(at: 1) }
            picking = min(picking + 1, max(1, cornerIdx.count - 1))
            return
        }
        if let r = Corners.room(at: p, polygons: rooms), r != roomIndex { chooseRoom(r) }
    }

    var cornerNames: [String] { ["A", "B", "C"] }

    // MARK: Visit

    /// Starts (or continues) the visit and writes plan.json. Returns false on failure.
    func beginVisit() -> Bool {
        let r = Revisit.startVisitIfNeeded(plan: plan, now: Date(), timeZone: .current)
        plan = r.plan
        visit = r.visit
        let visits = (plan["markup"] as? [String: Any])?["visits"] as? [[String: Any]] ?? []
        let n = visits.firstIndex { ($0["id"] as? String) == r.visit }.map { $0 + 1 } ?? 1
        visitLabel = "Visit \(n)\(r.started ? " (started today)" : "")"
        chooseDefaultWorkMode()
        if r.started { return savePlan() }
        return true
    }

    // MARK: AR session lifecycle (called by the screen / controller)

    func arStarted() {
        if start == .sharedSession, let f = savedFrame {
            // The scan's own session: the plan frame applies as it is.
            alignment = f.transform
            floorY = f.floorY ?? 0
            autoAligned = true
            fitAcceptable = true
            phase = .measuring
            refreshMarkers()
            logEvent(["type": "alignment", "shared": true, "angle": f.angle, "offset": f.offset, "floorY": floorY])
            return
        }
        if start == .corners {
            startCorners()
            return
        }
        if hasWorldMap, savedFrame != nil {
            phase = .relocalizing
            relocaliseDeadline = Date().addingTimeInterval(10)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_500_000_000)
                self?.relocaliseTimedOut()
            }
        } else {
            startCorners()
        }
    }

    func trackingChanged(_ t: TrackingStatus) {
        tracking = t
        if phase == .relocalizing, t == .normal, let f = savedFrame {
            // Relocalised onto the first scan's world map: its plan frame applies directly.
            alignment = f.transform
            floorY = f.floorY ?? 0
            autoAligned = true
            fitMessage = "Aligned automatically with the saved scan. Check the blue lines sit on the walls at floor level."
            fitAcceptable = true
            showCheck()
        }
    }

    private func relocaliseTimedOut() {
        guard phase == .relocalizing else { return }
        // The saved map didn't match (or not yet): carry on with corners, without fuss.
        controller?.restart(worldMap: nil)
        startCorners()
    }

    func useCornersInstead() {
        if phase == .relocalizing { controller?.restart(worldMap: nil) }
        startCorners()
    }

    func startCorners() {
        autoAligned = false
        alignment = nil
        hits = []
        fitMessage = nil
        fitAcceptable = false
        if cornerIdx.count > 2 { cornerIdx = Array(cornerIdx.prefix(2)) }
        controller?.clearMarkers()
        phase = .corner(0)
    }

    /// "Set A/B/C": the crosshair raycast hit is that corner.
    func setCorner() {
        guard case .corner(let i) = phase else { return }
        guard tracking.isNormal else { fitMessage = "Wait until tracking is normal, then try again."; return }
        guard let hit = controller?.centreHit() else {
            fitMessage = "Nothing under the crosshair yet. Point at the corner where the two walls meet the floor."
            return
        }
        if hits.count > i { hits = Array(hits.prefix(i)) }
        hits.append(hit)
        fitMessage = nil
        if hits.count < 2 {
            phase = .corner(hits.count)
            return
        }
        if hits.count < cornerPoints.count {
            phase = .corner(hits.count)
            return
        }
        evaluateFit()
    }

    func undoCorner() {
        guard !hits.isEmpty else { return }
        hits.removeLast()
        fitMessage = nil
        phase = .corner(hits.count)
    }

    /// Adds a third corner (the room corner farthest from A and B) and asks for it.
    func addThirdCorner() {
        let used = Set(cornerIdx.prefix(2))
        let pts = cornerPoints.prefix(2)
        guard let c = room.indices.filter({ !used.contains($0) }).max(by: { a, b in
            pts.map { simd_distance(room[a], $0) }.min() ?? 0 < pts.map { simd_distance(room[b], $0) }.min() ?? 0
        }) else { return }
        cornerIdx = Array(cornerIdx.prefix(2)) + [c]
        hits = Array(hits.prefix(2))
        fitMessage = nil
        phase = .corner(2)
    }

    private func evaluateFit() {
        let plans = cornerPoints
        switch Alignment.fit(world: hits, plan: plans) {
        case .failure(let p):
            fitMessage = p == .tooClose ? "Those corners are too close together. Choose corners further apart and redo."
                                        : "The corners don't match. Redo them."
            fitAcceptable = false
            phase = .corner(hits.count - 1)
        case .success(let f):
            alignment = f.transform
            floorY = Alignment.floorHeight(hits) ?? f.floorY
            if f.ok {
                fitAcceptable = true
                fitMessage = String(format: "Aligned. Corners match the plan within %.0f cm.", max(f.maxResidual, abs(f.distanceError)) * 100)
            } else {
                fitAcceptable = false
                var text = String(format: "Corner A to B measured %.2f m on site but %.2f m on the plan.",
                                  simd_distance(PlanVec(hits[0].x, hits[0].z), PlanVec(hits[1].x, hits[1].z)),
                                  simd_distance(plans[0], plans[1]))
                if let d = Alignment.diagnose(world: hits, plan: plans) {
                    switch d {
                    case .swapped: text += " The corners look like they were tapped in a different order."
                    case .mirrored: text += " It only fits as a mirror image: check you pointed at the corners shown."
                    default: break
                    }
                }
                fitMessage = text + " Redo the corners, add a third corner, or use it anyway."
            }
            showCheck()
        }
    }

    func acceptAnyway() {
        fitAcceptable = true
        showCheck()
    }

    private func showCheck() {
        phase = .check
        if let a = alignment { controller?.showOutline(walls: walls, alignment: a, floorY: floorY) }
    }

    func looksRight() {
        guard alignment != nil else { return }
        phase = .measuring
        refreshMarkers()
        logEvent(["type": "alignment", "auto": autoAligned, "angle": alignment?.angle ?? 0,
                  "offset": [alignment?.offset.x ?? 0, alignment?.offset.y ?? 0], "floorY": floorY])
    }

    func realign() {
        controller?.clearMarkers()
        startCorners()
    }

    // MARK: Markers and aiming

    func refreshMarkers() {
        markers = Revisit.markers(plan: plan, visit: visit)
        quoteTally = QuoteTally.from(plan: plan)
        scopeItems = ScopeList.items(plan: plan, names: EditorNamesStore.load(folder))
        if let id = aimedScope?.id { aimedScope = scopeItems.first { $0.id == id } }
        if purpose == .scope {
            guard phase == .measuring, let a = alignment else { return }
            controller?.showScope(scopeItems, walls: walls, alignment: a, floorY: floorY)
            return
        }
        guard phase == .measuring, let a = alignment else { return }
        controller?.showMarkers(markers, walls: walls, alignment: a, floorY: floorY)
    }

    var progress: (done: Int, total: Int) { Revisit.progress(markers) }

    /// Called ~10 times a second with the camera pose (this session's world space).
    func aim(camera: WorldVec, forward: WorldVec) {
        guard phase == .measuring, let a = alignment else {
            if target != nil { target = nil }
            hint = nil
            return
        }
        if purpose == .scope {
            let cands = scopeItems.map { it -> Revisit.Candidate in
                let h = it.kind == .floor ? 0.02 : it.height
                return Revisit.Candidate(id: it.id, kind: it.kind.rawValue,
                                         world: Revisit.world(it.pos, height: h, alignment: a, floorY: floorY),
                                         radius: it.kind == .equipment ? 0.4 : (it.kind == .wall ? 0.6 : 0.8))
            }
            let t = Revisit.target(cands, origin: camera, direction: forward)
            if t?.id != aimedScope?.id {
                aimedScope = t.flatMap { c in scopeItems.first { $0.id == c.id } }
                controller?.highlight(t?.id)
            }
            if hint != nil { hint = nil }
            return
        }
        let remeasuring = mode == .remeasure && moving == nil
        let marking = mode == .markDone && moving == nil
        let candidates = markers.filter {
            (remeasuring && $0.kind == "reading") || (marking && ($0.kind == "equipment" || ($0.kind == "removal" && !$0.done)))
        }.map {
            Revisit.Candidate(id: $0.id, kind: $0.kind,
                              world: Revisit.world($0.pos, height: $0.height, alignment: a, floorY: floorY),
                              radius: $0.kind == "reading" ? 0.15 : 0.35)
        }
        let t = Revisit.target(candidates, origin: camera, direction: forward)
        if t?.id != target?.id { target = t; controller?.highlight(t?.id) }
        // Hint towards the nearest point not yet re-measured (return visits only).
        guard remeasuring else { if hint != nil { hint = nil }; return }
        let open = markers.filter { $0.kind == "reading" && !$0.measured }
        let fy = floorY
        let placed: [(marker: Revisit.Marker, world: WorldVec, distance: Double)] = open.map { m in
            let w = Revisit.world(m.pos, height: m.height, alignment: a, floorY: fy)
            return (m, w, simd_distance(w, camera))
        }
        if let nearest = placed.min(by: { $0.distance < $1.distance }) {
            let near = nearest.marker
            let w = nearest.world
            let deg = Revisit.turnHint(camera: camera, forward: forward, target: w)
            let name = near.label.components(separatedBy: " ").first ?? ""
            hint = abs(deg) < 25 ? "Point \(name) ahead" : (deg > 0 ? "Point \(name) → turn right" : "← turn left · point \(name)")
        } else {
            hint = markers.contains { $0.kind == "reading" } ? "All points re-measured" : nil
        }
    }

    /// True from the second visit on (re-measuring makes sense).
    var isLaterVisit: Bool {
        let visits = ((plan["markup"] as? [String: Any])?["visits"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return (visits.firstIndex(of: visit) ?? 0) > 0
    }

    var canAct: Bool { phase == .measuring && tracking.isNormal && !flow.isBusy }

    /// Exactly what a tap on the big button does.
    var actionTitle: String {
        if purpose == .scope { return aimedScope?.actionTitle ?? "Aim at a scoped item" }
        if aimingDir != nil { return "Set airflow direction" }
        if moving != nil { return "Move here" }
        let aimed = target.flatMap { t in markers.first(where: { $0.id == t.id }) }
        switch mode {
        case .reading: return "Log reading"
        case .moisture:
            if moistureOnFloor { return floorCornerCount > 0 ? "Add corner \(floorCornerCount + 1)" : "Hold to trace wet floor" }
            return sweeping ? "Drawing… release to finish" : "Hold to draw moisture line"
        case .photo: return "Take photo"
        case .source: return "Mark source here"
        case .equipment: return "Place \(PlanDocument.equipmentName(lastEquipmentType).lowercased())"
        case .wallRemoval: return "Start \(RemovalItems.name(wallRemovalItem).lowercased()) removal here"
        case .floorRemoval: return "Start floor removal: first corner"
        case .remeasure:
            guard let m = aimed else { return "Aim at a reading" }
            return "Re-measure \(m.label.components(separatedBy: " ").first ?? "")"
        case .markDone:
            guard let m = aimed else { return "Aim at equipment or a removal" }
            return m.kind == "equipment" ? "Mark removed: \(m.label)" : "Mark done + after photo"
        }
    }

    func mainAction() {
        guard canAct else { return }
        if purpose == .scope {
            guard let it = aimedScope else { showToast("Put the crosshair on a red band, a floor section or a ghost marker"); return }
            guard !it.done else { showToast("\(it.tag) is already done"); return }
            confirm = it.kind == .equipment ? .equipmentPlaced(id: it.id, name: it.tag) : .removalDone(id: it.id, name: it.tag)
            return
        }
        if let id = aimingDir { setDirection(id); return }
        if let id = moving { moveHere(id); return }
        let aimed = target.flatMap { t in markers.first(where: { $0.id == t.id }) }
        switch mode {
        case .moisture: tapMoisture()
        case .photo:
            // One tap, no sheet: the frame is saved; a caption can be added from the item later.
            beginLog(kind: "photo")
            if pending != nil { saveLog(kind: "photo", value: nil, material: "wall", reference: false, note: "") }
        case .wallRemoval: startRemovalNow(item: wallRemovalItem)
        case .floorRemoval: startRemovalNow(item: "flooring")
        case .remeasure:
            if let m = aimed { beginRemeasure(m) } else { showToast("Put the crosshair on a saved reading") }
        case .markDone:
            guard let m = aimed else { showToast("Put the crosshair on equipment or a removal band"); return }
            confirm = m.kind == "equipment" ? .equipmentRemoved(id: m.id, name: m.label) : .removalDone(id: m.id, name: m.label)
        default: beginLog(kind: mode.kind)
        }
    }

    /// Quote mode: this frame is the start of a removal, no sheet first
    /// (wall: then "End here"; flooring: this tap is the first corner).
    func startRemovalNow(item: String) {
        guard pending == nil, var p = capturePending() else { return }
        lastRemovalItem = item
        lastKind = "removal"
        if item != "flooring" { p = PendingLog(id: p.id, seq: p.seq, roomIndex: p.roomIndex, takenAt: p.takenAt, capture: snapToWallEnd(p.capture), photoTask: p.photoTask) }
        flow.begin(item: item, start: p)
        if item == "flooring", let c = controller?.capturePose() { flow.addCorner(c) }
    }

    func beginLog(kind: String) {
        lastKind = kind
        beginLog()
    }

    /// A tap on a marker in the camera view: its sheet (edit, move, delete).
    func tapMarker(_ id: String) {
        guard phase == .measuring, purpose == .markup, moving == nil, aimingDir == nil, !sweeping, !flow.isBusy else { return }
        openEditor(id)
    }

    // MARK: Re-measure

    func beginRemeasure(_ m: Revisit.Marker) {
        guard let p = capturePending() else { return }
        let readings = (plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]] ?? []
        let r = readings.first { ($0["id"] as? String) == m.id } ?? [:]
        let visits = (plan["markup"] as? [String: Any])?["visits"] as? [[String: Any]] ?? []
        let previous = Revisit.history(r).map { e -> String in
            let vid = (e["visit"] as? String) ?? "v1"
            let n = visits.firstIndex { ($0["id"] as? String) == vid }.map { $0 + 1 } ?? 1
            let v = PlanDocument.number(e["value"]).map { Revisit.fmt($0) + "%" } ?? "–"
            return "Visit \(n): \(v)"
        }
        let name = m.label.components(separatedBy: " ").first ?? ""
        remeasure = RemeasureRequest(id: m.id, title: "Point \(name)", previous: previous, pending: p)
    }

    func saveRemeasure(value: Double) {
        guard let req = remeasure else { return }
        remeasure = nil
        let visit = self.visit
        Task {
            let photo = await Self.dataURL(req.pending.photoTask)
            guard let out = Revisit.recordMeasurement(plan: plan, readingId: req.id, visit: visit, value: value,
                                                      takenAt: req.pending.takenAt, photo: photo, note: nil) else {
                alert = "That point is no longer in the plan."
                return
            }
            plan = out
            if savePlan() {
                logEvent(["type": "remeasure", "id": req.id, "visit": visit, "value": value, "takenAt": req.pending.takenAt,
                          "camera": ScanModel.arr(req.pending.capture.cameraPosition)])
                refreshMarkers()
                let p = progress
                showToast("\(req.title) re-measured · \(Revisit.fmt(value))% · \(p.done) of \(p.total)")
            }
        }
    }

    func confirmAction(_ c: RevisitConfirm) {
        let now = PlanDocument.iso(Date())
        switch c {
        case .equipmentPlaced(let id, let name):
            guard let out = ScopeList.markPlaced(plan: plan, id: id, visit: visit, at: now) else { return }
            plan = out
            if savePlan() { logEvent(["type": "equipmentPlaced", "id": id, "visit": visit, "at": now]); refreshMarkers(); showToast("\(name) marked placed") }
        case .equipmentRemoved(let id, let name):
            guard let out = Revisit.markEquipmentRemoved(plan: plan, id: id, visit: visit, at: now) else { return }
            plan = out
            if savePlan() { logEvent(["type": "equipmentRemoved", "id": id, "visit": visit, "at": now]); refreshMarkers(); showToast("\(name) marked removed") }
        case .removalDone(let id, _):
            guard let p = capturePending(), let a = alignment else { return }
            let cam = a.point(Self.world(p.capture.cameraPosition))
            let visit = self.visit
            Task {
                let photo = await Self.dataURL(p.photoTask)
                guard let out = Revisit.markRemovalDone(plan: plan, id: id, visit: visit, photo: photo, takenAt: p.takenAt, cam: cam) else { return }
                plan = out
                if savePlan() { logEvent(["type": "removalDone", "id": id, "visit": visit, "at": p.takenAt]); refreshMarkers(); showToast("Removal marked done · photo kept") }
            }
        }
    }

    // MARK: Logging new items (LogSheetModel)

    var nextReadingNumber: Int {
        let readings = (plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]] ?? []
        return Int(readings.filter { (($0["kind"] as? String) ?? "reading") == "reading" }.compactMap { PlanDocument.number($0["n"]) }.max() ?? 0) + 1
    }

    var nextPhotoNumber: Int {
        let readings = (plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]] ?? []
        return Int(readings.filter { ($0["kind"] as? String) == "photo" }.compactMap { PlanDocument.number($0["n"]) }.max() ?? 0) + 1
    }

    func beginLog() {
        guard canAct, pending == nil, let p = capturePending() else { return }
        pending = p
    }

    func cancelLog() { pending = nil }

    func saveLog(kind: String, value: Double?, material: String, reference: Bool, note: String) {
        guard let p = pending else { return }
        pending = nil
        if kind == "reading" { lastMaterial = material }
        if kind == "equipment" { lastEquipmentType = material }
        if kind != "floorType" { lastKind = kind }
        var r = Self.pbReading(p, kind: kind, material: material, note: note)
        r.value = kind == "reading" ? value : nil
        r.reference = kind == "reading" && reference
        if kind == "floorType" { r.floorType = material }
        let photo = attachPhoto
        attachPhoto = true
        addResolved(r, photoTask: photo ? p.photoTask : Task<Data?, Never> { nil }, title: LogKind.name(kind), photo: photo)
    }

    func startRemoval(item: String) {
        guard let p = pending else { return }
        pending = nil
        lastRemovalItem = item
        lastKind = "removal"
        flow.begin(item: item, start: p)
    }

    func endHere() {
        guard let c = controller?.captureFrame() else { return }
        var pose = c
        pose.image = nil
        flow.setEnd(snapToWallEnd(pose))
    }

    /// A tap within 15 cm of the end of the wall under the reticle lands on its end.
    func snapToWallEnd(_ c: FrameCapture) -> FrameCapture {
        guard let w = reticleWall, let a = alignment, let h = c.hit else { return c }
        let hit = WorldVec(Double(h.x), Double(h.y), Double(h.z))
        let snapped = WallEndSnap.snapPoint(hit, wallA: a.world(w.a, y: hit.y), wallB: a.world(w.b, y: hit.y))
        guard snapped != hit else { return c }
        var out = c
        out.hit = SIMD3<Float>(snapped)
        let cam = WorldVec(Double(c.cameraPosition.x), Double(c.cameraPosition.y), Double(c.cameraPosition.z))
        if simd_length(snapped - cam) > 1e-6 { out.cameraForward = SIMD3<Float>(simd_normalize(snapped - cam)) }
        return out
    }

    /// "Whole wall": a wall strip-out from end to end of the wall under the
    /// reticle, at the reticle's height; then the usual height sheet.
    func wholeWall() {
        guard canAct, pending == nil, let w = reticleWall, let a = alignment, let y = reticleY,
              let p = capturePending() else { return }
        let ends = WallEndSnap.wholeWall(a: a.world(w.a, y: y), b: a.world(w.b, y: y), y: y)
        let cam = WorldVec(Double(p.capture.cameraPosition.x), Double(p.capture.cameraPosition.y), Double(p.capture.cameraPosition.z))
        func aimed(_ c: FrameCapture, at e: WorldVec) -> FrameCapture {
            var out = c
            out.hit = SIMD3<Float>(e)
            if simd_length(e - cam) > 1e-6 { out.cameraForward = SIMD3<Float>(simd_normalize(e - cam)) }
            return out
        }
        let start = PendingLog(id: p.id, seq: p.seq, roomIndex: p.roomIndex, takenAt: p.takenAt,
                               capture: aimed(p.capture, at: ends.0), photoTask: p.photoTask)
        lastRemovalItem = wallRemovalItem
        lastKind = "removal"
        flow.begin(item: wallRemovalItem, start: start)
        var end = aimed(p.capture, at: ends.1)
        end.image = nil
        flow.setEnd(end)
    }

    /// The height sheet's pre-picked height: from where the end was tapped.
    var suggestedRemovalMm: Int? {
        guard let h = flow.end?.hit else { return nil }
        return HeightSnap.suggested(endHeightMetres: Double(h.y) - floorY)
    }

    func addCorner() {
        guard let c = controller?.captureFrame() else { return }
        var pose = c
        pose.image = nil
        flow.addCorner(pose)
    }

    func saveRemoval(item: String, heightMm: Int, note: String, floorType: String?, underlay: Bool) {
        guard let d = flow.finish(item: item, heightMm: heightMm, note: note, floorType: floorType, underlay: underlay) else { return }
        var r = Self.pbReading(d.start, kind: "removal", material: d.item, note: d.note)
        if let e = d.end {
            r.end = PBPose(cameraPosition: Self.world(e.cameraPosition), cameraForward: Self.world(e.cameraForward),
                           hit: e.hit.map(Self.world))
        }
        r.corners = d.corners.map { PBPose(cameraPosition: Self.world($0.cameraPosition), cameraForward: Self.world($0.cameraForward),
                                           hit: $0.hit.map(Self.world)) }
        r.wholeRoom = d.wholeRoom
        r.heightMm = Double(d.heightMm)
        r.floorType = d.floorType
        r.underlay = d.underlay
        addResolved(r, photoTask: d.start.photoTask, title: "Removal")
    }

    /// Resolve against the saved plan through the alignment, embed the photo,
    /// add to plan.json, log the raw record.
    private func addResolved(_ r: PBReading, photoTask: Task<Data?, Never>, title: String, photo: Bool = true) {
        guard let a = alignment, phase == .measuring else {
            alert = "Not aligned yet - nothing was saved. Align with the corners first."
            return
        }
        let visit = self.visit, floorY = self.floorY
        Task {
            var pb = r
            pb.photo = await Self.dataURL(photoTask)
            switch Revisit.itemJSON(for: pb, plan: plan, alignment: a, floorY: floorY, visit: visit) {
            case .failure(let e):
                alert = e.message
            case .success(var item):
                // Equipment put in the scope (Quote / Scope mode) is planned until the crew marks it placed.
                if pb.kind == "equipment" && self.workMode == .quote { item["status"] = "planned" }
                plan = Revisit.addItem(plan: plan, item: item)
                if savePlan() {
                    if let scan = self.scan, let raw = self.rawRecord(pb, photo: photo) { scan.commit(raw, photoTask: photoTask) }
                    if pb.kind == "equipment" && pb.material == "airMover" {
                        self.aimingDir = pb.id
                        self.showToast("Aim along the airflow, then tap Set airflow direction")
                    }
                    self.pushUndo([pb.id], stroke: false)
                    var ev: [String: Any] = ["type": "logged", "id": pb.id, "kind": pb.kind, "visit": visit, "takenAt": pb.takenAt,
                                             "camera": [pb.cameraPosition.x, pb.cameraPosition.y, pb.cameraPosition.z],
                                             "forward": [pb.cameraForward.x, pb.cameraForward.y, pb.cameraForward.z]]
                    if let h = pb.hit { ev["hit"] = [h.x, h.y, h.z] }
                    logEvent(ev)
                    refreshMarkers()
                    showToast("\(title) logged · \(visitLabel)")
                }
            }
        }
    }

    // MARK: Reticle

    /// From the camera tick: what the crosshair is on, said before the tap.
    func updateReticle(hit: WorldVec?, normal: WorldVec?) {
        var text = ""
        if let h = hit, let a = alignment {
            let p = a.point(h)
            let ny = normal.map { simd_length($0) > 1e-9 ? simd_normalize($0).y : 0 } ?? 0
            let d = abs(ny) < 0.7 ? walls.map { PlanBuilder.distanceToSegment(p, $0.a, $0.b) }.min() : nil
            let s = Reticle.surface(normalY: ny, height: h.y - floorY, distanceToWall: d)
            let wall = s == .wall ? PlanBuilder.nearestWall(to: p, walls: walls, maxDistance: 0.25).map { walls[$0.index] } : nil
            if wall?.id != reticleWall?.id { reticleWall = wall }
            reticleY = h.y
            let room = FloorArea.room(containing: p, rooms: rooms).flatMap { i -> String? in
                let list = plan["rooms"] as? [[String: Any]] ?? []
                return list.indices.contains(i) ? list[i]["name"] as? String : nil
            }
            text = Reticle.describe(s, height: h.y - floorY, room: room)
        } else if hit == nil {
            if reticleWall != nil { reticleWall = nil }
            text = Reticle.blocked(trackingNormal: tracking.isNormal, hasHit: false, needsWall: mode != .equipment && mode != .floorRemoval) ?? ""
        }
        if reticle != text { reticle = text }
    }

    // MARK: Airflow (air movers) and the scope view

    /// The phone's heading now becomes the air mover's airflow ("dir", a plan angle).
    func setDirection(_ id: String) {
        guard let a = alignment, let c = controller?.capturePose() else { return }
        guard let angle = Airflow.planAngle(forward: Self.world(c.cameraForward), transform: a) else {
            showToast("Hold the phone up and point it the way the air should blow")
            return
        }
        aimingDir = nil
        controller?.clearPreview()
        guard let d = MarkupEdit.update(plan, id: id, set: ["dir": PlanDocument.r4(angle)]) else { return }
        plan = d
        if savePlan() { logEvent(["type": "airflow", "id": id, "dir": angle]); refreshMarkers(); showToast("Airflow set") }
    }

    func skipDirection() {
        aimingDir = nil
        controller?.clearPreview()
    }

    func reAimAirflow(_ id: String) {
        editing = nil
        aimingDir = id
        showToast("Aim along the airflow, then tap Set airflow direction")
    }

    /// "Edit scope": from the view-only scope to the Scope tools.
    func editScope() {
        purpose = .markup
        aimedScope = nil
        setWorkMode(.quote)
        refreshMarkers()
    }

    /// The list fallback (no camera): mark placed / done without a photo.
    func markFromList(_ it: ScopeItem) {
        let now = PlanDocument.iso(Date())
        let out = it.kind == .equipment
            ? ScopeList.markPlaced(plan: plan, id: it.id, visit: visit, at: now)
            : Revisit.markRemovalDone(plan: plan, id: it.id, visit: visit, photo: nil, takenAt: now, cam: nil)
        guard let out else { return }
        plan = out
        if savePlan() {
            logEvent(["type": it.kind == .equipment ? "equipmentPlaced" : "removalDone", "id": it.id, "visit": visit, "at": now, "from": "list"])
            refreshMarkers()
        }
    }

    // MARK: Hold and sweep (moisture line on walls, wet area on the floor)

    func pressBegan() {
        guard canAct, moving == nil, mode == .moisture, !sweeping else { return }
        pressStarted = Date()
        sweepPoses = []
        sweeping = true
        sampleSweep()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleSweep() }
        }
    }

    func pressEnded() {
        guard sweeping else { mainAction(); return }
        let held = pressStarted.map { Date().timeIntervalSince($0) } ?? 0
        pressStarted = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
        sweeping = false
        let poses = sweepPoses
        sweepPoses = []
        controller?.clearPreview()
        previewShown = false
        if held < 0.35 || poses.count < 3 { tapMoisture() } else { finishSweep(poses) }
    }

    /// About 8 times a second while the button is held: the crosshair's hit.
    private func sampleSweep() {
        guard sweeping, tracking.isNormal, let c = controller?.capturePose(), c.hit != nil else { return }
        sweepPoses.append(c)
        let pts = sweepPoses.compactMap { $0.hit.map(Self.world) }
        if moistureOnFloor { controller?.previewFloor(pts, floorY: floorY) }
        else { controller?.previewStroke(pts, floorY: floorY) }
        previewShown = true
    }

    private func pose(_ c: FrameCapture) -> PBPose {
        PBPose(cameraPosition: Self.world(c.cameraPosition), cameraForward: Self.world(c.cameraForward), hit: c.hit.map(Self.world))
    }

    private func plainItem(kind: String, _ c: FrameCapture, note: String = "") -> PBReading {
        let id = (firstScan ? "ar-" : "rv-") + UUID().uuidString.prefix(8).lowercased()
        seq += 1
        return PBReading(id: id, seq: scan?.allocateSeq() ?? seq, kind: kind, value: nil, material: kind == "affected" ? "floor" : "wall",
                         note: note, takenAt: PlanDocument.iso(Date()),
                         cameraPosition: Self.world(c.cameraPosition), cameraForward: Self.world(c.cameraForward),
                         hit: c.hit.map(Self.world))
    }

    /// A single tap in Moisture mode: one line point on the wall, or one corner of the wet area.
    func tapMoisture() {
        guard canAct, let c = controller?.capturePose() else { return }
        guard c.hit != nil else { showToast("Nothing under the crosshair — point at the wall or floor"); return }
        if moistureOnFloor {
            floorCorners.append(c)
            floorCornerCount = floorCorners.count
            showToast(floorCornerCount < 3 ? "Corner \(floorCornerCount) · tap the next corner" : "Corner \(floorCornerCount) · Close area when done")
            return
        }
        _ = addNow([plainItem(kind: "boundary", c)], stroke: false, toast: "Moisture line point added")
    }

    func undoFloorCorner() {
        guard !floorCorners.isEmpty else { return }
        floorCorners.removeLast()
        floorCornerCount = floorCorners.count
        if floorCorners.isEmpty { controller?.clearPreview(); previewShown = false }
    }

    func closeFloorArea() {
        let corners = floorCorners
        guard corners.count >= 3, let first = corners.first else { return }
        var item = plainItem(kind: "affected", first, note: "Wet area")
        item.corners = corners.map(pose)
        if addNow([item], stroke: true, toast: "Wet area saved") {
            floorCorners = []
            floorCornerCount = 0
            controller?.clearPreview()
            previewShown = false
        }
    }

    private func finishSweep(_ poses: [FrameCapture]) {
        guard let a = alignment, let first = poses.first else { return }
        if moistureOnFloor {
            var item = plainItem(kind: "affected", first, note: "Wet area")
            item.corners = poses.map(pose)
            _ = addNow([item], stroke: true, toast: "Wet floor area traced")
            return
        }
        let ws = walls
        let lengths = Dictionary(ws.map { ($0.id, $0.length) }, uniquingKeysWith: { x, _ in x })
        let floors: [Double?] = ws.map { _ in floorY }
        let items = poses.map { plainItem(kind: "boundary", $0) }
        let samples = items.indices.map { i -> Sweep.WallSample in
            let pb = items[i]
            let r = PlanBuilder.resolve(pb, walls: ws, wallFloorY: floors, globalFloorY: floorY, transform: a)
            return Sweep.WallSample(index: i, wallId: r.wallId, wallT: r.wallT, height: r.height,
                                    wallLength: r.wallId.flatMap { lengths[$0] } ?? 1)
        }
        let kept = Sweep.strokePoints(samples)
        guard !kept.isEmpty else {
            showToast("The line didn't land on a wall — sweep along the wall itself")
            return
        }
        let wallsUsed = Set(kept.compactMap(\.wallId)).count
        // A line that starts or ends within 15 cm of a wall's end is drawn to that end (2 cm in).
        let byId = Dictionary(ws.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let snappedItems = kept.map { k -> PBReading in
            var pb = items[k.index]
            guard let wid = k.wallId, let w = byId[wid], let t = k.wallT, let h = pb.hit, w.length > 0.05 else { return pb }
            let st = WallEndSnap.snap(t, length: w.length)
            guard st == 0 || st == 1 else { return pb }
            let along = (w.b - w.a) / w.length
            let e = st == 0 ? w.a + along * 0.02 : w.b - along * 0.02
            let world = a.world(e, y: h.y)
            pb.hit = world
            if simd_length(world - pb.cameraPosition) > 1e-6 { pb.cameraForward = simd_normalize(world - pb.cameraPosition) }
            return pb
        }
        _ = addNow(snappedItems, stroke: true,
                   toast: "Moisture line · \(kept.count) points on \(wallsUsed) wall\(wallsUsed == 1 ? "" : "s")")
    }

    func undoStroke() {
        guard let ids = strokeStack.last else { return }
        removeItems(ids)
        showToast("Last line removed")
    }

    func undoLast() {
        undoWindow.used()
        undoChipVisible = false
        guard let ids = undoStack.last else { return }
        removeItems(ids)
        showToast("Undone")
    }

    /// Adds items without photos (line points, wet areas) at once: plan.json,
    /// then the scan's raw log. All or nothing.
    private func addNow(_ items: [PBReading], stroke: Bool, toast: String) -> Bool {
        guard let a = alignment, phase == .measuring else {
            alert = "Not aligned yet - nothing was saved."
            return false
        }
        var doc = plan
        for pb in items {
            switch Revisit.itemJSON(for: pb, plan: doc, alignment: a, floorY: floorY, visit: visit) {
            case .failure(let e):
                alert = e.message.replacingOccurrences(of: "Tap at least 3 corners of the floor section.",
                                                        with: "Trace round the wet area (or tap at least 3 corners).")
                return false
            case .success(let item):
                doc = Revisit.addItem(plan: doc, item: item)
            }
        }
        plan = doc
        guard savePlan() else { return false }
        if let scan { for pb in items { if let r = rawRecord(pb, photo: false) { scan.commit(r, photoTask: nil) } } }
        pushUndo(items.map(\.id), stroke: stroke)
        logEvent(["type": "logged", "ids": items.map(\.id), "kind": items.first?.kind ?? "", "visit": visit])
        refreshMarkers()
        showToast(toast)
        return true
    }

    private func pushUndo(_ ids: [String], stroke: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        undoWindow.saved(at: Date())
        undoChipVisible = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_100_000_000)
            guard let self else { return }
            self.undoChipVisible = self.undoWindow.visible(at: Date())
        }
        undoStack.append(ids)
        if stroke { strokeStack.append(ids) }
        undoCount = undoStack.count
        strokeCount = strokeStack.count
    }

    /// Deletes items from plan.json and (first scan) from the raw log.
    func removeItems(_ ids: [String]) {
        var doc = plan
        for id in ids { if let d = MarkupEdit.delete(doc, id: id) { doc = d } }
        plan = doc
        savePlan()
        for id in ids { scan?.delete(id) }
        let gone = Set(ids)
        undoStack = undoStack.map { $0.filter { !gone.contains($0) } }.filter { !$0.isEmpty }
        strokeStack = strokeStack.map { $0.filter { !gone.contains($0) } }.filter { !$0.isEmpty }
        undoCount = undoStack.count
        strokeCount = strokeStack.count
        logEvent(["type": "deleted", "ids": ids])
        refreshMarkers()
    }

    // MARK: Live previews (removal band, floor corners)

    var wantsCrosshair: Bool { flow.mode != .idle || floorCornerCount > 0 || aimingDir != nil }

    /// From the camera tick (10 Hz) with the crosshair's hit.
    func livePreview(crosshair: WorldVec?) {
        guard !sweeping else { return }
        if let id = aimingDir, let a = alignment {
            // The airflow arrow from the air mover along where the phone points.
            if let e = MarkupEdit.find(plan, id: id), let p = Revisit.point(e.item["pos"]),
               let c = controller?.capturePose(), let angle = Airflow.planAngle(forward: Self.world(c.cameraForward), transform: a) {
                controller?.previewArrow(from: Revisit.world(p, height: 0.2, alignment: a, floorY: floorY),
                                         direction: Airflow.worldDirection(angle, transform: a))
                previewShown = true
            }
            return
        }
        if flow.mode == .wallEnd, let s = flow.start?.capture.hit.map(Self.world), let c = crosshair {
            let top = Double(max(RemovalItems.defaultMm(flow.item), 50)) / 1000
            controller?.previewBand(from: s, to: c, floorY: floorY, top: top)
            previewShown = true
        } else if flow.mode == .floorCorners {
            controller?.previewFloor(flow.corners.compactMap { $0.hit.map(Self.world) } + (crosshair.map { [$0] } ?? []), floorY: floorY)
            previewShown = true
        } else if floorCornerCount > 0 {
            controller?.previewFloor(floorCorners.compactMap { $0.hit.map(Self.world) } + (crosshair.map { [$0] } ?? []), floorY: floorY)
            previewShown = true
        } else if previewShown {
            controller?.clearPreview()
            previewShown = false
        }
    }

    // MARK: Editing what is there

    func openEditor(_ id: String) {
        guard let f = MarkupEdit.find(plan, id: id) else { return }
        let x = f.item
        let kind: String
        switch f.list {
        case "readings": kind = (x["kind"] as? String) ?? "reading"
        case "sources": kind = "source"
        case "equipment": kind = "equipment"
        case "removals": kind = "removal"
        case "affected": kind = "affected"
        default: kind = "floor"
        }
        let label: String
        switch f.list {
        case "sources", "equipment", "affected": label = (x["label"] as? String) ?? ""
        default: label = (x["note"] as? String) ?? ""
        }
        let title: String
        switch kind {
        case "reading": title = "Reading \(PlanDocument.number(x["n"]).map { String(Int($0)) } ?? "")"
        case "boundary": title = "Moisture line point"
        case "photo": title = "Photo P\(PlanDocument.number(x["n"]).map { String(Int($0)) } ?? "")"
        case "equipment": title = PlanDocument.equipmentName((x["type"] as? String) ?? "other")
        case "removal": title = "Removal · \(RemovalItems.name((x["item"] as? String) ?? "other"))"
        case "affected": title = "Wet area"
        case "source": title = "Source"
        default: title = "Floor type"
        }
        let removed = x["removed"].map { !($0 is NSNull) } ?? false
        editing = MarkerEdit(id: id, list: f.list, kind: kind, title: title,
                             value: PlanDocument.number(x["value"]), material: (x["material"] as? String) ?? "wall", label: label,
                             hasHeight: PlanDocument.number(x["height"]) != nil && x["wallId"] != nil,
                             movable: ["readings", "sources", "equipment"].contains(f.list),
                             canRemeasure: kind == "reading" && isLaterVisit,
                             canMarkRemoved: kind == "equipment" && isLaterVisit && !removed,
                             canMarkDone: kind == "removal" && (x["status"] as? String) != "done" && isLaterVisit,
                             isAirMover: kind == "equipment" && (x["type"] as? String) == "airMover",
                             planned: kind == "equipment" && ScopeList.isPlanned(x))
    }

    func saveEdit(_ e: MarkerEdit, value: Double?, material: String, label: String) {
        var set: [String: Any] = [:]
        let labelKey = ["sources", "equipment", "affected"].contains(e.list) ? "label" : "note"
        set[labelKey] = label
        if e.kind == "reading" {
            set["value"] = value.map { $0 as Any } ?? NSNull()
            set["material"] = material
        }
        editing = nil
        guard let d = MarkupEdit.update(plan, id: e.id, set: set) else { return }
        plan = d
        guard savePlan() else { return }
        scan?.updateRaw(e.id) { r in
            r.note = label
            if e.kind == "reading" { r.value = value; r.material = material }
        }
        logEvent(["type": "edited", "id": e.id])
        refreshMarkers()
        showToast("\(e.title) updated")
    }

    /// Raises / lowers a wall item 5 cm at a time.
    func nudge(_ id: String, by delta: Double) {
        guard let d = MarkupEdit.nudgeHeight(plan, id: id, by: delta) else { return }
        plan = d
        guard savePlan() else { return }
        scan?.updateRaw(id) { r in
            if var h = r.hit, h.count == 3 { h[1] += delta; r.hit = h }
        }
        refreshMarkers()
        let h = MarkupEdit.find(plan, id: id).flatMap { PlanDocument.number($0.item["height"]) } ?? 0
        showToast(String(format: "Height %.2f m", h))
    }

    func deleteItem(_ id: String) {
        editing = nil
        removeItems([id])
        showToast("Deleted")
    }

    func startMove(_ id: String) {
        editing = nil
        moving = id
        showToast("Aim where it should be, then tap Move here")
    }

    func cancelMove() { moving = nil }

    private func moveHere(_ id: String) {
        guard let a = alignment, let f = MarkupEdit.find(plan, id: id), let c = controller?.capturePose() else { return }
        let kind = f.list == "equipment" ? "equipment" : (f.list == "sources" ? "source" : ((f.item["kind"] as? String) ?? "reading"))
        var pb = plainItem(kind: kind, c)
        pb.id = id
        let ws = walls
        let r = kind == "equipment"
            ? PlanBuilder.resolveOnFloor(pb, globalFloorY: floorY, transform: a)
            : PlanBuilder.resolve(pb, walls: ws, wallFloorY: ws.map { _ in floorY }, globalFloorY: floorY, transform: a)
        guard let d = MarkupEdit.move(plan, id: id, to: r) else { return }
        moving = nil
        plan = d
        guard savePlan() else { return }
        scan?.updateRaw(id) { raw in
            raw.cameraPosition = Self.arr(self.scanWorld(pb.cameraPosition))
            raw.cameraForward = Self.arr(self.scanDirection(pb.cameraForward))
            raw.hit = pb.hit.map { Self.arr(self.scanWorld($0)) }
            raw.hitNormal = nil
            raw.resolved = nil
        }
        logEvent(["type": "moved", "id": id])
        refreshMarkers()
        showToast("Moved")
    }

    // MARK: First scan: the raw record in the scan's world space

    private func scanWorld(_ v: WorldVec) -> WorldVec {
        guard start != .sharedSession, let a = alignment, let f = savedFrame else { return v }
        return MarkupFrame.toScanWorld(v, session: a, sessionFloorY: floorY, scan: f.transform, scanFloorY: f.floorY ?? floorY)
    }

    private func scanDirection(_ d: WorldVec) -> WorldVec {
        guard start != .sharedSession, let a = alignment, let f = savedFrame else { return d }
        return MarkupFrame.directionToScan(d, session: a, scan: f.transform)
    }

    static func arr(_ v: WorldVec) -> [Double] { [v.x, v.y, v.z] }

    nonisolated static func fmtValue(_ v: Double) -> String { Revisit.fmt(v) }

    nonisolated static func kindName(_ kind: String) -> String {
        switch kind {
        case "affected": return "Wet area"
        case "boundary": return "Moisture line"
        default: return LogKind.name(kind)
        }
    }

    private func rawRecord(_ pb: PBReading, photo: Bool) -> RawReading? {
        guard scan != nil else { return nil }
        func pose9(_ p: PBPose) -> [Double] {
            Self.arr(scanWorld(p.cameraPosition)) + Self.arr(scanDirection(p.cameraForward)) + (p.hit.map { Self.arr(scanWorld($0)) } ?? [])
        }
        var r = RawReading(id: pb.id, seq: pb.seq, kind: pb.kind, value: pb.value, material: pb.material, reference: pb.reference,
                           note: pb.note, takenAt: pb.takenAt, roomIndex: max(0, roomNumber - 1),
                           cameraPosition: Self.arr(scanWorld(pb.cameraPosition)),
                           cameraForward: Self.arr(scanDirection(pb.cameraForward)),
                           hit: pb.hit.map { Self.arr(scanWorld($0)) }, hitKind: nil,
                           photoFile: photo ? "photos/\(pb.id).jpg" : nil, resolved: nil)
        if let e = pb.end {
            r.endCameraPosition = Self.arr(scanWorld(e.cameraPosition))
            r.endCameraForward = Self.arr(scanDirection(e.cameraForward))
            r.endHit = e.hit.map { Self.arr(scanWorld($0)) }
        }
        if pb.kind == "removal" { r.heightMm = pb.material == "flooring" ? 0 : pb.heightMm }
        if !pb.corners.isEmpty { r.corners = pb.corners.map(pose9) }
        r.wholeRoom = pb.wholeRoom ? true : nil
        r.floorType = pb.floorType
        r.underlay = pb.underlay ? true : nil
        return r
    }

    // MARK: Helpers

    private func capturePending() -> PendingLog? {
        guard let capture = controller?.captureFrame() else {
            showToast("Camera not ready — try again")
            return nil
        }
        let box = ImageBox(capture.image)
        let task = Task.detached(priority: .userInitiated) { FrameEncoder.jpeg(from: box.image) }
        var pose = capture
        pose.image = nil
        seq += 1
        return PendingLog(id: (firstScan ? "ar-" : "rv-") + UUID().uuidString.prefix(8).lowercased(), seq: scan?.allocateSeq() ?? seq,
                          roomIndex: max(0, roomNumber - 1),
                          takenAt: PlanDocument.iso(Date()), capture: pose, photoTask: task)
    }

    static func world(_ v: SIMD3<Float>) -> WorldVec { WorldVec(Double(v.x), Double(v.y), Double(v.z)) }

    static func pbReading(_ p: PendingLog, kind: String, material: String, note: String) -> PBReading {
        PBReading(id: p.id, seq: p.seq, kind: kind, value: nil, material: material, note: note, takenAt: p.takenAt,
                  cameraPosition: world(p.capture.cameraPosition), cameraForward: world(p.capture.cameraForward),
                  hit: p.capture.hit.map(world))
    }

    static func dataURL(_ task: Task<Data?, Never>) async -> String? {
        guard let d = await task.value else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    /// Writes plan.json (atomic). Small enough to do here; returns false on failure.
    @discardableResult
    private func savePlan() -> Bool {
        do {
            guard let clean = PlanDocument.sanitised(plan) as? [String: Any] else { return false }
            try PlanDocument.data(clean).write(to: folder.planURL, options: .atomic)
            return true
        } catch {
            alert = "Couldn't save to the plan: \(error.localizedDescription)"
            return false
        }
    }

    /// Appends an event to revisit-log.json (raw record of the visit).
    private func logEvent(_ e: [String: Any]) {
        var list = (try? Data(contentsOf: folder.revisitLogURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var ev = e
        ev["at"] = ev["at"] ?? PlanDocument.iso(Date())
        list.append(ev)
        if let data = try? JSONSerialization.data(withJSONObject: PlanDocument.sanitised(list)) {
            try? data.write(to: folder.revisitLogURL, options: .atomic)
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }
}
