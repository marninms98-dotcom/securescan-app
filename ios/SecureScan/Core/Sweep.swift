//
//  Sweep.swift
//  SecureScan
//
//  "Hold and sweep" drawing in AR, the maths:
//    * a moisture line swept along walls: samples of the crosshair's wall hit
//      -> split into runs per wall (a sweep can go round a corner) -> each run
//      simplified (Douglas-Peucker in wall space: along-wall metres x height)
//      to at most 12 points per wall;
//    * a wet floor area swept round its edge: floor points -> closed,
//      simplified polygon (no crossing edges, minimum area).
//  Also editing what is already in the plan (MarkupEdit) and which way the
//  mark-up screen gets its coordinate frame (MarkupStart).
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

enum Sweep {

    /// Douglas-Peucker: indices of the points kept (always the first and last).
    static func douglasPeucker(_ p: [PlanVec], tolerance: Double) -> [Int] {
        guard p.count > 2 else { return Array(p.indices) }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true
        keep[p.count - 1] = true
        var stack: [(Int, Int)] = [(0, p.count - 1)]
        while let seg = stack.popLast() {
            let s = seg.0, e = seg.1
            guard e > s + 1 else { continue }
            var best = -1.0, bestI = s
            for i in (s + 1)..<e {
                let d = PlanBuilder.distanceToSegment(p[i], p[s], p[e])
                if d > best { best = d; bestI = i }
            }
            if best > tolerance {
                keep[bestI] = true
                stack.append((s, bestI))
                stack.append((bestI, e))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// Douglas-Peucker with the tolerance raised until at most `maxPoints` remain.
    static func simplify(_ p: [PlanVec], tolerance: Double = 0.03, maxPoints: Int = 12) -> [Int] {
        guard p.count > 2 else { return Array(p.indices) }
        var tol = max(tolerance, 1e-6)
        var idx = douglasPeucker(p, tolerance: tol)
        var guardCount = 0
        while idx.count > max(2, maxPoints) && guardCount < 60 {
            tol *= 1.4
            idx = douglasPeucker(p, tolerance: tol)
            guardCount += 1
        }
        return idx
    }

    /// One sample of a swept moisture line, already resolved onto the plan.
    struct WallSample: Equatable {
        var index: Int               // position in the sweep
        var wallId: String?
        var wallT: Double?
        var height: Double?
        var wallLength: Double
    }

    /// Consecutive samples on the same wall (samples on no wall are skipped
    /// and do not split a run).
    static func runs(_ samples: [WallSample]) -> [[WallSample]] {
        var out: [[WallSample]] = []
        for s in samples {
            guard s.wallId != nil, s.wallT != nil, s.height != nil else { continue }
            if let last = out.last?.last, last.wallId == s.wallId {
                out[out.count - 1].append(s)
            } else {
                out.append([s])
            }
        }
        return out
    }

    /// The samples to keep from a sweep: per wall run, simplified in wall
    /// space (along-wall metres, height) to at most `maxPerWall` points.
    static func strokePoints(_ samples: [WallSample], tolerance: Double = 0.03, maxPerWall: Int = 12) -> [WallSample] {
        var out: [WallSample] = []
        for run in runs(samples) {
            let pts = run.map { PlanVec(($0.wallT ?? 0) * $0.wallLength, $0.height ?? 0) }
            for i in simplify(pts, tolerance: tolerance, maxPoints: maxPerWall) { out.append(run[i]) }
        }
        return out
    }

    /// A swept (or tapped) floor outline -> a closed polygon: near-duplicate
    /// points merged, simplified (closed Douglas-Peucker, at most `maxPoints`),
    /// then checked (3+ corners, no crossing edges, at least 0.1 m²).
    static func floorPolygon(_ pts: [PlanVec], tolerance: Double = 0.05, maxPoints: Int = 24) -> Result<[PlanVec], RevisitError> {
        var clean: [PlanVec] = []
        for p in pts where p.x.isFinite && p.y.isFinite {
            if let last = clean.last, simd_distance(last, p) < 0.03 { continue }
            clean.append(p)
        }
        if clean.count > 3 {
            // Close the loop for the simplification, then drop the repeated start.
            let idx = simplify(clean + [clean[0]], tolerance: tolerance, maxPoints: maxPoints + 1)
            clean = idx.filter { $0 < clean.count }.map { clean[$0] }
        }
        return FloorArea.polygon(clean)
    }
}

/// Changes to items already in plan.json, by id, whatever list they are in.
enum MarkupEdit {
    static let lists = ["readings", "sources", "equipment", "removals", "affected", "floors"]

    static func find(_ plan: [String: Any], id: String) -> (list: String, index: Int, item: [String: Any])? {
        let markup = plan["markup"] as? [String: Any] ?? [:]
        for l in lists {
            let arr = markup[l] as? [[String: Any]] ?? []
            if let i = arr.firstIndex(where: { ($0["id"] as? String) == id }) { return (l, i, arr[i]) }
        }
        return nil
    }

    private static func replace(_ plan: [String: Any], list: String, index: Int, with item: [String: Any]?) -> [String: Any] {
        var doc = plan
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var arr = markup[list] as? [[String: Any]] ?? []
        if let item { arr[index] = item } else { arr.remove(at: index) }
        markup[list] = arr
        doc["markup"] = markup
        return doc
    }

    /// Sets fields of an item (NSNull clears). Nil if the id is not found.
    static func update(_ plan: [String: Any], id: String, set: [String: Any]) -> [String: Any]? {
        guard let f = find(plan, id: id) else { return nil }
        var item = f.item
        for (k, v) in set { item[k] = v }
        return replace(plan, list: f.list, index: f.index, with: item)
    }

    static func delete(_ plan: [String: Any], id: String) -> [String: Any]? {
        guard let f = find(plan, id: id) else { return nil }
        return replace(plan, list: f.list, index: f.index, with: nil)
    }

    /// "Move here": the item takes the newly resolved position (wall items
    /// their wall, wallT and height; floor items only their position).
    static func move(_ plan: [String: Any], id: String, to r: PlanReading) -> [String: Any]? {
        guard let f = find(plan, id: id) else { return nil }
        var set: [String: Any] = ["pos": PlanDocument.pt(r.pos)]
        if f.list != "equipment" {
            set["wallId"] = r.wallId.map { $0 as Any } ?? NSNull()
            set["wallT"] = r.wallT.map { PlanDocument.r4($0) as Any } ?? NSNull()
            set["height"] = r.height.map { PlanDocument.r3($0) as Any } ?? NSNull()
        }
        if let c = r.cam { set["cam"] = PlanDocument.pt(c) }
        return update(plan, id: id, set: set)
    }

    /// Raises / lowers a wall item by `delta` metres (clamped at the floor).
    static func nudgeHeight(_ plan: [String: Any], id: String, by delta: Double) -> [String: Any]? {
        guard let f = find(plan, id: id), let h = PlanDocument.number(f.item["height"]) else { return nil }
        return update(plan, id: id, set: ["height": PlanDocument.r3(max(0, h + delta))])
    }
}

/// How the mark-up screen gets the plan's coordinate frame.
enum MarkupStart: Equatable {
    /// The scan's own ARSession is still running: the plan frame applies directly.
    case sharedSession
    /// A new session that relocalises onto the saved world map.
    case worldMap
    /// A new session aligned by tapping wall corners.
    case corners

    static func strategy(sharedSessionRunning: Bool, hasPlanFrame: Bool, hasWorldMap: Bool) -> MarkupStart {
        guard hasPlanFrame else { return .corners }
        if sharedSessionRunning { return .sharedSession }
        return hasWorldMap ? .worldMap : .corners
    }
}

/// Points logged in a mark-up session that is NOT the scan's own ARSession
/// (relocalised or aligned by corners) are moved into the scan's world space
/// before they go into readings-raw.json, so the final plan build resolves
/// them like everything else: same plan point, same height above the floor.
enum MarkupFrame {
    static func toScanWorld(_ w: WorldVec, session: PlanTransform, sessionFloorY: Double,
                            scan: PlanTransform, scanFloorY: Double) -> WorldVec {
        scan.world(session.point(w), y: w.y - sessionFloorY + scanFloorY)
    }

    /// A direction (camera forward) the same way: rotated, not moved.
    static func directionToScan(_ d: WorldVec, session: PlanTransform, scan: PlanTransform) -> WorldVec {
        let p = session.direction(d)
        let back = scan.world(p + scan.offset, y: 0)        // rotate back without the offset
        return WorldVec(back.x, d.y, back.z)
    }
}

/// Ear clipping, for filling a (possibly concave) floor outline in AR.
enum Triangulate {
    /// Triangle indices into `poly` (3 per triangle). Empty if it fails.
    static func ears(_ poly: [PlanVec]) -> [Int] {
        let n = poly.count
        guard n >= 3 else { return [] }
        var idx = Array(0..<n)
        if PlanBuilder.signedArea(poly) < 0 { idx.reverse() }          // work counter-clockwise
        func inside(_ p: PlanVec, _ a: PlanVec, _ b: PlanVec, _ c: PlanVec) -> Bool {
            let d1 = cross2(b - a, p - a), d2 = cross2(c - b, p - b), d3 = cross2(a - c, p - c)
            return d1 >= 0 && d2 >= 0 && d3 >= 0
        }
        var out: [Int] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < n * n {
            guardCount += 1
            var clipped = false
            for i in idx.indices {
                let ia = idx[(i + idx.count - 1) % idx.count], ib = idx[i], ic = idx[(i + 1) % idx.count]
                let a = poly[ia], b = poly[ib], c = poly[ic]
                guard cross2(b - a, c - b) > 1e-12 else { continue }      // reflex or flat
                let blocked = idx.contains { j in j != ia && j != ib && j != ic && inside(poly[j], a, b, c) }
                if blocked { continue }
                out += [ia, ib, ic]
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out += idx }
        return out.count == (n - 2) * 3 ? out : []
    }
}
