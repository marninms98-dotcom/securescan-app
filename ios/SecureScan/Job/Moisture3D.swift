//
//  Moisture3D.swift
//  SecureScan
//
//  The moisture model in the 3D tab (docs/MOISTURE.md), in the camera's styling:
//  wet areas on wall faces and floors in the blue wash - measured solid, estimated
//  lighter with a fine dashed edge, the scoper's own corrections solid with a
//  pencil badge - and the tide line on top. Built off the main thread.
//

import SceneKit
import simd
import UIKit

enum Moisture3D {
    static let blue = DollhouseMarks.blue
    static let tide = DollhouseMarks.tide

    static func fillAlpha(_ p: MoistProvenance) -> CGFloat { p == .estimated ? 0.24 : 0.52 }

    /// Every node for a solved model, on the plan's walls.
    static func nodes(_ d: MoistureDraw, walls: [String: PlanWall]) -> (nodes: [SCNNode], hints: [(SIMD3<Float>, String)]) {
        var out: [SCNNode] = []
        let cut = DollhouseMarks.cut
        for f in d.faces {
            guard let w = walls[f.wallId], w.length > 1e-6 else { continue }
            let side = f.side == .b ? "b" : "a"
            let n = DollhouseMarks.normal(w, side: side)
            let dir = (w.b - w.a) / w.length
            func p(_ q: MoistVec, _ extra: Double) -> SCNVector3 {
                let along = min(max(q.x, 0), w.length), z = min(max(q.y, 0), cut)
                let x = w.a + dir * along + n * (DollhouseMarks.faceOffset + 0.002 + extra)
                return SCNVector3(Float(x.x), Float(z), Float(x.y))
            }
            for a in f.areas {
                for loop in a.loops {
                    let pts = simplify(loop.map { PlanVec($0.x, min(max($0.y, 0), cut)) })
                    if let node = polygon(pts, map: { p(MoistVec($0.x, $0.y), 0) }, color: blue.withAlphaComponent(fillAlpha(a.provenance)), order: 148) {
                        out.append(node)
                    }
                    if a.provenance == .scoper, let b = badge(pts.map { p(MoistVec($0.x, $0.y), 0.03) }) { out.append(b) }
                }
            }
            for e in f.edges {
                out += band(e.points.map { p($0, 0.004) }, up: SIMD3<Float>(0, 1, 0), width: e.provenance == .estimated ? 0.014 : 0.03,
                            dashed: e.provenance == .estimated)
            }
        }
        for f in d.floors {
            for a in f.areas {
                for loop in a.loops {
                    let pts = simplify(loop.map { PlanVec($0.x, $0.y) })
                    if let node = polygon(pts, map: { SCNVector3(Float($0.x), 0.016, Float($0.y)) },
                                          color: blue.withAlphaComponent(fillAlpha(a.provenance) * 0.9), order: 133) {
                        out.append(node)
                    }
                    if a.provenance == .scoper, let b = badge(pts.map { SCNVector3(Float($0.x), 0.05, Float($0.y)) }) { out.append(b) }
                }
            }
            for e in f.edges {
                let pts = e.points.map { SCNVector3(Float($0.x), 0.02, Float($0.y)) }
                out += band(pts, up: nil, width: e.provenance == .estimated ? 0.022 : 0.04, dashed: e.provenance == .estimated)
            }
        }
        let hints = d.hints.map { h -> (SIMD3<Float>, String) in
            var q = SIMD3<Float>(Float(h.pos.x), Float(min(max(h.height, 0.05), cut)), Float(h.pos.y))
            if let wid = h.wallId, let w = walls[wid], h.side == .a || h.side == .b {
                q = DollhouseMarks.facePosition(w, t: PlanBuilder.projectParam(PlanVec(h.pos.x, h.pos.y), w.a, w.b),
                                                height: max(0.1, h.height), side: h.side?.rawValue, out: 0.12)
            }
            return (q, "Another source likely")
        }
        for (q, _) in hints { out.append(hintNode(q)) }
        return (out, hints)
    }

    /// Fewer points for a smooth outline (ear clipping is quadratic).
    static func simplify(_ loop: [PlanVec], tol: Double = 0.04) -> [PlanVec] {
        var out: [PlanVec] = []
        for p in loop where out.isEmpty || simd_distance(p, out[out.count - 1]) >= tol { out.append(p) }
        if out.count > 3, let f = out.first, let l = out.last, simd_distance(f, l) < tol { out.removeLast() }
        return out
    }

