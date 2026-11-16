//
//  ModelTab.swift
//  SecureScan
//
//  3D tab: the job as a dollhouse (Dollhouse.swift) on a warm light canvas,
//  with the markup in 3D: reading pins with value labels, moisture lines,
//  removal bands wrapped round the walls (red; done = green), lifted flooring
//  on the floor, equipment, photo notes and the water source.
//
//  Controls (Polycam-style, floating over the canvas):
//    top-left   Orbit / Plan switch (perspective orbit, or top-down plan),
//               Layers menu (readings, moisture lines, removals, equipment,
//               photos & source, furniture)
//    top-right  reset view, measure (tap two points), save image, AR view
//  One finger orbits (plan: pans), two fingers pan, pinch zooms, with
//  inertia; double-tap a room to focus on it.
//

import SwiftUI
import SceneKit
import QuickLook
import simd

struct MarkerInfo {
    var kind: String          // "reading" | "boundary" | "photo" | "source" | "equipment"
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

/// What the background build hands to the main actor.
struct SceneContent {
    var built: Dollhouse.Built?
    var markers: [MarkerInfo] = []
    var lines: [MoistureLine3D] = []
    /// Wall removals: plan ends, top height, done.
    var wallBands: [(a: PlanVec, b: PlanVec, top: Double, done: Bool)] = []
    /// Lifted flooring: outline, done.
    var floorAreas: [(poly: [PlanVec], done: Bool)] = []
    var error: String?
}

final class SceneBox: @unchecked Sendable {
    let value: SceneContent
    init(_ value: SceneContent) { self.value = value }
}

enum ModelLayer: String, CaseIterable, Identifiable {
    case readings = "Readings", lines = "Moisture lines", removals = "Removals",
         equipment = "Equipment", photos = "Photos and source", furniture = "Furniture"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .readings: return "percent"
        case .lines: return "point.topleft.down.to.point.bottomright.curvepath"
        case .removals: return "scissors"
        case .equipment: return "fan"
        case .photos: return "camera"
        case .furniture: return "bed.double"
        }
    }
}

@MainActor
final class ModelViewModel: ObservableObject {
    enum Mode { case orbit, plan }

    @Published var ready = false
    @Published var loading = false
    @Published var error: String?
    @Published var mode: Mode = ProcessInfo.processInfo.environment["SECURESCAN_3D_MODE"] == "plan" ? .plan : .orbit
    @Published var hidden: Set<ModelLayer> = []
    @Published var measuring = false
    @Published var measureText: String?

