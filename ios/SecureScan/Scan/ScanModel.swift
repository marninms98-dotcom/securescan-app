//
//  ScanModel.swift
//  SecureScan
//
//  The first visit: rooms captured so far, everything marked, the Room done /
//  Next room / Finish flow, and saving to the job folder as it happens
//  (rooms/<n>.json and readings-raw.json) so a failed merge or a crash never
//  loses what was captured. It is the CaptureEngine behind the one capture
//  screen for both scan cameras (classic RoomCaptureView, live ARSCNView):
//  marking during the scan and after a room is the same screen.
//

import Foundation
import CoreImage
import RoomPlan
import ARKit
import SwiftUI
import simd

/// Hands a CIImage to a background encoder (CIImage is immutable).
final class ImageBox: @unchecked Sendable {
    let image: CIImage?
    init(_ image: CIImage?) { self.image = image }
}

@MainActor
final class ScanModel: ObservableObject, CaptureEngine {

    enum Phase: Equatable {
        case scanning                // a room is being scanned
        case processingRoom          // waiting for RoomPlan to finish a room
        case roomFailed(String)      // last room failed; rooms before it are kept
        case roomDone                // a room is saved: mark it, next room, or finish
        case finishing(String)       // merging / exporting / building the plan
    }

    @Published var phase: Phase = .scanning
    /// The first room's scan waits for "Start" (the camera already runs, so the user can frame
    /// the room first). Later rooms start with "Next room".
    @Published private(set) var started = false
    @Published private(set) var roomsDone = 0
    @Published private(set) var totalCount = 0
    @Published var alert: String?
    @Published var confirmClose = false

    let job: JobMeta
    let folder: JobFolder
    weak var controller: (any ScanCaptureControlling)?
    /// Simulator screenshots only: no camera, nothing is deleted.
    let preview: Bool
    private(set) lazy var hud = CaptureHUDModel(engine: self)

    private var rooms: [CapturedRoom] = []
    private(set) var raw: [RawReading] = []
    private var extras: ScanExtras
    private var nextSeq = 1
    private var finishRequested = false
    private var finishNow = false
    private var discarded = false
    private var finalized = false
    private var photoWrites: [Task<Void, Never>] = []
    private let onFinished: (UUID) -> Void
    private let onDiscarded: () -> Void
    private var marksCache: (key: String, marks: [OverlayMark])?

    init(job: JobMeta, preview: Bool = false, onFinished: @escaping (UUID) -> Void, onDiscarded: @escaping () -> Void) {
        self.job = job
        self.preview = preview
        self.folder = JobFiles.folder(for: job.id)
        self.onFinished = onFinished
        self.onDiscarded = onDiscarded
        self.raw = JobFiles.loadRawReadings(folder)
        self.extras = ScanExtras.load(folder)
        self.nextSeq = (raw.map(\.seq).max() ?? 0) + 1
        recount()
        if !preview { ScanOpenMarker.mark(folder) }
        started = preview
    }

    /// "Start": RoomPlan begins the first room.
    func startScan() {
        guard !started else { return }
        started = true
        DS.Haptic.save()
        controller?.startRoom()
    }

    var currentRoomNumber: Int { roomsDone + 1 }
    var hasAnything: Bool { roomsDone > 0 || !raw.isEmpty || JobFiles.hasAudio(folder) }
    var hasAudio: Bool { JobFiles.hasAudio(folder) }
    var loggedItems: [RawReading] { raw.sorted { $0.seq > $1.seq } }

    /// The room being scanned (or, after Room done, the one just saved): 1-based.
    private var activeRoom: Int { phase == .roomDone ? max(roomsDone, 1) : roomsDone + 1 }

    // MARK: CaptureEngine - what the screen says

    var roomName: String { extras.roomNames["\(activeRoom)"] ?? "Room \(activeRoom)" }

    var phaseText: String {
        switch phase {
        case .scanning: return started ? "Scanning" : "Ready to scan"
        case .processingRoom: return "Saving room"
        case .roomFailed: return "Room didn't save"
        case .roomDone: return "Marking"
        case .finishing: return "Finishing"
        }
    }

