//
//  RevisitARViewController.swift
//  SecureScan
//
//  The camera for a return visit: a plain ARKit world-tracking session in an
//  ARSCNView that this app owns (not RoomCaptureView). Draws the saved plan
//  through the camera once aligned:
//    * wall outlines on the floor (alignment check)
//    * readings: numbered markers at their wall position and height,
//      coloured by the last value, ticked when re-measured this visit
//    * previous moisture-line points (blue), sources, equipment (quieter)
//    * removals: a red band on the wall between t0..t1 up to the cut height
//  Markers are scaled with distance so near and far ones stay legible.
//  The world map of the first scan is used for automatic relocalisation when
//  it exists (ARWorldTrackingConfiguration.initialWorldMap).
//  Never run on a device yet: kept conventional and defensive on purpose.
//

import UIKit
import ARKit
import SceneKit
import CoreImage

final class RevisitARViewController: UIViewController, ARSCNViewDelegate {

    weak var model: RevisitModel?
    private let sceneView = ARSCNView(frame: .zero)
    private let contentNode = SCNNode()
    private var markerNodes: [String: SCNNode] = [:]
    /// Point markers (not bands), scaled with distance.
    private var scalable: [SCNNode] = []
    private var timer: Timer?
    private var started = false
    /// Live drawing (sweeps, growing bands and floor outlines); not cleared with the markers.
    private let previewNode = SCNNode()
    /// The first scan's ARSession when marking up during the scan (not ours to pause).
    private var shared: ARSession?
    private weak var sharedDelegate: ARSessionDelegate?
    private var lastTracking: TrackingStatus?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.scene.rootNode.addChildNode(contentNode)
        sceneView.scene.rootNode.addChildNode(previewNode)
        if let s = model?.sharedSession {
            // Draw on RoomPlan's own session: same world origin as the scan.
            shared = s
            sharedDelegate = s.delegate
            sceneView.session = s
        }
        view.addSubview(sceneView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        sceneView.addGestureRecognizer(tap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        if shared == nil { restart(worldMap: model?.start == .corners ? nil : loadWorldMap()) }
        model?.arStarted()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        detach()
    }

    /// Stops drawing; hands a shared session back. Safe to call twice.
    func detach() {
        timer?.invalidate()
        timer = nil
        if let s = shared {
            // Hand RoomPlan's session back untouched: never pause it here.
            sceneView.session = ARSession()
            s.delegate = sharedDelegate
            shared = nil
        } else {
            sceneView.session.pause()
        }
    }

    private func loadWorldMap() -> ARWorldMap? {
        guard let folder = model?.folder, model?.hasWorldMap == true,
              let data = try? Data(contentsOf: folder.worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    /// (Re)starts the session; with a world map ARKit tries to relocalise onto it.
    func restart(worldMap: ARWorldMap?) {
        guard shared == nil, ARWorldTrackingConfiguration.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.initialWorldMap = worldMap
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        clearMarkers()
    }

    // MARK: Capture

    func captureFrame() -> FrameCapture? {
        let session = sceneView.session
        guard let frame = session.currentFrame else { return nil }
        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let (hit, normal, kind) = ScanViewController.centreRaycast(session: session, frame: frame)
        return FrameCapture(cameraPosition: position, cameraForward: forward, hit: hit, hitKind: kind,
                            image: CIImage(cvPixelBuffer: frame.capturedImage), hitNormal: normal)
    }

    /// Camera pose and crosshair hit without the camera image (sweeps, corners, Move here).
    func capturePose() -> FrameCapture? {
        let session = sceneView.session
        guard let frame = session.currentFrame else { return nil }
        let t = frame.camera.transform
        let (hit, normal, kind) = ScanViewController.centreRaycast(session: session, frame: frame)
        return FrameCapture(cameraPosition: SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                            cameraForward: -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z),
                            hit: hit, hitKind: kind, image: nil, hitNormal: normal)
    }

    func centreHit() -> WorldVec? {
        guard let c = captureFrame(), let h = c.hit else { return nil }
        return WorldVec(Double(h.x), Double(h.y), Double(h.z))
    }

    // MARK: Drawing

    func clearMarkers() {
        contentNode.childNodes.forEach { $0.removeFromParentNode() }
        markerNodes = [:]
        scalable = []
    }

    static func vec(_ w: WorldVec) -> SCNVector3 { SCNVector3(Float(w.x), Float(w.y), Float(w.z)) }

    /// Wall outlines of the saved plan, on the floor, for the alignment check.
    func showOutline(walls: [PlanWall], alignment: PlanTransform, floorY: Double) {
        clearMarkers()
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.85)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        for w in walls {
            let a = alignment.world(w.a, y: floorY + 0.01), b = alignment.world(w.b, y: floorY + 0.01)
            if let n = Self.bar(from: a, to: b, radius: 0.012, material: mat) { contentNode.addChildNode(n) }
        }
    }

    func showMarkers(_ markers: [Revisit.Marker], walls: [PlanWall], alignment: PlanTransform, floorY: Double) {
        clearMarkers()
        let byWall = Dictionary(walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The saved walls, faintly, at floor level and along the top.
        let faint = Self.overlay(UIColor.white.withAlphaComponent(0.28))
        for w in walls {
            for y in [floorY + 0.01, floorY + w.height] {
                if let n = Self.bar(from: alignment.world(w.a, y: y), to: alignment.world(w.b, y: y), radius: 0.006, material: faint) {
                    contentNode.addChildNode(n)
                }
            }
        }
        // Moisture lines: the points of each wall joined, filled down to the floor.
        var lines: [String: [Revisit.Marker]] = [:]
        for m in markers where m.kind == "boundary" { if let wid = m.wallId, m.wallT != nil { lines[wid, default: []].append(m) } }
        for (_, pts) in lines where pts.count >= 2 {
            let world = pts.sorted { ($0.wallT ?? 0) < ($1.wallT ?? 0) }
                .map { Revisit.world($0.pos, height: $0.height, alignment: alignment, floorY: floorY) }
            contentNode.addChildNode(Self.lineWithFill(world, floorY: floorY, current: pts.contains { $0.measured }))
        }
        for m in markers {
            let node: SCNNode
            switch m.kind {
            case "affected", "removal" where m.polygon != nil:
                let poly = (m.polygon ?? []).map { alignment.world($0, y: floorY + 0.012) }
                let color = m.kind == "affected" ? ModelViewModel.lineBlue.withAlphaComponent(0.30)
                                                 : UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: m.done ? 0.15 : 0.32)
                node = Self.floorPolygon(poly, color: color)
            case "removal":
                guard let wid = m.wallId, let w = byWall[wid], let t0 = m.t0, let t1 = m.t1, let top = m.top else { continue }
                node = Self.band(wall: w, t0: t0, t1: t1, top: top, done: m.done, alignment: alignment, floorY: floorY)
            case "equipment":
                // Stands on the floor at its true size (not scaled with distance).
                let p = Revisit.world(m.pos, height: 0, alignment: alignment, floorY: floorY)
                node = Self.marker(m)
                node.position = Self.vec(p)
                if let dir = m.dir {
                    let a = Self.arrow(from: WorldVec(0, 0.2, 0), direction: Airflow.worldDirection(dir, transform: alignment),
                                       color: UIColor.systemTeal)
                    node.addChildNode(a)          // in the marker's own space (it is not scaled)
                }
            default:
                let p = Revisit.world(m.pos, height: m.height, alignment: alignment, floorY: floorY)
                node = Self.marker(m)
                node.position = Self.vec(p)
                scalable.append(node)
            }
            node.name = "marker:" + m.id
            contentNode.addChildNode(node)
            markerNodes[m.id] = node
        }
    }

    func highlight(_ id: String?) {
        for (mid, node) in markerNodes {
            node.childNode(withName: "ring", recursively: true)?.isHidden = mid != id
        }
    }

    static func colour(_ status: String) -> UIColor {
        switch status {
        case "dry": return UIColor(red: 0.18, green: 0.62, blue: 0.33, alpha: 1)
        case "elevated": return UIColor(red: 0.93, green: 0.60, blue: 0.10, alpha: 1)
        case "wet": return UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 1)
        default: return .systemGray
        }
    }

