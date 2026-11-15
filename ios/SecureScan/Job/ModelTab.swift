//
//  ModelTab.swift
//  SecureScan
//
//  3D tab: SceneKit view of model.usdz (or, without one, walls extruded from
//  plan.json) with orbit/zoom, plus the markup in 3D:
//    * readings: status-coloured spheres with a billboarded "3 · 24%" label
//    * moisture-line marks: small blue cubes, and per wall a blue polyline
//      through them (wallT order) with a light translucent fill down to the floor
//    * water sources: a larger blue marker with its label
//    * photo notes: grey "P1" markers
//  Show/hide toggle, "Save image", "Open in AR Quick Look".
//
//  Framing: the camera looks at the model from an elevated three-quarter view
//  at the distance that fits the whole model (CameraFit) with a margin. The
//  bounds are computed from every geometry node in world space (a node's own
//  boundingBox does not include its children's geometry in the way needed).
//  Lighting: ambient + two directional lights (no camera-attached light, which
//  left faces turned away from it black), double-sided materials.
//
//  Positions: items are placed from their plan position + height. For a
//  scanned model, plan-frame.json (written with every plan build) maps plan
//  coordinates back to the scan's world space, so hand-added items appear too;
//  without it (older jobs) the resolved world points in readings-raw.json are
//  used for AR items.
//

import SwiftUI
import SceneKit
import QuickLook
import simd

struct MarkerInfo {
    var kind: String          // "reading" | "boundary" | "photo" | "source"
    var label: String?
    var color: UIColor
    var position: SIMD3<Float>
    /// Labels of nearby markers are stacked: 0 = lowest.
    var level: Int = 0
}

struct MoistureLine3D {
    var points: [SIMD3<Float>]   // in wallT order
    var floorY: [Float]          // floor level under each point
}

struct SceneContent {
    var scene: SCNScene?
    var markers: [MarkerInfo] = []
    var lines: [MoistureLine3D] = []
    /// Removal bands: 4 corners each (bottom a, bottom b, top b, top a); `done` drawn green.
    var bands: [(corners: [SIMD3<Float>], done: Bool)] = []
    var fallback = false
    var error: String?
}

final class SceneBox: @unchecked Sendable {
    let value: SceneContent
    init(_ value: SceneContent) { self.value = value }
}

@MainActor
final class ModelViewModel: ObservableObject {
    @Published var scene: SCNScene?
    @Published var cameraNode: SCNNode?
    @Published var target = SCNVector3Zero
    @Published var showMarkers = true { didSet { markersNode.isHidden = !showMarkers } }
    @Published var loading = false
    @Published var error: String?
    @Published var usingPlanFallback = false
    weak var view: SCNView?
    private let markersNode = SCNNode()
    private var loadedVersion: Int?

