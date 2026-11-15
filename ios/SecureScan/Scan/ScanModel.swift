//
//  ScanModel.swift
//  SecureScan
//
//  State of the scan screen: rooms captured so far, items logged, the
//  Next room / Finish flow, and saving everything to the job folder as it
//  happens (rooms/<n>.json and readings-raw.json) so a failed merge or a
//  crash never loses what was captured. One capture model for all six input
//  types: one sheet, one toast pattern, one counter, Undo last, a list.
//

import Foundation
import CoreImage
import RoomPlan
import ARKit
import SwiftUI

/// Hands a CIImage to the background JPEG encoder (CIImage is immutable).
final class ImageBox: @unchecked Sendable {
    let image: CIImage?
    init(_ image: CIImage?) { self.image = image }
}

/// One "Log" tap waiting for the user to finish the sheet.
struct PendingLog: Identifiable {
    let id: String
    let seq: Int
    let roomIndex: Int
    let takenAt: String
    let capture: FrameCapture
    let photoTask: Task<Data?, Never>
}

@MainActor
final class ScanModel: ObservableObject, LogSheetModel {

    enum Phase: Equatable {
        case scanning                // a room is being scanned
        case processingRoom          // waiting for RoomPlan to finish a room
        case roomFailed(String)      // last room failed; rooms before it are kept
        case roomDone                // a room is saved: Mark up this room / Scan next room / Finish
        case preparingMarkup         // building the plan so far for the AR mark-up
        case finishing(String)       // merging / exporting / building the plan
    }

    @Published var phase: Phase = .scanning
    @Published private(set) var roomsDone = 0
    @Published private(set) var readingCount = 0
    @Published private(set) var photoCount = 0
    @Published private(set) var totalCount = 0
    @Published var toast: String?
    @Published var pending: PendingLog?
    @Published var lastMaterial = "wall"
    @Published var lastEquipmentType = "airMover"
    @Published var lastKind = "reading"
    @Published var lastRemovalItem = "plasterboard"
    @Published var alert: String?
    @Published var showItems = false
    /// The AR mark-up screen for the rooms so far, when open.
    @Published var markup: RevisitModel?
    let flow = CaptureFlow()

    let job: JobMeta
    let folder: JobFolder
    weak var controller: ScanViewController?
    /// Simulator screenshots only: no camera, nothing is deleted.
    let preview: Bool

    private var rooms: [CapturedRoom] = []
    private(set) var raw: [RawReading] = []
    private var nextSeq = 1
    private var finishRequested = false
    private var discarded = false
    private var finalized = false
    private var photoWrites: [Task<Void, Never>] = []
    private let onFinished: (UUID) -> Void
    private let onDiscarded: () -> Void

    init(job: JobMeta, preview: Bool = false, onFinished: @escaping (UUID) -> Void, onDiscarded: @escaping () -> Void) {
        self.job = job
        self.preview = preview
        self.folder = JobFiles.folder(for: job.id)
        self.onFinished = onFinished
        self.onDiscarded = onDiscarded
        self.raw = JobFiles.loadRawReadings(folder)
        self.nextSeq = (raw.map(\.seq).max() ?? 0) + 1
        recount()
    }

    var currentRoomNumber: Int { roomsDone + 1 }
    var nextReadingNumber: Int { readingCount + 1 }
    var nextPhotoNumber: Int { photoCount + 1 }
    var canLog: Bool {
        switch phase {
        case .finishing, .preparingMarkup: return false
        default: return !flow.isBusy && markup == nil
        }
    }
    var hasAnything: Bool { roomsDone > 0 || !raw.isEmpty || JobFiles.hasAudio(folder) }
    var hasAudio: Bool { JobFiles.hasAudio(folder) }

    /// Logged items, newest first, for the list.
    var loggedItems: [RawReading] { raw.sorted { $0.seq > $1.seq } }

    // MARK: Voice notes