    var coaching: String? {
        switch phase {
        case .scanning: return started ? controller?.coaching : "Tap Start to begin scanning the room"
        case .roomFailed(let m): return m
        case .processingRoom: return "Hold still a moment"
        default: return nil
        }
    }

    var quietActions: [QuietAction] {
        let finish = QuietAction(id: "finish", title: "Finish", prominent: roomsDone > 0)
        switch phase {
        case .scanning:
            if !started { return roomsDone > 0 || !raw.isEmpty ? [finish] : [] }
            return [QuietAction(id: "roomDone", title: "Room done"), finish]
        case .roomDone: return [QuietAction(id: "next", title: "Next room"), finish]
        case .roomFailed: return [QuietAction(id: "retry", title: "Scan again"), finish]
        case .processingRoom: return [QuietAction(id: "roomDone", title: "Room done", enabled: false), finish]
        case .finishing: return []
        }
    }

    var showsTools: Bool {
        if case .finishing = phase { return false }
        return true
    }

    var busyText: String? {
        if case .finishing(let t) = phase { return t }
        return nil
    }

    var isReturnVisit: Bool { false }
    var isScopeOnSite: Bool { false }
    var canRenameRoom: Bool { true }

    var recordingSince: Date? {
        let r = VoiceRecorder.shared
        return r.isRecording ? r.startedAt : nil
    }

    func perform(quiet id: String) {
        switch id {
        case "roomDone": nextRoom()
        case "next": scanNextRoom()
        case "retry": retryRoom()
        case "finish": finish()
        default: break
        }
    }

    /// Confirm only when something would be lost.
    func requestClose() {
        if hasAnything || phase == .scanning && roomsDone == 0 && preview == false && controller?.liveWorld.walls.isEmpty == false {
            confirmClose = true
        } else {
            discard()
        }
    }

    func toggleRecording() {
        let recorder = VoiceRecorder.shared
        if recorder.isRecording {
            recorder.stop()
            hud.showToast("Voice note saved")
        } else {
            Task {
                if await recorder.start(folder: folder) { hud.showToast("Recording") }
                else if let p = recorder.problem { alert = p; recorder.problem = nil }
            }
        }
        objectWillChange.send()
    }

    func renameRoom(_ name: String) {
        extras.roomNames["\(activeRoom)"] = name
        if !preview { extras.save(folder) }
        objectWillChange.send()
        if finishRequested && phase == .roomDone { finalize() }
    }

    func roomSections() -> [String] {
        if phase == .roomDone, let r = rooms.last { return ScanWorld.sectionLabels(r) }
        return controller?.liveSections ?? []
    }

    // MARK: CaptureEngine - the world

    var world: CaptureWorld { controller?.liveWorld ?? .empty }

    func aimSample() -> AimSample? { ScanWorld.aimSample(controller?.arSession) }

    func projector(viewport: CGSize) -> Projector? { ScanWorld.projector(controller?.arSession, viewport: viewport) }
    func camera3D(viewport: CGSize) -> Camera3D? { ScanWorld.camera3D(controller?.arSession, viewport: viewport) }

    func overlayMarks() -> [OverlayMark] {
        let w = world
        let key = "\(raw.count)|\(raw.last?.id ?? "")|\(extras.airflow.count)|\(Int(((w.floorY ?? 0) * 50).rounded()))|\(w.walls.count)"
        if let c = marksCache, c.key == key { return c.marks }
        let m = ScanMarks.build(raw, world: w, extras: extras)
        marksCache = (key, m)
        return m
    }

    func shot(photo: Bool) -> CaptureShot? {
        guard canCapture else { return nil }
        return ScanWorld.shot(controller?.arSession, prefix: "ar-", photo: photo)
    }

    private var canCapture: Bool {
        switch phase {
        case .finishing: return false
        default: return !discarded
        }
    }

    // MARK: CaptureEngine - saving

