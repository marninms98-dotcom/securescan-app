//
//  RevisitModel.swift
//  SecureScan
//
//  Return visits ("Find my points") and "See scope on site": the
//  CaptureEngine behind the one capture screen when a job already has a plan.
//  The maths and every document change are Core functions (Alignment,
//  Revisit, PlanBuilder resolvers, Scope); this class sequences them:
//    relocalising with the saved world map | corners A, B[, C] -> check -> measuring
//  Everything is merged into plan.json at once and appended to
//  revisit-log.json (raw, in this session's world space, with the alignment),
//  so a crash or lost tracking loses nothing. Nothing is ever dropped: a mark
//  the plan cannot place is logged and shown in review as "needs a quick fix".
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
        case .relocalizing: return "Finding the saved room — move slowly"
        case .limited(let why): return "Tracking limited — \(why)"
        case .notAvailable: return "Starting the camera…"
        }
    }
}

@MainActor
final class RevisitModel: ObservableObject, CaptureEngine {

    enum Phase: Equatable {
        case intro
        case relocalizing
        case corner(Int)       // which corner is being set (0 = A, 1 = B, 2 = C)
        case check
        case measuring
    }

    enum Purpose { case markup, scope }

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
    @Published private(set) var visitNumber = 1
    @Published private(set) var tracking: TrackingStatus = .notAvailable
    @Published private(set) var markers: [Revisit.Marker] = []
    @Published private(set) var target: Revisit.Candidate?
    @Published private(set) var hint: String?
    @Published var alert: String?
    @Published private(set) var autoAligned = false
    @Published private(set) var purpose: Purpose
    @Published private(set) var scopeItems: [ScopeItem] = []
    @Published private(set) var aimedScope: ScopeItem?

    private(set) lazy var hud = CaptureHUDModel(engine: self)
    weak var controller: RevisitARViewController?
    private(set) var alignment: PlanTransform?
    private(set) var floorY = 0.0
    private var relocaliseDeadline: Date?
    private var lastSample: AimSample?
    private var marksCache: [OverlayMark]?
    private var worldCache: CaptureWorld?
    let hasWorldMap: Bool
    let savedFrame: PlanFrame?
    let start: MarkupStart?

    init(folder: JobFolder, purpose: Purpose = .markup, start: MarkupStart? = nil) {
        self.folder = folder
        self.purpose = purpose
        self.start = start
        self.hasWorldMap = FileManager.default.fileExists(atPath: folder.worldMapURL.path)
        self.savedFrame = JobFiles.loadFrame(folder)
        reloadPlan()
        chooseRoom(Self.largestRoom(rooms))
        visit = PlanDocument.currentVisit(plan["markup"] as? [String: Any] ?? [:])
    }

    // MARK: Plan

    var rooms: [[PlanVec]] { Revisit.rooms(plan) }
    var walls: [PlanWall] { Revisit.walls(plan) }
    var room: [PlanVec] { rooms.indices.contains(roomIndex) ? rooms[roomIndex] : [] }
    var cornerPoints: [PlanVec] { cornerIdx.compactMap { room.indices.contains($0) ? room[$0] : nil } }
    var cornerNames: [String] { ["A", "B", "C"] }

