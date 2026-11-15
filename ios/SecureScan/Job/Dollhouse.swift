//
//  Dollhouse.swift
//  SecureScan
//
//  The job as a "dollhouse": built from plan.json (walls with thickness cut
//  away at a fixed height so you can see in, door gaps, window glass, floors
//  with a procedural timber / carpet / tile texture, the scan's furniture as
//  soft-coloured boxes) on a warm light canvas with soft shadows. Used by the
//  3D tab (markup is added on top there) and for the jobs list thumbnail
//  (thumb3d.png, rendered offscreen and cached until plan.json changes).
//
//  Coordinates: plan (x, y) -> scene (x, height, y), y up, metres.
//

import SwiftUI
import SceneKit
import Metal
import simd

enum Dollhouse {
    /// Walls are cut here so the rooms read from above.
    static let cutHeight: Double = 1.15
    static let wallThickness: Double = 0.1

    /// Warm light canvas behind the model.
    static let canvas = UIColor(red: 0.953, green: 0.945, blue: 0.925, alpha: 1)

    /// Nodes that hit tests for measuring and room focus may land on.
    static let solidCategory = 1
    static let markupCategory = 2

    struct Room: Identifiable {
        var id: String
        var name: String
        var polygon: [PlanVec]
        var min: SIMD3<Float>
        var max: SIMD3<Float>
    }

    struct Built {
        var scene: SCNScene
        var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
        var rooms: [Room]
        /// Furniture container (a layer the user can hide).
        var furniture: SCNNode
    }

    // MARK: Build (any thread)