    func save(_ d: CaptureDraft) async -> Result<SavedCapture, PlainWords.Problem> {
        let room = roomName
        let roomIndex = phase == .roomDone ? max(roomsDone - 1, 0) : roomsDone
        switch d {
        case .reading(let s, let value, let material, let reference):
            var r = record(s, kind: "reading", material: material, roomIndex: roomIndex)
            r.value = value
            r.reference = reference
            commit(r, photo: s.photo)
            let n = raw.filter { $0.kind == "reading" }.count
            return .success(SavedCapture(entry: entry(r, kind: "reading", title: "\(CaptureCopy.readingTag(n)) · \(CaptureCopy.number(value))%",
                                                      detail: "\(CaptureCopy.materialName(material)) · \(room)", photo: true)))
        case .photo(let s, let caption):
            let r = record(s, kind: "photo", material: "wall", note: caption, roomIndex: roomIndex)
            commit(r, photo: s.photo)
            let n = raw.filter { $0.kind == "photo" }.count
            return .success(SavedCapture(entry: entry(r, kind: "photo", title: CaptureCopy.photoTag(n), detail: caption.isEmpty ? room : caption, photo: true)))
        case .source(let s, let cause, let note):
            let label = note.trimmingCharacters(in: .whitespaces).isEmpty ? cause : "\(cause) — \(note)"
            let r = record(s, kind: "source", material: "wall", note: label, roomIndex: roomIndex)
            commit(r, photo: s.photo)
            return .success(SavedCapture(entry: entry(r, kind: "source", title: "Source", detail: cause, photo: true)))
        case .equipment(let s, let type, let asset):
            var r = record(s, kind: "equipment", material: type, note: asset, roomIndex: roomIndex)
            if let h = s.hit, let fy = world.floorY { r.hit = [h.x, fy, h.z] }
            commit(r, photo: s.photo)
            let n = raw.filter { $0.kind == "equipment" && $0.material == type }.count
            return .success(SavedCapture(entry: entry(r, kind: "equipment", title: "\(CaptureCopy.equipmentName(type)) \(n)", detail: room, photo: true),
                                         airflowFor: type == "airMover" ? r.id : nil))
        case .mark(let m):
            return .success(saveMark(m, roomIndex: roomIndex, room: room))
        }
    }

    private func saveMark(_ m: MarkDraft, roomIndex: Int, room: String) -> SavedCapture {
        guard let first = m.shots.first else { return SavedCapture(entry: CaptureStack.Entry(id: "", ids: [], kind: "mark", title: "", detail: "", hasPhoto: false)) }
        let measure = m.meaning.isArea ? m.area.map(CaptureCopy.area) : m.length.map(CaptureCopy.length)
        let title = [m.meaning.tag, measure].compactMap { $0 }.joined(separator: " · ")
        let problem = MarkCheck.problem(meaning: m.meaning, points: m.shots.compactMap(\.hit), world: world)
        switch m.meaning {
        case .moistureLine:
            var ids: [String] = []
            for (i, s) in m.shots.enumerated() {
                var shot = s
                if i > 0 { shot.id = CaptureIDs.new("ar-") }
                let r = record(shot, kind: "boundary", material: "wall", roomIndex: roomIndex)
                commit(r, photo: i == 0 ? s.photo : nil)
                ids.append(r.id)
            }
            var e = CaptureStack.Entry(id: ids[0], ids: ids, kind: "mark", title: title, detail: room, hasPhoto: first.photo != nil)
            e.needsFix = problem?.sentence
            return SavedCapture(entry: e)
        case .wetFloor:
            var r = record(first, kind: "affected", material: "floor", note: "Wet area", roomIndex: roomIndex)
            r.corners = m.shots.map(Self.pose9)
            commit(r, photo: first.photo)
            return SavedCapture(entry: entry(r, kind: "mark", title: title, detail: room, photo: first.photo != nil))
        case .liftFlooring:
            var r = record(first, kind: "removal", material: "flooring", roomIndex: roomIndex)
            r.heightMm = 0
            r.corners = m.wholeRoom ? nil : m.shots.map(Self.pose9)
            r.wholeRoom = m.wholeRoom ? true : nil
            r.floorType = m.floorType
            r.underlay = m.underlay ? true : nil
            commit(r, photo: first.photo)
            let t = "\(MarkIntent.floorTypes.first { $0.key == m.floorType }?.name ?? "Flooring")\(measure.map { " · \($0)" } ?? "")"
            return SavedCapture(entry: entry(r, kind: "mark", title: t, detail: room, photo: first.photo != nil))
        case .skirting, .wallLining, .cabinetry:
            var r = record(first, kind: "removal", material: m.meaning.removalItem ?? "other", roomIndex: roomIndex)
            if m.shots.count >= 2 {
                let e = m.shots[m.shots.count - 1]
                r.endCameraPosition = Self.arr(e.camera)
                r.endCameraForward = Self.arr(e.forward)
                r.endHit = e.hit.map(Self.arr)
            }
            r.heightMm = Double(m.heightMm)
            commit(r, photo: first.photo)
            var e = entry(r, kind: "mark", title: title, detail: room, photo: first.photo != nil)
            e.needsFix = problem?.sentence
            return SavedCapture(entry: e)
        }
    }