    static func overlay(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    static func marker(_ m: Revisit.Marker) -> SCNNode {
        let node = SCNNode()
        let color: UIColor
        let geometry: SCNGeometry
        switch m.kind {
        case "boundary":
            color = ModelViewModel.lineBlue
            geometry = SCNBox(width: 0.03, height: 0.03, length: 0.03, chamferRadius: 0.004)
        case "source":
            color = ModelViewModel.lineBlue
            geometry = SCNSphere(radius: 0.04)
        case "equipment":
            color = UIColor(red: 0.20, green: 0.45, blue: 0.50, alpha: 0.85)
            geometry = SCNBox(width: 0.30, height: 0.30, length: 0.30, chamferRadius: 0.03)
        case "photo":
            color = .systemGray
            geometry = SCNSphere(radius: 0.03)
        default:
            color = colour(m.status)
            geometry = SCNSphere(radius: 0.035)
        }
        geometry.materials = [overlay(color)]
        let dot = SCNNode(geometry: geometry)
        dot.renderingOrder = 100
        if m.kind == "equipment" { dot.position = SCNVector3(0, 0.15, 0) }
        node.addChildNode(dot)

        // Aim ring (shown when the crosshair is on it).
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.08, pipeRadius: 0.008))
        ring.geometry?.materials = [overlay(.white)]
        ring.name = "ring"
        ring.isHidden = true
        ring.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        let facing = SCNNode()
        facing.constraints = [SCNBillboardConstraint()]
        facing.addChildNode(ring)
        node.addChildNode(facing)