    static let background = UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)

    func load(folder: JobFolder, version: Int) {
        guard loadedVersion != version else { return }
        loadedVersion = version
        loading = true
        error = nil
        Task {
            // SCNScene is not Sendable; the box hands it from the background task to
            // the main actor (nothing else touches it in between).
            let box = await Task.detached(priority: .userInitiated) {
                SceneBox(ModelViewModel.buildScene(folder: folder))
            }.value
            let content = box.value
            loading = false
            error = content.error
            usingPlanFallback = content.fallback
            guard let scene = content.scene else { return }

            // Bounds of the model itself (before markers are added).
            let bounds = Self.worldBounds(scene.rootNode)
            let extent = max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z, 1.5)
            Self.addGround(to: scene, bounds: bounds)
            Self.addLights(to: scene)

            markersNode.childNodes.forEach { $0.removeFromParentNode() }
            markersNode.removeFromParentNode()
            let scale = Float(extent)
            for line in content.lines { markersNode.addChildNode(Self.lineNode(line, scale: scale)) }
            for b in content.bands { markersNode.addChildNode(Self.bandNode(b.corners, done: b.done)) }
            for m in content.markers { markersNode.addChildNode(Self.markerNode(m, scale: scale)) }
            markersNode.isHidden = !showMarkers
            scene.rootNode.addChildNode(markersNode)

            let (cam, centre) = Self.frameCamera(scene, bounds: bounds)
            cameraNode = cam
            target = centre
            self.scene = scene
        }
    }

    func snapshotAndShare() {
        guard let v = view, let data = v.snapshot().pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SecureScan-3D.png")
        do {
            try data.write(to: url, options: .atomic)
            Presenter.share([url])
        } catch {
            self.error = "Couldn't save the image: \(error.localizedDescription)"
        }
    }

    // MARK: Scene building (background)

    nonisolated static func status(_ d: [String: Any], damp: Double, wet: Double) -> UIColor {
        let reference = (d["reference"] as? Bool) ?? false
        guard !reference, let v = PlanDocument.number(d["value"]) else { return .systemGray }
        if v < damp { return UIColor(red: 0.18, green: 0.62, blue: 0.33, alpha: 1) }
        if v < wet { return UIColor(red: 0.93, green: 0.60, blue: 0.10, alpha: 1) }
        return UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 1)
    }

    nonisolated static var lineBlue: UIColor { UIColor(red: 0.12, green: 0.43, blue: 0.85, alpha: 1) }

    nonisolated static func buildScene(folder: JobFolder) -> SceneContent {
        let plan = (try? Data(contentsOf: folder.planURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let items = markup["readings"] as? [[String: Any]] ?? []
        let sources = markup["sources"] as? [[String: Any]] ?? []
        let thresholds = markup["thresholds"] as? [String: Any] ?? [:]
        let damp = PlanDocument.number(thresholds["damp"]) ?? 15
        let wet = PlanDocument.number(thresholds["wet"]) ?? 20

        var content = SceneContent()
        let scene: SCNScene
        // Plan item -> 3D point, and the floor level below it.
        let place: ([String: Any]) -> (SIMD3<Float>, Float)?
        // Plan point + height above floor -> 3D point (nil: unknown frame).
        var toWorld: ((PlanVec, Double) -> SIMD3<Float>)? = nil

        if folder.hasModel {
            do { scene = try SCNScene(url: folder.modelURL, options: nil) }
            catch { return SceneContent(error: "The 3D model could not be opened: \(error.localizedDescription)") }
            prepareModelMaterials(scene.rootNode)
            if let frame = JobFiles.loadFrame(folder) {
                let t = frame.transform
                let floorY = frame.floorY ?? Double(worldBounds(scene.rootNode).min.y)
                place = { d in
                    guard let p = ModelViewModel.planPoint(d) else { return nil }
                    let h = PlanDocument.number(d["height"]) ?? 0
                    let w = t.world(p, y: floorY + h)
                    return (SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)), Float(floorY))
                }
                toWorld = { p, h in
                    let w = t.world(p, y: floorY + h)
                    return SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
                }
            } else {
                var resolved: [String: SIMD3<Float>] = [:]
                for r in JobFiles.loadRawReadings(folder) {
                    if let p = r.resolved ?? r.hit, p.count == 3 { resolved[r.id] = SIMD3<Float>(Float(p[0]), Float(p[1]), Float(p[2])) }
                }
                let modelFloor = worldBounds(scene.rootNode).min.y
                place = { d in
                    guard let id = d["id"] as? String, let p = resolved[id] else { return nil }
                    let h = Float(PlanDocument.number(d["height"]) ?? Double(p.y - modelFloor))
                    return (p, p.y - h)
                }
            }
        } else {
            // Fallback: walls extruded from plan.json, plan coordinates (x, height, y).
            guard !plan.isEmpty else { return SceneContent(error: "This job has no 3D model and no plan yet.") }
            scene = planScene(plan)
            content.fallback = true
            place = { d in
                guard let p = ModelViewModel.planPoint(d) else { return nil }
                let h = PlanDocument.number(d["height"]) ?? 0
                return (SIMD3<Float>(Float(p.x), Float(h), Float(p.y)), 0)
            }
            toWorld = { p, h in SIMD3<Float>(Float(p.x), Float(h), Float(p.y)) }
        }

        var byId: [String: (SIMD3<Float>, Float)] = [:]
        var marks: [MoistureLines.Mark] = []
        for d in items {
            guard let placed = place(d) else { continue }
            let pos = placed.0
            let kind = (d["kind"] as? String) ?? "reading"
            let n = PlanDocument.number(d["n"]).map { Int($0) }
            switch kind {
            case "boundary":
                content.markers.append(MarkerInfo(kind: kind, label: nil, color: lineBlue, position: pos))
                if let id = d["id"] as? String {
                    byId[id] = placed
                    marks.append(MoistureLines.Mark(id: id, wallId: d["wallId"] as? String, wallT: PlanDocument.number(d["wallT"])))
                }
            case "photo":
                content.markers.append(MarkerInfo(kind: kind, label: n.map { "P\($0)" } ?? "P", color: .systemGray, position: pos))
            default:
                let reference = (d["reference"] as? Bool) ?? false
                var label = n.map { "\($0)\(reference ? "R" : "")" } ?? "–"
                if let v = PlanDocument.number(d["value"]) { label += " · \(ScanModel.format(v))%" }
                content.markers.append(MarkerInfo(kind: kind, label: label, color: status(d, damp: damp, wet: wet), position: pos))
            }
        }
        for d in sources {
            guard let placed = place(d) else { continue }
            let pos = placed.0
            let text = ((d["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            content.markers.append(MarkerInfo(kind: "source", label: text.isEmpty ? "Source" : "Source · \(text)",
                                              color: lineBlue, position: pos))
        }
        for d in markup["equipment"] as? [[String: Any]] ?? [] {
            // Only equipment still on site.
            if let removed = d["removed"], !(removed is NSNull) { continue }
            guard let placed = place(d) else { continue }
            let label = ((d["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let name = PlanDocument.equipmentName((d["type"] as? String) ?? "other")
            // Short labels (the asset number when there is one) so they don't cover readings.
            content.markers.append(MarkerInfo(kind: "equipment", label: label.isEmpty ? name : label,
                                              color: UIColor(red: 0.20, green: 0.45, blue: 0.50, alpha: 1),
                                              position: placed.0 + SIMD3<Float>(0, 0.08, 0)))
        }
        // Removals: a band on the wall t0..t1 up to the cut height; flooring
        // sections as a low band round their outline.
        if let toWorld {
            let walls = Dictionary(Revisit.walls(plan).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for x in markup["removals"] as? [[String: Any]] ?? [] {
                let done = (x["status"] as? String) == "done"
                if let wid = x["wallId"] as? String, let w = walls[wid] {
                    let t0 = PlanDocument.number(x["t0"]) ?? 0, t1 = PlanDocument.number(x["t1"]) ?? 1
                    let item = (x["item"] as? String) ?? "other"
                    let top = item == "flooring" ? 0.05 : min(max((PlanDocument.number(x["heightMm"]) ?? 600) / 1000, 0.05), w.height)
                    let p0 = w.a + (w.b - w.a) * t0, p1 = w.a + (w.b - w.a) * t1
                    content.bands.append(([toWorld(p0, 0), toWorld(p1, 0), toWorld(p1, top), toWorld(p0, top)], done))
                } else if let area = x["area"] as? [Any] {
                    let pts = area.compactMap { Revisit.point($0) }
                    guard pts.count >= 3 else { continue }
                    for i in pts.indices {
                        let a = pts[i], b = pts[(i + 1) % pts.count]
                        content.bands.append(([toWorld(a, 0.005), toWorld(b, 0.005), toWorld(b, 0.06), toWorld(a, 0.06)], done))
                    }
                }
            }
        }
        stackLabels(&content.markers)
        for ids in MoistureLines.lines(marks) {
            let pts = ids.compactMap { byId[$0] }
            guard pts.count >= 2 else { continue }
            content.lines.append(MoistureLine3D(points: pts.map { $0.0 }, floorY: pts.map { $0.1 }))
        }
        content.scene = scene
        return content
    }

    /// Gives each label the lowest level not used by an earlier label within
    /// 0.8 m (horizontally), so labels of neighbouring markers (e.g. both
    /// sides of a wall) don't sit on top of each other.
    nonisolated static func stackLabels(_ markers: inout [MarkerInfo]) {
        var placed: [(SIMD2<Float>, Int)] = []
        for i in markers.indices where markers[i].label != nil {
            let p = SIMD2<Float>(markers[i].position.x, markers[i].position.z)
            let used = Set(placed.filter { simd_distance($0.0, p) < 0.8 }.map { $0.1 })
            var level = 0
            while used.contains(level) { level += 1 }
            markers[i].level = level
            placed.append((p, level))
        }
    }

    nonisolated static func planPoint(_ d: [String: Any]) -> PlanVec? {
        guard let pos = d["pos"] as? [Any], pos.count == 2,
              let x = PlanDocument.number(pos[0]), let y = PlanDocument.number(pos[1]) else { return nil }
        return PlanVec(x, y)
    }

    /// Double-sided, evenly lit materials for the scanned model.
    nonisolated static func prepareModelMaterials(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] {
                m.isDoubleSided = true
                m.lightingModel = .lambert
            }
        }
    }

    nonisolated static var roomTints: [UIColor] { [
        UIColor(red: 0.78, green: 0.85, blue: 0.96, alpha: 1),
        UIColor(red: 0.80, green: 0.92, blue: 0.83, alpha: 1),
        UIColor(red: 0.96, green: 0.89, blue: 0.77, alpha: 1),
        UIColor(red: 0.89, green: 0.83, blue: 0.96, alpha: 1),
    ] }

    nonisolated static func planScene(_ plan: [String: Any]) -> SCNScene {
        let scene = SCNScene()
        let wallMaterial = SCNMaterial()
        wallMaterial.diffuse.contents = UIColor(red: 0.80, green: 0.81, blue: 0.86, alpha: 1)
        wallMaterial.lightingModel = .lambert
        wallMaterial.isDoubleSided = true
        for w in plan["walls"] as? [[String: Any]] ?? [] {
            guard let a = w["a"] as? [Any], let b = w["b"] as? [Any], a.count == 2, b.count == 2,
                  let ax = PlanDocument.number(a[0]), let ay = PlanDocument.number(a[1]),
                  let bx = PlanDocument.number(b[0]), let by = PlanDocument.number(b[1]) else { continue }
            let h = PlanDocument.number(w["height"]) ?? 2.4
            let dx = bx - ax, dy = by - ay
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0.01 else { continue }
            // Slightly longer than the wall so corners close.
            let box = SCNBox(width: CGFloat(len + 0.1), height: CGFloat(h), length: 0.1, chamferRadius: 0)
            box.materials = [wallMaterial]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(Float((ax + bx) / 2), Float(h / 2), Float((ay + by) / 2))
            // Rotation about +Y by θ maps local +X to (cosθ, 0, -sinθ); we want (dx, 0, dy)/len.
            node.eulerAngles = SCNVector3(0, Float(atan2(-dy, dx)), 0)
            scene.rootNode.addChildNode(node)
        }
        // Room floors, pale tint per room.
        for (i, r) in (plan["rooms"] as? [[String: Any]] ?? []).enumerated() {
            let poly = (r["polygon"] as? [[Any]] ?? []).compactMap { p -> CGPoint? in
                guard p.count == 2, let x = PlanDocument.number(p[0]), let y = PlanDocument.number(p[1]) else { return nil }
                return CGPoint(x: x, y: y)
            }
            guard poly.count >= 3 else { continue }
            let path = UIBezierPath()
            path.move(to: poly[0])
            for p in poly.dropFirst() { path.addLine(to: p) }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.02)
            let m = SCNMaterial()
            m.diffuse.contents = roomTints[i % roomTints.count]
            m.lightingModel = .lambert
            m.isDoubleSided = true
            shape.materials = [m]
            let node = SCNNode(geometry: shape)
            // Shape lies in its x-y plane; +90° about X maps (x, y, 0) to (x, 0, y).
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            node.position = SCNVector3(0, -0.01, 0)
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    // MARK: Scene dressing (main)

    /// Axis-aligned bounds of every geometry in world space.
    nonisolated static func worldBounds(_ root: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            let m = node.simdWorldTransform
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = m * SIMD4<Float>(x, y, z, 1)
                lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
            } } }
        }
        if lo.x > hi.x { return (SIMD3(-1, 0, -1), SIMD3(1, 2.4, 1)) }
        return (lo, hi)
    }

    static func addGround(to scene: SCNScene, bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        let w = bounds.max.x - bounds.min.x + 2, d = bounds.max.z - bounds.min.z + 2
        let plane = SCNPlane(width: CGFloat(w), height: CGFloat(d))
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        m.lightingModel = .lambert
        m.isDoubleSided = true
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)       // lie flat, facing up
        node.position = SCNVector3((bounds.min.x + bounds.max.x) / 2, bounds.min.y - 0.025, (bounds.min.z + bounds.max.z) / 2)
        scene.rootNode.addChildNode(node)
    }

    static func addLights(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 420
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        func directional(_ intensity: CGFloat, _ euler: SCNVector3) {
            let n = SCNNode()
            n.light = SCNLight()
            n.light?.type = .directional
            n.light?.intensity = intensity
            n.light?.color = UIColor.white
            n.eulerAngles = euler
            scene.rootNode.addChildNode(n)
        }
        directional(560, SCNVector3(-Float.pi / 3, Float.pi / 5, 0))        // key, from above front-right
        directional(300, SCNVector3(-Float.pi / 4, Float.pi + Float.pi / 4, 0)) // fill, from behind-left
    }

    /// Elevated three-quarter view of the whole model with a margin.
    static func frameCamera(_ scene: SCNScene, bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> (SCNNode, SCNVector3) {
        let lo = SIMD3<Double>(bounds.min), hi = SIMD3<Double>(bounds.max)
        let centre = (lo + hi) / 2
        var corners: [SIMD3<Double>] = []
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] { corners.append(SIMD3(x, y, z)) } } }
        // SECURESCAN_3D_AZIMUTH (degrees) is for automated screenshots only.
        let azimuth = ProcessInfo.processInfo.environment["SECURESCAN_3D_AZIMUTH"].flatMap { Double($0) } ?? 28
        let dir = CameraFit.direction(azimuthDegrees: azimuth, elevationDegrees: 58)
        let fov = 50.0
        let tanH = tan(fov / 2 * .pi / 180)
        let tanV = tanH / 0.62                       // portrait view, roughly w/h = 0.62
        let d = CameraFit.distance(points: corners, target: centre, direction: dir, tanH: tanH, tanV: tanV, margin: 0.94)
        let pos = centre + dir * d

        let cam = SCNNode()
        cam.name = "frame-camera"
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = CGFloat(fov)
        camera.zNear = 0.05
        camera.zFar = max(100, d * 6)
        cam.camera = camera
        cam.simdPosition = SIMD3<Float>(pos)
        let c = SCNVector3(Float(centre.x), Float(centre.y), Float(centre.z))
        cam.look(at: c, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(cam)
        return (cam, c)
    }

    // MARK: Markup nodes (main)

    /// Material that draws on top of the model, so markers are never hidden
    /// inside or behind walls.
    static func overlayMaterial(_ color: UIColor, constant: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = constant ? .constant : .lambert
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    static func markerNode(_ m: MarkerInfo, scale: Float) -> SCNNode {
        let node = SCNNode()
        node.simdPosition = m.position
        node.renderingOrder = 200
        let r = CGFloat(max(0.05, min(0.14, scale * 0.012)))
        let geometry: SCNGeometry
        switch m.kind {
        case "boundary": geometry = SCNBox(width: r * 1.1, height: r * 1.1, length: r * 1.1, chamferRadius: r * 0.1)
        case "source": geometry = SCNSphere(radius: r * 1.5)
        case "photo": geometry = SCNSphere(radius: r * 0.9)
        case "equipment": geometry = SCNBox(width: r * 1.8, height: r * 1.1, length: r * 1.8, chamferRadius: r * 0.25)
        default: geometry = SCNSphere(radius: r)
        }
        geometry.materials = [overlayMaterial(m.color)]
        let dot = SCNNode(geometry: geometry)
        dot.renderingOrder = 200
        node.addChildNode(dot)
        if m.kind == "source" {
            // White ring so the source reads as a target, not a reading.
            let ring = SCNTorus(ringRadius: r * 2.1, pipeRadius: r * 0.28)
            ring.materials = [overlayMaterial(lineBlue)]
            let rn = SCNNode(geometry: ring)
            rn.renderingOrder = 201
            rn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)    // ring faces +Z...
            let facing = SCNNode()
            facing.constraints = [SCNBillboardConstraint()]    // ...and +Z faces the camera
            facing.addChildNode(rn)
            node.addChildNode(facing)
        }

        if let text = m.label, let image = labelImage(text, accent: m.color) {
            let height = CGFloat(max(0.16, min(0.45, scale * 0.055)))
            let plane = SCNPlane(width: height * image.size.width / image.size.height, height: height)
            let lm = overlayMaterial(.white)
            lm.diffuse.contents = image
            plane.materials = [lm]
            let labelNode = SCNNode(geometry: plane)
            labelNode.renderingOrder = 210
            // The container faces the camera, so its local "up" is screen-up:
            // stacked labels stay apart however steeply the camera looks down.
            let lift = r * (m.kind == "source" ? 2.6 : 1.4) + height / 2 + CGFloat(m.level) * height * 1.2
            labelNode.position = SCNVector3(0, Float(lift), 0)
            let facing = SCNNode()
            facing.constraints = [SCNBillboardConstraint()]
            facing.addChildNode(labelNode)
            node.addChildNode(facing)
        }
        return node
    }

    /// Polyline through the marks plus a translucent fill down to the floor,
    /// both drawn over the model so they show from either side of the wall.
    static func lineNode(_ line: MoistureLine3D, scale: Float) -> SCNNode {
        let node = SCNNode()
        let pts = line.points
        guard pts.count >= 2, line.floorY.count == pts.count else { return node }

        // Fill: one quad strip in the wall's plane, drawn over the wall (a wall
        // has two faces and the neighbouring room's wall may be right behind
        // it, so a depth-tested fill would be hidden from one side).
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for (i, p) in pts.enumerated() {
            let bottom = SIMD3<Float>(p.x, line.floorY[i], p.z)
            vertices.append(SCNVector3(p.x, p.y, p.z))
            vertices.append(SCNVector3(bottom.x, bottom.y, bottom.z))
        }
        for i in 0..<(pts.count - 1) {
            let t0 = Int32(i * 2), b0 = t0 + 1, t1 = t0 + 2, b1 = t0 + 3
            indices += [b0, b1, t1, b0, t1, t0]
        }
        let fill = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let fm = SCNMaterial()
        fm.diffuse.contents = lineBlue.withAlphaComponent(0.42)
        fm.lightingModel = .constant
        fm.isDoubleSided = true
        fm.readsFromDepthBuffer = false
        fm.writesToDepthBuffer = false
        fill.materials = [fm]
        let fillNode = SCNNode(geometry: fill)
        fillNode.renderingOrder = 150
        node.addChildNode(fillNode)

        // Line: thin tubes between consecutive marks, drawn on top.
        let radius = CGFloat(max(0.015, min(0.045, scale * 0.005)))
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let v = b - a
            let len = simd_length(v)
            guard len > 1e-4 else { continue }
            let tube = SCNCylinder(radius: radius, height: CGFloat(len))
            tube.materials = [overlayMaterial(lineBlue)]
            let tn = SCNNode(geometry: tube)
            tn.simdPosition = (a + b) / 2
            tn.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: v / len)
            tn.renderingOrder = 190
            node.addChildNode(tn)
        }
        return node
    }

    /// Translucent red (done: green) quad, drawn over the model.
    static func bandNode(_ c: [SIMD3<Float>], done: Bool) -> SCNNode {
        guard c.count == 4 else { return SCNNode() }
        let src = SCNGeometrySource(vertices: c.map { SCNVector3($0.x, $0.y, $0.z) })
        let el = SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [el])
        let m = SCNMaterial()
        m.diffuse.contents = done ? UIColor(red: 0.18, green: 0.62, blue: 0.33, alpha: 0.40) : UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.40)
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.renderingOrder = 140
        return n
    }

    static func labelImage(_ text: String, accent: UIColor) -> UIImage? {
        let font = UIFont.systemFont(ofSize: 44, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 0.1, alpha: 1)]
        let size = (text as NSString).size(withAttributes: attrs)
        let dot: CGFloat = 26
        let canvas = CGSize(width: ceil(size.width) + 40 + dot + 12, height: ceil(size.height) + 20)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: canvas).insetBy(dx: 2, dy: 2)
            let pill = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
            UIColor.white.setFill()
            pill.fill()
            UIColor(white: 0.25, alpha: 1).setStroke()
            pill.lineWidth = 3
            pill.stroke()
            accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: 20, y: (canvas.height - dot) / 2, width: dot, height: dot)).fill()
            (text as NSString).draw(at: CGPoint(x: 20 + dot + 12, y: 10), withAttributes: attrs)
        }
    }
}