    private func entry(_ r: RawReading, kind: String, title: String, detail: String, photo: Bool) -> CaptureStack.Entry {
        CaptureStack.Entry(id: r.id, ids: [r.id], kind: kind, title: title, detail: detail, hasPhoto: photo && r.photoFile != nil)
    }

    private func record(_ s: CaptureShot, kind: String, material: String, note: String = "", roomIndex: Int) -> RawReading {
        let seq = nextSeq
        nextSeq += 1
        var r = RawReading(id: s.id, seq: seq, kind: kind, value: nil, material: material, reference: false, note: note,
                           takenAt: s.takenAt, roomIndex: roomIndex,
                           cameraPosition: Self.arr(s.camera), cameraForward: Self.arr(s.forward),
                           hit: s.hit.map(Self.arr), hitKind: s.hitKind,
                           photoFile: s.photo == nil ? nil : "photos/\(s.id).jpg", resolved: nil)
        r.hitNormal = s.normal.map(Self.arr)
        return r
    }

    func remove(ids: [String]) { for id in ids { delete(id) } }

    func edit(id: String, _ e: ItemEdit) {
        switch e {
        case .reading(let v, let m): updateRaw(id) { $0.value = v; $0.material = m }
        case .caption(let t): updateRaw(id) { $0.note = t }
        }
    }

    func equipmentUnits() -> [EquipmentGuard.Unit] {
        var counts: [String: Int] = [:]
        return raw.sorted { $0.seq < $1.seq }.compactMap { r -> EquipmentGuard.Unit? in
            guard r.kind == "equipment", let h = r.hit, h.count == 3 else { return nil }
            counts[r.material, default: 0] += 1
            let tag = r.note.isEmpty ? "\(CaptureCopy.equipmentShort[r.material] ?? "EQ") \(counts[r.material] ?? 1)" : r.note
            return EquipmentGuard.Unit(id: r.id, type: r.material, pos: PlanVec(h[0], h[2]), hasAirflow: extras.airflow[r.id] != nil, tag: tag)
        }
    }

    func setAirflow(id: String, direction: WorldVec) -> Bool {
        extras.airflow[id] = [PlanDocument.r4(direction.x), PlanDocument.r4(direction.z)]
        if !preview { extras.save(folder) }
        marksCache = nil
        return true
    }

    // MARK: Photos

    func jobPhotos() -> [JobPhoto] {
        let fy = world.floorY
        let photos = raw.filter { $0.kind == "photo" && $0.photoFile != nil }.sorted { $0.seq < $1.seq }
        let folder = self.folder
        return photos.enumerated().map { i, r in
            JobPhoto(id: r.id, title: "Photo \(i + 1)", place: place(r, floorY: fy), caption: r.note, load: {
                UIImage(contentsOfFile: folder.photosDir.appendingPathComponent("\(r.id)-full.jpg").path)
                    ?? r.photoFile.flatMap { UIImage(contentsOfFile: folder.url.appendingPathComponent($0).path) }
            })
        }.reversed()
    }

    /// "Bedroom · wall 0.8 m up"
    private func place(_ r: RawReading, floorY: Double?) -> String {
        let room = extras.roomNames["\(r.roomIndex + 1)"] ?? "Room \(r.roomIndex + 1)"
        if let n = r.hitNormal, n.count == 3, n[1] > 0.7 { return "\(room) · floor" }
        if let h = r.hit, h.count == 3, let fy = floorY { return "\(room) · wall \(String(format: "%.1f", max(0, h[1] - fy))) m up" }
        return room
    }