    /// A flat polygon (2D outline mapped into 3D), translucent, depth-tested.
    static func polygon(_ pts2: [PlanVec], map: (PlanVec) -> SCNVector3, color: UIColor, order: Int) -> SCNNode? {
        guard pts2.count >= 3 else { return nil }
        var pts = pts2
        if PlanBuilder.signedArea(pts) < 0 { pts.reverse() }
        guard let tris = Dollhouse.earClip(pts), !tris.isEmpty else { return nil }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts.map(map))],
                            elements: [SCNGeometryElement(indices: tris.map { Int32($0) }, primitiveType: .triangles)])
        g.materials = [DollhouseMarks.flat(color)]
        let node = SCNNode(geometry: g)
        node.renderingOrder = order
        return node
    }

    /// A line as a flat band: on a wall face (`up` = the face's vertical) or on the floor
    /// (nil = lying flat). Solid, or dashed (0.06 m on, 0.05 m off) where estimated.
    static func band(_ pts: [SCNVector3], up: SIMD3<Float>?, width: Float, dashed: Bool) -> [SCNNode] {
        guard pts.count >= 2 else { return [] }
        var v: [SCNVector3] = [], idx: [Int32] = []
        var casing: [SCNVector3] = [], cidx: [Int32] = []
        var run: Float = 0
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ hw: Float, into vs: inout [SCNVector3], _ ids: inout [Int32]) {
            let d = b - a
            let off: SIMD3<Float>
            if let u = up { off = u * hw } else {
                let l = simd_length(SIMD2(d.x, d.z))
                guard l > 1e-6 else { return }
                off = SIMD3(-d.z / l, 0, d.x / l) * hw
            }
            let k = Int32(vs.count)
            vs += [SCNVector3(a - off), SCNVector3(a + off), SCNVector3(b + off), SCNVector3(b - off)]
            ids += [k, k + 1, k + 2, k, k + 2, k + 3]
        }
        for i in 1..<pts.count {
            let a = SIMD3<Float>(pts[i - 1]), b = SIMD3<Float>(pts[i])
            let len = simd_length(b - a)
            guard len > 1e-5 else { continue }
            if !dashed {
                quad(a, b, width / 2, into: &v, &idx)
                quad(a, b, width / 2 + 0.008, into: &casing, &cidx)
                continue
            }
            // Dash pattern along the run.
            var s: Float = 0
            while s < len {
                let phase = (run + s).truncatingRemainder(dividingBy: 0.11)
                let on = phase < 0.06
                let step = min(len - s, on ? 0.06 - phase : 0.11 - phase)
                if on { quad(a + (b - a) * (s / len), a + (b - a) * ((s + step) / len), width / 2, into: &v, &idx) }
                s += max(step, 1e-4)
            }
            run += len
        }
        var out: [SCNNode] = []
        if !casing.isEmpty {
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: casing)], elements: [SCNGeometryElement(indices: cidx, primitiveType: .triangles)])
            g.materials = [DollhouseMarks.flat(UIColor(white: 1, alpha: 0.9))]
            let n = SCNNode(geometry: g)
            n.renderingOrder = 161
            out.append(n)
        }
        if !v.isEmpty {
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v)], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
            g.materials = [DollhouseMarks.flat(dashed ? tide.withAlphaComponent(0.95) : tide)]
            let n = SCNNode(geometry: g)
            n.renderingOrder = 162
            out.append(n)
        }
        return out
    }

    /// The scoper's pencil, a small billboard badge at the area's middle.
    static func badge(_ pts: [SCNVector3]) -> SCNNode? {
        guard !pts.isEmpty else { return nil }
        var c = SIMD3<Float>(0, 0, 0)
        for p in pts { c += SIMD3<Float>(p) }
        c /= Float(pts.count)
        let plane = SCNPlane(width: 0.16, height: 0.16)
        plane.materials = [DollhouseMarks.flat(.white, image: pencil)]
        let n = SCNNode(geometry: plane)
        n.simdPosition = c
        n.constraints = [SCNBillboardConstraint()]
        n.renderingOrder = 170
        return n
    }

    static let pencil: UIImage = DollhouseMarks.image(CGSize(width: 64, height: 64)) { c in
        c.setFillColor(UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.8).cgColor)
        c.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        c.setStrokeColor(UIColor.white.cgColor)
        c.setLineWidth(6)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: 22, y: 42)); c.addLine(to: CGPoint(x: 42, y: 22))
        c.strokePath()
        c.setFillColor(UIColor.white.cgColor)
        c.move(to: CGPoint(x: 17, y: 47)); c.addLine(to: CGPoint(x: 20, y: 38)); c.addLine(to: CGPoint(x: 26, y: 44)); c.closePath()
        c.fillPath()
    }

    /// "Look here": a dashed ring with a blue dot, always on top.
    static func hintNode(_ q: SIMD3<Float>) -> SCNNode {
        let root = SCNNode()
        root.simdPosition = q
        let facing = SCNNode()
        facing.constraints = [SCNBillboardConstraint()]
        let plane = SCNPlane(width: 0.34, height: 0.34)
        plane.materials = [ModelViewModel.overlayMaterial(.white)]
        plane.firstMaterial?.diffuse.contents = hintImage
        plane.firstMaterial?.blendMode = .alpha
        let pn = SCNNode(geometry: plane)
        pn.renderingOrder = 210
        facing.addChildNode(pn)
        root.addChildNode(facing)
        return root
    }

    static let hintImage: UIImage = DollhouseMarks.image(CGSize(width: 96, height: 96)) { c in
        c.setStrokeColor(UIColor(white: 0, alpha: 0.35).cgColor)
        c.setLineWidth(10)
        c.strokeEllipse(in: CGRect(x: 10, y: 10, width: 76, height: 76))
        c.setStrokeColor(UIColor.white.cgColor)
        c.setLineWidth(5)
        c.setLineDash(phase: 0, lengths: [12, 8])
        c.strokeEllipse(in: CGRect(x: 10, y: 10, width: 76, height: 76))
        c.setLineDash(phase: 0, lengths: [])
        c.setFillColor(DollhouseMarks.blue.cgColor)
        c.fillEllipse(in: CGRect(x: 34, y: 34, width: 28, height: 28))
        c.setStrokeColor(UIColor.white.cgColor)
        c.setLineWidth(4)
        c.strokeEllipse(in: CGRect(x: 34, y: 34, width: 28, height: 28))
    }
}