    func toggleRecording() {
        let recorder = VoiceRecorder.shared
        if recorder.isRecording {
            recorder.stop()
            showToast("Voice note saved")
        } else {
            Task {
                if await recorder.start(folder: folder) { showToast("Recording voice notes") }
                else if let p = recorder.problem { alert = p; recorder.problem = nil }
            }
        }
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

    /// Finish on the scan screen ends the room and offers "Mark up this
    /// room" first; `now` (the choice card's Finish, "Save what's captured")
    /// builds the job straight away.
    func finish(now: Bool = false) {
        flow.cancel()
        switch phase {
        case .scanning:
            finishRequested = now
            phase = .processingRoom
            controller?.finishRoom()
            if now { finishSafetyNet() }
        case .processingRoom:
            if now { finishRequested = true; finishSafetyNet() }
        case .roomFailed, .roomDone:
            if now || phase != .roomDone { finalize() }
        case .finishing, .preparingMarkup:
            break
        }
    }

    /// From the choice card: back to RoomPlan for the next room.
    func scanNextRoom() {
        guard phase == .roomDone else { return }
        phase = .scanning
        controller?.startRoom()
        VoiceRecorder.shared.ensureRunning()
    }

    /// "Mark up this room": builds the plan of the rooms so far (walls and the
    /// plan frame), then opens the AR mark-up on the scan's own ARSession when
    /// it is still running; otherwise on a new session that relocalises with
    /// the world map saved now, or failing that is aligned by two corners.
    func markUp() {
        guard phase == .roomDone, !preview else { return }
        phase = .preparingMarkup
        let folder = self.folder
        let writes = photoWrites
        Task {
            for w in writes { await w.value }        // photos on disk before the plan embeds them
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try JobProcessor.buildPlan(folder: folder, modelNote: nil)
                }.value
            } catch {
                self.phase = .roomDone
                self.alert = "The plan so far could not be built (\(error.localizedDescription)). Scan the next room or Finish; nothing is lost."
                return
            }
            let session = self.controller?.arSession
            let running = session?.currentFrame != nil
            if !running, let c = self.controller { _ = await c.saveWorldMap(to: folder.worldMapURL, timeout: 3) }
            let start = MarkupStart.strategy(sharedSessionRunning: running,
                                             hasPlanFrame: JobFiles.loadFrame(folder) != nil,
                                             hasWorldMap: FileManager.default.fileExists(atPath: folder.worldMapURL.path))
            let m = RevisitModel(folder: folder, firstScan: self, session: start == .sharedSession ? session : nil,
                                 start: start, roomNumber: self.roomsDone)
            self.markup = m
            self.phase = .roomDone
        }
    }

    /// Back from the mark-up screen to the choice card.
    func closeMarkup() {
        markup?.flow.cancel()
        markup = nil
        recount()
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

    /// Called by ScanViewController when RoomPlan has processed a room.
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
            if finishRequested {
                finalize()
            } else {
                showToast("Room \(roomsDone) saved")
                phase = .roomDone
                // Keep the voice recording going while marking up.
                VoiceRecorder.shared.ensureRunning()
            }
        } else {
            let message = error?.localizedDescription ?? "Unknown error"
            if finishRequested {
                finalize()
            } else {
                phase = .roomFailed("That room didn't save (\(message)). Rooms already saved are kept.")
            }
        }
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
        let writes = photoWrites
        Task {
            // Save the AR world map (for return visits) while the session still runs.
            if !rooms.isEmpty, let c = self.controller {
                _ = await c.saveWorldMap(to: folder.worldMapURL)
            }
            self.controller?.shutdown()
            // Make sure every logged photo is on disk before the plan embeds them,
            // and the voice recording is closed and converted.
            for w in writes { await w.value }
            await VoiceRecorder.shared.waitForConversions()
            let note = await JobProcessor.exportModel(rooms: rooms, folder: folder)
            self.phase = .finishing("Drawing the floor plan…")
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try JobProcessor.buildPlan(folder: folder, modelNote: note ?? "")
                }.value
            } catch {
                self.alert = "The plan could not be built: \(error.localizedDescription). Your rooms and readings are saved — open the job and use Files › Regenerate plan."
                return
            }
            self.onFinished(jobID)
        }
    }

    /// Dismiss the build-failure alert and open the job anyway.
    func acknowledgeFinalAlert() {
        guard alert != nil else { return }
        alert = nil
        if finalized { onFinished(job.id) }
    }

    // MARK: Logging

    func beginLog() {
        guard canLog, pending == nil else { return }
        guard let p = capturePending() else {
            showToast("Camera not ready — try again")
            return
        }
        pending = p
    }

    /// Camera pose + raycast now, photo encoded in the background.
    private func capturePending() -> PendingLog? {
        guard let capture = controller?.captureFrame() else { return nil }
        // The CIImage wraps ARKit's camera pixel buffer: only the encode task keeps
        // it (briefly), not the pending item, so ARKit's buffer pool isn't starved.
        let box = ImageBox(capture.image)
        let task = Task.detached(priority: .userInitiated) { FrameEncoder.jpeg(from: box.image) }
        var pose = capture
        pose.image = nil
        let seq = nextSeq
        nextSeq += 1
        return PendingLog(id: "ar-" + UUID().uuidString.prefix(8).lowercased(), seq: seq,
                          roomIndex: rooms.count, takenAt: PlanDocument.iso(Date()),
                          capture: pose, photoTask: task)
    }

    func cancelLog() { pending = nil }

    static func arr(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }

    /// Saves the pending item. kind: "reading" | "boundary" | "photo" | "source" |
    /// "equipment" (material = type) | "floorType" (material = floor type).
    func saveLog(kind: String, value: Double?, material: String, reference: Bool, note: String) {
        guard let p = pending else { return }
        pending = nil
        if kind == "reading" { lastMaterial = material }
        if kind == "equipment" { lastEquipmentType = material }
        if kind != "floorType" { lastKind = kind }
        let c = p.capture
        var r = RawReading(id: p.id, seq: p.seq, kind: kind, value: kind == "reading" ? value : nil,
                           material: material, reference: kind == "reading" && reference, note: note,
                           takenAt: p.takenAt, roomIndex: p.roomIndex,
                           cameraPosition: Self.arr(c.cameraPosition), cameraForward: Self.arr(c.cameraForward),
                           hit: c.hit.map(Self.arr), hitKind: c.hitKind, photoFile: "photos/\(p.id).jpg", resolved: nil)
        r.hitNormal = c.hitNormal.map(Self.arr)
        if kind == "floorType" { r.floorType = material }
        commit(r, photoTask: p.photoTask)
        switch kind {
        case "reading": logged("Reading \(readingCount)", "\(Self.format(value ?? 0))%")
        case "photo": logged("Photo P\(photoCount)", note.isEmpty ? nil : note)
        case "source": logged("Source", note.isEmpty ? nil : note)
        case "equipment": logged(PlanDocument.equipmentName(material), note.isEmpty ? nil : note)
        case "floorType": logged("Floor type", material.capitalized)
        default: logged(LogKind.name(kind), nil)
        }
    }

    // MARK: Removals (two taps on a wall, or floor corners)

    func startRemoval(item: String) {
        guard let p = pending else { return }
        pending = nil
        lastRemovalItem = item
        lastKind = "removal"
        flow.begin(item: item, start: p)
    }

    func endHere() {
        guard let c = controller?.captureFrame() else { showToast("Camera not ready — try again"); return }
        var pose = c
        pose.image = nil
        flow.setEnd(pose)
    }

    func addCorner() {
        guard let c = controller?.captureFrame() else { showToast("Camera not ready — try again"); return }
        var pose = c
        pose.image = nil
        flow.addCorner(pose)
    }

    func saveRemoval(item: String, heightMm: Int, note: String, floorType: String?, underlay: Bool) {
        guard let d = flow.finish(item: item, heightMm: heightMm, note: note, floorType: floorType, underlay: underlay) else { return }
        let s = d.start
        var r = RawReading(id: s.id, seq: s.seq, kind: "removal", value: nil, material: d.item, reference: false, note: d.note,
                           takenAt: s.takenAt, roomIndex: s.roomIndex,
                           cameraPosition: Self.arr(s.capture.cameraPosition), cameraForward: Self.arr(s.capture.cameraForward),
                           hit: s.capture.hit.map(Self.arr), hitKind: s.capture.hitKind,
                           photoFile: "photos/\(s.id).jpg", resolved: nil)
        r.hitNormal = s.capture.hitNormal.map(Self.arr)
        if let e = d.end {
            r.endCameraPosition = Self.arr(e.cameraPosition)
            r.endCameraForward = Self.arr(e.cameraForward)
            r.endHit = e.hit.map(Self.arr)
        }
        r.heightMm = d.item == "flooring" ? 0 : Double(d.heightMm)
        if !d.corners.isEmpty {
            r.corners = d.corners.map { c in Self.arr(c.cameraPosition) + Self.arr(c.cameraForward) + (c.hit.map(Self.arr) ?? []) }
        }
        r.wholeRoom = d.wholeRoom ? true : nil
        r.floorType = d.floorType
        r.underlay = d.underlay ? true : nil
        commit(r, photoTask: s.photoTask)
        logged("Removal", d.item == "flooring" ? "Flooring\(d.wholeRoom ? " · whole room" : "")" : "\(RemovalItems.name(d.item)) to \(d.heightMm) mm")
    }

    // MARK: Saving, undo, delete

    /// Appends a record, persists it at once, writes its photo when ready.
    func commit(_ record: RawReading, photoTask: Task<Data?, Never>?) {
        raw.append(record)
        persistRaw()
        recount()
        // The photo is written when the JPEG is ready; if it fails the record
        // simply loses its photo.
        let folder = self.folder
        let id = record.id
        guard let photoFile = record.photoFile, let photoTask else { return }
        let write = Task {
            let data = await photoTask.value
            // Scan discarded meanwhile, or the item undone: don't recreate it.
            guard !self.discarded, self.raw.contains(where: { $0.id == id }) else { return }
            var ok = false
            if let data {
                try? FileManager.default.createDirectory(at: folder.photosDir, withIntermediateDirectories: true)
                ok = (try? data.write(to: folder.url.appendingPathComponent(photoFile), options: .atomic)) != nil
            }
            if !ok, let i = self.raw.firstIndex(where: { $0.id == id }) {
                self.raw[i].photoFile = nil
                self.persistRaw()
            }
        }
        photoWrites.append(write)
    }

    /// Removes the most recently logged item (record and photo).
    func undoLast() {
        guard let last = raw.max(by: { $0.seq < $1.seq }) else { return }
        delete(last.id)
        showToast("Undone: \(describe(last).title) · \(totalCount) item\(totalCount == 1 ? "" : "s")")
    }

    /// The next capture number (AR mark-up records share the scan's order).
    func allocateSeq() -> Int {
        defer { nextSeq += 1 }
        return nextSeq
    }

    /// Changes a raw record in place (AR mark-up edits) and saves at once.
    func updateRaw(_ id: String, _ change: (inout RawReading) -> Void) {
        guard let i = raw.firstIndex(where: { $0.id == id }) else { return }
        change(&raw[i])
        persistRaw()
        recount()
    }

    func delete(_ id: String) {
        guard let i = raw.firstIndex(where: { $0.id == id }) else { return }
        let r = raw.remove(at: i)
        if let f = r.photoFile { try? FileManager.default.removeItem(at: folder.url.appendingPathComponent(f)) }
        persistRaw()
        recount()
        // Once a mark-up has built plan.json the item is in there too (a later
        // build keeps document items), so take it out of the plan as well.
        if !preview, let data = try? Data(contentsOf: folder.planURL),
           let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let out = MarkupEdit.delete(doc, id: id),
           let clean = PlanDocument.sanitised(out) as? [String: Any],
           let bytes = try? PlanDocument.data(clean) {
            try? bytes.write(to: folder.planURL, options: .atomic)
        }
    }

    func describe(_ r: RawReading) -> (title: String, detail: String) {
        switch r.kind {
        case "reading": return ("Reading", r.value.map { "\(Self.format($0))% · \(r.material)" } ?? r.material)
        case "equipment": return (PlanDocument.equipmentName(r.material), r.note)
        case "removal":
            let what = RemovalItems.name(r.material)
            return ("Removal", r.material == "flooring" ? what + (r.floorType.map { " · \($0)" } ?? "")
                                                       : "\(what) to \(Int(r.heightMm ?? 0)) mm")
        case "floorType": return ("Floor type", (r.floorType ?? r.material).capitalized)
        case "affected": return ("Wet area", r.note)
        case "boundary": return ("Moisture line", "")
        default: return (LogKind.name(r.kind), r.note)
        }
    }

    private func persistRaw() {
        guard !preview else { return }
        do { try JobFiles.saveRawReadings(raw, folder) }
        catch { alert = "Couldn't save readings: \(error.localizedDescription)" }
    }

    private func recount() {
        readingCount = raw.filter { $0.kind == "reading" }.count
        photoCount = raw.filter { $0.kind == "photo" }.count
        totalCount = raw.count
    }

    /// The one confirmation pattern for every type: "<what> logged · <detail> · N items".
    private func logged(_ what: String, _ detail: String?) {
        var parts = ["\(what) logged"]
        if let d = detail, !d.isEmpty { parts.append(d) }
        parts.append("\(totalCount) item\(totalCount == 1 ? "" : "s")")
        showToast(parts.joined(separator: " · "))
    }

    func showToast(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    /// Simulator screenshots: open the Log sheet without a camera frame.
    func previewLogSheet() {
        let pose = FrameCapture(cameraPosition: .zero, cameraForward: SIMD3<Float>(0, 0, -1), hit: nil, hitKind: nil, image: nil)
        lastKind = "removal"
        pending = PendingLog(id: "preview", seq: 0, roomIndex: 0, takenAt: "", capture: pose, photoTask: Task { nil })
    }

    /// Simulator screenshots: show the removal bar as if Start here had been tapped.
    func previewRemovalBar() {
        let pose = FrameCapture(cameraPosition: .zero, cameraForward: SIMD3<Float>(0, 0, -1), hit: nil, hitKind: nil, image: nil)
        let p = PendingLog(id: "preview", seq: 0, roomIndex: 0, takenAt: "", capture: pose, photoTask: Task { nil })
        flow.begin(item: "skirting", start: p)
    }

    /// Simulator screenshots: the card shown when a room is saved.
    func previewRoomDone() {
        roomsDone = 1
        phase = .roomDone
    }

    nonisolated static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }
}