    func replacePhoto(id: String, photo: Task<CapturedPhoto?, Never>) async -> Bool {
        guard raw.contains(where: { $0.id == id }), let p = await photo.value else { return false }
        guard preview || PhotoFiles.write(p, id: id, folder: folder) else { return false }
        updateRaw(id) { $0.photoFile = "photos/\(id).jpg" }
        return true
    }

    /// 0.5x: the ultra-wide camera can't run while RoomPlan is capturing a room.
    var zoomState: ZoomState {
        guard UltraWideCamera.exists else { return .unavailable }
        switch phase {
        case .scanning, .processingRoom: return .blocked("0.5× after Room done")
        case .finishing: return .unavailable
        default: return .available
        }
    }

    func beginHandoff() -> CaptureShot? {
        guard zoomState == .available, let s = ScanWorld.shot(controller?.arSession, prefix: "ar-", photo: false) else { return nil }
        controller?.arSession?.pause()
        return s
    }

    /// Resume without resetting tracking: ARKit relocalises on the same world.
    func endHandoff() {
        guard let s = controller?.arSession, let c = s.configuration else { return }
        s.run(c, options: [])
    }

    func primaryOverride(tool: CaptureTool, aim: Aim) -> EnginePrimary? {
        if phase == .scanning && !started {
            return EnginePrimary(title: "Start scan", icon: "record.circle", start: true) { [weak self] in self?.startScan() }
        }
        if case .processingRoom = phase {
            return EnginePrimary(title: "Saving the room…", enabled: false, action: {})
        }
        return nil
    }

    // MARK: Rooms

    func nextRoom() {
        guard phase == .scanning else { return }
        phase = .processingRoom
        controller?.finishRoom()
    }

    func retryRoom() {
        phase = .scanning
        controller?.startRoom()
    }

    /// Finish: ends the room being scanned (then asks its name), or builds the job.
    /// `now` ("Save what's captured"): no room-name question, build as soon as the room is in.
    func finish(now: Bool = false) {
        switch phase {
        case .scanning:
            if !started { finalize(); return }
            finishRequested = true
            finishNow = now
            phase = .processingRoom
            controller?.finishRoom()
            finishSafetyNet()
        case .processingRoom:
            finishRequested = true
            finishNow = finishNow || now
            finishSafetyNet()
        case .roomFailed, .roomDone:
            finalize()
        case .finishing:
            break
        }
    }

    func scanNextRoom() {
        guard phase == .roomDone else { return }
        phase = .scanning
        controller?.startRoom()
        VoiceRecorder.shared.ensureRunning()
    }

