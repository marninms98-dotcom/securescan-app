//
//  Alignment.swift
//  SecureScan
//
//  Return visits: line up a NEW AR session with the saved plan.
//
//  A new ARKit session has its own world origin. The plan was built in the
//  first scan's world frame, mapped to plan space by a PlanTransform
//  (rotation about the vertical + translation; plan-frame.json). Here the user
//  points at two (or more) wall corners of the saved plan; their raycast hits
//  in the new session give world points, and a rigid 2D fit (no scale)
//  produces a new PlanTransform for this session, plus the floor height.
//
//  Pure maths, simd only - unit tested with rotated / offset / noisy points.
//

import Foundation
import simd

enum Alignment {

    /// Plan distance A-B vs measured distance A-B above this (metres) is
    /// reported, and the user is offered to redo or add a corner.
    static let distanceTolerance = 0.08
    /// Corners closer than this cannot define a direction.
    static let minSeparation = 0.5

    struct Fit {
        /// World (x, z) -> plan (x, y) for THIS session; y = floor height.
        var transform: PlanTransform
        var floorY: Double
        /// Distance of each mapped corner from its plan corner (metres).
        var residuals: [Double]
        var rms: Double { residuals.isEmpty ? 0 : (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot() }
        var maxResidual: Double { residuals.max() ?? 0 }
        /// Measured (world) distance between the first two corners minus the plan distance.
        var distanceError: Double
        var ok: Bool { abs(distanceError) <= Alignment.distanceTolerance && maxResidual <= Alignment.distanceTolerance }
    }

    enum Problem: Error, Equatable {
        case tooClose                  // corners too near each other / coincident
        case countMismatch
        case swapped([Int])            // a different order of the plan corners fits far better
        case mirrored                  // only a mirror image fits: the plan corners are probably the wrong way round
    }

    /// Least-squares rigid fit (rotation about the vertical + translation, no
    /// scale) of world points onto plan points. `world` are raycast hits in the
    /// new session (x, y, z); `plan` the matching plan corners. Two points give
    /// an exact rotation; more points are averaged (2D Kabsch).
    static func fit(world: [WorldVec], plan: [PlanVec]) -> Result<Fit, Problem> {
        guard world.count == plan.count, world.count >= 2 else { return .failure(.countMismatch) }
        let w2 = world.map { PlanVec($0.x, $0.z) }
        guard maxSpread(w2) >= minSeparation, maxSpread(plan) >= minSeparation else { return .failure(.tooClose) }
        let cw = w2.reduce(PlanVec.zero, +) / Double(w2.count)
        let cp = plan.reduce(PlanVec.zero, +) / Double(plan.count)
        var sDot = 0.0, sCross = 0.0
        for (w, p) in zip(w2, plan) {
            let a = w - cw, b = p - cp
            sDot += simd_dot(a, b)
            sCross += cross2(a, b)
        }
        let angle = atan2(sCross, sDot)
        let rot = PlanTransform(angle: angle, offset: .zero)
        let offset = cp - rot.rotate(cw)
        let t = PlanTransform(angle: angle, offset: offset)
        let residuals = zip(w2, plan).map { simd_distance(t.rotate($0.0) + offset, $0.1) }
        let floorY = world.map(\.y).reduce(0, +) / Double(world.count)
        let measured = simd_distance(w2[0], w2[1]), planned = simd_distance(plan[0], plan[1])
        return .success(Fit(transform: t, floorY: floorY, residuals: residuals, distanceError: measured - planned))
    }

    /// With three or more corners: if the fit is poor, check whether the
    /// corners were tapped in a different order, or only fit as a mirror
    /// image. Returns nil when the given order is fine (or nothing better fits).
    static func diagnose(world: [WorldVec], plan: [PlanVec]) -> Problem? {
        guard world.count >= 3, world.count == plan.count, world.count <= 5 else { return nil }
        guard case .success(let base) = fit(world: world, plan: plan), base.maxResidual > distanceTolerance else { return nil }
        var best: (perm: [Int], rms: Double)? = nil
        for perm in permutations(Array(0..<plan.count)) where perm != Array(0..<plan.count) {
            if case .success(let f) = fit(world: world, plan: perm.map { plan[$0] }), f.maxResidual <= distanceTolerance,
               f.rms < (best?.rms ?? .infinity) {
                best = (perm, f.rms)
            }
        }
        if let b = best { return .swapped(b.perm) }
        let mirroredWorld = world.map { WorldVec(-$0.x, $0.y, $0.z) }
        if case .success(let m) = fit(world: mirroredWorld, plan: plan), m.maxResidual <= distanceTolerance { return .mirrored }
        return nil
    }

    /// Floor height from corner hits that may land a little up the wall:
    /// the lowest hit, but never more than 0.3 m below the average.
    static func floorHeight(_ hits: [WorldVec]) -> Double? {
        guard !hits.isEmpty else { return nil }
        let avg = hits.map(\.y).reduce(0, +) / Double(hits.count)
        let low = hits.map(\.y).min()!
        return max(low, avg - 0.3)
    }

    static func maxSpread(_ p: [PlanVec]) -> Double {
        var m = 0.0
        for i in p.indices { for j in p.indices where j > i { m = max(m, simd_distance(p[i], p[j])) } }
        return m
    }

