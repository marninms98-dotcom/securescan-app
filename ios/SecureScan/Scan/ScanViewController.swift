//
//  ScanViewController.swift
//  SecureScan
//
//  Hosts RoomPlan's RoomCaptureView (the scan engine proven on a real phone).
//  Rooms are finished with captureSession.stop(pauseARSession: false) so the
//  ARSession - and its world origin - keeps running, which keeps the rooms
//  aligned and keeps marking usable between rooms. The capture session's
//  delegate gives the room as it is found (live walls for the reticle,
//  snapping and the overlay) and RoomPlan's coaching, which goes to the top
//  capsule. The overlay is drawn over this view by CaptureScreen.
//
//  RoomCaptureViewDelegate inherits NSCoding; UIViewController already
//  provides init?(coder:) and encode(with:), which satisfies it.
//

import UIKit
import ARKit
import RoomPlan
import CoreImage

/// Resolves a Bool continuation once (a completion or a timeout, whichever comes first).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<Bool, Never>?
    init(_ c: CheckedContinuation<Bool, Never>) { self.c = c }
    func resume(_ v: Bool) {
        lock.lock(); let k = c; c = nil; lock.unlock()
        k?.resume(returning: v)
    }
}

/// Hands an ARWorldMap to a background queue for archiving.
final class WorldMapBox: @unchecked Sendable {
    let map: ARWorldMap
    init(_ map: ARWorldMap) { self.map = map }
}

final class ScanViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate, ScanCaptureControlling {

    weak var model: ScanModel?
    private var roomCaptureView: RoomCaptureView?
    private var started = false
    /// Walls of rooms already finished in this session, and of the room being scanned.
    private var finished = CaptureWorld.empty
    private var live = CaptureWorld.empty
    private var sections: [String] = []
    private(set) var coaching: String?
    /// New walls / doors / windows / objects, for the scan's soft tick.
    private var structure = StructureDiff()
    private var configuration: RoomCaptureSession.Configuration {
        var c = RoomCaptureSession.Configuration()
        c.isCoachingEnabled = true
        return c
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let v = RoomCaptureView(frame: view.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.delegate = self
        // Live room updates and coaching (Apple's RoomPlan sample sets this too).
        v.captureSession.delegate = self
        view.addSubview(v)
        roomCaptureView = v
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            // The camera runs (world tracking only) so the room can be framed; RoomPlan's
            // capture starts with "Start" (ScanModel.startScan -> startRoom). The same
            // ARSession carries on, as between rooms (stop(pauseARSession: false)).
            if model?.started == true { startRoom() } else { roomCaptureView?.captureSession.arSession.run(ARWorldTrackingConfiguration()) }
        }
    }

    var arSession: ARSession? { roomCaptureView?.captureSession.arSession }

    var liveWorld: CaptureWorld {
        var w = finished
        w.walls += live.walls
        w.openings += live.openings
        w.objects += live.objects
        w.rooms += live.rooms
        w.floorY = live.floorY ?? finished.floorY
        return w
    }

    var liveSections: [String] { sections }

    // MARK: Commands from ScanModel

    func startRoom() {
        live = .empty
        sections = []
        structure.reset()
        roomCaptureView?.captureSession.run(configuration: configuration)
    }

    func finishRoom() {
        roomCaptureView?.captureSession.stop(pauseARSession: false)
    }

    func shutdown() {
        roomCaptureView?.captureSession.stop()
    }

    /// Raycast from the screen centre: existing plane geometry first, then an
    /// estimated plane. Returns the hit, the surface normal and which kind hit.
    static func centreRaycast(session: ARSession, frame: ARFrame) -> (SIMD3<Float>?, SIMD3<Float>?, String?) {
        let centre = CGPoint(x: 0.5, y: 0.5)
        let kinds: [(ARRaycastQuery.Target, String)] = [(.existingPlaneGeometry, "existingPlaneGeometry"), (.estimatedPlane, "estimatedPlane")]
        for (target, name) in kinds {
            let q = frame.raycastQuery(from: centre, allowing: target, alignment: .any)
            if let r = session.raycast(q).first {
                let t = r.worldTransform
                return (SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                        SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z), name)
            }
        }
        return (nil, nil, nil)
    }

    /// Saves the session's ARWorldMap (secure-coded) for return visits. Gives
    /// up after `timeout` seconds; never throws.
    func saveWorldMap(to url: URL, timeout: Double = 4) async -> Bool {
        guard let session = roomCaptureView?.captureSession.arSession else { return false }
        return await Self.saveWorldMap(session: session, to: url, timeout: timeout)
    }

    static func saveWorldMap(session: ARSession, to url: URL, timeout: Double) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag(c)
            session.getCurrentWorldMap { map, _ in
                guard let map else { once.resume(false); return }
                let box = WorldMapBox(map)
                DispatchQueue.global(qos: .utility).async {
                    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: box.map, requiringSecureCoding: true) else {
                        once.resume(false); return
                    }
                    once.resume((try? data.write(to: url, options: .atomic)) != nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }

    private func roomUpdated(_ room: CapturedRoom) {
        let name = model?.roomName ?? "Room"
        let r = ScanWorld.from(room, name: name, idPrefix: "live\(model?.roomsDone ?? 0)-")
        live = CaptureWorld(floorY: r.floorY ?? live.floorY, walls: r.walls, rooms: r.room.map { [$0] } ?? [],
                            openings: r.openings, objects: r.objects)
        sections = ScanWorld.sectionLabels(room)
        if structure.add(ScanWorld.structureIds(room)) > 0 { DS.Haptic.structure() }
    }

    private func roomFinished(_ room: CapturedRoom) {
        let n = model?.roomsDone ?? 0
        let r = ScanWorld.from(room, name: model?.roomName ?? "Room", idPrefix: "room\(n)-")
        finished.walls += r.walls
        finished.openings += r.openings
        finished.objects += r.objects
        if let rr = r.room { finished.rooms.append(rr) }
        finished.floorY = r.floorY ?? finished.floorY
        live = .empty
        sections = ScanWorld.sectionLabels(room)
    }

    // MARK: RoomCaptureSessionDelegate (live)

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in self?.roomUpdated(room) }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text = ScanWorld.coaching(instruction)
        Task { @MainActor [weak self] in self?.coaching = text }
    }

    // MARK: RoomCaptureViewDelegate

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true   // let RoomPlan process and present the room
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor [weak self] in
            if error == nil || !processedResult.walls.isEmpty { self?.roomFinished(processedResult) }
            self?.coaching = nil
            self?.model?.roomProcessed(processedResult, error: error)
        }
    }
}

/// Camera frame -> portrait JPEG, max `maxLongEdge` px long edge.
enum FrameEncoder {
    static let context = CIContext()

    static func jpeg(from image: CIImage?, maxLongEdge: CGFloat = 1280, quality: CGFloat = 0.7) -> Data? {
        guard let image else { return nil }
        // ARKit's capturedImage is in the sensor's landscape orientation;
        // .right rotates it upright for a phone held in portrait.
        let oriented = image.oriented(.right)
        let extent = oriented.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, maxLongEdge / longEdge)
        let scaled = scale < 1 ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : oriented
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}
