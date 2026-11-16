//
//  ScanWorld.swift
//  SecureScan
//
//  The scan engines' camera plumbing, shared by the classic RoomCaptureView
//  screen and the live screen: RoomPlan's room (live or finished) as a
//  CaptureWorld, the per-frame aim sample, the ARKit projector, and a tap's
//  CaptureShot (pose, centre raycast, photo task).
//

import Foundation
import ARKit
import RoomPlan
import CoreImage
import simd

enum ScanWorld {
    /// A CapturedRoom in its session's world space: wall lines, the room outline, the floor height.
    static func from(_ room: CapturedRoom, name: String, idPrefix: String) -> (walls: [WorldWall], room: WorldRoom?, floorY: Double?) {
        var walls: [WorldWall] = []
        var bases: [Double] = []
        for (i, w) in room.walls.enumerated() {
            let t = w.transform
            let c = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
            let x = SIMD3<Double>(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z))
            let half = Double(w.dimensions.x) / 2
            let h = Double(w.dimensions.y)
            walls.append(WorldWall(id: "\(idPrefix)w\(i)", a: PlanVec(c.x - x.x * half, c.z - x.z * half),
                                   b: PlanVec(c.x + x.x * half, c.z + x.z * half), height: h))
            bases.append(c.y - h / 2)
        }
        var floorY: Double? = bases.isEmpty ? nil : bases.sorted()[bases.count / 2]
        if let f = room.floors.first {
            floorY = Double(f.transform.columns.3.y)
        }
        let pts = walls.flatMap { [$0.a, $0.b] }
        let hull = PlanBuilder.convexHull(pts)
        return (walls, hull.count >= 3 ? WorldRoom(name: name, polygon: hull) : nil, floorY)
    }

    /// Every wall, door, window, opening and object found so far (for the new-structure tick).
    static func structureIds(_ room: CapturedRoom) -> [String] {
        let surfaces = room.walls + room.doors + room.windows + room.openings
        return surfaces.map { $0.identifier.uuidString } + room.objects.map { $0.identifier.uuidString }
    }

    static func sectionLabels(_ room: CapturedRoom) -> [String] {
        room.sections.map { RoomPlanAdapter.label($0.label) }
    }

    /// Camera pose + centre raycast for the aim.
    static func aimSample(_ session: ARSession?) -> AimSample? {
        guard let session, let frame = session.currentFrame else { return nil }
        let t = frame.camera.transform
        let cam = WorldVec(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        let fwd = -WorldVec(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))
        let (hit, normal, _) = ScanViewController.centreRaycast(session: session, frame: frame)
        var tracking = false
        if case .normal = frame.camera.trackingState { tracking = true }
        return AimSample(camera: cam, forward: fwd, hit: hit.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) },
                         normal: normal.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) }, tracking: tracking)
    }

    static func projector(_ session: ARSession?, viewport: CGSize) -> Projector? {
        guard let frame = session?.currentFrame, viewport.width > 0 else { return nil }
        return ARCameraProjector(camera: frame.camera, viewport: viewport)
    }

    /// The 3D layer's camera: the same view and projection ARKit uses for this viewport.
    static func camera3D(_ session: ARSession?, viewport: CGSize) -> Camera3D? {
        guard let frame = session?.currentFrame, viewport.width > 0, viewport.height > 0 else { return nil }
        let c = frame.camera
        return Camera3D(view: c.viewMatrix(for: .portrait),
                        projection: c.projectionMatrix(for: .portrait, viewportSize: viewport, zNear: 0.01, zFar: 60))
    }

    /// A tap: pose, raycast, and (optionally) the photo task.
    @MainActor
    static func shot(_ session: ARSession?, prefix: String, photo: Bool) -> CaptureShot? {
        guard let session, let frame = session.currentFrame else { return nil }
        let t = frame.camera.transform
        let cam = WorldVec(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        let fwd = -WorldVec(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))
        let (hit, normal, kind) = ScanViewController.centreRaycast(session: session, frame: frame)
        let image: CIImage? = photo ? CIImage(cvPixelBuffer: frame.capturedImage) : nil
        return CaptureShot(id: CaptureIDs.new(prefix), takenAt: PlanDocument.iso(Date()), camera: cam, forward: fwd,
                           hit: hit.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) },
                           normal: normal.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) }, hitKind: kind,
                           photo: photo ? PhotoCapture.task(session: session, frameImage: image) : nil)
    }

    /// RoomPlan's coaching, in a few plain words.
    static func coaching(_ instruction: RoomCaptureSession.Instruction) -> String? {
        let name = String(describing: instruction)
        if name.contains("moveCloseToWall") { return "Move closer to the wall" }
        if name.contains("moveAwayFromWall") { return "Step back from the wall" }
        if name.contains("slowDown") { return "Slow down" }
        if name.contains("turnOnLight") { return "More light needed" }
        if name.contains("lowTexture") { return "Point at walls with more detail" }
        return nil
    }
}