    static func permutations(_ a: [Int]) -> [[Int]] {
        guard a.count > 1 else { return [a] }
        var out: [[Int]] = []
        for (i, x) in a.enumerated() {
            var rest = a
            rest.remove(at: i)
            for p in permutations(rest) { out.append([x] + p) }
        }
        return out
    }
}

/// Which wall corners to ask for.
enum Corners {
    /// Index of the room polygon containing `p`, else the nearest room.
    static func room(at p: PlanVec, polygons: [[PlanVec]]) -> Int? {
        if let i = FloorArea.room(containing: p, rooms: polygons) { return i }
        var best: (Int, Double)? = nil
        for (i, poly) in polygons.enumerated() where poly.count >= 3 {
            let d = simd_distance(PlanBuilder.centroid(poly), p)
            if d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// The two corners of a room that are farthest apart (well-separated
    /// corners give the most accurate rotation). Indices into `polygon`.
    static func defaultPair(_ polygon: [PlanVec]) -> (Int, Int)? {
        guard polygon.count >= 2 else { return nil }
        var best: (Int, Int, Double)? = nil
        for i in polygon.indices { for j in polygon.indices where j > i {
            let d = simd_distance(polygon[i], polygon[j])
            if d > (best?.2 ?? -1) { best = (i, j, d) }
        } }
        return best.map { ($0.0, $0.1) }
    }

    /// The polygon corner nearest to a tap, within `maxDistance` metres.
    static func nearest(to p: PlanVec, in polygon: [PlanVec], maxDistance: Double = 0.8) -> Int? {
        var best: (Int, Double)? = nil
        for (i, c) in polygon.enumerated() {
            let d = simd_distance(c, p)
            if d <= maxDistance, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }
}

/// Live check while logging a removal with two taps: are both taps on the
/// same flat wall? Uses the raycast hits and their surface normals. Returns
/// nil when it cannot tell (no normals, or a floor / ceiling surface).
enum RemovalCheck {
    static func sameWall(startHit: WorldVec?, startNormal: WorldVec?, endHit: WorldVec?, endNormal: WorldVec?) -> Bool? {
        guard let s = startHit, let e = endHit, let ns = startNormal, let ne = endNormal else { return nil }
        let hs = PlanVec(ns.x, ns.z), he = PlanVec(ne.x, ne.z)
        // Only vertical surfaces (normal mostly horizontal) are judged.
        guard simd_length(hs) > 0.7 * simd_length(ns), simd_length(he) > 0.7 * simd_length(ne) else { return nil }
        let a = simd_normalize(hs), b = simd_normalize(he)
        if simd_dot(a, b) < cos(25 * Double.pi / 180) { return false }
        let off = abs(simd_dot(PlanVec(e.x - s.x, e.z - s.z), a))
        return off <= 0.2
    }
}

/// Floor sections (flooring removals, floor-type zones).
enum FloorArea {
    static let types = ["carpet", "timber", "laminate", "vinyl", "tile", "concrete", "other"]
    static let minArea = 0.1

    /// Even-odd point-in-polygon test.
    static func inside(_ p: PlanVec, _ poly: [PlanVec]) -> Bool {
        guard poly.count >= 3 else { return false }
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    static func area(_ poly: [PlanVec]) -> Double { abs(PlanBuilder.signedArea(poly)) }

    /// The room containing `p` (the smallest one if rooms overlap), or nil.
    static func room(containing p: PlanVec, rooms: [[PlanVec]]) -> Int? {
        var best: (Int, Double)? = nil
        for (i, poly) in rooms.enumerated() where inside(p, poly) {
            let a = area(poly)
            if a < (best?.1 ?? .infinity) { best = (i, a) }
        }
        return best?.0
    }

    /// True if any two non-adjacent edges cross.
    static func selfIntersects(_ poly: [PlanVec]) -> Bool {
        let n = poly.count
        guard n >= 4 else { return false }
        func cross(_ p1: PlanVec, _ p2: PlanVec, _ q1: PlanVec, _ q2: PlanVec) -> Bool {
            let d1 = cross2(p2 - p1, q1 - p1), d2 = cross2(p2 - p1, q2 - p1)
            let d3 = cross2(q2 - q1, p1 - q1), d4 = cross2(q2 - q1, p2 - q1)
            return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                if j == i + 1 || (i == 0 && j == n - 1) { continue }     // adjacent edges share a corner
                if cross(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n]) { return true }
            }
        }
        return false
    }

    /// Corner taps -> a floor section: repeated taps (< 5 cm apart) merged,
    /// at least 3 corners, edges must not cross, area at least 0.1 m².
    static func polygon(_ pts: [PlanVec]) -> Result<[PlanVec], RevisitError> {
        var clean: [PlanVec] = []
        for p in pts where p.x.isFinite && p.y.isFinite {
            if let last = clean.last, simd_distance(last, p) < 0.05 { continue }
            clean.append(p)
        }
        if clean.count > 1, let f = clean.first, let l = clean.last, simd_distance(f, l) < 0.05 { clean.removeLast() }
        guard clean.count >= 3 else { return .failure(RevisitError(message: "Tap at least 3 corners of the floor section.")) }
        guard !selfIntersects(clean) else {
            return .failure(RevisitError(message: "The corners cross over. Tap them in order around the section."))
        }
        guard area(clean) >= minArea else { return .failure(RevisitError(message: "The section is too small. Tap its corners on the floor.")) }
        return .success(clean.map { PlanVec(PlanDocument.r3($0.x), PlanDocument.r3($0.y)) })
    }
}
