//
//  DollhouseMarks.swift
//  SecureScan
//
//  The marks in the job's 3D tab, in the same visual language as the AR view
//  (docs/MARKING.md D and H):
//    * skirting: a red strip on the wall's base with white cut ticks every 0.5 m;
//    * strip-back: the wall face washed red with a white hatch to the cut height,
//      the cut line dashed white;
//    * cabinetry: the cabinet as a red wire box with a 25 % fill and an "x" badge;
//    * flooring: the area in the red family with its material's pattern
//      (carpet stipple, vinyl hatch, timber planks, tile grid);
//    * moisture extent: a blue wash from the floor to the tide line (#64D2FF);
//    * wet floor areas: blue.
//  Sidedness: a one-sided mark is drawn on its own face of the wall, just off
//  the surface, and depth-tested - the wall itself hides it from the other side.
//  Cavity marks sit inside the wall thickness and show through the cut top.
//  Everything is clamped to the dollhouse's cut height (nothing floats above a
//  cut wall). Plan coordinates (x, y) -> scene (x, height, y).
//

import SwiftUI
import SceneKit
import simd

enum DollhouseMarks {
    struct Built {
        var removals: [SCNNode] = []
        var moisture: [SCNNode] = []
        /// Labels: removal / wash tags (no marker node of their own).
        var labels: [MarkerInfo] = []
        /// Cabinets being removed (plan centres), drawn red in their own box.
        var cabinets: [(center: PlanVec, done: Bool)] = []
    }