        let quiet = m.kind == "boundary"
        if !quiet, !m.label.isEmpty {
            let text = (m.measured ? "✓ " : "") + m.label
            if let image = ModelViewModel.labelImage(text, accent: m.measured ? colour("dry") : color) {
                let h: CGFloat = m.kind == "reading" ? 0.07 : 0.05
                let plane = SCNPlane(width: h * image.size.width / image.size.height, height: h)
                let mat = overlay(.white)
                mat.diffuse.contents = image
                plane.materials = [mat]
                let label = SCNNode(geometry: plane)
                label.position = SCNVector3(0, Float(h) / 2 + (m.kind == "equipment" ? 0.36 : 0.06), 0)
                label.renderingOrder = 110
                let lf = SCNNode()
                lf.constraints = [SCNBillboardConstraint()]
                lf.addChildNode(label)
                node.addChildNode(lf)
            }
        }
        return node
    }

    /// Red (done: green) translucent band on the wall, t0..t1, floor to `top`.
    static func band(wall w: PlanWall, t0: Double, t1: Double, top: Double, done: Bool,
                     alignment: PlanTransform, floorY: Double) -> SCNNode {
        let p0 = w.a + (w.b - w.a) * t0, p1 = w.a + (w.b - w.a) * t1
        let corners = [alignment.world(p0, y: floorY), alignment.world(p1, y: floorY),
                       alignment.world(p1, y: floorY + top), alignment.world(p0, y: floorY + top)]
        let src = SCNGeometrySource(vertices: corners.map(vec))
        let el = SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)
        let g = SCNGeometry(sources: [src], elements: [el])
        let color = done ? UIColor(red: 0.18, green: 0.62, blue: 0.33, alpha: 0.35) : UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.35)
        g.materials = [overlay(color)]
        let node = SCNNode()
        let face = SCNNode(geometry: g)
        face.renderingOrder = 90
        node.addChildNode(face)
        // A pivot at the middle of the band, for aiming / distance scaling to ignore.
        return node
    }

    static func bar(from a: WorldVec, to b: WorldVec, radius: CGFloat, material: SCNMaterial) -> SCNNode? {
        let v = b - a
        let len = simd_length(v)
        guard len > 0.01 else { return nil }
        let cyl = SCNCylinder(radius: radius, height: CGFloat(len))
        cyl.materials = [material]
        let n = SCNNode(geometry: cyl)
        n.simdPosition = SIMD3<Float>((a + b) / 2)
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: SIMD3<Float>(v / len))
        return n
    }

    // MARK: Scope of works (view only)

    /// Diagonal red stripes, repeated over bands and floor sections.
    static let hatch: UIImage = {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.18).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let c = ctx.cgContext
            c.setStrokeColor(UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.75).cgColor)
            c.setLineWidth(6)
            for k in stride(from: -64.0, through: 128.0, by: 21.33) {
                c.move(to: CGPoint(x: k, y: 64)); c.addLine(to: CGPoint(x: k + 64, y: 0))
            }
            c.strokePath()
        }
    }()

    static func hatched() -> SCNMaterial {
        let m = overlay(.white)
        m.diffuse.contents = hatch
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        return m
    }

    /// A flat textured face: `corners` in world space, `uv` in metres (one stripe tile per 20 cm).
    static func texturedFace(_ corners: [WorldVec], uv: [CGPoint], triangles: [Int32], material: SCNMaterial) -> SCNNode {
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: corners.map(vec)),
                                      SCNGeometrySource(textureCoordinates: uv.map { CGPoint(x: $0.x * 5, y: $0.y * 5) })],
                            elements: [SCNGeometryElement(indices: triangles, primitiveType: .triangles)])
        g.materials = [material]
        let n = SCNNode(geometry: g)
        n.renderingOrder = 85
        return n
    }

    static func tag(_ text: String, accent: UIColor, height: CGFloat = 0.07) -> SCNNode {
        let lf = SCNNode()
        lf.constraints = [SCNBillboardConstraint()]
        if let image = ModelViewModel.labelImage(text, accent: accent) {
            let plane = SCNPlane(width: height * image.size.width / image.size.height, height: height)
            let mat = overlay(.white)
            mat.diffuse.contents = image
            plane.materials = [mat]
            let n = SCNNode(geometry: plane)
            n.renderingOrder = 120
            lf.addChildNode(n)
        }
        return lf
    }

    /// An arrow along `direction` (unit, horizontal) starting at `from`.
    static func arrow(from: WorldVec, direction: WorldVec, length: Double = 0.9, color: UIColor) -> SCNNode {
        let node = SCNNode()
        let mat = overlay(color)
        let end = from + direction * length
        if let shaft = bar(from: from, to: end, radius: 0.012, material: mat) { node.addChildNode(shaft) }
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.12)
        cone.materials = [mat]
        let head = SCNNode(geometry: cone)
        head.simdPosition = SIMD3<Float>(end + direction * 0.06)
        head.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: SIMD3<Float>(simd_normalize(direction)))
        node.addChildNode(head)
        return node
    }

    func showScope(_ items: [ScopeItem], walls: [PlanWall], alignment: PlanTransform, floorY: Double) {
        clearMarkers()
        let byWall = Dictionary(walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let faint = Self.overlay(UIColor.white.withAlphaComponent(0.28))
        for w in walls {
            if let n = Self.bar(from: alignment.world(w.a, y: floorY + 0.01), to: alignment.world(w.b, y: floorY + 0.01), radius: 0.006, material: faint) {
                contentNode.addChildNode(n)
            }
        }
        let red = UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 1)
        let green = UIColor(red: 0.18, green: 0.62, blue: 0.33, alpha: 1)
        for it in items {
            let node = SCNNode()
            let accent = it.done ? green : red
            switch it.kind {
            case .wall:
                guard let wid = it.wallId, let w = byWall[wid], let t0 = it.t0, let t1 = it.t1, let top = it.top else { continue }
                let p0 = w.a + (w.b - w.a) * t0, p1 = w.a + (w.b - w.a) * t1
                let len = simd_distance(p0, p1)
                let c = [alignment.world(p0, y: floorY), alignment.world(p1, y: floorY),
                         alignment.world(p1, y: floorY + top), alignment.world(p0, y: floorY + top)]
                let mat = it.done ? Self.overlay(green.withAlphaComponent(0.3)) : Self.hatched()
                node.addChildNode(Self.texturedFace(c, uv: [CGPoint(x: 0, y: 0), CGPoint(x: len, y: 0), CGPoint(x: len, y: top), CGPoint(x: 0, y: top)],
                                                    triangles: [0, 1, 2, 0, 2, 3], material: mat))
                let edge = Self.overlay(accent)
                if let n = Self.bar(from: c[3], to: c[2], radius: 0.007, material: edge) { node.addChildNode(n) }
                let t = Self.tag(it.done ? "✓ " + it.tag : it.tag, accent: accent)
                t.simdPosition = SIMD3<Float>(Revisit.world(it.pos, height: top + 0.12, alignment: alignment, floorY: floorY))
                node.addChildNode(t)
                scalable.append(t)
            case .floor:
                guard let poly = it.polygon, poly.count >= 3 else { continue }
                let tri = Triangulate.ears(poly).map { Int32($0) }
                let mat = it.done ? Self.overlay(green.withAlphaComponent(0.3)) : Self.hatched()
                if !tri.isEmpty {
                    node.addChildNode(Self.texturedFace(poly.map { alignment.world($0, y: floorY + 0.012) },
                                                        uv: poly.map { CGPoint(x: $0.x, y: $0.y) }, triangles: tri, material: mat))
                }
                let edge = Self.overlay(accent)
                for i in poly.indices {
                    let a = alignment.world(poly[i], y: floorY + 0.015), b = alignment.world(poly[(i + 1) % poly.count], y: floorY + 0.015)
                    if let n = Self.bar(from: a, to: b, radius: 0.007, material: edge) { node.addChildNode(n) }
                }
                let t = Self.tag(it.done ? "✓ " + it.tag : it.tag, accent: accent)
                t.simdPosition = SIMD3<Float>(Revisit.world(it.pos, height: 0.15, alignment: alignment, floorY: floorY))
                node.addChildNode(t)
                scalable.append(t)
            case .equipment:
                // A ghost box where it goes (solid once placed), its tag, and the airflow.
                let base = Revisit.world(it.pos, height: 0, alignment: alignment, floorY: floorY)
                let teal = UIColor(red: 0.20, green: 0.45, blue: 0.50, alpha: 1)
                let box = SCNBox(width: 0.30, height: 0.30, length: 0.30, chamferRadius: 0.03)
                box.materials = [Self.overlay(teal.withAlphaComponent(it.done ? 0.8 : 0.3))]
                let b = SCNNode(geometry: box)
                b.simdPosition = SIMD3<Float>(base + WorldVec(0, 0.15, 0))
                b.renderingOrder = 100
                node.addChildNode(b)
                if let dir = it.dir {
                    node.addChildNode(Self.arrow(from: base + WorldVec(0, 0.2, 0), direction: Airflow.worldDirection(dir, transform: alignment),
                                                 color: UIColor.systemTeal))
                }
                let t = Self.tag(it.done ? "✓ " + it.tag : it.tag, accent: teal)
                t.simdPosition = SIMD3<Float>(base + WorldVec(0, 0.45, 0))
                node.addChildNode(t)
                scalable.append(t)
            }
            // A ring to show what the crosshair is on.
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.12, pipeRadius: 0.01))
            ring.geometry?.materials = [Self.overlay(.white)]
            ring.name = "ring"
            ring.isHidden = true
            ring.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            let facing = SCNNode()
            facing.constraints = [SCNBillboardConstraint()]
            facing.simdPosition = SIMD3<Float>(Revisit.world(it.pos, height: it.kind == .floor ? 0.02 : it.height, alignment: alignment, floorY: floorY))
            facing.addChildNode(ring)
            node.addChildNode(facing)
            node.name = "marker:" + it.id
            contentNode.addChildNode(node)
            markerNodes[it.id] = node
        }
    }

    /// The airflow being aimed (Scope mode placement or "Re-aim airflow").
    func previewArrow(from: WorldVec, direction: WorldVec) {
        clearPreview()
        previewNode.addChildNode(Self.arrow(from: from, direction: direction, color: UIColor.systemTeal))
    }

    /// A polyline (blue) through `pts` with a translucent fill down to the floor.
    static func lineWithFill(_ pts: [WorldVec], floorY: Double, current: Bool = true) -> SCNNode {
        let node = SCNNode()
        let blue = ModelViewModel.lineBlue
        let lineMat = overlay(blue.withAlphaComponent(current ? 1 : 0.55))
        for i in 1..<max(pts.count, 1) {
            if let b = bar(from: pts[i - 1], to: pts[i], radius: 0.008, material: lineMat) { node.addChildNode(b) }
        }
        guard pts.count >= 2 else { return node }
        var verts: [SCNVector3] = []
        var idx: [Int32] = []
        for (i, p) in pts.enumerated() {
            verts.append(vec(p))
            verts.append(vec(WorldVec(p.x, floorY, p.z)))
            if i > 0 {
                let k = Int32(i * 2)
                idx += [k - 2, k - 1, k, k - 1, k + 1, k]
            }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [overlay(blue.withAlphaComponent(current ? 0.22 : 0.12))]
        let fill = SCNNode(geometry: g)
        fill.renderingOrder = 80
        node.addChildNode(fill)
        return node
    }

    /// A translucent polygon on the floor (concave outlines are triangulated properly).
    static func floorPolygon(_ pts: [WorldVec], color: UIColor, outline: Bool = true) -> SCNNode {
        let node = SCNNode()
        guard pts.count >= 2 else { return node }
        let edge = overlay(color.withAlphaComponent(min(1, color.cgColor.alpha * 3)))
        for i in pts.indices where outline && (i > 0 || pts.count >= 3) {
            let a = pts[i == 0 ? pts.count - 1 : i - 1], b = pts[i]
            if let n = bar(from: a, to: b, radius: 0.007, material: edge) { node.addChildNode(n) }
        }
        let tri = Triangulate.ears(pts.map { PlanVec($0.x, $0.z) })
        guard !tri.isEmpty else { return node }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts.map(vec))],
                            elements: [SCNGeometryElement(indices: tri.map { Int32($0) }, primitiveType: .triangles)])
        g.materials = [overlay(color)]
        let fill = SCNNode(geometry: g)
        fill.renderingOrder = 70
        node.addChildNode(fill)
        return node
    }

    func clearPreview() {
        previewNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    /// The moisture line being swept.
    func previewStroke(_ pts: [WorldVec], floorY: Double) {
        clearPreview()
        previewNode.addChildNode(Self.lineWithFill(pts, floorY: floorY))
    }

    /// A wet area (or flooring section) growing corner by corner / as it is swept.
    func previewFloor(_ pts: [WorldVec], floorY: Double) {
        clearPreview()
        let flat = pts.map { WorldVec($0.x, floorY + 0.015, $0.z) }
        previewNode.addChildNode(Self.floorPolygon(flat, color: ModelViewModel.lineBlue.withAlphaComponent(0.28)))
    }

    /// A removal band from the start tap to the crosshair, before "End here".
    func previewBand(from a: WorldVec, to b: WorldVec, floorY: Double, top: Double) {
        clearPreview()
        let corners = [WorldVec(a.x, floorY, a.z), WorldVec(b.x, floorY, b.z), WorldVec(b.x, floorY + top, b.z), WorldVec(a.x, floorY + top, a.z)]
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: corners.map(Self.vec))],
                            elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
        g.materials = [Self.overlay(UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.35))]
        previewNode.addChildNode(SCNNode(geometry: g))
        let edge = Self.overlay(UIColor(red: 0.84, green: 0.20, blue: 0.18, alpha: 0.9))
        if let n = Self.bar(from: corners[3], to: corners[2], radius: 0.006, material: edge) { previewNode.addChildNode(n) }
    }

    // MARK: Per-frame (10 Hz)

    private func tick() {
        guard let frame = sceneView.session.currentFrame else { return }
        let t = frame.camera.transform
        let cam = WorldVec(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        let fwd = -WorldVec(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))
        model?.aim(camera: cam, forward: fwd)
        // Tracking, polled as well: on a shared session the callbacks may go to RoomPlan.
        let status = Self.status(frame.camera.trackingState)
        if status != lastTracking {
            lastTracking = status
            model?.trackingChanged(status)
        }
        let pose = capturePose()
        let hit = pose?.hit.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) }
        model?.updateReticle(hit: hit, normal: pose?.hitNormal.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) })
        if model?.wantsCrosshair == true { model?.livePreview(crosshair: hit) }
        // Keep markers legible: grow with distance (bands keep their true size).
        for node in scalable {
            let d = Double(simd_distance(node.simdPosition, SIMD3<Float>(cam)))
            let s = Float(min(max(d / 1.2, 1), 5))
            node.scale = SCNVector3(s, s, s)
        }
    }

    // MARK: Taps

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: sceneView)
        let hits = sceneView.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        for h in hits {
            var n: SCNNode? = h.node
            while let node = n {
                if let name = node.name, name.hasPrefix("marker:") {
                    model?.tapMarker(String(name.dropFirst("marker:".count)))
                    return
                }
                n = node.parent
            }
        }
    }

    // MARK: ARSCNViewDelegate / ARSessionObserver

    nonisolated static func status(_ state: ARCamera.TrackingState) -> TrackingStatus {
        let status: TrackingStatus
        switch state {
        case .normal: status = .normal
        case .notAvailable: status = .notAvailable
        case .limited(let reason):
            switch reason {
            case .relocalizing: status = .relocalizing
            case .initializing: status = .limited("starting up")
            case .excessiveMotion: status = .limited("moving too fast")
            case .insufficientFeatures: status = .limited("not enough detail in view")
            @unknown default: status = .limited("unknown")
            }
        @unknown default:
            status = .notAvailable
        }
        return status
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let status = Self.status(camera.trackingState)
        Task { @MainActor [weak self] in
            self?.lastTracking = status
            self?.model?.trackingChanged(status)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.model?.trackingChanged(.limited("camera interrupted")) }
    }
}
