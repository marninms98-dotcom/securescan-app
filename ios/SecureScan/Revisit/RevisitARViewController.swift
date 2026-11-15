//
//  RevisitARViewController.swift
//  SecureScan
//
//  The camera for return visits and "See scope on site": an ARSCNView on our
//  own world-tracking session (relocalising onto the first scan's world map
//  when there is one). It draws only the saved plan's wall outline while the
//  user checks the alignment; every mark is drawn by the shared capture
//  overlay (CaptureScreen). It feeds RevisitModel the pose and tracking state.
//

import UIKit
import ARKit
import SceneKit
import CoreImage

final class RevisitARViewController: UIViewController, ARSCNViewDelegate {

    weak var model: RevisitModel?
    private let sceneView = ARSCNView(frame: .zero)
    private let outlineNode = SCNNode()
    private var timer: Timer?
    private var started = false
    private var lastTracking: TrackingStatus?

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene.rootNode.addChildNode(outlineNode)
        view.addSubview(sceneView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        restart(worldMap: model?.start == .corners ? nil : loadWorldMap())
        model?.arStarted()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        detach()
    }

    /// Stops the camera. Safe to call twice.
    func detach() {
        timer?.invalidate()
        timer = nil
        sceneView.session.pause()
    }

    private func loadWorldMap() -> ARWorldMap? {
        guard let folder = model?.folder, model?.hasWorldMap == true,
              let data = try? Data(contentsOf: folder.worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    private func configuration(worldMap: ARWorldMap?) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        config.initialWorldMap = worldMap
        return config
    }

    /// (Re)starts the session; with a world map ARKit tries to relocalise onto it.
    func restart(worldMap: ARWorldMap?) {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        sceneView.session.run(configuration(worldMap: worldMap), options: [.resetTracking, .removeExistingAnchors])
        clearOutline()
    }

    /// 0.5x hand-off: the camera goes to AVFoundation for one photo, then back (tracking kept).
    func pauseForHandoff() { sceneView.session.pause() }

    func resumeAfterHandoff() {
        guard let c = sceneView.session.configuration else { return }
        sceneView.session.run(c, options: [])
    }

    // MARK: Camera for the capture screen

    func aimSample() -> AimSample? { ScanWorld.aimSample(sceneView.session) }

    func projector(viewport: CGSize) -> Projector? { ScanWorld.projector(sceneView.session, viewport: viewport) }

    func shot(photo: Bool) -> CaptureShot? { ScanWorld.shot(sceneView.session, prefix: "rv-", photo: photo) }

    // MARK: The alignment check: the saved walls on the floor

    func showOutline(walls: [PlanWall], alignment: PlanTransform, floorY: Double) {
        clearOutline()
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        let accent = SCNMaterial()
        accent.diffuse.contents = UIColor(red: 0.12, green: 0.44, blue: 0.92, alpha: 1)
        accent.lightingModel = .constant
        accent.readsFromDepthBuffer = false
        for w in walls {
            let a = alignment.world(w.a, y: floorY + 0.01), b = alignment.world(w.b, y: floorY + 0.01)
            if let n = Self.bar(from: a, to: b, radius: 0.016, material: mat) { outlineNode.addChildNode(n) }
            if let n = Self.bar(from: a, to: b, radius: 0.010, material: accent) { outlineNode.addChildNode(n) }
        }
    }

    func clearOutline() {
        outlineNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    static func bar(from a: WorldVec, to b: WorldVec, radius: CGFloat, material: SCNMaterial) -> SCNNode? {
        let v = b - a
        let len = simd_length(v)
        guard len > 0.01 else { return nil }
        let cyl = SCNCylinder(radius: radius, height: CGFloat(len))
        cyl.materials = [material]
        let n = SCNNode(geometry: cyl)
        n.simdPosition = SIMD3<Float>((a + b) / 2)
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: SIMD3<Float>(simd_normalize(v)))
        n.renderingOrder = 10
        return n
    }

    // MARK: Per-frame (10 Hz)

    private func tick() {
        guard let frame = sceneView.session.currentFrame else { return }
        let t = frame.camera.transform
        let cam = WorldVec(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        let fwd = -WorldVec(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))
        model?.aim(camera: cam, forward: fwd)
        let status = Self.status(frame.camera.trackingState)
        if status != lastTracking {
            lastTracking = status
            model?.trackingChanged(status)
        }
    }

    // MARK: ARSCNViewDelegate / ARSessionObserver

    nonisolated static func status(_ state: ARCamera.TrackingState) -> TrackingStatus {
        switch state {
        case .normal: return .normal
        case .notAvailable: return .notAvailable
        case .limited(let reason):
            switch reason {
            case .relocalizing: return .relocalizing
            case .initializing: return .limited("starting up")
            case .excessiveMotion: return .limited("moving too fast")
            case .insufficientFeatures: return .limited("point at something with detail")
            @unknown default: return .limited("move slowly")
            }
        @unknown default:
            return .notAvailable
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let status = Self.status(camera.trackingState)
        Task { @MainActor [weak self] in
            self?.lastTracking = status
            self?.model?.trackingChanged(status)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.model?.trackingChanged(.limited("camera interrupted")) }
    }
}
