//
//  LiveScanViewController.swift
//  SecureScan
//
//  "Scan and mark together": RoomPlan's RoomCaptureSession runs on OUR
//  ARSession (RoomCaptureSession(arSession:), iOS 17) and the camera is our
//  own ARSCNView on that same session. It draws only the room as it is found
//  (translucent wall quads with bright edges, door and window outlines);
//  every mark is drawn by the shared CaptureScreen overlay, exactly as over
//  the classic RoomCaptureView. Rooms end with stop(pauseARSession: false)
//  and RoomBuilder, then go to ScanModel.roomProcessed like the classic screen.
//

import UIKit
import ARKit
import RoomPlan
import SceneKit
import CoreImage

final class LiveScanViewController: UIViewController, ScanCaptureControlling, RoomCaptureSessionDelegate {

    weak var model: ScanModel?
    /// Called when no walls are found 25 s into a room (offer the classic scan).
    var onStalled: ((Bool) -> Void)?
    private let sceneView = ARSCNView(frame: .zero)
    private let session = ARSession()
    private var capture: RoomCaptureSession?
    private let roomNode = SCNNode()
    private var started = false
    private var lastRoom: CapturedRoom?
    private var roomStartedAt = Date()
    private var sawWalls = false
    private var stallTimer: Timer?
    private var finished = CaptureWorld.empty
    private var live = CaptureWorld.empty
    private var sections: [String] = []
    private(set) var coaching: String?
    /// Set by shutdown(): a room that ends because the screen is going away is not reported.
    private var shutDown = false

    var arSession: ARSession? { session }

    var liveWorld: CaptureWorld {
        var w = finished
        w.walls += live.walls
        w.rooms += live.rooms
        w.floorY = live.floorY ?? finished.floorY
        return w
    }

    var liveSections: [String] { sections }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session = session
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene.rootNode.addChildNode(roomNode)
        view.addSubview(sceneView)
        let c = RoomCaptureSession(arSession: session)
        c.delegate = self
        capture = c
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        startRoom()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStall() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stallTimer?.invalidate()
        stallTimer = nil
    }

    // MARK: ScanCaptureControlling

    func startRoom() {
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = true
        capture?.run(configuration: config)
        roomStartedAt = Date()
        sawWalls = false
        live = .empty
        sections = []
        onStalled?(false)
        roomNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    func finishRoom() {
        capture?.stop(pauseARSession: false)
    }

    func shutdown() {
        shutDown = true
        stallTimer?.invalidate()
        stallTimer = nil
        capture?.stop()
        session.pause()
    }

    func saveWorldMap(to url: URL, timeout: Double) async -> Bool {
        await ScanViewController.saveWorldMap(session: session, to: url, timeout: timeout)
    }

    private func checkStall() {
        guard let model, !sawWalls, model.phase == .scanning, Date().timeIntervalSince(roomStartedAt) > 25 else { return }
        onStalled?(true)
    }

    // MARK: RoomCaptureSessionDelegate (all optional; called off the main thread)

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in self?.roomUpdated(room) }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text = ScanWorld.coaching(instruction)
        Task { @MainActor [weak self] in self?.coaching = text }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, !self.shutDown else { return }
            self.coaching = nil
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.roomFinished(room)
                self.model?.roomProcessed(room, error: nil)
            } catch {
                if let last = self.lastRoom, !last.walls.isEmpty {
                    // The tidy-up failed: keep the room as it was last seen.
                    self.roomFinished(last)
                    self.model?.roomProcessed(last, error: nil)
                } else {
                    self.model?.liveRoomFailed(error.localizedDescription)
                    self.onStalled?(true)
                }
            }
            self.lastRoom = nil
        }
    }

    // MARK: The room as it is found

    private func roomUpdated(_ room: CapturedRoom) {
        lastRoom = room
        if !room.walls.isEmpty { sawWalls = true; onStalled?(false) }
        let r = ScanWorld.from(room, name: model?.roomName ?? "Room", idPrefix: "live\(model?.roomsDone ?? 0)-")
        live = CaptureWorld(floorY: r.floorY ?? live.floorY, walls: r.walls, rooms: r.room.map { [$0] } ?? [])
        sections = ScanWorld.sectionLabels(room)
        roomNode.childNodes.forEach { $0.removeFromParentNode() }
        let edge = UIColor(white: 1, alpha: 0.9)
        for w in room.walls { roomNode.addChildNode(Self.surfaceNode(w, fill: UIColor(white: 1, alpha: 0.10), edge: edge)) }
        for d in room.doors { roomNode.addChildNode(Self.surfaceNode(d, fill: nil, edge: UIColor(white: 1, alpha: 0.5), inset: 0.01)) }
        for w in room.windows { roomNode.addChildNode(Self.surfaceNode(w, fill: nil, edge: UIColor(white: 1, alpha: 0.5), inset: 0.01)) }
        for o in room.openings { roomNode.addChildNode(Self.surfaceNode(o, fill: nil, edge: UIColor(white: 1, alpha: 0.35), inset: 0.01)) }
    }

    private func roomFinished(_ room: CapturedRoom) {
        let n = model?.roomsDone ?? 0
        let r = ScanWorld.from(room, name: model?.roomName ?? "Room", idPrefix: "room\(n)-")
        finished.walls += r.walls
        if let rr = r.room { finished.rooms.append(rr) }
        finished.floorY = r.floorY ?? finished.floorY
        live = .empty
        sections = ScanWorld.sectionLabels(room)
    }

    static func overlay(_ c: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }

    /// A captured surface: its own frame has x along the width, y up, z out of it.
    static func surfaceNode(_ s: CapturedRoom.Surface, fill: UIColor?, edge: UIColor, inset: Float = 0) -> SCNNode {
        let node = SCNNode()
        node.simdTransform = s.transform
        let w = CGFloat(s.dimensions.x), h = CGFloat(s.dimensions.y)
        if let fill {
            let plane = SCNPlane(width: w, height: h)
            plane.materials = [overlay(fill)]
            node.addChildNode(SCNNode(geometry: plane))
        }
        let hw = s.dimensions.x / 2, hh = s.dimensions.y / 2
        let corners = [SIMD3<Float>(-hw, -hh, inset), SIMD3<Float>(hw, -hh, inset), SIMD3<Float>(hw, hh, inset), SIMD3<Float>(-hw, hh, inset)]
        let mat = overlay(edge)
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let len = simd_length(b - a)
            guard len > 0.01 else { continue }
            let cyl = SCNCylinder(radius: 0.004, height: CGFloat(len))
            cyl.materials = [mat]
            let n = SCNNode(geometry: cyl)
            n.simdPosition = (a + b) / 2
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
            node.addChildNode(n)
        }
        return node
    }

}
