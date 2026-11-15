//
//  LiveScanViewController.swift
//  SecureScan
//
//  "Mark while scanning" (new, behind a switch): RoomPlan's RoomCaptureSession
//  runs on OUR ARSession (RoomCaptureSession(arSession:), iOS 17) and the
//  camera is our own ARSCNView on that same session, so the reticle, the
//  pins and the room being found share one world. No RoomCaptureView.
//    * the room as found (captureSession(_:didUpdate:)): translucent wall
//      quads with bright edges, door and window outlines;
//    * every logged item as it is saved (readings coloured by value);
//    * live previews: a removal band to the crosshair, floor corners;
//    * 10 times a second: what the reticle is on, its height, tracking.
//  Rooms end with stop(pauseARSession: false) and RoomBuilder, then go to
//  ScanModel.roomProcessed exactly like the classic screen.
//  Never run on a device yet - kept conventional and defensive.
//

import UIKit
import ARKit
import RoomPlan
import SceneKit
import CoreImage

/// What the live screen shows over the camera (set by the controller).
@MainActor
final class LiveScanState: ObservableObject {
    @Published var reticle = ""
    @Published var blocked: String? = "Starting the camera…"
    @Published var coaching: String?
    @Published var preview: String?
    /// No walls found a while after a room started, or the session failed.
    @Published var stalled = false
    @Published var undoVisible = false
    /// The reading material the reticle suggests (floor / ceiling / cabinetry), nil = keep.
    var suggestedMaterial: String?
    /// The live wall under the reticle (ends at the reticle's height), for "Whole wall".
    var wallEnds: (WorldVec, WorldVec)?
    @Published var onWall = false
    var reticleY: Double?
    var floorY: Double?
    /// Snap taps to wall ends (wall strip-outs and moisture lines).
    var snapEnds = false
    var lastWallMaterial = "wall"
    private var undo = UndoWindow()

    func saved() {
        undo.saved(at: Date())
        undoVisible = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_100_000_000)
            guard let self else { return }
            self.undoVisible = self.undo.visible(at: Date())
        }
    }

    func undoUsed() {
        undo.used()
        undoVisible = false
    }
}

final class LiveScanViewController: UIViewController, ScanCaptureControlling, RoomCaptureSessionDelegate {

    weak var model: ScanModel?
    weak var live: LiveScanState?
    private let sceneView = ARSCNView(frame: .zero)
    private let session = ARSession()
    private var capture: RoomCaptureSession?
    private let roomNode = SCNNode()
    private let itemsNode = SCNNode()
    private let previewNode = SCNNode()
    private var timer: Timer?
    private var started = false
    private var lastRoom: CapturedRoom?
    private var floorY: Double?
    private var drawnCount = -1
    private var roomStartedAt = Date()
    private var sawWalls = false
    /// Set by shutdown(): a room that ends because the screen is going away is not reported.
    private var shutDown = false

    var arSession: ARSession? { session }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session = session
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene.rootNode.addChildNode(roomNode)
        sceneView.scene.rootNode.addChildNode(itemsNode)
        sceneView.scene.rootNode.addChildNode(previewNode)
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    // MARK: ScanCaptureControlling