    static func build(plan: [String: Any]) -> Built? {
        let rooms = (plan["rooms"] as? [[String: Any]] ?? []).enumerated().compactMap { (i, r) -> Room? in
            let poly = (r["polygon"] as? [Any] ?? []).compactMap(ScopeList.pt)
            guard poly.count >= 3 else { return nil }
            let name = ((r["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let xs = poly.map(\.x), ys = poly.map(\.y)
            return Room(id: (r["id"] as? String) ?? "r\(i + 1)", name: name.isEmpty ? "Room \(i + 1)" : name, polygon: poly,
                        min: SIMD3(Float(xs.min()!), 0, Float(ys.min()!)), max: SIMD3(Float(xs.max()!), Float(cutHeight), Float(ys.max()!)))
        }
        let walls = Revisit.walls(plan)
        guard !walls.isEmpty || !rooms.isEmpty else { return nil }

        let scene = SCNScene()
        scene.background.contents = canvas
        let root = scene.rootNode

        // Floors.
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let zones: [(poly: [PlanVec], type: String)] = (markup["floors"] as? [[String: Any]] ?? []).compactMap { z in
            let p = (z["polygon"] as? [Any] ?? []).compactMap(ScopeList.pt)
            return p.count >= 3 ? (p, (z["type"] as? String) ?? "other") : nil
        }
        for room in rooms {
            let c = PlanBuilder.centroid(room.polygon)
            let type = zones.first { FloorArea.inside(c, $0.poly) }?.type ?? "timber"
            if let g = floorGeometry(room.polygon, tile: Floor.tileSize(type)) {
                g.materials = [Floor.material(type)]
                let n = SCNNode(geometry: g)
                n.name = "floor:" + room.id
                n.categoryBitMask = solidCategory
                root.addChildNode(n)
            }
        }

        // Walls, split round their openings.
        var openings: [String: [(t0: Double, t1: Double, type: String, sill: Double, height: Double)]] = [:]
        let byId = Dictionary(walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for o in plan["openings"] as? [[String: Any]] ?? [] {
            guard let wid = o["wallId"] as? String, let w = byId[wid],
                  let a = ScopeList.pt(o["a"]), let b = ScopeList.pt(o["b"]) else { continue }
            let d = w.b - w.a
            let l2 = (d * d).sum()
            guard l2 > 1e-6 else { continue }
            let ta = ((a - w.a) * d).sum() / l2, tb = ((b - w.a) * d).sum() / l2
            openings[wid, default: []].append((max(0, min(ta, tb)), min(1, max(ta, tb)), (o["type"] as? String) ?? "door",
                                              PlanDocument.number(o["sill"]) ?? 0, PlanDocument.number(o["height"]) ?? 2.04))
        }
        let wallMats = wallMaterials()
        let glass = SCNMaterial()
        glass.diffuse.contents = UIColor(red: 0.72, green: 0.84, blue: 0.94, alpha: 0.55)
        glass.lightingModel = .blinn
        glass.specular.contents = UIColor(white: 1, alpha: 0.6)
        glass.transparencyMode = .dualLayer
        for w in walls {
            let len = ((w.b - w.a) * (w.b - w.a)).sum().squareRoot()
            guard len > 0.02 else { continue }
            let top = min(cutHeight, w.height)
            // Solid stretches between openings.
            let gaps = (openings[w.id] ?? []).sorted { $0.t0 < $1.t0 }
            var t = 0.0
            for g in gaps {
                if g.t0 > t + 0.005 { root.addChildNode(wallSegment(w.a, w.b, t, g.t0, from: 0, to: top, len: len, mats: wallMats)) }
                if g.type == "window" {
                    let sill = min(max(g.sill, 0), top)
                    if sill > 0.02 { root.addChildNode(wallSegment(w.a, w.b, g.t0, g.t1, from: 0, to: sill, len: len, mats: wallMats)) }
                    if sill < top - 0.02 {
                        let pane = wallSegment(w.a, w.b, g.t0, g.t1, from: sill, to: min(top, sill + g.height), len: len, mats: [glass], thickness: 0.035)
                        root.addChildNode(pane)
                    }
                }
                t = max(t, g.t1)
            }
            if t < 0.995 { root.addChildNode(wallSegment(w.a, w.b, t, 1, from: 0, to: top, len: len, mats: wallMats)) }
        }

        // Furniture.
        let furniture = SCNNode()
        furniture.name = "layer:furniture"
        for o in plan["objects"] as? [[String: Any]] ?? [] {
            guard let c = ScopeList.pt(o["center"]), let s = ScopeList.pt(o["size"]) else { continue }
            let cat = (o["category"] as? String) ?? "storage"
            let h = Furniture.height(cat)
            let box = SCNBox(width: CGFloat(max(s.x, 0.1)), height: CGFloat(h), length: CGFloat(max(s.y, 0.1)), chamferRadius: 0.035)
            box.materials = [Furniture.material(cat)]
            let n = SCNNode(geometry: box)
            n.categoryBitMask = solidCategory
            n.position = SCNVector3(Float(c.x), Float(h / 2), Float(c.y))
            n.eulerAngles = SCNVector3(0, -Float(PlanDocument.number(o["rotation"]) ?? 0), 0)
            if cat == "bed" {
                // A pillow strip at the head end reads as a bed at a glance.
                let pillow = SCNBox(width: CGFloat(max(s.x, 0.1) * 0.86), height: 0.08, length: 0.32, chamferRadius: 0.04)
                pillow.materials = [Furniture.paint(UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))]
                let p = SCNNode(geometry: pillow)
                p.position = SCNVector3(0, Float(h / 2) + 0.03, -Float(max(s.y, 0.1) / 2) + 0.24)
                n.addChildNode(p)
            }
            furniture.addChildNode(n)
        }
        root.addChildNode(furniture)

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for r in rooms { lo = simd_min(lo, r.min); hi = simd_max(hi, r.max) }
        for w in walls {
            for p in [w.a, w.b] { lo = simd_min(lo, SIMD3(Float(p.x), 0, Float(p.y))); hi = simd_max(hi, SIMD3(Float(p.x), Float(cutHeight), Float(p.y))) }
        }
        if lo.x > hi.x { lo = SIMD3(-1, 0, -1); hi = SIMD3(1, 1, 1) }
        addShadowCatcher(root, lo: lo, hi: hi)
        return Built(scene: scene, bounds: (lo, hi), rooms: rooms, furniture: furniture)
    }

    /// One wall stretch t0...t1 (0...1 along a->b), from...to metres high. The
    /// wall's own ends run on by half a thickness so corners close.
    static func wallSegment(_ a: PlanVec, _ b: PlanVec, _ t0: Double, _ t1: Double, from y0: Double, to y1: Double,
                            len: Double, mats: [SCNMaterial], thickness: Double = wallThickness) -> SCNNode {
        let dir = (b - a) / len
        var s = len * t0, e = len * t1
        if t0 <= 0.0001 { s -= thickness / 2 }
        if t1 >= 0.9999 { e += thickness / 2 }
        let p0 = a + dir * s, p1 = a + dir * e
        let box = SCNBox(width: CGFloat(e - s), height: CGFloat(max(y1 - y0, 0.01)), length: CGFloat(thickness), chamferRadius: 0)
        box.materials = mats
        let n = SCNNode(geometry: box)
        n.categoryBitMask = solidCategory
        n.position = SCNVector3(Float((p0.x + p1.x) / 2), Float((y0 + y1) / 2), Float((p0.y + p1.y) / 2))
        // Rotation about +Y by θ maps local +X to (cos θ, 0, -sin θ); we want (dx, 0, dy).
        n.eulerAngles = SCNVector3(0, Float(atan2(-dir.y, dir.x)), 0)
        return n
    }

    /// SCNBox materials: front, right, back, left, top, bottom. A slightly
    /// darker top shows where the wall was cut.
    static func wallMaterials() -> [SCNMaterial] {
        func m(_ c: UIColor) -> SCNMaterial {
            let x = SCNMaterial()
            x.diffuse.contents = c
            x.lightingModel = .lambert
            return x
        }
        let side = m(UIColor(red: 0.985, green: 0.982, blue: 0.975, alpha: 1))
        let top = m(UIColor(red: 0.86, green: 0.845, blue: 0.82, alpha: 1))
        return [side, side, side, side, top, side]
    }

    /// A depth-only ground that still receives the (deferred) shadows, so the
    /// house sits on the canvas without a visible floor edge.
    static func addShadowCatcher(_ root: SCNNode, lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let size = CGFloat(max(hi.x - lo.x, hi.z - lo.z) * 4 + 10)
        let plane = SCNPlane(width: size, height: size)
        let m = SCNMaterial()
        m.diffuse.contents = canvas
        m.lightingModel = .constant
        m.colorBufferWriteMask = []
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        n.position = SCNVector3((lo.x + hi.x) / 2, -0.002, (lo.z + hi.z) / 2)
        n.renderingOrder = -10
        n.categoryBitMask = 4
        root.addChildNode(n)
    }

    /// Soft key light with deferred shadows, a fill, and ambient.
    static func addLights(_ root: SCNNode, extent: Float) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 520
        ambient.light!.color = UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1)
        root.addChildNode(ambient)

        let key = SCNNode()
        let l = SCNLight()
        l.type = .directional
        l.intensity = 620
        l.castsShadow = true
        l.shadowMode = .deferred
        l.shadowColor = UIColor(white: 0, alpha: 0.22)
        l.shadowRadius = 10
        l.shadowSampleCount = 16
        l.shadowMapSize = CGSize(width: 2048, height: 2048)
        l.orthographicScale = CGFloat(max(extent, 3)) * 0.75
        l.zNear = 0.1
        l.zFar = CGFloat(max(extent, 3)) * 6
        l.shadowCascadeCount = 1
        key.light = l
        key.eulerAngles = SCNVector3(-Float.pi * 0.36, Float.pi * 0.2, 0)
        root.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 260
        fill.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi * 1.2, 0)
        root.addChildNode(fill)
    }