struct ModelTab: View {
    @ObservedObject var vm: JobViewModel
    @StateObject private var model = ModelViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.scene != nil {
                SceneContainer(model: model)
            } else if model.loading {
                ProgressView("Loading 3D…")
            } else {
                ContentUnavailableView("No 3D view", systemImage: "cube.transparent",
                                       description: Text(model.error ?? vm.meta?.note ?? "This job has no 3D model."))
            }
            if model.scene != nil { controls }
        }
        .onAppear { model.load(folder: vm.folder, version: vm.planVersion) }
        .onChange(of: vm.planVersion) { _, v in model.load(folder: vm.folder, version: v) }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if model.usingPlanFallback {
                Text("No scanned 3D model for this job — showing walls drawn from the plan.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Toggle(isOn: $model.showMarkers) { Text("Markers").font(.headline) }
                    .toggleStyle(.button)
                Button { model.snapshotAndShare() } label: { Label("Save image", systemImage: "camera") }
                    .buttonStyle(.bordered)
                if vm.hasModel {
                    Button { Presenter.quickLook(vm.folder.modelURL) } label: { Label("AR", systemImage: "arkit") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Open in AR Quick Look")
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}

struct SceneContainer: UIViewRepresentable {
    @ObservedObject var model: ModelViewModel

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = false      // the scene has its own lights
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = ModelViewModel.background
        apply(v)
        model.view = v
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        if v.scene !== model.scene { apply(v) }
    }

    private func apply(_ v: SCNView) {
        v.scene = model.scene
        v.pointOfView = model.cameraNode
        // Orbit around the middle of the model, keeping "up" up.
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.target = model.target
        v.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
    }
}

/// Share sheet and Quick Look from SwiftUI.
@MainActor
enum Presenter {
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    static func share(_ items: [Any]) {
        guard let top = topViewController() else { return }
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = top.view
        top.present(ac, animated: true)
    }

    private static let quickLookSource = QuickLookSource()

    static func quickLook(_ url: URL) {
        guard let top = topViewController() else { return }
        quickLookSource.url = url
        let ql = QLPreviewController()
        ql.dataSource = quickLookSource
        top.present(ql, animated: true)
    }
}

final class QuickLookSource: NSObject, QLPreviewControllerDataSource {
    var url: URL?
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
