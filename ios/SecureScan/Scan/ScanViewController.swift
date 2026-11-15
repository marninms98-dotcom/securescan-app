//
//  ScanViewController.swift
//  SecureScan
//
//  Hosts RoomPlan's RoomCaptureView. Rooms are finished with
//  captureSession.stop(pauseARSession: false) so the ARSession - and its world
//  origin - keeps running, which keeps the rooms aligned for StructureBuilder
//  and keeps "Log" usable between rooms.
//
//  RoomCaptureViewDelegate inherits NSCoding; UIViewController already
//  provides init?(coder:) and encode(with:), which satisfies it.
//

import UIKit
import ARKit
import RoomPlan
import CoreImage

/// Everything captured in the instant "Log" is tapped.
struct FrameCapture {
    var cameraPosition: SIMD3<Float>
    var cameraForward: SIMD3<Float>
    var hit: SIMD3<Float>?
    var hitKind: String?
    var image: CIImage?             // nil once handed to the JPEG encoder
    /// Surface normal at the hit (the raycast result's y axis), for the live same-wall check.
    var hitNormal: SIMD3<Float>? = nil
}

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

final class ScanViewController: UIViewController, RoomCaptureViewDelegate {

    weak var model: ScanModel?
    private var roomCaptureView: RoomCaptureView?
    private var started = false
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
        view.addSubview(v)
        roomCaptureView = v
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            startRoom()
        }
    }

    /// RoomPlan's own ARSession. It keeps running between rooms
    /// (stop(pauseARSession: false)), so the AR mark-up can draw on it.
    var arSession: ARSession? { roomCaptureView?.captureSession.arSession }

    // MARK: Commands from ScanModel

    func startRoom() {
        roomCaptureView?.captureSession.run(configuration: configuration)
    }

    /// Finish the current room but keep the AR session (and world origin) alive.
    func finishRoom() {
        roomCaptureView?.captureSession.stop(pauseARSession: false)
    }

    /// Stop everything (leaving the screen).
    func shutdown() {
        roomCaptureView?.captureSession.stop()
    }

    /// Grabs camera pose, a centre-screen raycast and the camera frame.
    func captureFrame() -> FrameCapture? {
        guard let session = roomCaptureView?.captureSession.arSession,
              let frame = session.currentFrame else { return nil }
        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // ARKit cameras look down their local -Z axis.
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)

        let (hit, normal, hitKind) = Self.centreRaycast(session: session, frame: frame)
        // CIImage keeps a reference to the pixel buffer, not the ARFrame.
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        return FrameCapture(cameraPosition: position, cameraForward: forward, hit: hit, hitKind: hitKind,
                            image: image, hitNormal: normal)
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
    /// up after `timeout` seconds; never throws. Must be called while the
    /// AR session is still running.
    func saveWorldMap(to url: URL, timeout: Double = 4) async -> Bool {
        guard let session = roomCaptureView?.captureSession.arSession else { return false }
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

    // MARK: RoomCaptureViewDelegate

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true   // let RoomPlan process and present the room
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor [weak self] in
            self?.model?.roomProcessed(processedResult, error: error)
        }
    }
}

/// Camera frame -> portrait JPEG, max 1280 px long edge, quality 0.7.
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
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}