    // MARK: Cameras

    /// Elevated three-quarter (or top-down orthographic) camera that fits `lo...hi`.
    static func camera(lo: SIMD3<Float>, hi: SIMD3<Float>, aspect: Double, plan: Bool,
                       azimuth: Double = 28, elevation: Double = 56, margin: Double = 0.9) -> (SCNNode, SIMD3<Float>) {
        let l = SIMD3<Double>(lo), h = SIMD3<Double>(hi)
        let centre = (l + h) / 2
        let node = SCNNode()
        let cam = SCNCamera()
        cam.zNear = 0.05
        node.camera = cam
        if plan {
            cam.usesOrthographicProjection = true
            let w = h.x - l.x, d = h.z - l.z
            // orthographicScale = half the visible height.
            cam.orthographicScale = max(d / 2, w / 2 / max(aspect, 0.1)) / margin + 0.3
            cam.zFar = 100
            node.simdPosition = SIMD3<Float>(Float(centre.x), 30, Float(centre.z))
            node.look(at: SCNVector3(Float(centre.x), 0, Float(centre.z)), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        } else {
            var corners: [SIMD3<Double>] = []
            for x in [l.x, h.x] { for y in [l.y, h.y] { for z in [l.z, h.z] { corners.append(SIMD3(x, y, z)) } } }
            let dir = CameraFit.direction(azimuthDegrees: azimuth, elevationDegrees: elevation)
            let fov = 40.0
            cam.projectionDirection = .vertical
            cam.fieldOfView = CGFloat(fov)
            let tanV = tan(fov / 2 * .pi / 180), tanH = tanV * aspect
            let dist = CameraFit.distance(points: corners, target: centre, direction: dir, tanH: tanH, tanV: tanV, margin: margin)
            cam.zFar = max(100, dist * 8)
            node.simdPosition = SIMD3<Float>(centre + dir * dist)
            node.look(at: SCNVector3(Float(centre.x), Float(centre.y), Float(centre.z)), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        }
        cam.screenSpaceAmbientOcclusionIntensity = 0.55
        cam.screenSpaceAmbientOcclusionRadius = 0.25
        cam.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        return (node, SIMD3<Float>(centre))
    }

    // MARK: Thumbnail (jobs list)

    static func thumbURL(_ folder: JobFolder) -> URL { folder.url.appendingPathComponent("thumb3d.png") }

    /// thumb3d.png is missing or older than plan.json.
    static func thumbNeedsRender(_ folder: JobFolder) -> Bool {
        guard folder.hasPlan else { return false }
        let fm = FileManager.default
        guard let plan = (try? fm.attributesOfItem(atPath: folder.planURL.path))?[.modificationDate] as? Date else { return false }
        guard let thumb = (try? fm.attributesOfItem(atPath: thumbURL(folder).path))?[.modificationDate] as? Date else { return true }
        return thumb < plan
    }

    /// Renders and caches the dollhouse thumbnail; false if it can't be made here.
    @discardableResult
    static func renderThumb(_ folder: JobFolder, side: CGFloat = 240) -> Bool {
        guard let data = try? Data(contentsOf: folder.planURL),
              let plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let built = build(plan: plan),
              let device = MTLCreateSystemDefaultDevice() else { return false }
        let extent = max(built.bounds.max.x - built.bounds.min.x, built.bounds.max.z - built.bounds.min.z)
        addLights(built.scene.rootNode, extent: extent)
        let (cam, _) = camera(lo: built.bounds.min, hi: built.bounds.max, aspect: 1, plan: false, azimuth: 30, elevation: 52, margin: 0.96)
        cam.camera?.screenSpaceAmbientOcclusionIntensity = 0
        built.scene.rootNode.addChildNode(cam)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = built.scene
        renderer.pointOfView = cam
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .multisampling4X)
        guard let png = image.pngData() else { return false }
        return (try? png.write(to: thumbURL(folder), options: .atomic)) != nil
    }

    // MARK: Floor geometry

    /// A flat floor at y = 0 (ear clipping), texture coordinates in metres / tile.
    static func floorGeometry(_ poly: [PlanVec], tile: Double) -> SCNGeometry? {
        var pts = poly
        if PlanBuilder.signedArea(pts) < 0 { pts.reverse() }
        guard let tris = earClip(pts), !tris.isEmpty else { return nil }
        let verts = pts.map { SCNVector3(Float($0.x), 0, Float($0.y)) }
        let normals = pts.map { _ in SCNVector3(0, 1, 0) }
        let uvs = pts.map { CGPoint(x: $0.x / tile, y: $0.y / tile) }
        let el = SCNGeometryElement(indices: tris.map { Int32($0) }, primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)], elements: [el])
    }

    /// Ear clipping for a simple polygon with positive signed area.
    static func earClip(_ p: [PlanVec]) -> [Int]? {
        var idx = Array(p.indices)
        var out: [Int] = []
        func cross(_ o: PlanVec, _ a: PlanVec, _ b: PlanVec) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func inside(_ q: PlanVec, _ a: PlanVec, _ b: PlanVec, _ c: PlanVec) -> Bool {
            cross(a, b, q) >= 0 && cross(b, c, q) >= 0 && cross(c, a, q) >= 0
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for i in idx.indices {
                let ia = idx[(i + idx.count - 1) % idx.count], ib = idx[i], ic = idx[(i + 1) % idx.count]
                let a = p[ia], b = p[ib], c = p[ic]
                guard cross(a, b, c) > 1e-9 else { continue }
                let blocked = idx.contains { j in j != ia && j != ib && j != ic && inside(p[j], a, b, c) }
                if blocked { continue }
                out += [ia, ib, ic]
                idx.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if idx.count == 3 { out += idx }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Floors (procedural textures)

enum Floor {
    static func tileSize(_ type: String) -> Double {
        switch type {
        case "tile": return 0.9
        case "carpet", "concrete": return 1.0
        default: return 1.2
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: UIImage] = [:]

    static func material(_ type: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = texture(type)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.lightingModel = .lambert
        m.isDoubleSided = true
        return m
    }

    static func texture(_ type: String) -> UIImage {
        let key = ["carpet", "tile", "concrete"].contains(type) ? type : "timber"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let t = cache[key] { return t }
        let t = draw(key)
        cache[key] = t
        return t
    }

    /// Deterministic noise.
    private struct RNG {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    }

    private static func draw(_ key: String) -> UIImage {
        let side: CGFloat = 512
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var rng = RNG(s: 0x5EC0_5CA9)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            let c = ctx.cgContext
            switch key {
            case "carpet":
                UIColor(red: 0.84, green: 0.81, blue: 0.77, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<9000 {
                    let v = 0.74 + rng.next() * 0.16
                    UIColor(red: v, green: v * 0.97, blue: v * 0.93, alpha: 0.5).setFill()
                    c.fill(CGRect(x: rng.next() * Double(side), y: rng.next() * Double(side), width: 2, height: 2))
                }
            case "tile":
                UIColor(red: 0.91, green: 0.90, blue: 0.88, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: side, height: side))
                UIColor(red: 0.80, green: 0.79, blue: 0.76, alpha: 1).setFill()
                let n = 3, step = side / CGFloat(n)
                for i in 0...n {
                    c.fill(CGRect(x: CGFloat(i) * step - 2, y: 0, width: 4, height: side))
                    c.fill(CGRect(x: 0, y: CGFloat(i) * step - 2, width: side, height: 4))
                }
            case "concrete":
                UIColor(red: 0.80, green: 0.80, blue: 0.79, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: side, height: side))
                for _ in 0..<5000 {
                    let v = 0.70 + rng.next() * 0.18
                    UIColor(white: v, alpha: 0.35).setFill()
                    c.fill(CGRect(x: rng.next() * Double(side), y: rng.next() * Double(side), width: 3, height: 3))
                }
            default:
                // Light oak planks: 8 rows, staggered joints, subtle grain.
                let rows = 8
                let rowH = side / CGFloat(rows)
                for r in 0..<rows {
                    var x: CGFloat = -CGFloat(rng.next()) * side * 0.5
                    while x < side {
                        let w = side * CGFloat(0.45 + rng.next() * 0.35)
                        let t = 0.80 + rng.next() * 0.08
                        UIColor(red: t, green: t * 0.90, blue: t * 0.76, alpha: 1).setFill()
                        let rect = CGRect(x: x, y: CGFloat(r) * rowH, width: w, height: rowH)
                        c.fill(rect)
                        for _ in 0..<5 {
                            let gy = rect.minY + CGFloat(rng.next()) * rowH
                            UIColor(red: t * 0.93, green: t * 0.83, blue: t * 0.70, alpha: 0.35).setStroke()
                            c.setLineWidth(1)
                            c.move(to: CGPoint(x: rect.minX, y: gy))
                            c.addLine(to: CGPoint(x: rect.maxX, y: gy + CGFloat(rng.next() * 3 - 1.5)))
                            c.strokePath()
                        }
                        UIColor(red: 0.62, green: 0.54, blue: 0.44, alpha: 0.55).setFill()
                        c.fill(CGRect(x: rect.minX, y: rect.minY, width: 1.5, height: rowH))
                        x += w
                    }
                    UIColor(red: 0.62, green: 0.54, blue: 0.44, alpha: 0.55).setFill()
                    c.fill(CGRect(x: 0, y: CGFloat(r) * rowH, width: side, height: 1.5))
                }
            }
        }
    }
}

// MARK: - Furniture

enum Furniture {
    static func height(_ category: String) -> Double {
        switch category {
        case "bed", "bathtub": return 0.55
        case "sofa", "chair", "toilet": return 0.8
        case "table": return 0.75
        case "refrigerator": return 1.8
        case "television": return 0.5
        case "fireplace": return 1.0
        case "stairs": return 1.0
        default: return 0.9                      // storage, stove, oven, sink, washerDryer, dishwasher
        }
    }

    static func paint(_ c: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.lightingModel = .lambert
        return m
    }

    static func material(_ category: String) -> SCNMaterial {
        switch category {
        case "bed", "sofa", "chair":
            return paint(UIColor(red: 0.74, green: 0.73, blue: 0.85, alpha: 1))     // soft lavender
        case "table", "storage", "stairs", "fireplace":
            return paint(UIColor(red: 0.86, green: 0.81, blue: 0.72, alpha: 1))     // light beige
        case "television":
            return paint(UIColor(red: 0.33, green: 0.35, blue: 0.40, alpha: 1))
        default:
            return paint(UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))     // fixtures, appliances
        }
    }
}