    func reloadPlan() {
        if let data = try? Data(contentsOf: folder.planURL),
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            plan = doc
        }
        invalidate()
    }

    private func invalidate() {
        marksCache = nil
        worldCache = nil
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

    /// A tap on the mini plan: a corner of the chosen room replaces the corner being picked; elsewhere selects that room.
    func tapPlan(_ p: PlanVec) {
        if let c = Corners.nearest(to: p, in: room, maxDistance: 0.6) {
            if cornerIdx.count <= picking { cornerIdx.append(c) } else { cornerIdx[picking] = c }
            if cornerIdx.count >= 2, cornerIdx[0] == cornerIdx[1] { cornerIdx.remove(at: 1) }
            picking = min(picking + 1, max(1, cornerIdx.count - 1))
            return
        }
        if let r = Corners.room(at: p, polygons: rooms), r != roomIndex { chooseRoom(r) }
    }

    private func planRoomName(_ i: Int) -> String? {
        let list = plan["rooms"] as? [[String: Any]] ?? []
        return list.indices.contains(i) ? list[i]["name"] as? String : nil
    }

    // MARK: Visit

    /// Starts (or continues) the visit and writes plan.json. Returns false on failure.
    func beginVisit() -> Bool {
        let r = Revisit.startVisitIfNeeded(plan: plan, now: Date(), timeZone: .current)
        plan = r.plan
        visit = r.visit
        let visits = (plan["markup"] as? [String: Any])?["visits"] as? [[String: Any]] ?? []
        visitNumber = visits.firstIndex { ($0["id"] as? String) == r.visit }.map { $0 + 1 } ?? 1
        hud.tool = CaptureTool.rail(returnVisit: isReturnVisit, scopeOnSite: isScopeOnSite).first ?? .reading
        if purpose == .scope { hud.context = .scope }
        if r.started { return savePlan() }
        return true
    }

    /// True from the second visit on (re-measuring makes sense).
    var isLaterVisit: Bool {
        let visits = ((plan["markup"] as? [String: Any])?["visits"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return (visits.firstIndex(of: visit) ?? 0) > 0
    }

    // MARK: AR session lifecycle (called by the controller)

    func arStarted() {
        if start == .corners { startCorners(); return }
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
            fitMessage = "Lined up with the saved scan"
            fitAcceptable = true
            showCheck()
        }
    }

    private func relocaliseTimedOut() {
        guard phase == .relocalizing else { return }
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
        invalidate()
        if cornerIdx.count > 2 { cornerIdx = Array(cornerIdx.prefix(2)) }
        controller?.clearOutline()
        phase = .corner(0)
    }

    /// "Set A/B/C": the reticle's raycast hit is that corner.
    func setCorner() {
        guard case .corner(let i) = phase else { return }
        guard tracking.isNormal else { fitMessage = "Wait a moment — finding the room"; return }
        guard let hit = lastSample?.hit else { fitMessage = "Aim at the corner where the walls meet the floor"; return }
        if hits.count > i { hits = Array(hits.prefix(i)) }
        hits.append(hit)
        fitMessage = nil
        DS.Haptic.save()
        if hits.count < max(2, cornerPoints.count) { phase = .corner(hits.count); return }
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
            fitMessage = p == .tooClose ? "Those corners are too close — pick corners further apart" : "The corners don't match — try again"
            fitAcceptable = false
            phase = .corner(hits.count - 1)
        case .success(let f):
            alignment = f.transform
            floorY = Alignment.floorHeight(hits) ?? f.floorY
            if f.ok {
                fitAcceptable = true
                fitMessage = String(format: "Lined up within %.0f cm", max(f.maxResidual, abs(f.distanceError)) * 100)
            } else {
                fitAcceptable = false
                fitMessage = String(format: "A to B is %.2f m here, %.2f m on the plan",
                                    simd_distance(PlanVec(hits[0].x, hits[0].z), PlanVec(hits[1].x, hits[1].z)),
                                    simd_distance(plans[0], plans[1]))
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
        invalidate()
        if let a = alignment { controller?.showOutline(walls: walls, alignment: a, floorY: floorY) }
    }

    func looksRight() {
        guard alignment != nil else { return }
        controller?.clearOutline()
        phase = .measuring
        refreshMarkers()
        logEvent(["type": "alignment", "auto": autoAligned, "angle": alignment?.angle ?? 0,
                  "offset": [alignment?.offset.x ?? 0, alignment?.offset.y ?? 0], "floorY": floorY])
    }

    func realign() {
        controller?.clearOutline()
        startCorners()
    }

    // MARK: Markers and aiming

    func refreshMarkers() {
        markers = Revisit.markers(plan: plan, visit: visit)
        scopeItems = ScopeList.items(plan: plan, names: EditorNamesStore.load(folder))
        if let id = aimedScope?.id { aimedScope = scopeItems.first { $0.id == id } }
        invalidate()
    }

    var progress: (done: Int, total: Int) { Revisit.progress(markers) }

    /// ~10 times a second with the camera pose (this session's world space).
    func aim(camera: WorldVec, forward: WorldVec) {
        guard phase == .measuring, let a = alignment else {
            if target != nil { target = nil }
            hint = nil
            return
        }
        let tool = hud.tool
        if tool == .done || purpose == .scope {
            let cands: [Revisit.Candidate]
            if purpose == .scope {
                cands = scopeItems.map { it in
                    Revisit.Candidate(id: it.id, kind: it.kind.rawValue,
                                      world: Revisit.world(it.pos, height: it.kind == .floor ? 0.02 : it.height, alignment: a, floorY: floorY),
                                      radius: it.kind == .equipment ? 0.4 : (it.kind == .wall ? 0.6 : 0.8))
                }
            } else {
                cands = markers.filter { $0.kind == "equipment" || ($0.kind == "removal" && !$0.done) }.map {
                    Revisit.Candidate(id: $0.id, kind: $0.kind, world: Revisit.world($0.pos, height: $0.height, alignment: a, floorY: floorY), radius: 0.4)
                }
            }
            let t = Revisit.target(cands, origin: camera, direction: forward)
            if t?.id != target?.id { target = t; if t != nil { DS.Haptic.lock() } }
            aimedScope = purpose == .scope ? t.flatMap { c in scopeItems.first { $0.id == c.id } } : nil
            hint = nil
            return
        }
        guard tool == .remeasure else { if target != nil { target = nil }; hint = nil; return }
        let candidates = markers.filter { $0.kind == "reading" }.map {
            Revisit.Candidate(id: $0.id, kind: $0.kind, world: Revisit.world($0.pos, height: $0.height, alignment: a, floorY: floorY), radius: 0.15)
        }
        let t = Revisit.target(candidates, origin: camera, direction: forward)
        if t?.id != target?.id { target = t; if t != nil { DS.Haptic.lock() } }
        // Hint towards the nearest point not yet re-measured.
        let open = markers.filter { $0.kind == "reading" && !$0.measured }
        let near = open.map { m -> (Revisit.Marker, WorldVec, Double) in
            let w = Revisit.world(m.pos, height: m.height, alignment: a, floorY: floorY)
            return (m, w, simd_distance(w, camera))
        }.min { $0.2 < $1.2 }
        if let near {
            let deg = Revisit.turnHint(camera: camera, forward: forward, target: near.1)
            let tag = "R" + (near.0.label.components(separatedBy: " ").first ?? "")
            hint = abs(deg) < 25 ? "\(tag) is ahead" : (deg > 0 ? "Turn right for \(tag)" : "Turn left for \(tag)")
        } else {
            hint = markers.contains { $0.kind == "reading" } ? "Every point re-measured" : nil
        }
    }

    private func marker(_ id: String?) -> Revisit.Marker? { id.flatMap { i in markers.first { $0.id == i } } }

    private func tag(_ m: Revisit.Marker) -> String {
        if m.kind == "reading" { return "R" + (m.label.components(separatedBy: " ").first ?? "").replacingOccurrences(of: "R", with: "") }
        return m.label
    }

    // MARK: CaptureEngine - what the screen says

    var roomName: String {
        guard let a = alignment, let cam = lastSample?.camera else { return "" }
        return FloorArea.room(containing: a.point(cam), rooms: rooms).flatMap(planRoomName) ?? ""
    }

    var phaseText: String {
        switch phase {
        case .intro, .relocalizing, .corner, .check: return "Lining up"
        case .measuring:
            if purpose == .scope {
                let p = ScopeList.progress(scopeItems)
                return "Scope · \(p.done) of \(p.total) done"
            }
            let p = progress
            return isLaterVisit ? CaptureCopy.visit(visitNumber, done: p.done, total: p.total) : "Visit \(visitNumber)"
        }
    }

    var coaching: String? {
        if !tracking.isNormal && phase != .intro { return tracking.message }
        switch phase {
        case .relocalizing: return "Move the phone slowly round the room"
        case .corner(let i): return fitMessage ?? "Aim at corner \(cornerNames[min(i, 2)]) — where two walls meet the floor"
        case .check: return fitMessage
        case .measuring: return hud.tool == .remeasure ? hint : nil
        case .intro: return nil
        }
    }

    var quietActions: [QuietAction] { [] }
    var showsTools: Bool { phase == .measuring }
    var busyText: String? { nil }
    var isReturnVisit: Bool { purpose == .markup && isLaterVisit }
    var isScopeOnSite: Bool { purpose == .scope }

    var recordingSince: Date? {
        let r = VoiceRecorder.shared
        return r.isRecording && r.isRecordingJob(folder) ? r.startedAt : nil
    }

    func perform(quiet id: String) { if id == "realign" { realign() } }

    var onClose: (() -> Void)?
    func requestClose() { onClose?() }

    func toggleRecording() {
        let r = VoiceRecorder.shared
        if r.isRecording { r.stop(); hud.showToast("Voice note saved") }
        else {
            Task {
                if await r.start(folder: folder) { hud.showToast("Recording") }
                else if let p = r.problem { alert = p; r.problem = nil }
            }
        }
    }

    func renameRoom(_ name: String) {}

    var zoomState: ZoomState {
        guard UltraWideCamera.exists else { return .unavailable }
        return phase == .measuring ? .available : .blocked("0.5× once lined up")
    }

    func beginHandoff() -> CaptureShot? {
        guard zoomState == .available, let s = controller?.shot(photo: false) else { return nil }
        controller?.pauseForHandoff()
        return s
    }

    func endHandoff() { controller?.resumeAfterHandoff() }

    func jobPhotos() -> [JobPhoto] {
        let readings = (plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]] ?? []
        let folder = self.folder
        let photos = readings.filter { ($0["kind"] as? String) == "photo" }
        return photos.compactMap { r -> JobPhoto? in
            guard let id = r["id"] as? String else { return nil }
            let url = r["photo"] as? String
            let n = PlanDocument.number(r["n"]).map { Int($0) } ?? 0
            var place = Revisit.point(r["pos"]).flatMap { FloorArea.room(containing: $0, rooms: rooms) }.flatMap(planRoomName) ?? ""
            if let h = PlanDocument.number(r["height"]) { place += (place.isEmpty ? "" : " · ") + "wall \(String(format: "%.1f", h)) m up" }
            return JobPhoto(id: id, title: "Photo \(n)", place: place, caption: (r["note"] as? String) ?? "", load: {
                if let img = UIImage(contentsOfFile: folder.photosDir.appendingPathComponent("\(id)-full.jpg").path) { return img }
                guard let u = url, let comma = u.firstIndex(of: ","), let d = Data(base64Encoded: String(u[u.index(after: comma)...])) else { return nil }
                return UIImage(data: d)
            })
        }.reversed()
    }

    func replacePhoto(id: String, photo: Task<CapturedPhoto?, Never>) async -> Bool {
        guard let p = await photo.value, let preview = p.preview else { return false }
        _ = PhotoFiles.write(p, id: id, folder: folder)
        guard let d = MarkupEdit.update(plan, id: id, set: ["photo": "data:image/jpeg;base64," + preview.base64EncodedString()]) else { return false }
        plan = d
        guard savePlan() else { return false }
        logEvent(["type": "retake", "id": id])
        refreshMarkers()
        return true
    }
    func trayCancelled() { remeasureFor = nil }

    // MARK: CaptureEngine - the world

    var world: CaptureWorld {
        if let w = worldCache { return w }
        guard let a = alignment else { return CaptureWorld(floorY: nil) }
        let ws = walls.map { w -> WorldWall in
            let p = a.world(w.a, y: 0), q = a.world(w.b, y: 0)
            return WorldWall(id: w.id, a: PlanVec(p.x, p.z), b: PlanVec(q.x, q.z), height: w.height)
        }
        let rs = rooms.enumerated().map { i, poly in
            WorldRoom(name: planRoomName(i) ?? "Room \(i + 1)", polygon: poly.map { let w = a.world($0, y: 0); return PlanVec(w.x, w.z) })
        }
        let w = CaptureWorld(floorY: floorY, walls: ws, rooms: rs)
        worldCache = w
        return w
    }

    func aimSample() -> AimSample? {
        lastSample = controller?.aimSample()
        return lastSample
    }

    func projector(viewport: CGSize) -> Projector? { controller?.projector(viewport: viewport) }

    func overlayMarks() -> [OverlayMark] {
        guard phase == .measuring, let a = alignment else { return [] }
        if let m = marksCache { return m }
        var m = purpose == .scope
            ? OverlayBuild.marks(scope: scopeItems, walls: walls, alignment: a, floorY: floorY)
            : OverlayBuild.marks(markers, walls: walls, alignment: a, floorY: floorY, removalTags: ScopeList.refs(plan: plan))
        if !isLaterVisit { for i in m.indices { m[i].faded = false } }
        marksCache = m
        return m.map { mk in
            var x = mk
            x.selected = x.id == target?.id
            return x
        }
    }

    func shot(photo: Bool) -> CaptureShot? {
        guard phase == .measuring, tracking.isNormal else { return nil }
        return controller?.shot(photo: photo)
    }

    // MARK: CaptureEngine - saving

    func save(_ d: CaptureDraft) async -> Result<SavedCapture, PlainWords.Problem> {
        guard let a = alignment, phase == .measuring else { return .failure(PlainWords.problem("not aligned")) }
        switch d {
        case .reading(let s, let value, let material, let reference):
            if let rid = remeasureFor { return await saveRemeasure(rid, shot: s, value: value) }
            var pb = Self.pb(s, kind: "reading", material: material)
            pb.value = value
            pb.reference = reference
            return await add(pb, shot: s, alignment: a, kind: "reading",
                             title: { [weak self] in "R\(self?.lastNumber("reading") ?? 0) · \(CaptureCopy.number(value))%" },
                             detail: CaptureCopy.materialName(material))
        case .photo(let s, let caption):
            let pb = Self.pb(s, kind: "photo", material: "wall", note: caption)
            return await add(pb, shot: s, alignment: a, kind: "photo", title: { [weak self] in "P\(self?.lastNumber("photo") ?? 0)" }, detail: caption)
        case .source(let s, let cause, let note):
            let label = note.trimmingCharacters(in: .whitespaces).isEmpty ? cause : "\(cause) — \(note)"
            let pb = Self.pb(s, kind: "source", material: "wall", note: label)
            return await add(pb, shot: s, alignment: a, kind: "source", title: { "Source" }, detail: cause)
        case .equipment(let s, let type, let asset):
            let pb = Self.pb(s, kind: "equipment", material: type, note: asset)
            let r = await add(pb, shot: s, alignment: a, kind: "equipment", title: { CaptureCopy.equipmentName(type) }, detail: roomName)
            if case .success(var saved) = r, type == "airMover" { saved.airflowFor = pb.id; return .success(saved) }
            return r
        case .mark(let m):
            return await saveMark(m, alignment: a)
        }
    }

    private func saveMark(_ m: MarkDraft, alignment a: PlanTransform) async -> Result<SavedCapture, PlainWords.Problem> {
        guard let first = m.shots.first else { return .failure(PlainWords.problem("")) }
        let measure = m.meaning.isArea ? m.area.map(CaptureCopy.area) : m.length.map(CaptureCopy.length)
        let title = [m.meaning.tag, measure].compactMap { $0 }.joined(separator: " · ")
        var items: [PBReading] = []
        switch m.meaning {
        case .moistureLine:
            items = m.shots.enumerated().map { i, s in
                var shot = s
                if i > 0 { shot.id = CaptureIDs.new("rv-") }
                return Self.pb(shot, kind: "boundary", material: "wall")
            }
        case .wetFloor:
            var pb = Self.pb(first, kind: "affected", material: "floor", note: "Wet area")
            pb.corners = m.shots.map(Self.pose)
            items = [pb]
        case .liftFlooring:
            var pb = Self.pb(first, kind: "removal", material: "flooring")
            pb.corners = m.wholeRoom ? [] : m.shots.map(Self.pose)
            pb.wholeRoom = m.wholeRoom
            pb.floorType = m.floorType
            pb.underlay = m.underlay
            pb.heightMm = 0
            items = [pb]
        case .skirting, .wallLining, .cabinetry:
            var pb = Self.pb(first, kind: "removal", material: m.meaning.removalItem ?? "other")
            if let e = m.shots.last, m.shots.count >= 2 { pb.end = Self.pose(e) }
            pb.heightMm = Double(m.heightMm)
            items = [pb]
        }
        let photo = await Self.dataURL(first.photo)
        if let p = await first.photo?.value { _ = PhotoFiles.write(p, id: first.id, folder: folder) }
        if items.indices.contains(0) { items[0].photo = photo }
        var doc = plan
        var problem: PlainWords.Problem?
        for pb in items {
            switch Revisit.itemJSON(for: pb, plan: doc, alignment: a, floorY: floorY, visit: visit) {
            case .failure(let e): problem = PlainWords.problem(e.message)
            case .success(var item):
                if pb.kind == "removal" && hud.context == .scope { item["status"] = "proposed" }
                doc = Revisit.addItem(plan: doc, item: item)
            }
            if problem != nil { break }
        }
        let ids = items.map(\.id)
        if let problem {
            // Never dropped: kept in the visit log and shown in review to fix.
            logEvent(["type": "unplaced", "ids": ids, "kind": m.meaning.rawValue, "visit": visit, "reason": problem.sentence,
                      "points": m.shots.compactMap { $0.hit.map { [$0.x, $0.y, $0.z] } }])
            var e = CaptureStack.Entry(id: ids.first ?? CaptureIDs.new("fix-"), ids: [], kind: "mark", title: title, detail: roomName, hasPhoto: photo != nil)
            e.needsFix = problem.sentence
            return .success(SavedCapture(entry: e))
        }
        plan = doc
        guard savePlan() else { return .failure(PlainWords.Problem(sentence: "Couldn't save to the plan", fix: "Try again")) }
        logEvent(["type": "logged", "ids": ids, "kind": items.first?.kind ?? "", "visit": visit,
                  "camera": [first.camera.x, first.camera.y, first.camera.z]])
        refreshMarkers()
        return .success(SavedCapture(entry: CaptureStack.Entry(id: ids[0], ids: ids, kind: "mark", title: title, detail: roomName, hasPhoto: photo != nil)))
    }

    /// One item: resolve against the saved plan through the alignment, embed the photo, add to plan.json, log it.
    private func add(_ r: PBReading, shot: CaptureShot, alignment a: PlanTransform, kind: String,
                     title: @escaping () -> String, detail: String) async -> Result<SavedCapture, PlainWords.Problem> {
        var pb = r
        pb.photo = await Self.dataURL(shot.photo)
        if let p = await shot.photo?.value { _ = PhotoFiles.write(p, id: pb.id, folder: folder) }
        switch Revisit.itemJSON(for: pb, plan: plan, alignment: a, floorY: floorY, visit: visit) {
        case .failure(let e):
            let p = PlainWords.problem(e.message)
            logEvent(["type": "unplaced", "ids": [pb.id], "kind": pb.kind, "visit": visit, "reason": p.sentence])
            var en = CaptureStack.Entry(id: pb.id, ids: [], kind: kind, title: title(), detail: detail, hasPhoto: pb.photo != nil)
            en.needsFix = p.sentence
            return .success(SavedCapture(entry: en))
        case .success(var item):
            if pb.kind == "equipment" && hud.context == .scope && purpose == .markup && !isLaterVisit { item["status"] = "planned" }
            plan = Revisit.addItem(plan: plan, item: item)
            guard savePlan() else { return .failure(PlainWords.Problem(sentence: "Couldn't save to the plan", fix: "Try again")) }
            var ev: [String: Any] = ["type": "logged", "id": pb.id, "kind": pb.kind, "visit": visit, "takenAt": pb.takenAt,
                                     "camera": [pb.cameraPosition.x, pb.cameraPosition.y, pb.cameraPosition.z],
                                     "forward": [pb.cameraForward.x, pb.cameraForward.y, pb.cameraForward.z]]
            if let h = pb.hit { ev["hit"] = [h.x, h.y, h.z] }
            logEvent(ev)
            refreshMarkers()
            return .success(SavedCapture(entry: CaptureStack.Entry(id: pb.id, ids: [pb.id], kind: kind, title: title(), detail: detail,
                                                                   hasPhoto: pb.photo != nil)))
        }
    }

    private func lastNumber(_ kind: String) -> Int {
        let readings = (plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]] ?? []
        return Int(readings.filter { (($0["kind"] as? String) ?? "reading") == kind }.compactMap { PlanDocument.number($0["n"]) }.max() ?? 0)
    }

    func remove(ids: [String]) {
        var doc = plan
        for id in ids {
            if id.hasPrefix("status:") {
                let parts = id.split(separator: ":").map(String.init)
                guard parts.count == 3 else { continue }
                doc = revertStatus(doc, kind: parts[1], id: parts[2])
            } else if id.hasPrefix("remeasure:") {
                let rid = String(id.dropFirst("remeasure:".count))
                if let d = Revisit.undoMeasurement(plan: doc, readingId: rid, visit: visit) { doc = d }
            } else if let d = MarkupEdit.delete(doc, id: id) {
                doc = d
                PhotoFiles.remove(id: id, folder: folder)
            }
        }
        plan = doc
        savePlan()
        logEvent(["type": "deleted", "ids": ids])
        refreshMarkers()
    }

    private func revertStatus(_ doc: [String: Any], kind: String, id: String) -> [String: Any] {
        switch kind {
        case "done": return MarkupEdit.update(doc, id: id, set: ["status": "proposed", "doneVisit": NSNull()]) ?? doc
        case "removed": return MarkupEdit.update(doc, id: id, set: ["removed": NSNull(), "removedAt": NSNull()]) ?? doc
        case "placed": return MarkupEdit.update(doc, id: id, set: ["status": "planned"]) ?? doc
        default: return doc
        }
    }

    func edit(id: String, _ e: ItemEdit) {
        let set: [String: Any]
        switch e {
        case .reading(let v, let m): set = ["value": v, "material": m]
        case .caption(let t): set = ["note": t]
        }
        guard let d = MarkupEdit.update(plan, id: id, set: set) else { return }
        plan = d
        if savePlan() { logEvent(["type": "edited", "id": id]); refreshMarkers() }
    }

    func equipmentUnits() -> [EquipmentGuard.Unit] {
        guard let a = alignment else { return [] }
        var counts: [String: Int] = [:]
        return markers.filter { $0.kind == "equipment" }.map { m in
            let type = m.type ?? "other"
            counts[type, default: 0] += 1
            let w = a.world(m.pos, y: floorY)
            return EquipmentGuard.Unit(id: m.id, type: type, pos: PlanVec(w.x, w.z), hasAirflow: m.dir != nil,
                                       tag: m.label.contains("·") ? m.label : "\(CaptureCopy.equipmentShort[type] ?? "EQ") \(counts[type] ?? 1)")
        }
    }

    func setAirflow(id: String, direction: WorldVec) -> Bool {
        guard let a = alignment, let angle = Airflow.planAngle(forward: direction, transform: a),
              let d = MarkupEdit.update(plan, id: id, set: ["dir": PlanDocument.r4(angle)]) else { return false }
        plan = d
        guard savePlan() else { return false }
        logEvent(["type": "airflow", "id": id, "dir": angle])
        refreshMarkers()
        return true
    }

    // MARK: Re-measure, done / removed / placed

    private var remeasureFor: String?

    func primaryOverride(tool: CaptureTool, aim: Aim) -> EnginePrimary? {
        switch phase {
        case .intro: return EnginePrimary(title: "Starting the camera…", enabled: false, action: {})
        case .relocalizing: return EnginePrimary(title: "Finding the saved room…", enabled: false, action: {})
        case .corner(let i):
            let name = cornerNames[min(i, 2)]
            return EnginePrimary(title: tracking.isNormal ? "Set corner \(name)" : "Move slowly…", enabled: tracking.isNormal && aim.hit != nil) { [weak self] in self?.setCorner() }
        case .check:
            return EnginePrimary(title: "Looks right", enabled: fitAcceptable) { [weak self] in self?.looksRight() }
        case .measuring:
            break
        }
        switch tool {
        case .remeasure:
            guard let m = marker(target?.id) else {
                return EnginePrimary(title: "Aim at a reading", enabled: false, action: {})
            }
            return EnginePrimary(title: CaptureCopy.remeasure(tag(m))) { [weak self] in self?.beginRemeasure(m) }
        case .done:
            if purpose == .scope {
                guard let it = aimedScope else { return EnginePrimary(title: "Aim at a scoped item", enabled: false, action: {}) }
                if it.done { return EnginePrimary(title: "\(it.tag) is \(it.kind == .equipment ? "placed" : "done")", enabled: false, action: {}) }
                return EnginePrimary(title: it.kind == .equipment ? "Mark placed · \(it.tag)" : "\(CaptureCopy.markDone) · \(it.tag)",
                                     tint: DS.Color.dry) { [weak self] in self?.markScope(it) }
            }
            guard let m = marker(target?.id) else { return EnginePrimary(title: "Aim at a removal or equipment", enabled: false, action: {}) }
            if m.kind == "equipment" {
                return EnginePrimary(title: "Mark removed · \(m.label)") { [weak self] in self?.markRemoved(m) }
            }
            return EnginePrimary(title: "\(CaptureCopy.markDone) · \(m.label.replacingOccurrences(of: "Remove ", with: ""))") { [weak self] in
                self?.markDone(m.id, title: m.label)
            }
        default:
            return nil
        }
    }

    func customTray() -> AnyView? {
        switch phase {
        case .relocalizing, .corner, .check: return AnyView(AlignmentTray(model: self))
        default: return nil
        }
    }

    private func beginRemeasure(_ m: Revisit.Marker) {
        remeasureFor = m.id
        let readings = (plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]] ?? []
        let r = readings.first { ($0["id"] as? String) == m.id } ?? [:]
        let last = Revisit.history(r).last.flatMap { PlanDocument.number($0["value"]) }
        hud.beginRemeasure(tag: tag(m), previous: last.map { "was \(CaptureCopy.number($0))%" })
    }

    private func saveRemeasure(_ id: String, shot: CaptureShot, value: Double) async -> Result<SavedCapture, PlainWords.Problem> {
        remeasureFor = nil
        let photo = await Self.dataURL(shot.photo)
        guard let out = Revisit.recordMeasurement(plan: plan, readingId: id, visit: visit, value: value,
                                                  takenAt: shot.takenAt, photo: photo, note: nil) else {
            return .failure(PlainWords.Problem(sentence: "That point is no longer on the plan", fix: "Add a new reading"))
        }
        let before = marker(id)
        plan = out
        guard savePlan() else { return .failure(PlainWords.Problem(sentence: "Couldn't save to the plan", fix: "Try again")) }
        logEvent(["type": "remeasure", "id": id, "visit": visit, "value": value, "takenAt": shot.takenAt,
                  "camera": [shot.camera.x, shot.camera.y, shot.camera.z]])
        refreshMarkers()
        let t = before.map(tag) ?? "R"
        let was = before?.value.map { "was \(CaptureCopy.number($0))%" } ?? ""
        return .success(SavedCapture(entry: CaptureStack.Entry(id: "remeasure:\(id)", ids: ["remeasure:\(id)"], kind: "remeasure",
                                                               title: "\(t) · \(CaptureCopy.number(value))%", detail: was, hasPhoto: photo != nil)))
    }

    private func markDone(_ id: String, title: String) {
        guard let s = controller?.shot(photo: true), let a = alignment else { return }
        let cam = a.point(s.camera)
        let visit = self.visit
        Task {
            let photo = await Self.dataURL(s.photo)
            guard let out = Revisit.markRemovalDone(plan: plan, id: id, visit: visit, photo: photo, takenAt: s.takenAt, cam: cam) else { return }
            plan = out
            if savePlan() {
                logEvent(["type": "removalDone", "id": id, "visit": visit, "at": s.takenAt])
                refreshMarkers()
                hud.statusSaved(CaptureStack.Entry(id: "status:done:\(id)", ids: ["status:done:\(id)"], kind: "done",
                                                   title: "\(title.replacingOccurrences(of: "Remove ", with: "").capitalized) done", detail: "After photo kept", hasPhoto: photo != nil),
                                thumb: await s.photo?.value?.thumb)
            }
        }
    }

    private func markRemoved(_ m: Revisit.Marker) {
        let now = PlanDocument.iso(Date())
        guard let out = Revisit.markEquipmentRemoved(plan: plan, id: m.id, visit: visit, at: now) else { return }
        plan = out
        if savePlan() {
            logEvent(["type": "equipmentRemoved", "id": m.id, "visit": visit, "at": now])
            refreshMarkers()
            hud.statusSaved(CaptureStack.Entry(id: "status:removed:\(m.id)", ids: ["status:removed:\(m.id)"], kind: "done",
                                               title: "\(m.label) removed", detail: roomName, hasPhoto: false), thumb: nil)
        }
    }

    private func markScope(_ it: ScopeItem) {
        if it.kind == .equipment {
            let now = PlanDocument.iso(Date())
            guard let out = ScopeList.markPlaced(plan: plan, id: it.id, visit: visit, at: now) else { return }
            plan = out
            if savePlan() {
                logEvent(["type": "equipmentPlaced", "id": it.id, "visit": visit, "at": now])
                refreshMarkers()
                hud.statusSaved(CaptureStack.Entry(id: "status:placed:\(it.id)", ids: ["status:placed:\(it.id)"], kind: "done",
                                                   title: "\(it.tag) placed", detail: "", hasPhoto: false), thumb: nil)
            }
        } else {
            markDone(it.id, title: it.tag)
        }
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

    // MARK: Helpers

    static func pb(_ s: CaptureShot, kind: String, material: String, note: String = "") -> PBReading {
        PBReading(id: s.id, seq: 0, kind: kind, value: nil, material: material, note: note, takenAt: s.takenAt,
                  cameraPosition: s.camera, cameraForward: s.forward, hit: s.hit)
    }

    static func pose(_ s: CaptureShot) -> PBPose { PBPose(cameraPosition: s.camera, cameraForward: s.forward, hit: s.hit) }

    static func dataURL(_ task: Task<CapturedPhoto?, Never>?) async -> String? {
        guard let task, let d = await task.value?.preview else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    @discardableResult
    private func savePlan() -> Bool {
        invalidate()
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

    nonisolated static func fmtValue(_ v: Double) -> String { Revisit.fmt(v) }
}

/// The alignment card (relocalising, corners, check): one line, the mini plan, quiet buttons.
struct AlignmentTray: View {
    @ObservedObject var model: RevisitModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.gap) {
            switch model.phase {
            case .relocalizing:
                HStack(spacing: DS.Space.gap) {
                    ProgressView().tint(.white)
                    Text("Recognising the room").font(DS.Font.bodyBold).foregroundStyle(.white)
                    Spacer()
                    SecondaryButton("Use corners") { model.useCornersInstead() }
                }
            case .corner(let i):
                HStack(alignment: .center, spacing: DS.Space.gap) {
                    MiniPlanView(model: model, interactive: false, focus: i)
                        .frame(width: 120, height: 96)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Corner \(model.cornerNames[min(i, 2)])").font(DS.Font.headline).foregroundStyle(.white)
                        Text("Where two walls meet the floor").font(DS.Font.callout).foregroundStyle(DS.Color.onCameraSecondary)
                        if i > 0 { SecondaryButton("Back", icon: "arrow.uturn.backward") { model.undoCorner() } }
                    }
                    Spacer(minLength: 0)
                }
            case .check:
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Text("Do the lines sit on the walls?").font(DS.Font.bodyBold).foregroundStyle(.white)
                    HStack(spacing: DS.Space.tight) {
                        SecondaryButton("Redo corners") { model.realign() }
                        if !model.fitAcceptable {
                            SecondaryButton("Add corner C") { model.addThirdCorner() }
                            SecondaryButton("Use anyway") { model.acceptAnyway() }
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(.top, 4)
    }
}