    static let red = UIColor(red: 1.0, green: 0.271, blue: 0.227, alpha: 1)       // #FF453A
    static let blue = UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1)      // #0A84FF
    static let tide = UIColor(red: 0.392, green: 0.824, blue: 1.0, alpha: 1)      // #64D2FF
    static let doneGreen = UIColor(DS.Color.dry)

    static var cut: Double { Dollhouse.cutHeight }
    /// Face marks sit just off the wall's surface.
    static var faceOffset: Double { Dollhouse.wallThickness / 2 + 0.006 }

    // MARK: Geometry on a wall face

    /// The unit normal pointing out of a wall's side ("a" = left of a -> b; "b" the other).
    static func normal(_ w: PlanWall, side: String) -> PlanVec {
        let d = w.b - w.a
        let l = max(simd_length(d), 1e-9)
        let n = PlanVec(-d.y, d.x) / l
        return side == "b" ? -n : n
    }

    /// The sides to draw a mark on: its own, or both when the plan doesn't say (older jobs).
    static func sides(_ side: String?) -> [String] {
        switch side {
        case "a"?: return ["a"]
        case "b"?: return ["b"]
        default: return ["a", "b"]
        }
    }

    /// A plane on a wall's face from t0 to t1, y0 to y1 metres, facing out of `side`.
    static func facePlane(_ w: PlanWall, side: String, t0: Double, t1: Double, y0: Double, y1: Double,
                          material: SCNMaterial, extra: Double = 0) -> SCNNode? {
        let len = w.length * abs(t1 - t0)
        guard len > 0.01, y1 - y0 > 0.002 else { return nil }
        let plane = SCNPlane(width: CGFloat(len), height: CGFloat(y1 - y0))
        plane.materials = [material]
        let n = SCNNode(geometry: plane)
        let mid = w.a + (w.b - w.a) * ((t0 + t1) / 2) + normal(w, side: side) * (faceOffset + extra)
        n.simdPosition = SIMD3<Float>(Float(mid.x), Float((y0 + y1) / 2), Float(mid.y))
        // Plane +X along the wall, +Z out of the side.
        let d = (w.b - w.a) / max(w.length, 1e-9)
        let yaw = atan2(-d.y, d.x) + (side == "b" ? .pi : 0)
        n.simdEulerAngles = [0, Float(yaw), 0]
        return n
    }

    static func flat(_ c: UIColor, image: UIImage? = nil, tile: (Double, Double)? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = image ?? c
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        m.blendMode = .alpha
        if let t = tile {
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(t.0), Float(t.1), 1)
        }
        return m
    }

    // MARK: Patterns (textures)

    static func image(_ size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return UIGraphicsImageRenderer(size: size, format: f).image { draw($0.cgContext) }
    }

    /// Strip-back: red 26 % with white 45 deg hatch (one tile = 0.25 m).
    static let hatch: UIImage = image(CGSize(width: 64, height: 64)) { c in
        c.setFillColor(red.withAlphaComponent(0.30).cgColor)
        c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        c.setStrokeColor(UIColor(white: 1, alpha: 0.55).cgColor)
        c.setLineWidth(4)
        for k in -1...2 {
            let o = CGFloat(k) * 32
            c.move(to: CGPoint(x: o, y: 64)); c.addLine(to: CGPoint(x: o + 64, y: 0))
        }
        c.strokePath()
    }

    /// The cut line: a white dash (one tile = 0.15 m).
    static let dash: UIImage = image(CGSize(width: 64, height: 8)) { c in
        c.setFillColor(UIColor.white.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: 38, height: 8))
    }

    /// Flooring patterns, one tile = 0.6 m, over red 30 %.
    static func floorPattern(_ type: String?, done: Bool) -> UIImage {
        let base = done ? doneGreen : red
        return image(CGSize(width: 128, height: 128)) { c in
            c.setFillColor(base.withAlphaComponent(0.32).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.6).cgColor)
            c.setFillColor(UIColor(white: 1, alpha: 0.6).cgColor)
            switch type {
            case "carpet"?:
                for i in 0..<8 { for j in 0..<8 {
                    let x = CGFloat(i) * 16 + (j % 2 == 0 ? 4 : 12), y = CGFloat(j) * 16 + 8
                    c.fillEllipse(in: CGRect(x: x - 1.8, y: y - 1.8, width: 3.6, height: 3.6))
                } }
            case "timber"?:
                c.setLineWidth(2)
                for k in 0...4 { let y = CGFloat(k) * 32; c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: 128, y: y)) }
                for k in 0..<4 {
                    let x: CGFloat = k % 2 == 0 ? 0 : 64
                    c.move(to: CGPoint(x: x, y: CGFloat(k) * 32)); c.addLine(to: CGPoint(x: x, y: CGFloat(k + 1) * 32))
                }
                c.strokePath()
            case "tile"?:
                c.setLineWidth(2)
                for k in [0, 64, 128] {
                    c.move(to: CGPoint(x: k, y: 0)); c.addLine(to: CGPoint(x: k, y: 128))
                    c.move(to: CGPoint(x: 0, y: k)); c.addLine(to: CGPoint(x: 128, y: k))
                }
                c.strokePath()
            default:   // vinyl / other: diagonal hatch
                c.setLineWidth(2.5)
                for k in -2...4 {
                    let o = CGFloat(k) * 26
                    c.move(to: CGPoint(x: o, y: 128)); c.addLine(to: CGPoint(x: o + 128, y: 0))
                }
                c.strokePath()
            }
        }
    }

    // MARK: Build

    static func build(markup: [String: Any], walls: [String: PlanWall], objects: [[String: Any]]) -> Built {
        var out = Built()
        let fmt: (Double) -> String = { String(format: "%.2f m", $0) }
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            let done = (x["status"] as? String) == "done"
            let color = done ? doneGreen : red
            let item = (x["item"] as? String) ?? "other"
            let side = x["side"] as? String
            if let wid = x["wallId"] as? String, let w = walls[wid] {
                let t0 = min(PlanDocument.number(x["t0"]) ?? 0, PlanDocument.number(x["t1"]) ?? 1)
                let t1 = max(PlanDocument.number(x["t0"]) ?? 0, PlanDocument.number(x["t1"]) ?? 1)
                let len = w.length * (t1 - t0)
                let mm = PlanDocument.number(x["heightMm"]) ?? (item == "skirting" ? 100 : 600)
                let midT = (t0 + t1) / 2
                let labelSide = sides(side)[0]
                func at(_ t: Double, _ y: Double, out o: Double = 0.08) -> SIMD3<Float> {
                    let p = w.a + (w.b - w.a) * t + normal(w, side: labelSide) * (faceOffset + o)
                    return SIMD3<Float>(Float(p.x), Float(y), Float(p.y))
                }
                switch item {
                case "skirting":
                    for s in sides(side) {
                        if let n = facePlane(w, side: s, t0: t0, t1: t1, y0: 0.005, y1: 0.085, material: flat(color)) { out.removals.append(n) }
                        // White cut ticks every 0.5 m.
                        var d = 0.5
                        while d < len - 0.05 {
                            let t = t0 + d / w.length
                            if let n = facePlane(w, side: s, t0: t - 0.008 / w.length, t1: t + 0.008 / w.length, y0: 0.0, y1: 0.11,
                                                 material: flat(.white), extra: 0.002) { out.removals.append(n) }
                            d += 0.5
                        }
                    }
                    out.labels.append(MarkerInfo(kind: "removal", label: "Skirting · \(fmt(len))", color: color, position: at(midT, 0.1),
                                                 priority: 12))
                case "cabinetry":
                    if let ob = cabinet(for: w, t0: t0, t1: t1, objects: objects) {
                        let kick = (x["note"] as? String) == MarkIntent.kickBoardNote
                        let h = kick ? 0.15 : min(Furniture.height(ob.category), cut)
                        out.removals.append(wireBox(center: ob.center, size: SIMD2(ob.size.x, ob.size.y), height: h, rotation: ob.rotation, color: color))
                        if !kick { out.cabinets.append((ob.center, done)) }
                        out.labels.append(MarkerInfo(kind: "removal", label: kick ? "Kick board · \(fmt(ob.size.x))" : "Remove cabinetry · base \(fmt(ob.size.x))",
                                                     color: color, position: SIMD3<Float>(Float(ob.center.x), Float(h) + 0.05, Float(ob.center.y)), priority: 12))
                    } else {
                        for s in sides(side) {
                            if let n = facePlane(w, side: s, t0: t0, t1: t1, y0: 0, y1: min(mm / 1000, cut), material: flat(color.withAlphaComponent(0.4))) { out.removals.append(n) }
                        }
                        out.labels.append(MarkerInfo(kind: "removal", label: "Remove cabinetry · \(fmt(len))", color: color, position: at(midT, 0.5), priority: 12))
                    }
                default:
                    // Strip-back (plasterboard / other): wash + hatch to the cut height, the cut line dashed.
                    let top = min(mm / 1000, cut)
                    for s in sides(side) {
                        if let n = facePlane(w, side: s, t0: t0, t1: t1, y0: 0, y1: top,
                                             material: flat(color, image: done ? nil : hatch, tile: (len / 0.25, top / 0.25))) {
                            if done { (n.geometry?.firstMaterial)?.diffuse.contents = color.withAlphaComponent(0.3) }
                            out.removals.append(n)
                        }
                        if mm / 1000 <= cut + 1e-6, let n = facePlane(w, side: s, t0: t0, t1: t1, y0: top - 0.014, y1: top,
                                                                     material: flat(.white, image: dash, tile: (len / 0.15, 1)), extra: 0.002) {
                            out.removals.append(n)
                        }
                    }
                    let area = len * mm / 1000
                    out.labels.append(MarkerInfo(kind: "removal", label: "Strip wall to \(Int(mm)) · \(String(format: "%.1f m²", area))", color: color,
                                                 position: at(midT, top + 0.04), priority: 12))
                }
            } else if let area = (x["area"] as? [Any])?.compactMap(ScopeList.pt), area.count >= 3 {
                let type = x["floorType"] as? String
                if let g = Dollhouse.floorGeometry(area, tile: 0.6) {
                    let m = flat(color, image: floorPattern(type, done: done))
                    m.diffuse.wrapS = .repeat
                    m.diffuse.wrapT = .repeat
                    g.materials = [m]
                    let n = SCNNode(geometry: g)
                    n.position = SCNVector3(0, 0.012, 0)
                    n.renderingOrder = 130
                    out.removals.append(n)
                    out.removals.append(outline(area, y: 0.014, color: color))
                }
                let name = CaptureCopy.floorName(type ?? "", underlay: (x["underlay"] as? Bool) ?? false)
                let c = PlanBuilder.centroid(area)
                out.labels.append(MarkerInfo(kind: "removal", label: "\(type == nil ? "Flooring" : name) · \(String(format: "%.1f m²", FloorArea.area(area)))",
                                             color: color, position: SIMD3<Float>(Float(c.x), 0.05, Float(c.y)), priority: 11))
            }
        }
        // Wet floor areas (inspection): blue.
        for a in markup["affected"] as? [[String: Any]] ?? [] {
            guard let poly = (a["polygon"] as? [Any])?.compactMap(ScopeList.pt), poly.count >= 3, let g = Dollhouse.floorGeometry(poly, tile: 1) else { continue }
            g.materials = [flat(blue.withAlphaComponent(0.3))]
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(0, 0.01, 0)
            n.renderingOrder = 129
            out.moisture.append(n)
            out.moisture.append(outline(poly, y: 0.012, color: blue))
        }
        return out
    }

    /// A moisture line on its wall face: the blue wash from the floor to the tide and the tide line.
    /// `points`: (t along the wall, height) in wall order.
    static func moistureWash(_ w: PlanWall, points: [(t: Double, h: Double)], side: String?) -> (nodes: [SCNNode], label: MarkerInfo)? {
        guard points.count >= 2 else { return nil }
        var nodes: [SCNNode] = []
        let pts = points.map { (t: $0.t, h: min(max($0.h, 0.02), cut)) }
        for s in sides(side) {
            let n = normal(w, side: s) * faceOffset
            func p(_ t: Double, _ y: Double) -> SCNVector3 {
                let q = w.a + (w.b - w.a) * t + n
                return SCNVector3(Float(q.x), Float(y), Float(q.y))
            }
            var washV: [SCNVector3] = [], tideV: [SCNVector3] = [], caseV: [SCNVector3] = []
            var washI: [Int32] = []
            for (i, q) in pts.enumerated() {
                washV += [p(q.t, 0.004), p(q.t, q.h)]
                // The tide line on top: 4 cm of tide blue on a white casing, readable at the default zoom.
                tideV += [p(q.t, q.h - 0.02), p(q.t, q.h + 0.02)]
                caseV += [p(q.t, q.h - 0.032), p(q.t, q.h + 0.032)]
                if i > 0 {
                    let k = Int32(i * 2)
                    washI += [k - 2, k, k + 1, k - 2, k + 1, k - 1]
                }
            }
            for (v, idx, mat, order) in [(washV, washI, flat(blue.withAlphaComponent(0.5)), 150), (caseV, washI, flat(.white), 159),
                                         (tideV, washI, flat(tide), 160)] {
                let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v)], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
                g.materials = [mat]
                let node = SCNNode(geometry: g)
                node.renderingOrder = order
                nodes.append(node)
            }
        }
        let top = pts.max { $0.h < $1.h }!
        let mm = Int((top.h * 100).rounded()) * 10
        let q = w.a + (w.b - w.a) * top.t + normal(w, side: sides(side)[0]) * (faceOffset + 0.08)
        return (nodes, MarkerInfo(kind: "wash", label: "Moisture to \(mm) mm", color: blue,
                                  position: SIMD3<Float>(Float(q.x), Float(top.h) + 0.05, Float(q.y)), priority: 14))
    }

    /// The point a wall-attached marker (reading, source) is drawn at: on its own face, or for
    /// cavity marks inside the wall (seen through the cut top).
    static func facePosition(_ w: PlanWall, t: Double, height: Double, side: String?, out: Double) -> SIMD3<Float> {
        let h = min(height, cut)
        let p: PlanVec
        switch side {
        case "a"?, "b"?: p = w.a + (w.b - w.a) * t + normal(w, side: side!) * (Dollhouse.wallThickness / 2 + out)
        default: p = w.a + (w.b - w.a) * t
        }
        return SIMD3<Float>(Float(p.x), Float(h), Float(p.y))
    }

    // MARK: Cabinets

    struct PlanObject { var category: String; var center: PlanVec; var size: PlanVec; var rotation: Double }

    /// The cabinet a cabinetry removal was taken from: the closest storage / sink / oven / ...
    /// within 0.7 m of the stretch's middle.
    static func cabinet(for w: PlanWall, t0: Double, t1: Double, objects: [[String: Any]]) -> PlanObject? {
        let mid = w.a + (w.b - w.a) * ((t0 + t1) / 2)
        let removable = WorldObject.cabinetry.union(WorldObject.appliances)
        return objects.compactMap { o -> PlanObject? in
            guard let cat = o["category"] as? String, removable.contains(cat), let c = ScopeList.pt(o["center"]), let s = ScopeList.pt(o["size"]) else { return nil }
            return PlanObject(category: cat, center: c, size: s, rotation: PlanDocument.number(o["rotation"]) ?? 0)
        }
        .filter { simd_distance($0.center, mid) < 0.7 + max($0.size.x, $0.size.y) / 2 }
        .min { simd_distance($0.center, mid) < simd_distance($1.center, mid) }
    }

    /// A red wire box with a 25 % fill and an "x" badge on top.
    static func wireBox(center: PlanVec, size: SIMD2<Double>, height h: Double, rotation: Double, color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.simdPosition = SIMD3<Float>(Float(center.x), 0, Float(center.y))
        root.simdEulerAngles = [0, -Float(rotation), 0]
        let fill = SCNBox(width: CGFloat(size.x) + 0.02, height: CGFloat(h) + 0.01, length: CGFloat(size.y) + 0.02, chamferRadius: 0)
        fill.materials = [flat(color.withAlphaComponent(0.25))]
        let fn = SCNNode(geometry: fill)
        fn.simdPosition = [0, Float(h / 2), 0]
        fn.renderingOrder = 140
        root.addChildNode(fn)
        let hx = Float(size.x / 2) + 0.01, hz = Float(size.y / 2) + 0.01, hy = Float(h) + 0.005
        let c: [SIMD3<Float>] = [[-hx, 0, -hz], [hx, 0, -hz], [hx, 0, hz], [-hx, 0, hz], [-hx, hy, -hz], [hx, hy, -hz], [hx, hy, hz], [-hx, hy, hz]]
        for (i, j) in [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
            let a = c[i], b = c[j]
            let len = simd_length(b - a)
            let cyl = SCNCylinder(radius: 0.008, height: CGFloat(len))
            cyl.materials = [flat(color)]
            let e = SCNNode(geometry: cyl)
            e.simdPosition = (a + b) / 2
            e.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(b - a))
            e.renderingOrder = 141
            root.addChildNode(e)
        }
        // The badge.
        let badge = SCNPlane(width: 0.14, height: 0.14)
        badge.materials = [flat(.white, image: xBadge)]
        let bn = SCNNode(geometry: badge)
        bn.simdPosition = [0, hy + 0.1, 0]
        bn.constraints = [SCNBillboardConstraint()]
        bn.renderingOrder = 142
        root.addChildNode(bn)
        return root
    }

    static let xBadge: UIImage = image(CGSize(width: 64, height: 64)) { c in
        c.setFillColor(red.cgColor)
        c.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        c.setStrokeColor(UIColor.white.cgColor)
        c.setLineWidth(5)
        c.strokeEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
        c.setLineWidth(7)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: 22, y: 22)); c.addLine(to: CGPoint(x: 42, y: 42))
        c.move(to: CGPoint(x: 42, y: 22)); c.addLine(to: CGPoint(x: 22, y: 42))
        c.strokePath()
    }

    /// A thin outline round a floor area.
    static func outline(_ poly: [PlanVec], y: Double, color: UIColor) -> SCNNode {
        let root = SCNNode()
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let len = simd_distance(a, b)
            guard len > 0.01 else { continue }
            let box = SCNBox(width: CGFloat(len), height: 0.006, length: 0.025, chamferRadius: 0)
            box.materials = [flat(color)]
            let n = SCNNode(geometry: box)
            let d = (b - a) / len
            n.simdPosition = SIMD3<Float>(Float((a.x + b.x) / 2), Float(y), Float((a.y + b.y) / 2))
            n.simdEulerAngles = [0, Float(atan2(-d.y, d.x)), 0]
            n.renderingOrder = 131
            root.addChildNode(n)
        }
        return root
    }

    // MARK: Demo marks (Debug screenshots only)

    #if DEBUG
    /// SECURESCAN_3D_MARKS=1: adds one of every mark to a plan (in memory) so the 3D tab's
    /// marking visuals can be screenshot on the demo job.
    static func withDemoMarks(_ plan: [String: Any]) -> [String: Any] {
        var plan = plan
        let walls = Revisit.walls(plan)
        let rooms = Revisit.rooms(plan).filter { $0.count >= 3 }
        guard let room = rooms.max(by: { FloorArea.area($0) < FloorArea.area($1) }) else { return plan }
        let c = PlanBuilder.centroid(room)
        // The room's walls, longest first, and the side facing into the room.
        let own = walls.filter { w in
            room.indices.contains { i in PlanBuilder.distanceToSegment((w.a + w.b) / 2, room[i], room[(i + 1) % room.count]) < 0.25 }
        }.sorted { $0.length > $1.length }
        guard own.count >= 3 else { return plan }
        func inside(_ w: PlanWall) -> String { simd_dot(c - w.a, normal(w, side: "a")) >= 0 ? "a" : "b" }
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var removals = markup["removals"] as? [[String: Any]] ?? []
        var readings = markup["readings"] as? [[String: Any]] ?? []
        var sources = markup["sources"] as? [[String: Any]] ?? []
        let wA = own[0], wB = own[1], wC = own[2], wD = own.count > 3 ? own[3] : own[0]
        removals.append(["id": "demo-x1", "item": "skirting", "wallId": wA.id, "t0": 0.1, "t1": 0.85, "heightMm": 100, "side": inside(wA), "status": "proposed"])
        removals.append(["id": "demo-x2", "item": "plasterboard", "wallId": wB.id, "t0": 0.15, "t1": 0.8, "heightMm": 600, "side": inside(wB), "status": "proposed"])
        // A cabinet against wC, and its removal.
        let dir = (wC.b - wC.a) / wC.length
        let cabCentre = wC.a + (wC.b - wC.a) * 0.5 + normal(wC, side: inside(wC)) * 0.36
        var objects = plan["objects"] as? [[String: Any]] ?? []
        objects.append(["id": "demo-cab", "category": "storage", "center": [cabCentre.x, cabCentre.y], "size": [1.2, 0.6], "rotation": atan2(dir.y, dir.x)])
        plan["objects"] = objects
        let half = 0.6 / wC.length
        removals.append(["id": "demo-x3", "item": "cabinetry", "wallId": wC.id, "t0": 0.5 - half, "t1": 0.5 + half, "heightMm": 900,
                         "side": inside(wC), "status": "proposed"])
        // Flooring of each kind: small patches in the room's quadrants.
        let xs = room.map(\.x), ys = room.map(\.y)
        let w = (xs.max()! - xs.min()!) * 0.18, h = (ys.max()! - ys.min()!) * 0.18
        for (k, type) in ["carpet", "vinyl", "timber", "tile"].enumerated() {
            let o = PlanVec((k % 2 == 0 ? -1 : 1) * w * 1.15, (k < 2 ? -1 : 1) * h * 1.15)
            let p = c + o
            let rect = [p + PlanVec(-w, -h), p + PlanVec(w, -h), p + PlanVec(w, h), p + PlanVec(-w, h)].map { [$0.x, $0.y] }
            removals.append(["id": "demo-f\(k)", "item": "flooring", "area": rect, "floorType": type, "underlay": type == "carpet", "status": "proposed"])
        }
        // A moisture line along wD (into the room), and sources: suspected, confirmed, inside the wall.
        for k in 0...8 {
            let t = 0.1 + Double(k) * 0.1
            let p = wD.a + (wD.b - wD.a) * t
            readings.append(["id": "demo-b\(k)", "kind": "boundary", "pos": [p.x, p.y], "wallId": wD.id, "wallT": t,
                             "height": 0.42 + 0.05 * sin(Double(k) * 1.3), "side": inside(wD), "source": "ar"])
        }
        func src(_ id: String, _ wall: PlanWall, _ t: Double, _ hgt: Double, _ label: String, _ status: String, _ side: String) -> [String: Any] {
            let p = wall.a + (wall.b - wall.a) * t
            return ["id": id, "label": label, "pos": [p.x, p.y], "wallId": wall.id, "wallT": t, "height": hgt, "status": status, "side": side]
        }
        sources.append(src("demo-s1", wB, 0.9, 0.9, "Shower", "suspected", inside(wB)))
        sources.append(src("demo-s2", wC, 0.25, 0.95, "Vanity", "confirmed", inside(wC)))
        sources.append(src("demo-s3", wD, 0.95, 0.6, "Leak", "suspected", "cavity"))
        markup["removals"] = removals
        markup["readings"] = readings
        markup["sources"] = sources
        plan["markup"] = markup
        return plan
    }
    #endif
}