    /// If RoomPlan never reports back, finish with what we have.
    private func finishSafetyNet() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !self.finalized, self.phase == .processingRoom else { return }
            self.finalize()
        }
    }

    func discard() {
        guard !preview else { onDiscarded(); return }
        discarded = true
        VoiceRecorder.shared.stop()
        controller?.shutdown()
        try? JobFiles.delete(job.id)
        onDiscarded()
    }

    /// Called by the scan camera when RoomPlan has processed a room.
    func roomProcessed(_ room: CapturedRoom, error: Error?) {
        guard !discarded, !finalized else { return }
        if error == nil || !room.walls.isEmpty {
            rooms.append(room)
            do {
                try JobProcessor.saveRoom(room, index: rooms.count, folder: folder)
            } catch {
                alert = "Room \(rooms.count) could not be saved to disk: \(error.localizedDescription)"
            }
            roomsDone = rooms.count
            phase = .roomDone
            DS.Haptic.roomDone()
            if finishNow { finalize(); return }
            VoiceRecorder.shared.ensureRunning()
            // Name it now (RoomPlan's sections pre-select); Finish continues after the name.
            hud.askRoomName()
        } else {
            let message = PlainWords.roomFailed(error?.localizedDescription)
            if finishRequested { finalize() } else { phase = .roomFailed(message) }
        }
    }

    /// The live screen could not build a room.
    func liveRoomFailed(_ message: String) {
        guard !discarded, !finalized else { return }
        if finishRequested { finalize() } else { phase = .roomFailed(PlainWords.roomFailed(message)) }
    }

    private func finalize() {
        guard !finalized else { return }
        finalized = true
        phase = .finishing("Building the 3D model…")
        VoiceRecorder.shared.stop()
        let rooms = self.rooms
        let folder = self.folder
        let jobID = job.id
        guard !rooms.isEmpty || !raw.isEmpty || JobFiles.hasAudio(folder) else {
            controller?.shutdown()
            try? JobFiles.delete(jobID)
            onDiscarded()
            return
        }
        extras.save(folder)
        let writes = photoWrites
        Task {
            if !rooms.isEmpty, let c = self.controller {
                _ = await c.saveWorldMap(to: folder.worldMapURL)
            }
            self.controller?.shutdown()
            for w in writes { await w.value }
            await VoiceRecorder.shared.waitForConversions()
            let note = await JobProcessor.exportModel(rooms: rooms, folder: folder)
            self.phase = .finishing("Drawing the floor plan…")
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try JobProcessor.buildPlan(folder: folder, modelNote: note ?? "")
                }.value
            } catch {
                self.alert = "The plan couldn't be drawn yet. Everything you captured is saved — open the job and choose Files › Regenerate plan."
                return
            }
            ScanOpenMarker.clear(folder)
            DS.Haptic.success()
            self.onFinished(jobID)
        }
    }

    func acknowledgeFinalAlert() {
        guard alert != nil else { return }
        alert = nil
        if finalized { onFinished(job.id) }
    }

    // MARK: Saving, undo, delete

    static func arr(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }
    static func arr(_ v: WorldVec) -> [Double] { [v.x, v.y, v.z] }
    static func pose9(_ s: CaptureShot) -> [Double] { arr(s.camera) + arr(s.forward) + (s.hit.map(arr) ?? []) }

    /// Appends a record, persists it at once, writes its photo files when ready.
    func commit(_ record: RawReading, photo: Task<CapturedPhoto?, Never>?) {
        raw.append(record)
        persistRaw()
        recount()
        marksCache = nil
        guard record.photoFile != nil, let photo, !preview else { return }
        let folder = self.folder
        let id = record.id
        let write = Task {
            let p = await photo.value
            guard !self.discarded, self.raw.contains(where: { $0.id == id }) else { return }
            let ok = p.map { PhotoFiles.write($0, id: id, folder: folder) } ?? false
            if !ok, let i = self.raw.firstIndex(where: { $0.id == id }) {
                self.raw[i].photoFile = nil
                self.persistRaw()
            }
        }
        photoWrites.append(write)
    }

    func updateRaw(_ id: String, _ change: (inout RawReading) -> Void) {
        guard let i = raw.firstIndex(where: { $0.id == id }) else { return }
        change(&raw[i])
        persistRaw()
        recount()
        marksCache = nil
    }

    func delete(_ id: String) {
        guard let i = raw.firstIndex(where: { $0.id == id }) else { return }
        raw.remove(at: i)
        if !preview { PhotoFiles.remove(id: id, folder: folder) }
        extras.airflow[id] = nil
        persistRaw()
        recount()
        marksCache = nil
    }

    private func persistRaw() {
        guard !preview else { return }
        do { try JobFiles.saveRawReadings(raw, folder) }
        catch { alert = "Couldn't save what you captured: \(error.localizedDescription)" }
    }

    private func recount() {
        totalCount = raw.count
    }

    nonisolated static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// readings-raw.json items -> overlay marks (scan world space).