    func startRoom() {
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = true
        capture?.run(configuration: config)
        roomStartedAt = Date()
        sawWalls = false
        live?.stalled = false
        roomNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    func finishRoom() {
        capture?.stop(pauseARSession: false)
    }

    func shutdown() {
        shutDown = true
        timer?.invalidate()
        timer = nil
        capture?.stop()
        session.pause()
    }

    func captureFrame() -> FrameCapture? {
        guard let frame = session.currentFrame else { return nil }
        let t = frame.camera.transform
        let (rawHit, normal, kind) = ScanViewController.centreRaycast(session: session, frame: frame)
        let cam = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var hit = rawHit
        // Wall strip-outs and moisture lines: a tap within 15 cm of a wall's end lands on it.
        if live?.snapEnds == true, let h = rawHit {
            let w = WorldVec(Double(h.x), Double(h.y), Double(h.z))
            if let near = nearestWall(w), near.distance <= 0.25 {
                let s = WallEndSnap.snapPoint(w, wallA: near.a, wallB: near.b)
                if s != w {
                    hit = SIMD3<Float>(s)
                    let v = SIMD3<Float>(s) - cam
                    if simd_length(v) > 1e-6 { forward = simd_normalize(v) }
                }
            }
        }
        return FrameCapture(cameraPosition: cam, cameraForward: forward,
                            hit: hit, hitKind: kind, image: CIImage(cvPixelBuffer: frame.capturedImage), hitNormal: normal)
    }

    func saveWorldMap(to url: URL, timeout: Double) async -> Bool {
        let session = self.session
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
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

    // MARK: RoomCaptureSessionDelegate (all optional; called off the main thread)

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in self?.roomUpdated(room) }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        // Matched by name, so a renamed case can't break the build.
        let name = String(describing: instruction)
        let text: String?
        if name.contains("moveCloseToWall") { text = "Move closer to the wall" }
        else if name.contains("moveAwayFromWall") { text = "Step back from the wall" }
        else if name.contains("slowDown") { text = "Slow down" }
        else if name.contains("turnOnLight") { text = "More light needed" }
        else if name.contains("lowTexture") { text = "Point at walls with more detail" }
        else { text = nil }
        Task { @MainActor [weak self] in self?.live?.coaching = text }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, !self.shutDown else { return }
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                self.model?.roomProcessed(room, error: nil)
            } catch {
                if let last = self.lastRoom, !last.walls.isEmpty {
                    // The tidy-up failed: keep the room as it was last seen.
                    self.model?.roomProcessed(last, error: nil)
                } else {
                    self.model?.liveRoomFailed("That room didn't save (\(error.localizedDescription)). Rooms already saved are kept.")
                    self.live?.stalled = true
                }
            }
            self.lastRoom = nil
        }
    }

    // MARK: The room as it is found

    private func roomUpdated(_ room: CapturedRoom) {
        lastRoom = room
        if !room.walls.isEmpty { sawWalls = true; live?.stalled = false }
        let bottoms = room.walls.map { Double($0.transform.columns.3.y) - Double($0.dimensions.y) / 2 }
        if let lowest = bottoms.min() { floorY = lowest }
        roomNode.childNodes.forEach { $0.removeFromParentNode() }
        let blue = UIColor(red: 0.30, green: 0.65, blue: 1.0, alpha: 1)
        for w in room.walls { roomNode.addChildNode(Self.surfaceNode(w, fill: blue.withAlphaComponent(0.18), edge: blue)) }
        for d in room.doors { roomNode.addChildNode(Self.surfaceNode(d, fill: nil, edge: .systemOrange, inset: 0.01)) }
        for w in room.windows { roomNode.addChildNode(Self.surfaceNode(w, fill: nil, edge: .systemTeal, inset: 0.01)) }
        for o in room.openings { roomNode.addChildNode(Self.surfaceNode(o, fill: nil, edge: .systemYellow, inset: 0.01)) }
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
            let cyl = SCNCylinder(radius: 0.008, height: CGFloat(len))
            cyl.materials = [mat]
            let n = SCNNode(geometry: cyl)
            n.simdPosition = (a + b) / 2
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
            node.addChildNode(n)
        }
        return node
    }

    /// The nearest live wall to a point (horizontal distance), with its two
    /// ends at the point's height - for "is this a wall or a cabinet",
    /// "Whole wall" and snapping taps to wall ends.
    private func nearestWall(_ p: WorldVec) -> (distance: Double, a: WorldVec, b: WorldVec)? {
        guard let room = lastRoom, !room.walls.isEmpty else { return nil }
        let q = PlanVec(p.x, p.z)
        var best: (distance: Double, a: WorldVec, b: WorldVec)? = nil
        for w in room.walls {
            let t = w.transform
            let c = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
            let x = SIMD3<Double>(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z)) * Double(w.dimensions.x) / 2
            let a = WorldVec(c.x - x.x, p.y, c.z - x.z), b = WorldVec(c.x + x.x, p.y, c.z + x.z)
            let d = PlanBuilder.distanceToSegment(q, PlanVec(a.x, a.z), PlanVec(b.x, b.z))
            if d < (best?.distance ?? .infinity) { best = (d, a, b) }
        }
        return best
    }

    private func distanceToWalls(_ p: WorldVec) -> Double? { nearestWall(p)?.distance }

    // MARK: Per frame (10 Hz)

    private func tick() {
        guard let frame = session.currentFrame, let model, let live else { return }
        let tracking: Bool
        if case .normal = frame.camera.trackingState { tracking = true } else { tracking = false }
        let (hit, normal, _) = ScanViewController.centreRaycast(session: session, frame: frame)
        let world = hit.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) }
        let camY = Double(frame.camera.transform.columns.3.y)
        let fy = floorY ?? (camY - 1.4)
        var text = ""
        var suggestion: String? = nil
        if let w = world {
            let ny = normal.map { Double(simd_normalize($0).y) } ?? 0
            let s = Reticle.surface(normalY: ny, height: w.y - fy, distanceToWall: ny.magnitude < 0.7 ? distanceToWalls(w) : nil)
            text = Reticle.describe(s, height: w.y - fy, room: "Room \(model.currentRoomNumber)")
            suggestion = Reticle.material(s)
            let near = s == .wall ? nearestWall(w) : nil
            live.wallEnds = near.flatMap { n -> (WorldVec, WorldVec)? in n.distance <= 0.25 ? (n.a, n.b) : nil }
            live.reticleY = w.y
        } else {
            live.wallEnds = nil
        }
        live.floorY = fy
        let onWall = live.wallEnds != nil
        if live.onWall != onWall { live.onWall = onWall }
        if live.reticle != text { live.reticle = text }
        live.suggestedMaterial = suggestion
        let blocked = Reticle.blocked(trackingNormal: tracking, hasHit: world != nil, needsWall: false)
        if live.blocked != blocked { live.blocked = blocked }
        if !sawWalls, model.phase == .scanning, Date().timeIntervalSince(roomStartedAt) > 25, !live.stalled { live.stalled = true }

        // Logged items: redraw when the count changes; a tick of haptics on each new one.
        if model.totalCount != drawnCount {
            if drawnCount >= 0 && model.totalCount > drawnCount {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                live.saved()
            }
            drawnCount = model.totalCount
            drawItems(model.raw)
        }
        drawPreview(model: model, crosshair: world, floorY: fy)
    }

    private func drawItems(_ raw: [RawReading]) {
        itemsNode.childNodes.forEach { $0.removeFromParentNode() }
        var n = 0
        for r in raw.sorted(by: { $0.seq < $1.seq }) {
            guard let h = r.hit, h.count == 3 else { continue }
            let p = SIMD3<Float>(Float(h[0]), Float(h[1]), Float(h[2]))
            let colour: UIColor
            var label: String? = nil
            let geometry: SCNGeometry
            switch r.kind {
            case "reading":
                n += 1
                let st = ReadingColour.status(r.value, reference: r.reference)
                colour = st == "wet" ? UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 1)
                    : st == "elevated" ? UIColor(red: 0.93, green: 0.60, blue: 0.10, alpha: 1)
                    : UIColor(red: 0.18, green: 0.62, blue: 0.33, alpha: 1)
                label = r.value.map { "\(n) · \(ScanModel.format($0))%" } ?? "\(n)"
                geometry = SCNSphere(radius: 0.035)
            case "boundary":
                colour = ModelViewModel.lineBlue
                geometry = SCNBox(width: 0.03, height: 0.03, length: 0.03, chamferRadius: 0.004)
            case "equipment":
                colour = UIColor(red: 0.20, green: 0.45, blue: 0.50, alpha: 0.85)
                geometry = SCNBox(width: 0.3, height: 0.3, length: 0.3, chamferRadius: 0.03)
                label = PlanDocument.equipmentName(r.material)
            case "removal":
                colour = UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.9)
                geometry = SCNBox(width: 0.05, height: 0.05, length: 0.05, chamferRadius: 0)
                label = RemovalItems.name(r.material)
            case "source":
                colour = ModelViewModel.lineBlue
                geometry = SCNSphere(radius: 0.045)
                label = "Source"
            default:
                colour = .systemGray
                geometry = SCNSphere(radius: 0.03)
            }
            geometry.materials = [Self.overlay(colour)]
            let node = SCNNode(geometry: geometry)
            node.simdPosition = p
            if let label, let image = ModelViewModel.labelImage(label, accent: colour) {
                let hgt: CGFloat = 0.06
                let plane = SCNPlane(width: hgt * image.size.width / image.size.height, height: hgt)
                let m = Self.overlay(.white)
                m.diffuse.contents = image
                plane.materials = [m]
                let l = SCNNode(geometry: plane)
                l.position = SCNVector3(0, 0.09, 0)
                let face = SCNNode()
                face.constraints = [SCNBillboardConstraint()]
                face.addChildNode(l)
                node.addChildNode(face)
            }
            itemsNode.addChildNode(node)
        }
    }

    /// A removal band growing to the crosshair (with its length), or the
    /// floor section growing corner by corner (with its area).
    private func drawPreview(model: ScanModel, crosshair: WorldVec?, floorY: Double) {
        previewNode.childNodes.forEach { $0.removeFromParentNode() }
        let flow = model.flow
        var text: String? = nil
        let red = UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 1)
        if flow.mode == .wallEnd, let s = flow.start?.capture.hit, let c = crosshair {
            let a = WorldVec(Double(s.x), Double(s.y), Double(s.z))
            let top = Double(RemovalItems.defaultMm(flow.item)) / 1000
            let quad = [WorldVec(a.x, floorY, a.z), WorldVec(c.x, floorY, c.z), WorldVec(c.x, floorY + top, c.z), WorldVec(a.x, floorY + top, a.z)]
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: quad.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) })],
                                elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
            g.materials = [Self.overlay(red.withAlphaComponent(0.35))]
            previewNode.addChildNode(SCNNode(geometry: g))
            text = Readout.lengthText(Readout.length([a, c]))
        } else if flow.mode == .floorCorners {
            var pts: [WorldVec] = flow.corners.compactMap { c in c.hit.map { h in WorldVec(Double(h.x), floorY + 0.015, Double(h.z)) } }
            if let c = crosshair { pts.append(WorldVec(c.x, floorY + 0.015, c.z)) }
            let mat = Self.overlay(red)
            for i in pts.indices where i > 0 || pts.count >= 3 {
                let a = pts[i == 0 ? pts.count - 1 : i - 1], b = pts[i]
                let len = simd_length(b - a)
                guard len > 0.01 else { continue }
                let cyl = SCNCylinder(radius: 0.008, height: CGFloat(len))
                cyl.materials = [mat]
                let nd = SCNNode(geometry: cyl)
                nd.simdPosition = SIMD3<Float>((a + b) / 2)
                nd.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: SIMD3<Float>(simd_normalize(b - a)))
                previewNode.addChildNode(nd)
            }
            text = pts.count >= 3 ? Readout.areaText(pts) : "\(flow.cornerCount) corner\(flow.cornerCount == 1 ? "" : "s")"
        }
        if live?.preview != text { live?.preview = text }
    }
}
