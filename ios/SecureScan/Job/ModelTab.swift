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
    /// Label order when space is short: higher first (wet > damp > dry).
    var priority: Int = 0
    /// Where the screen label points (default: the marker itself).
    var labelAnchor: SIMD3<Float>? = nil
    /// Sources: confirmed (solid disc) rather than suspected (outlined rings).
    var confirmed = false
}

/// A label drawn over the 3D view (screen space).
struct ScreenLabel: Identifiable, Equatable {
    var id: String
    var text: String
    var color: UIColor
    var frame: CGRect
    var selected: Bool
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
    /// Drying equipment as 3D models (EquipmentModels): type, floor point, yaw (0 = +Z), airflow arrow.
    var equipment: [(type: String, position: SIMD3<Float>, yaw: Float, flow: Bool)] = []
    /// Marks drawn by DollhouseMarks (removals, moisture washes), by layer.
    var extra: [(layer: ModelLayer, node: SCNNode)] = []
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
    /// Screen labels, laid out after every camera move.
    @Published private(set) var labels: [ScreenLabel] = []
    @Published var selectedID: String? { didSet { relayout() } }

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
    /// Every label's anchor and what it says.
    private struct Anchor { var id: String; var point: SIMD3<Float>; var layer: ModelLayer; var text: String
                            var color: UIColor; var priority: Int; var onlyWhenSelected: Bool; var size: CGSize }
    private var anchors: [Anchor] = []

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
        for e in content.extra { layers[e.layer]!.addChildNode(e.node) }
        anchors = []
        for (i, m) in content.markers.enumerated() {
            let layer: ModelLayer
            switch m.kind {
            case "equipment": layer = .equipment
            case "photo", "source": layer = .photos
            case "boundary", "wash": layer = .lines
            case "removal": layer = .removals
            default: layer = .readings
            }
            // Equipment is drawn as its 3D model (below), removals and washes by DollhouseMarks;
            // their markers only carry the label.
            if !["equipment", "removal", "wash"].contains(m.kind) { layers[layer]!.addChildNode(Self.markerNode(m, scale: scale)) }
            if let text = m.label {
                anchors.append(Anchor(id: "m\(i)", point: m.labelAnchor ?? m.position, layer: layer, text: text, color: m.color,
                                      priority: m.priority, onlyWhenSelected: m.kind == "equipment", size: Self.labelSize(text)))
            }
        }
        for e in content.equipment {
            let n = EquipmentModels.model(e.type)
            if e.flow { n.addChildNode(EquipmentModels.airflow()) }
            n.simdPosition = e.position
            n.simdEulerAngles = [0, e.yaw, 0]
            layers[.equipment]!.addChildNode(n)
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
        relayout()
    }

    // MARK: Screen labels

    static let labelFont = UIFont.systemFont(ofSize: 13, weight: .semibold)

    static func labelSize(_ text: String) -> CGSize {
        let w = (text as NSString).size(withAttributes: [.font: labelFont]).width
        return CGSize(width: ceil(w) + 32, height: 24)      // dot + padding
    }

    /// Where the floating controls are (labels keep clear of them).
    private func controlRects(_ size: CGSize) -> [CGRect] {
        var r = [CGRect(x: 0, y: 0, width: 168, height: 132),                     // Orbit / Plan, Layers
                 CGRect(x: size.width - 76, y: 0, width: 76, height: 256)]        // the right column
        if measuring { r.append(CGRect(x: size.width / 2 - 120, y: size.height - 72, width: 240, height: 72)) }
        return r
    }