    private(set) var scene: SCNScene?
    private(set) var rooms: [Dollhouse.Room] = []
    private(set) var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)
    private(set) var fitPoints: [SIMD3<Float>] = []
    private(set) var target = SIMD3<Float>.zero
    weak var view: SCNView?
    private var layers: [ModelLayer: SCNNode] = [:]
    private let measureNode = SCNNode()
    private var measurePoints: [SIMD3<Float>] = []
    private var loadedVersion: Int?
    private var folder: JobFolder?

    func load(folder: JobFolder, version: Int) {
        guard loadedVersion != version else { return }
        loadedVersion = version
        self.folder = folder
        loading = true
        error = nil
        Task {
            // SCNScene is not Sendable; the box hands it from the background task
            // to the main actor (nothing else touches it in between).
            let box = await Task.detached(priority: .userInitiated) { SceneBox(ModelViewModel.buildContent(folder: folder)) }.value
            let content = box.value
            loading = false
            error = content.error
            guard let built = content.built else { ready = false; return }
            assemble(built, content)
        }
    }

    private func assemble(_ built: Dollhouse.Built, _ content: SceneContent) {
        let root = built.scene.rootNode
        let extent = max(built.bounds.max.x - built.bounds.min.x, built.bounds.max.z - built.bounds.min.z, 1.5)
        Dollhouse.addLights(root, extent: extent)

        layers = [:]
        for l in ModelLayer.allCases where l != .furniture {
            let n = SCNNode()
            n.name = "layer:" + l.rawValue
            root.addChildNode(n)
            layers[l] = n
        }
        layers[.furniture] = built.furniture
        let scale = Float(extent)
        for line in content.lines { layers[.lines]!.addChildNode(Self.lineNode(line, scale: scale)) }
        for b in content.wallBands { layers[.removals]!.addChildNode(Self.wallBandNode(b.a, b.b, top: b.top, done: b.done)) }
        for f in content.floorAreas { if let n = Self.floorAreaNode(f.poly, done: f.done) { layers[.removals]!.addChildNode(n) } }
        for m in content.markers {
            let layer: ModelLayer
            switch m.kind {
            case "equipment": layer = .equipment
            case "photo", "source": layer = .photos
            case "boundary": layer = .lines
            default: layer = .readings
            }
            layers[layer]!.addChildNode(Self.markerNode(m, scale: scale))
        }
        for l in ModelLayer.allCases where l != .furniture {
            layers[l]!.enumerateHierarchy { n, _ in n.categoryBitMask = Dollhouse.markupCategory }
        }
        measureNode.childNodes.forEach { $0.removeFromParentNode() }
        measureNode.removeFromParentNode()
        root.addChildNode(measureNode)
        applyLayers()

        scene = built.scene
        rooms = built.rooms
        bounds = built.bounds
        fitPoints = built.fitPoints
        ready = true
    }

    // MARK: View state

    func toggle(_ l: ModelLayer) {
        if hidden.contains(l) { hidden.remove(l) } else { hidden.insert(l) }
        applyLayers()
    }

    private func applyLayers() {
        for (l, n) in layers { n.isHidden = hidden.contains(l) }
    }

    var aspect: Double {
        guard let v = view, v.bounds.height > 0 else { return 0.62 }
        return Double(v.bounds.width / v.bounds.height)
    }

    /// The default camera for the current mode, installed on the view.
    func resetView(animated: Bool = true) {
        guard let v = view, let scene else { return }
        let azimuth = ProcessInfo.processInfo.environment["SECURESCAN_3D_AZIMUTH"].flatMap { Double($0) } ?? 28
        // Plan: leave the side columns of buttons clear.
        let (cam, centre) = Dollhouse.camera(lo: bounds.min, hi: bounds.max, aspect: aspect, plan: mode == .plan, points: fitPoints,
                                             azimuth: azimuth, margin: mode == .plan ? 0.66 : 0.8,
                                             lift: mode == .plan ? 0.12 : 0.2, shiftLeft: 0.1)
        install(cam, centre: centre, in: v, scene: scene, animated: animated)
    }

    private func install(_ cam: SCNNode, centre: SIMD3<Float>, in v: SCNView, scene: SCNScene, animated: Bool) {
        target = centre
        if animated, let pov = v.pointOfView, pov.camera?.usesOrthographicProjection == cam.camera?.usesOrthographicProjection {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.45
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pov.simdPosition = cam.simdPosition
            pov.simdOrientation = cam.simdOrientation
            if let c = cam.camera, c.usesOrthographicProjection { pov.camera?.orthographicScale = c.orthographicScale }
            SCNTransaction.commit()
        } else {
            v.pointOfView?.removeFromParentNode()
            scene.rootNode.addChildNode(cam)
            v.pointOfView = cam
        }
        configureController(v)
    }

    func configureController(_ v: SCNView) {
        let c = v.defaultCameraController
        c.interactionMode = mode == .plan ? .pan : .orbitTurntable
        c.inertiaEnabled = true
        c.inertiaFriction = 0.12
        c.worldUp = SCNVector3(0, 1, 0)
        c.target = SCNVector3(target.x, target.y, target.z)
        c.minimumVerticalAngle = 8
        c.maximumVerticalAngle = 89
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        resetView(animated: false)
    }

    /// Double-tap: frame the room under the finger.
    func focusRoom(at point: CGPoint) {
        guard let v = view, let scene, let pov = v.pointOfView else { return }
        let hits = v.hitTest(point, options: [.categoryBitMask: Dollhouse.solidCategory,
                                              .searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first else { return }
        let p = PlanVec(Double(hit.simdWorldCoordinates.x), Double(hit.simdWorldCoordinates.z))
        guard let room = rooms.first(where: { FloorArea.inside(p, $0.polygon) }) ?? nearestRoom(p) else { return }
        let lo = room.min - SIMD3(0.3, 0, 0.3), hi = room.max + SIMD3(0.3, 0, 0.3)
        if mode == .plan {
            let (cam, centre) = Dollhouse.camera(lo: lo, hi: hi, aspect: aspect, plan: true, margin: 0.7)
            install(cam, centre: centre, in: v, scene: scene, animated: true)
        } else {
            // Keep the current viewing direction.
            let d = simd_normalize(pov.simdWorldPosition - target)
            let el = Double(asin(max(-1, min(1, d.y)))) * 180 / .pi
            let az = Double(atan2(d.x, d.z)) * 180 / .pi
            let (cam, centre) = Dollhouse.camera(lo: lo, hi: hi, aspect: aspect, plan: false, azimuth: az, elevation: max(20, el), margin: 0.85)
            install(cam, centre: centre, in: v, scene: scene, animated: true)
        }
    }

    private func nearestRoom(_ p: PlanVec) -> Dollhouse.Room? {
        func d(_ r: Dollhouse.Room) -> Double {
            let c = PlanBuilder.centroid(r.polygon)
            return ((c - p) * (c - p)).sum()
        }
        return rooms.min { d($0) < d($1) }
    }

    // MARK: Measure

    func toggleMeasure() {
        measuring.toggle()
        clearMeasure()
    }

    func clearMeasure() {
        measurePoints = []
        measureText = nil
        measureNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    func measureTap(at point: CGPoint) {
        guard measuring, let v = view else { return }
        let hits = v.hitTest(point, options: [.categoryBitMask: Dollhouse.solidCategory,
                                              .searchMode: SCNHitTestSearchMode.closest.rawValue])
        guard let hit = hits.first else { return }
        if measurePoints.count >= 2 { clearMeasure() }
        let p = hit.simdWorldCoordinates
        measurePoints.append(p)
        let dot = SCNNode(geometry: SCNSphere(radius: 0.045))
        dot.geometry?.materials = [Self.overlayMaterial(UIColor(white: 0.08, alpha: 1))]
        dot.simdPosition = p
        dot.renderingOrder = 300
        measureNode.addChildNode(dot)
        if measurePoints.count == 2 {
            let a = measurePoints[0], b = measurePoints[1]
            let len = simd_distance(a, b)
            if len > 1e-4 {
                let tube = SCNCylinder(radius: 0.018, height: CGFloat(len))
                tube.materials = [Self.overlayMaterial(UIColor(white: 0.08, alpha: 1))]
                let t = SCNNode(geometry: tube)
                t.simdPosition = (a + b) / 2
                t.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: (b - a) / len)
                t.renderingOrder = 299
                measureNode.addChildNode(t)
            }
            measureText = String(format: "%.2f m", len)
        }
        DS.Haptic.lock()
    }

    // MARK: Share, AR

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

    /// AR Quick Look: the scanned model when there is one, else the dollhouse as USDZ.
    func openAR() {
        guard let folder else { return }
        if folder.hasModel { Presenter.quickLook(folder.modelURL); return }
        let plan = (try? Data(contentsOf: folder.planURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        guard let built = Dollhouse.build(plan: plan) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SecureScan-dollhouse.usdz")
        try? FileManager.default.removeItem(at: url)
        if built.scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) {
            Presenter.quickLook(url)
        } else {
            error = "The 3D view couldn't be opened in AR."
        }
    }

    // MARK: Content (background)

    nonisolated static func status(_ d: [String: Any], damp: Double, wet: Double) -> UIColor {
        guard let v = PlanDocument.number(d["value"]) else { return .systemGray }
        if v < damp { return UIColor(DS.Color.dry) }
        if v < wet { return UIColor(DS.Color.damp) }
        return UIColor(DS.Color.wet)
    }

    nonisolated static var lineBlue: UIColor { UIColor(DS.Color.source) }

    nonisolated static func buildContent(folder: JobFolder) -> SceneContent {
        let plan = (try? Data(contentsOf: folder.planURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard !plan.isEmpty else { return SceneContent(error: "This job has no plan yet. Scan it to see it in 3D.") }
        guard let built = Dollhouse.build(plan: plan) else { return SceneContent(error: "This plan has no rooms to show in 3D.") }
        var content = SceneContent(built: built)
        let markup = plan["markup"] as? [String: Any] ?? [:]
        let thresholds = markup["thresholds"] as? [String: Any] ?? [:]
        let damp = PlanDocument.number(thresholds["damp"]) ?? 15
        let wet = PlanDocument.number(thresholds["wet"]) ?? 20
        let cut = Float(Dollhouse.cutHeight)
        func place(_ d: [String: Any]) -> SIMD3<Float>? {
            guard let p = ScopeList.pt(d["pos"]) else { return nil }
            let h = Float(PlanDocument.number(d["height"]) ?? 0)
            return SIMD3<Float>(Float(p.x), min(h, cut), Float(p.y))
        }

        var byId: [String: SIMD3<Float>] = [:]
        var marks: [MoistureLines.Mark] = []
        for d in markup["readings"] as? [[String: Any]] ?? [] {
            guard let pos = place(d) else { continue }
            let kind = (d["kind"] as? String) ?? "reading"
            let n = PlanDocument.number(d["n"]).map { Int($0) }
            switch kind {
            case "boundary":
                content.markers.append(MarkerInfo(kind: kind, label: nil, color: lineBlue, position: pos))
                if let id = d["id"] as? String {
                    byId[id] = pos
                    marks.append(MoistureLines.Mark(id: id, wallId: d["wallId"] as? String, wallT: PlanDocument.number(d["wallT"])))
                }
            case "photo":
                content.markers.append(MarkerInfo(kind: kind, label: n.map { "P\($0)" } ?? "P", color: .systemGray, position: pos))
            default:
                var label = n.map { "R\($0)" } ?? "R"
                if let v = PlanDocument.number(d["value"]) { label += " · \(ItemsModel.fmt(v))%" }
                content.markers.append(MarkerInfo(kind: kind, label: label, color: status(d, damp: damp, wet: wet), position: pos))
            }
        }
        for d in markup["sources"] as? [[String: Any]] ?? [] {
            guard let pos = place(d) else { continue }
            let text = ((d["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            content.markers.append(MarkerInfo(kind: "source", label: text.isEmpty ? "Source" : text, color: lineBlue, position: pos))
        }
        for d in markup["equipment"] as? [[String: Any]] ?? [] {
            if let removed = d["removed"], !(removed is NSNull), (removed as? String)?.isEmpty != true { continue }
            guard let p = ScopeList.pt(d["pos"]) else { continue }
            // No label: the teal unit reads as equipment, and its asset number
            // (in Items) would cover the readings' labels.
            content.markers.append(MarkerInfo(kind: "equipment", label: nil,
                                              color: UIColor(DS.Color.equip), position: SIMD3(Float(p.x), 0.12, Float(p.y))))
        }
        let walls = Dictionary(Revisit.walls(plan).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            let done = (x["status"] as? String) == "done"
            if let wid = x["wallId"] as? String, let w = walls[wid] {
                let t0 = PlanDocument.number(x["t0"]) ?? 0, t1 = PlanDocument.number(x["t1"]) ?? 1
                let item = (x["item"] as? String) ?? "other"
                let mm = PlanDocument.number(x["heightMm"]) ?? (item == "skirting" ? 100 : 600)
                let top = min(max(mm / 1000, 0.08), Dollhouse.cutHeight)
                content.wallBands.append((w.a + (w.b - w.a) * t0, w.a + (w.b - w.a) * t1, top, done))
            } else if let area = (x["area"] as? [Any])?.compactMap(ScopeList.pt), area.count >= 3 {
                content.floorAreas.append((area, done))
            }
        }
        stackLabels(&content.markers)
        for ids in MoistureLines.lines(marks) {
            let pts = ids.compactMap { byId[$0] }
            guard pts.count >= 2 else { continue }
            content.lines.append(MoistureLine3D(points: pts, floorY: pts.map { _ in 0 }))
        }
        return content
    }

    /// Gives each label the lowest level not used by an earlier label within
    /// 0.8 m (horizontally), so neighbouring labels don't sit on top of each other.
    nonisolated static func stackLabels(_ markers: inout [MarkerInfo]) {
        var placed: [(SIMD2<Float>, Int)] = []
        for i in markers.indices where markers[i].label != nil {
            let p = SIMD2<Float>(markers[i].position.x, markers[i].position.z)
            let used = Set(placed.filter { simd_distance($0.0, p) < 1.1 }.map { $0.1 })
            var level = 0
            while used.contains(level) { level += 1 }
            markers[i].level = level
            placed.append((p, level))
        }
    }

    // MARK: Markup nodes (main)

    /// Drawn on top of the model, so markers are never hidden behind walls.
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
        let r = CGFloat(max(0.06, min(0.12, scale * 0.014)))
        let geometry: SCNGeometry
        switch m.kind {
        case "boundary": geometry = SCNBox(width: r * 0.9, height: r * 0.9, length: r * 0.9, chamferRadius: r * 0.1)
        case "source": geometry = SCNSphere(radius: r * 1.3)
        case "photo": geometry = SCNBox(width: r * 1.5, height: r * 1.5, length: r * 1.5, chamferRadius: r * 0.3)
        case "equipment": geometry = SCNBox(width: r * 2.4, height: r * 1.6, length: r * 2.4, chamferRadius: r * 0.4)
        default: geometry = SCNSphere(radius: r)
        }
        geometry.materials = [overlayMaterial(m.color)]
        let dot = SCNNode(geometry: geometry)
        dot.renderingOrder = 200
        node.addChildNode(dot)
        if m.kind == "reading" || m.kind == "source" {
            // White ring round the head reads as a pin, from any angle.
            let ring = SCNTorus(ringRadius: r * (m.kind == "source" ? 1.9 : 1.25), pipeRadius: r * 0.22)
            ring.materials = [overlayMaterial(.white)]
            let rn = SCNNode(geometry: ring)
            rn.renderingOrder = 201
            rn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            let facing = SCNNode()
            facing.constraints = [SCNBillboardConstraint()]
            facing.addChildNode(rn)
            node.addChildNode(facing)
        }
        if let text = m.label, let image = labelImage(text, accent: m.color) {
            let height = CGFloat(max(0.3, min(0.55, scale * 0.07)))
            let plane = SCNPlane(width: height * image.size.width / image.size.height, height: height)
            let lm = overlayMaterial(.white)
            lm.diffuse.contents = image
            plane.materials = [lm]
            let labelNode = SCNNode(geometry: plane)
            labelNode.name = "label"
            labelNode.renderingOrder = 210
            let lift = r * 1.6 + height / 2 + CGFloat(m.level) * height * 1.15
            labelNode.position = SCNVector3(0, Float(lift), 0)
            let facing = SCNNode()
            facing.constraints = [SCNBillboardConstraint()]
            facing.addChildNode(labelNode)
            node.addChildNode(facing)
        }
        return node
    }

    /// Polyline through the marks plus a translucent fill down to the floor.
    static func lineNode(_ line: MoistureLine3D, scale: Float) -> SCNNode {
        let node = SCNNode()
        let pts = line.points
        guard pts.count >= 2, line.floorY.count == pts.count else { return node }
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for (i, p) in pts.enumerated() {
            vertices.append(SCNVector3(p.x, p.y, p.z))
            vertices.append(SCNVector3(p.x, line.floorY[i], p.z))
        }
        for i in 0..<(pts.count - 1) {
            let t0 = Int32(i * 2), b0 = t0 + 1, t1 = t0 + 2, b1 = t0 + 3
            indices += [b0, b1, t1, b0, t1, t0]
        }
        let fill = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                               elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let fm = SCNMaterial()
        fm.diffuse.contents = lineBlue.withAlphaComponent(0.32)
        fm.lightingModel = .constant
        fm.isDoubleSided = true
        fm.readsFromDepthBuffer = false
        fm.writesToDepthBuffer = false
        fill.materials = [fm]
        let fillNode = SCNNode(geometry: fill)
        fillNode.renderingOrder = 150
        node.addChildNode(fillNode)
        let radius = CGFloat(max(0.012, min(0.03, scale * 0.004)))
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

    static func removalColor(done: Bool, alpha: CGFloat) -> UIColor {
        UIColor(done ? DS.Color.dry : DS.Color.remove).withAlphaComponent(alpha)
    }

    /// A translucent sleeve round the wall from the floor to the cut height.
    static func wallBandNode(_ a: PlanVec, _ b: PlanVec, top: Double, done: Bool) -> SCNNode {
        let len = ((b - a) * (b - a)).sum().squareRoot()
        guard len > 0.01 else { return SCNNode() }
        let dir = (b - a) / len
        let box = SCNBox(width: CGFloat(len), height: CGFloat(top + 0.006), length: CGFloat(Dollhouse.wallThickness + 0.05), chamferRadius: 0)
        let m = SCNMaterial()
        m.diffuse.contents = removalColor(done: done, alpha: 0.55)
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        box.materials = [m]
        let n = SCNNode(geometry: box)
        n.renderingOrder = 140
        n.position = SCNVector3(Float((a.x + b.x) / 2), Float(top / 2), Float((a.y + b.y) / 2))
        n.eulerAngles = SCNVector3(0, Float(atan2(-dir.y, dir.x)), 0)
        return n
    }

    /// Lifted flooring: a translucent red patch on the floor.
    static func floorAreaNode(_ poly: [PlanVec], done: Bool) -> SCNNode? {
        guard let g = Dollhouse.floorGeometry(poly, tile: 1) else { return nil }
        let m = SCNMaterial()
        m.diffuse.contents = removalColor(done: done, alpha: 0.38)
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = SCNVector3(0, 0.012, 0)
        n.renderingOrder = 130
        return n
    }

    static func labelImage(_ text: String, accent: UIColor) -> UIImage? {
        let font = UIFont.systemFont(ofSize: 40, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(red: 0.04, green: 0.06, blue: 0.08, alpha: 1)]
        let size = (text as NSString).size(withAttributes: attrs)
        let dot: CGFloat = 22
        let canvas = CGSize(width: ceil(size.width) + 36 + dot + 12, height: ceil(size.height) + 20)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: canvas).insetBy(dx: 2, dy: 2)
            let pill = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
            UIColor.white.setFill()
            pill.fill()
            UIColor(white: 0, alpha: 0.12).setStroke()
            pill.lineWidth = 2
            pill.stroke()
            accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: 18, y: (canvas.height - dot) / 2, width: dot, height: dot)).fill()
            (text as NSString).draw(at: CGPoint(x: 18 + dot + 12, y: 10), withAttributes: attrs)
        }
    }
}

struct ModelTab: View {
    @ObservedObject var vm: JobViewModel
    @StateObject private var model = ModelViewModel()

    var body: some View {
        ZStack {
            Color(uiColor: Dollhouse.canvas).ignoresSafeArea(edges: .horizontal)
            if model.ready {
                SceneContainer(model: model)
                controls
            } else if model.loading {
                ProgressView()
            } else if let e = model.error {
                ContentUnavailableView("No 3D view yet", systemImage: "cube.transparent", description: Text(e))
            }
        }
        .onAppear { model.load(folder: vm.folder, version: vm.planVersion) }
        .onChange(of: vm.planVersion) { _, v in model.load(folder: vm.folder, version: v) }
    }

    private var controls: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                modeSwitch
                layersMenu
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                IconButton("scope", label: "Reset view", tint: DS.Color.ink, size: 48) { model.resetView() }
                IconButton("ruler", label: model.measuring ? "Stop measuring" : "Measure",
                           tint: model.measuring ? DS.Color.accent : DS.Color.ink, size: 48) { model.toggleMeasure() }
                IconButton("camera", label: "Save image", tint: DS.Color.ink, size: 48) { model.snapshotAndShare() }
                IconButton("arkit", label: "View in AR", tint: DS.Color.ink, size: 48) { model.openAR() }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if model.measuring {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "ruler")
                        Text(model.measureText ?? "Tap two points")
                            .font(model.measureText == nil ? DS.Font.calloutBold : DS.Font.value(20))
                            .monospacedDigit()
                        if model.measureText != nil {
                            Button { model.clearMeasure() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7)) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear measurement")
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(DS.Color.ink))
                }
            }
        }
        .padding(16)
        .alert("3D view", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    /// Orbit / Plan, as one dark capsule.
    private var modeSwitch: some View {
        HStack(spacing: 4) {
            modeButton(.orbit, icon: "rotate.3d", label: "Orbit")
            modeButton(.plan, icon: "square.split.2x2", label: "Plan")
        }
        .padding(4)
        .background(Capsule().fill(DS.Color.ink))
    }

    private func modeButton(_ m: ModelViewModel.Mode, icon: String, label: String) -> some View {
        let on = model.mode == m
        return Button { withAnimation(DS.Motion.tray) { model.setMode(m) } } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? DS.Color.ink : .white)
                .frame(width: 52, height: 40)
                .background { if on { Capsule().fill(Color.white) } }
                .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var layersMenu: some View {
        Menu {
            ForEach(ModelLayer.allCases) { l in
                Toggle(isOn: Binding(get: { !model.hidden.contains(l) }, set: { _ in model.toggle(l) })) {
                    Label(l.rawValue, systemImage: l.icon)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d")
                Text("Layers")
                if !model.hidden.isEmpty {
                    Text("\(ModelLayer.allCases.count - model.hidden.count)/\(ModelLayer.allCases.count)")
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(DS.Font.calloutBold)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Capsule().fill(DS.Color.ink))
        }
        .accessibilityLabel("Layers")
    }
}

struct SceneContainer: UIViewRepresentable {
    @ObservedObject var model: ModelViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = Dollhouse.canvas
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = false
        v.scene = model.scene
        v.allowsCameraControl = true
        model.view = v
        // Our double-tap focuses a room (SceneKit's own one would reset the view).
        for g in v.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { t.isEnabled = false }
        }
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        v.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        single.require(toFail: double)
        v.addGestureRecognizer(single)
        // Frame once the view has its size.
        Task { @MainActor in model.resetView(animated: false) }
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        if v.scene !== model.scene {
            v.scene = model.scene
            Task { @MainActor in model.resetView(animated: false) }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: ModelViewModel
        init(model: ModelViewModel) { self.model = model }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            model.focusRoom(at: g.location(in: v))
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            model.measureTap(at: g.location(in: v))
        }
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