enum ScanMarks {
    static func build(_ raw: [RawReading], world: CaptureWorld, extras: ScanExtras) -> [OverlayMark] {
        func v(_ a: [Double]?) -> WorldVec? { a.flatMap { $0.count == 3 ? WorldVec($0[0], $0[1], $0[2]) : nil } }
        let fy = world.floorY
        var out: [OverlayMark] = []
        var readingN = 0, photoN = 0
        var equipN: [String: Int] = [:]
        var run: [WorldVec] = []
        var runId = ""
        func flushRun() {
            if run.count >= 2 { out.append(OverlayMark(id: runId, style: .moisture, points: run, tag: "Moisture line")) }
            run = []
        }
        for r in raw.sorted(by: { $0.seq < $1.seq }) {
            let p = v(r.hit) ?? v(r.resolved)
            if r.kind != "boundary" { flushRun() }
            switch r.kind {
            case "reading":
                readingN += 1
                guard let p else { continue }
                out.append(OverlayMark(id: r.id, style: .reading(status: OverlayBuild.status(r.value, reference: false), reference: r.reference),
                                       points: [p], value: r.value.map(CaptureCopy.number), tag: CaptureCopy.readingTag(readingN)))
            case "photo":
                photoN += 1
                guard let p else { continue }
                out.append(OverlayMark(id: r.id, style: .photo, points: [p], tag: CaptureCopy.photoTag(photoN)))
            case "source":
                guard let p else { continue }
                let cause = r.note.components(separatedBy: " — ").first ?? r.note
                out.append(OverlayMark(id: r.id, style: .source, points: [p], tag: cause.isEmpty || cause == "Unknown" ? "Source" : "\(cause) leak"))
            case "equipment":
                guard let p else { continue }
                equipN[r.material, default: 0] += 1
                let tag = r.note.isEmpty ? "\(CaptureCopy.equipmentShort[r.material] ?? "EQ") \(equipN[r.material] ?? 1)" : r.note
                out.append(OverlayMark(id: r.id, style: .equipment(type: r.material, planned: false),
                                       points: [WorldVec(p.x, fy ?? p.y, p.z)], airflow: extras.direction(r.id), tag: tag))
            case "boundary":
                guard let p else { continue }
                if let last = run.last, simd_distance(last, p) > 3 { flushRun() }
                if run.isEmpty { runId = r.id }
                run.append(p)
            case "affected":
                let poly = (r.corners ?? []).compactMap { c -> WorldVec? in c.count >= 9 ? WorldVec(c[6], fy ?? c[7], c[8]) : nil }
                guard poly.count >= 3 else { continue }
                out.append(OverlayMark(id: r.id, style: .wetFloor, points: poly,
                                       tag: "Wet floor · \(CaptureCopy.area(FloorArea.area(poly.map { PlanVec($0.x, $0.z) })))"))
            case "removal":
                if r.material == "flooring" {
                    var poly = (r.corners ?? []).compactMap { c -> WorldVec? in c.count >= 9 ? WorldVec(c[6], fy ?? c[7], c[8]) : nil }
                    if r.wholeRoom == true, let cam = v(r.cameraPosition), let room = world.room(containing: PlanVec(cam.x, cam.z)) {
                        poly = room.polygon.map { WorldVec($0.x, fy ?? cam.y - 1.4, $0.y) }
                    }
                    guard poly.count >= 3 else { continue }
                    let type = MarkIntent.floorTypes.first { $0.key == r.floorType }?.name ?? "Flooring"
                    out.append(OverlayMark(id: r.id, style: .liftFlooring, points: poly,
                                           tag: "\(type) · \(CaptureCopy.area(FloorArea.area(poly.map { PlanVec($0.x, $0.z) })))"))
                } else {
                    guard let a = p, let b = v(r.endHit) else { continue }
                    let (wa, wb) = onWall(a, b, world: world)
                    let base = fy ?? min(a.y, b.y)
                    let len = simd_distance(PlanVec(wa.x, wa.y), PlanVec(wb.x, wb.y))
                    let skirting = r.material == "skirting"
                    let name = skirting ? "Skirting" : (r.material == "cabinetry" ? "Cabinetry" : "Wall lining")
                    out.append(OverlayMark(id: r.id, style: skirting ? .skirting : .lining,
                                           points: [WorldVec(wa.x, base, wa.y), WorldVec(wb.x, base, wb.y)],
                                           top: skirting ? nil : (r.heightMm ?? 600) / 1000, tag: "\(name) · \(CaptureCopy.length(len))"))
                }
            default:
                break
            }
        }
        flushRun()
        return out
    }

    /// The two ends of a wall stretch moved onto the nearest wall line (x, z).
    static func onWall(_ a: WorldVec, _ b: WorldVec, world: CaptureWorld) -> (PlanVec, PlanVec) {
        let pa = PlanVec(a.x, a.z), pb = PlanVec(b.x, b.z)
        guard let n = world.nearestWall(to: (pa + pb) / 2, maxDistance: 0.5) else { return (pa, pb) }
        let w = n.wall
        func proj(_ p: PlanVec) -> PlanVec { w.a + (w.b - w.a) * min(max(PlanBuilder.projectParam(p, w.a, w.b), 0), 1) }
        return (proj(pa), proj(pb))
    }
}
