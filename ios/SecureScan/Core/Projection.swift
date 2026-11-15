//
//  Projection.swift
//  SecureScan
//
//  World space -> screen space for the capture overlay (UX2 "OverlayRenderer").
//  Every mark is drawn as a 2D vector, projected from world space each frame,
//  so it looks the same over RoomCaptureView, our own ARSCNView and the
//  Studio harness. Lines and polygons are clipped against the near plane in
//  camera space BEFORE projection (a point behind the camera has no sensible
//  screen position).
//
//  Conventions: world y up, metres. Camera space: x right, y up, z = depth in
//  front of the camera (positive = in front). Screen: points, origin top-left,
//  y down. Foundation + simd only - unit tested.
//

import Foundation
import simd

typealias ScreenVec = SIMD2<Double>

/// Anything that can place a world point on the screen: ARKit's camera on a
/// phone (ARCameraProjector, in the app) or a pure pinhole (tests, Studio).
protocol Projector {
    /// The viewport in points (width, height).
    var viewport: ScreenVec { get }
    var cameraPosition: WorldVec { get }
    /// World -> camera space (x right, y up, z forward depth).
    func view(_ w: WorldVec) -> WorldVec
    /// Screen point of a world point that is in front of the camera.
    func screen(_ w: WorldVec) -> ScreenVec
}

extension Projector {
    /// Near plane (metres): anything closer is clipped away.
    var near: Double { 0.05 }

    func depth(_ w: WorldVec) -> Double { view(w).z }

    /// nil when the point is behind (or too close to) the camera.
    func project(_ w: WorldVec) -> ScreenVec? { depth(w) > near ? screen(w) : nil }

    /// A segment clipped to the near plane, projected; nil if wholly behind.
    func projectSegment(_ a: WorldVec, _ b: WorldVec) -> (ScreenVec, ScreenVec)? {
        guard let c = Clip.segment(a, b, near: near, depth: { self.depth($0) }) else { return nil }
        return (screen(c.0), screen(c.1))
    }

    /// A closed polygon clipped to the near plane, projected (empty if wholly behind).
    func projectPolygon(_ p: [WorldVec]) -> [ScreenVec] {
        Clip.polygon(p, near: near, depth: { self.depth($0) }).map { screen($0) }
    }

    /// An open polyline clipped to the near plane: the visible runs, projected.
    func projectPolyline(_ p: [WorldVec]) -> [[ScreenVec]] {
        Clip.polyline(p, near: near, depth: { self.depth($0) }).map { $0.map { screen($0) } }
    }

    /// True when `s` is inside the viewport, `inset` points in from every edge.
    func onScreen(_ s: ScreenVec, inset: Double = 0) -> Bool {
        s.x >= inset && s.y >= inset && s.x <= viewport.x - inset && s.y <= viewport.y - inset
    }

    /// For an item that is off screen or behind: the unit screen direction from
    /// the centre towards it (x right, y down), for an edge arrow.
    func offscreenDirection(_ w: WorldVec) -> ScreenVec {
        let v = view(w)
        var d = ScreenVec(v.x, -v.y)
        if v.z > near, let s = project(w) { d = s - viewport / 2 }
        let len = simd_length(d)
        return len > 1e-9 ? d / len : ScreenVec(0, -1)
    }
}

/// A plain pinhole camera: the Studio's SCNView camera and the tests.
/// `fovY` is the vertical field of view (SceneKit's default projection direction).
struct PinholeProjector: Projector {
    var cameraPosition: WorldVec
    var right: WorldVec
    var up: WorldVec
    var forward: WorldVec
    var fovYDegrees: Double
    var viewport: ScreenVec

    /// Camera at `position` looking at `target`, `worldUp` keeping it level.
    init(position: WorldVec, lookAt target: WorldVec, worldUp: WorldVec = WorldVec(0, 1, 0),
         fovYDegrees: Double, viewport: ScreenVec) {
        cameraPosition = position
        let f = simd_normalize(target - position)
        var r = simd_cross(f, worldUp)
        if simd_length(r) < 1e-9 { r = WorldVec(1, 0, 0) }
        r = simd_normalize(r)
        forward = f
        right = r
        up = simd_cross(r, f)
        self.fovYDegrees = fovYDegrees
        self.viewport = viewport
    }

    /// Focal length in points.
    var focal: Double { (viewport.y / 2) / tan(fovYDegrees * .pi / 360) }

    func view(_ w: WorldVec) -> WorldVec {
        let v = w - cameraPosition
        return WorldVec(simd_dot(v, right), simd_dot(v, up), simd_dot(v, forward))
    }

    func screen(_ w: WorldVec) -> ScreenVec {
        let c = view(w)
        let z = max(c.z, 1e-9)
        return ScreenVec(viewport.x / 2 + c.x / z * focal, viewport.y / 2 - c.y / z * focal)
    }

    /// The world ray through a screen point (for the Studio's synthetic raycast).
    func ray(through s: ScreenVec) -> WorldVec {
        let x = (s.x - viewport.x / 2) / focal, y = -(s.y - viewport.y / 2) / focal
        return simd_normalize(forward + right * x + up * y)
    }
}

/// Near-plane clipping in camera depth (depth is affine in world space for a
/// pinhole, so interpolating world points by depth is exact).
enum Clip {
    static func lerp(_ a: WorldVec, _ b: WorldVec, _ t: Double) -> WorldVec { a + (b - a) * t }

    /// The part of a->b with depth >= near; nil if none.
    static func segment(_ a: WorldVec, _ b: WorldVec, near: Double, depth: (WorldVec) -> Double) -> (WorldVec, WorldVec)? {
        let da = depth(a), db = depth(b)
        if da >= near && db >= near { return (a, b) }
        if da < near && db < near { return nil }
        let t = (near - da) / (db - da)
        let p = lerp(a, b, t)
        return da < near ? (p, b) : (a, p)
    }

    /// Sutherland-Hodgman against the near plane. Closed polygon in, closed polygon out.
    static func polygon(_ p: [WorldVec], near: Double, depth: (WorldVec) -> Double) -> [WorldVec] {
        guard p.count >= 2 else { return p.filter { depth($0) >= near } }
        var out: [WorldVec] = []
        for i in p.indices {
            let cur = p[i], prev = p[(i + p.count - 1) % p.count]
            let dc = depth(cur), dp = depth(prev)
            let curIn = dc >= near, prevIn = dp >= near
            if curIn {
                if !prevIn { out.append(lerp(prev, cur, (near - dp) / (dc - dp))) }
                out.append(cur)
            } else if prevIn {
                out.append(lerp(prev, cur, (near - dp) / (dc - dp)))
            }
        }
        return out
    }

    /// An open polyline cut into the runs in front of the near plane.
    static func polyline(_ p: [WorldVec], near: Double, depth: (WorldVec) -> Double) -> [[WorldVec]] {
        guard p.count >= 2 else { return p.filter { depth($0) >= near }.map { [$0] } }
        var runs: [[WorldVec]] = []
        var run: [WorldVec] = []
        for i in 1..<p.count {
            guard let s = segment(p[i - 1], p[i], near: near, depth: depth) else {
                if !run.isEmpty { runs.append(run); run = [] }
                continue
            }
            if run.isEmpty { run = [s.0, s.1] }
            else if simd_distance(run[run.count - 1], s.0) < 1e-9 { run.append(s.1) }
            else { runs.append(run); run = [s.0, s.1] }
            if s.1 != p[i] { runs.append(run); run = [] }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }
}