    /// Projects every anchor and places the labels (called after camera moves).
    func relayout() {
        guard let v = view, ready, v.bounds.width > 0 else { if !labels.isEmpty { labels = [] }; return }
        var items: [LabelLayout.Item] = []
        for a in anchors where !hidden.contains(a.layer) {
            if a.onlyWhenSelected && a.id != selectedID { continue }
            let p = v.projectPoint(SCNVector3(a.point.x, a.point.y, a.point.z))
            let pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
            let visible = p.z > 0 && p.z < 1 && v.bounds.contains(pt)
            items.append(LabelLayout.Item(id: a.id, anchor: pt, size: a.size,
                                          priority: a.priority + (a.id == selectedID ? 100 : 0), onScreen: visible))
        }
        let frames = LabelLayout.layout(items, in: v.bounds.insetBy(dx: 6, dy: 6), obstacles: controlRects(v.bounds.size))
        let byId = Dictionary(anchors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let out = frames.compactMap { id, f -> ScreenLabel? in
            guard let a = byId[id] else { return nil }
            return ScreenLabel(id: id, text: a.text, color: a.color, frame: f, selected: id == selectedID)
        }.sorted { $0.id < $1.id }
        if out != labels { labels = out }
    }

    /// Tap (not measuring): select the nearest marker, or clear.
    func select(at point: CGPoint) {
        guard let v = view else { return }
        var best: (String, CGFloat)?
        for a in anchors where !hidden.contains(a.layer) {
            let p = v.projectPoint(SCNVector3(a.point.x, a.point.y, a.point.z))
            guard p.z > 0, p.z < 1 else { continue }
            let d = hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y)
            if d < 34, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (a.id, d) }
        }
        if let l = labels.first(where: { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }) { best = (l.id, 0) }
        selectedID = best.map { $0.0 == selectedID ? nil : $0.0 } ?? nil
    }

    var aspect: Double {
        guard let v = view, v.bounds.height > 0 else { return 0.62 }
        return Double(v.bounds.width / v.bounds.height)
    }

    /// The default camera for the current mode, installed on the view: the
    /// model fills the free canvas, either below the right-hand button column
    /// (full width) or beside it (full height), whichever shows it bigger.
    func resetView(animated: Bool = true) {
        guard let v = view, let scene else { return }
        let fixedAzimuth = ProcessInfo.processInfo.environment["SECURESCAN_3D_AZIMUTH"].flatMap { Double($0) }
        let size = v.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let w = size.width, h = size.height
        let below = CGRect(x: 0.05, y: min(0.6, 262 / h), width: 0.9, height: max(0.3, (h - 262 - 12) / h))
        let beside = CGRect(x: 12 / w, y: 12 / h, width: (w - 12 - 80) / w, height: (h - 24) / h)
        var lo = bounds.min, hi = bounds.max, pts = fitPoints
        #if DEBUG
        // Screenshots of the marks: frame the largest room only (SECURESCAN_3D_FOCUS=1).
        if ProcessInfo.processInfo.environment["SECURESCAN_3D_FOCUS"] == "1",
           let r = rooms.max(by: { FloorArea.area($0.polygon) < FloorArea.area($1.polygon) }) {
            lo = r.min; hi = r.max
            pts = r.polygon.flatMap { p in [SIMD3<Float>(Float(p.x), 0, Float(p.y)), SIMD3<Float>(Float(p.x), Float(Dollhouse.cutHeight), Float(p.y))] }
        }
        #endif
        func make(_ rect: CGRect, _ azimuth: Double) -> (SCNNode, SIMD3<Float>) {
            Dollhouse.camera(lo: lo, hi: hi, aspect: aspect, plan: mode == .plan, points: pts,
                             azimuth: azimuth, margin: 0.98, rect: rect)
        }
        // Bigger on screen = closer camera (orbit) or smaller orthographic scale (plan).
        func spread(_ c: (SCNNode, SIMD3<Float>)) -> Double {
            if let cam = c.0.camera, cam.usesOrthographicProjection { return cam.orthographicScale }
            return Double(simd_distance(c.0.simdPosition, c.1))
        }
        // Orbit: of the diagonal three-quarter angles (the Polycam look), the one
        // that shows the house biggest. Plan stays north-up.
        let diagonals: [Double] = [45, 135, 225, 315].flatMap { [$0 - 10, $0, $0 + 10] }
        let azimuths: [Double] = mode == .plan ? [0] : (fixedAzimuth.map { [$0] } ?? diagonals)
        var best: (SCNNode, SIMD3<Float>)?
        for az in azimuths {
            for rect in [below, beside] {
                let c = make(rect, az)
                if best == nil || spread(c) < spread(best!) { best = c }
            }
        }
        guard let pick = best else { return }
        let (cam, centre) = pick
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
        relayout()
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
        relayout()
    }

    func clearMeasure() {
        measurePoints = []
        measureText = nil
        measureNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    func measureTap(at point: CGPoint) {
        guard measuring else { select(at: point); return }
        guard let v = view else { return }
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
        relayout()
    }

    // MARK: Share, AR

    func snapshotAndShare() {
        guard let v = view else { return }
        let base = v.snapshot()
        let labels = self.labels
        let composed = UIGraphicsImageRenderer(size: base.size).image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            for l in labels {
                if let img = Self.labelImage(l.text, accent: l.color) { img.draw(in: l.frame) }
            }
        }
        guard let data = composed.pngData() else { return }
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
        var plan = (try? Data(contentsOf: folder.planURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard !plan.isEmpty else { return SceneContent(error: "This job has no plan yet. Scan it to see it in 3D.") }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SECURESCAN_3D_MARKS"] == "1" { plan = DollhouseMarks.withDemoMarks(plan) }
        #endif
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

        let walls = Dictionary(Revisit.walls(plan).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// On its own face of its wall (or inside the wall for cavity marks), per docs/MARKING.md H.
        func sided(_ d: [String: Any], _ pos: SIMD3<Float>, out: Double) -> SIMD3<Float> {
            guard let side = d["side"] as? String, let wid = d["wallId"] as? String, let w = walls[wid],
                  let t = PlanDocument.number(d["wallT"]) else { return pos }
            return DollhouseMarks.facePosition(w, t: t, height: Double(pos.y), side: side, out: out)
        }
        var byId: [String: SIMD3<Float>] = [:]
        var marks: [MoistureLines.Mark] = []
        var wallMarks: [String: (t: Double, h: Double, side: String?)] = [:]
        for d in markup["readings"] as? [[String: Any]] ?? [] {
            guard let pos0 = place(d) else { continue }
            let pos = sided(d, pos0, out: 0.08)
            let kind = (d["kind"] as? String) ?? "reading"
            let n = PlanDocument.number(d["n"]).map { Int($0) }
            switch kind {
            case "boundary":
                content.markers.append(MarkerInfo(kind: kind, label: nil, color: lineBlue, position: pos))
                if let id = d["id"] as? String {
                    byId[id] = pos0
                    marks.append(MoistureLines.Mark(id: id, wallId: d["wallId"] as? String, wallT: PlanDocument.number(d["wallT"])))
                    if let t = PlanDocument.number(d["wallT"]) {
                        wallMarks[id] = (t, PlanDocument.number(d["height"]) ?? Double(pos0.y), d["side"] as? String)
                    }
                }
            case "photo":
                content.markers.append(MarkerInfo(kind: kind, label: n.map { "P\($0)" } ?? "P", color: .systemGray, position: pos))
            default:
                var label = n.map { "R\($0)" } ?? "R"
                let value = PlanDocument.number(d["value"])
                if let v = value { label += " · \(ItemsModel.fmt(v))%" }
                // Wet readings keep their labels first when space is short.
                let priority = value.map { $0 >= wet ? 30 : ($0 >= damp ? 20 : 10) } ?? 5
                content.markers.append(MarkerInfo(kind: kind, label: label, color: status(d, damp: damp, wet: wet), position: pos, priority: priority))
            }
        }
        for d in markup["sources"] as? [[String: Any]] ?? [] {
            guard let pos0 = place(d) else { continue }
            let pos = sided(d, pos0, out: 0.1)
            let text = ((d["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let confirmed = (d["status"] as? String) == "confirmed"
            let cavity = (d["side"] as? String) == "cavity"
            let detail = cavity ? "inside wall" : (confirmed ? "Confirmed" : "Suspected")
            var m = MarkerInfo(kind: "source", label: "\(text.isEmpty ? (cavity ? "Leak" : "Source") : text) · \(detail)", color: lineBlue, position: pos, priority: 25)
            m.confirmed = confirmed
            content.markers.append(m)
        }
        for d in markup["equipment"] as? [[String: Any]] ?? [] {
            if let removed = d["removed"], !(removed is NSNull), (removed as? String)?.isEmpty != true { continue }
            guard let p = ScopeList.pt(d["pos"]) else { continue }
            let type = (d["type"] as? String) ?? "other"
            let dir = PlanDocument.number(d["dir"])
            // The unit as its 3D model; plan angle a -> yaw about +y with 0 = +Z.
            content.equipment.append((type: type, position: SIMD3(Float(p.x), 0, Float(p.y)),
                                      yaw: dir.map { a in Float(atan2(cos(a), sin(a))) } ?? 0, flow: dir != nil && type == "airMover"))
            // Its label shows only when the unit is selected.
            let label = ((d["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let name = PlanDocument.equipmentName(type)
            let top = Float(EquipmentModels.height(type)) + 0.05
            content.markers.append(MarkerInfo(kind: "equipment", label: label.isEmpty ? name : "\(label) · \(name)",
                                              color: UIColor(DS.Color.equip), position: SIMD3(Float(p.x), top, Float(p.y)), priority: 0))
        }
        // Removals and wet floors in the AR view's language (docs/MARKING.md D, H).
        let drawn = DollhouseMarks.build(markup: markup, walls: walls, objects: plan["objects"] as? [[String: Any]] ?? [])
        content.extra += drawn.removals.map { (layer: ModelLayer.removals, node: $0) } + drawn.moisture.map { (layer: ModelLayer.lines, node: $0) }
        content.markers += drawn.labels
        for ids in MoistureLines.lines(marks) {
            // On its wall's face: the blue wash to the tide line.
            let wm = ids.compactMap { wallMarks[$0] }
            if wm.count == ids.count, let wid = marks.first(where: { $0.id == ids[0] })?.wallId, let w = walls[wid],
               let wash = DollhouseMarks.moistureWash(w, points: wm.map { (t: $0.t, h: $0.h) }.sorted { $0.t < $1.t }, side: wm[0].side) {
                content.extra += wash.nodes.map { (layer: ModelLayer.lines, node: $0) }
                content.markers.append(wash.label)
                continue
            }
            let pts = ids.compactMap { byId[$0] }
            guard pts.count >= 2 else { continue }
            content.lines.append(MoistureLine3D(points: pts, floorY: pts.map { _ in 0 }))
        }
        return content
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
        if m.kind == "source" {
            // Confirmed: a solid disc behind the drop; suspected: an outlined outer ring.
            let facing = SCNNode()
            facing.constraints = [SCNBillboardConstraint()]
            if m.confirmed {
                let disc = SCNPlane(width: r * 5.2, height: r * 5.2)
                disc.cornerRadius = r * 2.6
                disc.materials = [overlayMaterial(lineBlue.withAlphaComponent(0.35))]
                let dn = SCNNode(geometry: disc)
                dn.renderingOrder = 199
                facing.addChildNode(dn)
            } else {
                let outer = SCNTorus(ringRadius: r * 2.7, pipeRadius: r * 0.12)
                outer.materials = [overlayMaterial(lineBlue.withAlphaComponent(0.6))]
                let on = SCNNode(geometry: outer)
                on.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
                on.renderingOrder = 199
                facing.addChildNode(on)
            }
            node.addChildNode(facing)
        }
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
                labelLayer
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

    /// Labels in screen space, laid out by LabelLayout after every camera move.
    private var labelLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.labels) { l in
                HStack(spacing: 6) {
                    Circle().fill(Color(uiColor: l.color)).frame(width: 8, height: 8)
                    Text(l.text)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(l.selected ? Color.white : DS.Color.ink)
                .padding(.horizontal, 10)
                .frame(width: l.frame.width, height: l.frame.height)
                .background(Capsule().fill(l.selected ? DS.Color.ink : Color.white))
                .overlay(Capsule().strokeBorder(Color.black.opacity(l.selected ? 0 : 0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .position(x: l.frame.midX, y: l.frame.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        // Labels follow the camera.
        v.delegate = context.coordinator
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
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let model: ModelViewModel
        init(model: ModelViewModel) { self.model = model }

        private let lock = NSLock()
        nonisolated(unsafe) private var last = simd_float4x4()
        nonisolated(unsafe) private var lastScale = 0.0
        nonisolated(unsafe) private var pending = false

        /// Render thread: when the camera moved, lay the labels out again (coalesced).
        nonisolated func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard let pov = renderer.pointOfView?.presentation else { return }
            let t = pov.simdWorldTransform
            let sc = pov.camera?.orthographicScale ?? 0
            lock.lock()
            let moved = t != last || sc != lastScale
            if moved { last = t; lastScale = sc }
            let schedule = moved && !pending
            if schedule { pending = true }
            lock.unlock()
            guard schedule else { return }
            let m = model
            DispatchQueue.main.async { [weak self] in
                self?.donePending()
                MainActor.assumeIsolated { m.relayout() }
            }
        }

        nonisolated private func donePending() {
            lock.lock(); pending = false; lock.unlock()
        }

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
