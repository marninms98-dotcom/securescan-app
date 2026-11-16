//
//  EquipmentModels.swift
//  SecureScan
//
//  Drying equipment as real-scale 3D models, built from SceneKit primitives
//  (no third-party assets). Origin = the centre of the footprint on the floor;
//  +Z = the way the air comes out (the outlet faces +Z); y up; metres.
//    * air mover     - snail-shell centrifugal blower, side intake grilles,
//                      rectangular outlet, carry handle, rubber feet
//                      (~0.45 L x 0.38 W x 0.40 H)
//    * dehumidifier  - upright LGR: rounded body, front intake grille, top
//                      control panel, handle, two wheels (~0.40 x 0.50 x 0.75 H)
//    * air scrubber  - box with a round outlet (~0.45 x 0.45 x 0.60 H)
//    * heater        - compact box with a glowing grille (~0.30 x 0.28 x 0.40 H)
//  Satin plastic PBR materials, a soft rim so they read on dark carpet, and a
//  contact shadow. Used by the AR equipment layer and the job's 3D tab.
//

import SceneKit
import SwiftUI
import UIKit
import simd

enum EquipmentModels {

    /// Beyond this (m) a unit is drawn as the 2D glyph instead.
    static let maxDistance = 8.0

    /// Model height (m), for labels and layout.
    static func height(_ type: String) -> Double { OverlayLayout.equipmentHeight(type) }

    // MARK: Materials

    static let rim = """
    float rimEdge = 1.0 - max(dot(normalize(_surface.normal), normalize(-_surface.position)), 0.0);
    _output.color.rgb += pow(rimEdge, 3.0) * 0.28;
    """

    static func plastic(_ hex: UInt32, rough: CGFloat = 0.45, metal: CGFloat = 0, emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(Color(hex: hex))
        m.roughness.contents = rough
        m.metalness.contents = metal
        if let emission { m.emission.contents = emission }
        m.shaderModifiers = [.fragment: rim]
        return m
    }

    // Charcoal housings with a teal accent (the drying kit's look), satin plastic.
    static let teal = plastic(0x2B3238, rough: 0.38, metal: 0.15)
    static let tealDark = plastic(0x1A1F23, rough: 0.5)
    static let accent = plastic(0x3CCFA8, rough: 0.35, emission: UIColor(red: 0.05, green: 0.25, blue: 0.2, alpha: 1))
    static let charcoal = plastic(0x14181B, rough: 0.62)
    static let rubber = plastic(0x15181B, rough: 0.9)
    static let steel = plastic(0x9AA1A8, rough: 0.32, metal: 0.85)
    static let lightGrey = plastic(0xD5D9DD, rough: 0.5)
    static let midGrey = plastic(0x5A616A, rough: 0.55)

    static func node(_ g: SCNGeometry, _ m: SCNMaterial, at p: SIMD3<Float>, euler: SIMD3<Float> = .zero) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = p
        n.simdEulerAngles = euler
        return n
    }

    // MARK: Models

    /// A model by type, on the floor at the origin, outlet towards +Z.
    static func model(_ type: String) -> SCNNode {
        let root = SCNNode()
        root.name = "equipment-\(type)"
        let body: SCNNode
        switch type {
        case "dehumidifier": body = dehumidifier()
        case "airScrubber": body = airScrubber()
        case "heater": body = heater()
        default: body = airMover()
        }
        root.addChildNode(contactShadow(width: type == "dehumidifier" ? 0.62 : 0.6, depth: type == "dehumidifier" ? 0.7 : 0.62))
        root.addChildNode(body)
        return root
    }

    static func airMover() -> SCNNode {
        let n = SCNNode()
        let r: CGFloat = 0.17, w: CGFloat = 0.28
        // The snail shell: a drum on its side (axis X) plus a scroll widening into the outlet.
        n.addChildNode(node(SCNCylinder(radius: r, height: w), teal, at: [0, 0.215, -0.06], euler: [0, 0, .pi / 2]))
        n.addChildNode(node(SCNBox(width: w, height: 0.17, length: 0.24, chamferRadius: 0.03), teal, at: [0, 0.125, 0.07]))
        // Outlet: the dark mouth facing +Z, with a lip.
        n.addChildNode(node(SCNBox(width: w + 0.02, height: 0.15, length: 0.04, chamferRadius: 0.012), tealDark, at: [0, 0.12, 0.2]))
        n.addChildNode(node(SCNBox(width: w - 0.04, height: 0.105, length: 0.02, chamferRadius: 0.006), charcoal, at: [0, 0.12, 0.215]))
        for k in 0..<3 {
            n.addChildNode(node(SCNBox(width: w - 0.05, height: 0.006, length: 0.012, chamferRadius: 0.002), steel,
                                at: [0, 0.09 + Float(k) * 0.03, 0.222]))
        }
        // Side intakes: dark disc with steel rings, both sides.
        for side: Float in [-1, 1] {
            let x = side * Float(w / 2 + 0.004)
            n.addChildNode(node(SCNCylinder(radius: 0.125, height: 0.008), charcoal, at: [x, 0.215, -0.06], euler: [0, 0, .pi / 2]))
            for (i, rr) in [0.11, 0.08, 0.05].enumerated() {
                n.addChildNode(node(SCNTorus(ringRadius: CGFloat(rr), pipeRadius: 0.0045), steel,
                                    at: [x + side * 0.004 * Float(i + 1) * 0.3, 0.215, -0.06], euler: [0, 0, .pi / 2]))
            }
            n.addChildNode(node(SCNCylinder(radius: 0.022, height: 0.01), steel, at: [x + side * 0.004, 0.215, -0.06], euler: [0, 0, .pi / 2]))
        }
        // Teal rim round the shell's edge (both sides) and a strip on the base.
        for side: Float in [-1, 1] {
            n.addChildNode(node(SCNTorus(ringRadius: r - 0.006, pipeRadius: 0.006), accent,
                                at: [side * Float(w / 2 - 0.004), 0.215, -0.06], euler: [0, 0, .pi / 2]))
        }
        n.addChildNode(node(SCNBox(width: 0.16, height: 0.012, length: 0.008, chamferRadius: 0.004), accent, at: [Float(w / 2) + 0.002, 0.05, 0.02],
                            euler: [0, .pi / 2, 0]))
        n.addChildNode(node(SCNBox(width: 0.16, height: 0.012, length: 0.008, chamferRadius: 0.004), accent, at: [-Float(w / 2) - 0.002, 0.05, 0.02],
                            euler: [0, .pi / 2, 0]))
        // Carry handle over the top.
        for z: Float in [-0.16, 0.05] {
            n.addChildNode(node(SCNBox(width: 0.03, height: 0.07, length: 0.03, chamferRadius: 0.01), charcoal, at: [0, 0.405, z]))
        }
        n.addChildNode(node(SCNCapsule(capRadius: 0.018, height: 0.27), charcoal, at: [0, 0.44, -0.055], euler: [.pi / 2, 0, 0]))
        // Feet.
        for x: Float in [-0.11, 0.11] { for z: Float in [-0.17, 0.17] {
            n.addChildNode(node(SCNBox(width: 0.05, height: 0.02, length: 0.05, chamferRadius: 0.008), rubber, at: [x, 0.01, z]))
        } }
        return n
    }

    static func dehumidifier() -> SCNNode {
        let n = SCNNode()
        let W: CGFloat = 0.40, H: CGFloat = 0.70, D: CGFloat = 0.50
        n.addChildNode(node(SCNBox(width: W, height: H, length: D, chamferRadius: 0.05), teal, at: [0, Float(H / 2) + 0.05, 0]))
        // Teal band and the front intake grille (faces +Z).
        n.addChildNode(node(SCNBox(width: W + 0.004, height: 0.03, length: D + 0.004, chamferRadius: 0.012), accent, at: [0, 0.62, 0]))
        n.addChildNode(node(SCNBox(width: W - 0.08, height: 0.38, length: 0.01, chamferRadius: 0.01), charcoal, at: [0, 0.32, Float(D / 2) + 0.002]))
        for k in 0..<9 {
            n.addChildNode(node(SCNBox(width: W - 0.1, height: 0.008, length: 0.012, chamferRadius: 0.002), midGrey,
                                at: [0, 0.155 + Float(k) * 0.041, Float(D / 2) + 0.008]))
        }
        // Top control panel with a status light.
        n.addChildNode(node(SCNBox(width: 0.26, height: 0.012, length: 0.16, chamferRadius: 0.006), charcoal, at: [0, 0.755, 0.08]))
        n.addChildNode(node(SCNSphere(radius: 0.008), plastic(0x2E9E5B, emission: UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1)), at: [0.08, 0.763, 0.1]))
        // Handle at the back of the top.
        for x: Float in [-0.14, 0.14] {
            n.addChildNode(node(SCNBox(width: 0.025, height: 0.09, length: 0.025, chamferRadius: 0.008), charcoal, at: [x, 0.79, -0.19]))
        }
        n.addChildNode(node(SCNCapsule(capRadius: 0.016, height: 0.32), charcoal, at: [0, 0.835, -0.19], euler: [0, 0, .pi / 2]))
        // Wheels at the back, feet at the front.
        for x: Float in [-0.19, 0.19] {
            n.addChildNode(node(SCNCylinder(radius: 0.06, height: 0.035), rubber, at: [x, 0.06, -0.17], euler: [0, 0, .pi / 2]))
            n.addChildNode(node(SCNCylinder(radius: 0.025, height: 0.04), steel, at: [x, 0.06, -0.17], euler: [0, 0, .pi / 2]))
            n.addChildNode(node(SCNBox(width: 0.05, height: 0.05, length: 0.05, chamferRadius: 0.01), rubber, at: [x * 0.8, 0.025, 0.18]))
        }
        return n
    }

    static func airScrubber() -> SCNNode {
        let n = SCNNode()
        n.addChildNode(node(SCNBox(width: 0.45, height: 0.56, length: 0.45, chamferRadius: 0.035), teal, at: [0, 0.32, 0]))
        n.addChildNode(node(SCNBox(width: 0.454, height: 0.03, length: 0.454, chamferRadius: 0.012), accent, at: [0, 0.56, 0]))
        // Round outlet on the front (+Z).
        n.addChildNode(node(SCNTube(innerRadius: 0.1, outerRadius: 0.125, height: 0.06), accent, at: [0, 0.34, 0.25], euler: [.pi / 2, 0, 0]))
        n.addChildNode(node(SCNCylinder(radius: 0.1, height: 0.01), charcoal, at: [0, 0.34, 0.235], euler: [.pi / 2, 0, 0]))
        for k in 0..<4 {
            n.addChildNode(node(SCNBox(width: 0.19, height: 0.006, length: 0.01, chamferRadius: 0.002), steel, at: [0, 0.28 + Float(k) * 0.04, 0.24]))
        }
        for x: Float in [-0.17, 0.17] { for z: Float in [-0.17, 0.17] {
            n.addChildNode(node(SCNCylinder(radius: 0.03, height: 0.04), rubber, at: [x, 0.02, z]))
        } }
        n.addChildNode(node(SCNCapsule(capRadius: 0.016, height: 0.3), charcoal, at: [0, 0.64, 0], euler: [0, 0, .pi / 2]))
        return n
    }

    static func heater() -> SCNNode {
        let n = SCNNode()
        n.addChildNode(node(SCNBox(width: 0.30, height: 0.34, length: 0.28, chamferRadius: 0.03), teal, at: [0, 0.2, 0]))
        n.addChildNode(node(SCNBox(width: 0.304, height: 0.02, length: 0.284, chamferRadius: 0.008), accent, at: [0, 0.36, 0]))
        let glow = plastic(0x4A2A12, rough: 0.6, emission: UIColor(red: 1.0, green: 0.45, blue: 0.12, alpha: 1))
        n.addChildNode(node(SCNBox(width: 0.22, height: 0.2, length: 0.01, chamferRadius: 0.01), glow, at: [0, 0.2, 0.142]))
        for k in 0..<6 {
            n.addChildNode(node(SCNBox(width: 0.23, height: 0.008, length: 0.012, chamferRadius: 0.002), steel, at: [0, 0.115 + Float(k) * 0.034, 0.149]))
        }
        n.addChildNode(node(SCNCapsule(capRadius: 0.014, height: 0.2), charcoal, at: [0, 0.4, 0], euler: [0, 0, .pi / 2]))
        for x: Float in [-0.1, 0.1] { for z: Float in [-0.09, 0.09] {
            n.addChildNode(node(SCNBox(width: 0.04, height: 0.03, length: 0.04, chamferRadius: 0.008), rubber, at: [x, 0.015, z]))
        } }
        return n
    }

    // MARK: Shadow and airflow

    static let shadowImage: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 64, y: 64), startRadius: 8,
                                             endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
    }()

    static func contactShadow(width: CGFloat, depth: CGFloat) -> SCNNode {
        let p = SCNPlane(width: width, height: depth)
        let m = SCNMaterial()
        m.diffuse.contents = shadowImage
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        p.materials = [m]
        let n = SCNNode(geometry: p)
        n.simdEulerAngles = [-.pi / 2, 0, 0]
        n.simdPosition = [0, 0.003, 0]
        n.renderingOrder = -1
        return n
    }

    /// A soft teal fan on the floor from the outlet (1.0 m, widening), with chevrons moving
    /// along it (+Z).
    static func airflow() -> SCNNode {
        let root = SCNNode()
        root.name = "airflow"
        // The fan: a widening quad with a gradient that fades in and out.
        let fan = UIBezierPath()
        fan.move(to: CGPoint(x: -0.12, y: 0.0))
        fan.addLine(to: CGPoint(x: 0.12, y: 0.0))
        fan.addLine(to: CGPoint(x: 0.32, y: 1.0))
        fan.addLine(to: CGPoint(x: -0.32, y: 1.0))
        fan.close()
        let fanShape = SCNShape(path: fan, extrusionDepth: 0)
        let fm = SCNMaterial()
        fm.lightingModel = .constant
        fm.diffuse.contents = fanImage
        fm.writesToDepthBuffer = false
        fm.isDoubleSided = true
        fm.blendMode = .alpha
        fanShape.materials = [fm]
        let fanNode = SCNNode(geometry: fanShape)
        fanNode.simdEulerAngles = [.pi / 2, 0, 0]          // path y -> world +Z
        fanNode.simdPosition = [0, 0.008, 0.24]
        fanNode.renderingOrder = 1
        root.addChildNode(fanNode)
        // Chevrons.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -0.07, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 0.055))
        path.addLine(to: CGPoint(x: 0.07, y: 0))
        path.addLine(to: CGPoint(x: 0.07, y: -0.022))
        path.addLine(to: CGPoint(x: 0, y: 0.033))
        path.addLine(to: CGPoint(x: -0.07, y: -0.022))
        path.close()
        let mover = SCNNode()
        root.addChildNode(mover)
        let spacing: Float = 0.22
        for k in 0..<4 {
            let shape = SCNShape(path: path, extrusionDepth: 0.001)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(red: 0.62, green: 0.94, blue: 0.84, alpha: 1)
            m.transparency = CGFloat(0.95 - 0.2 * Double(k))
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            shape.materials = [m]
            let c = SCNNode(geometry: shape)
            c.simdEulerAngles = [.pi / 2, 0, 0]
            c.simdPosition = [0, 0.012, 0.34 + Float(k) * spacing]
            c.renderingOrder = 2
            mover.addChildNode(c)
        }
        mover.runAction(.repeatForever(.sequence([.move(by: SCNVector3(0, 0, spacing), duration: 0.8), .move(by: SCNVector3(0, 0, -spacing), duration: 0)])))
        return root
    }

    /// The fan's gradient: teal, fading in from the outlet and out at 1 m, soft at the sides.
    static let fanImage: UIImage = {
        let size = CGSize(width: 64, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = UIColor(red: 0.39, green: 0.82, blue: 0.71, alpha: 1)
            let colors = [c.withAlphaComponent(0).cgColor, c.withAlphaComponent(0.5).cgColor, c.withAlphaComponent(0).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 1])!
            ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: 0, y: 128), end: CGPoint(x: 0, y: 0), options: [])
        }
    }()
}

/// What the equipment layer shows (world space, y up).
struct EquipmentModelState: Equatable {
    var id: String
    var type: String
    var position: SIMD3<Float>
    /// Rotation about y so the outlet faces the airflow (radians); 0 = +Z.
    var yaw: Float
    var planned = false
    var flow = false
    var ghost = false

    static func yaw(for dir: WorldVec) -> Float { Float(atan2(dir.x, dir.z)) }
}

// MARK: - The layer

/// The equipment models over the camera: a transparent SCNView whose camera follows the
/// engine's camera every frame (ARKit's view and projection for this viewport, or the Studio's
/// pinhole), so the models sit in the room over RoomCaptureView, our ARSCNView or the Studio.
struct EquipmentLayer: UIViewRepresentable {
    @ObservedObject var hud: CaptureHUDModel

    func makeUIView(context: Context) -> EquipmentLayerView {
        EquipmentLayerView(hud: hud)
    }

    func updateUIView(_ v: EquipmentLayerView, context: Context) { v.hud = hud }

    static func dismantleUIView(_ v: EquipmentLayerView, coordinator: ()) { v.stop() }
}

final class EquipmentLayerView: SCNView {
    weak var hud: CaptureHUDModel?
    private var link: CADisplayLink?
    private let cameraNode = SCNNode()
    private var nodes: [String: (state: EquipmentModelState, node: SCNNode)] = [:]

    init(hud: CaptureHUDModel) {
        self.hud = hud
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        isOpaque = false
        antialiasingMode = .multisampling4X
        isUserInteractionEnabled = false
        rendersContinuously = true
        isPlaying = true
        let s = SCNScene()
        s.background.contents = UIColor.clear
        s.lightingEnvironment.contents = Self.environment
        s.lightingEnvironment.intensity = 1.3
        cameraNode.camera = SCNCamera()
        s.rootNode.addChildNode(cameraNode)
        // A soft key light from above and a fill, so the satin reads on dark carpet.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.simdEulerAngles = [-1.1, 0.5, 0]
        s.rootNode.addChildNode(key)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 280
        s.rootNode.addChildNode(amb)
        scene = s
        pointOfView = cameraNode
        let l = CADisplayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func stop() { link?.invalidate(); link = nil }

    deinit { link?.invalidate() }

    @objc private func step() { update() }

    private func update() {
        guard let hud, bounds.width > 0, let cam = hud.engine.camera3D(viewport: bounds.size) else {
            isHidden = true
            if hud?.models3D == true { hud?.models3D = false }
            return
        }
        isHidden = false
        if !hud.models3D { hud.models3D = true }
        cameraNode.simdTransform = cam.view.inverse
        cameraNode.camera?.projectionTransform = SCNMatrix4(cam.projection)
        let states = hud.equipmentModels()
        let ids = Set(states.map(\.id))
        for (id, e) in nodes where !ids.contains(id) { e.node.removeFromParentNode(); nodes[id] = nil }
        for st in states {
            if let e = nodes[st.id], e.state.type == st.type, e.state.planned == st.planned, e.state.ghost == st.ghost, e.state.flow == st.flow {
                e.node.simdPosition = st.position
                e.node.simdEulerAngles = [0, st.yaw, 0]
                nodes[st.id] = (st, e.node)
                continue
            }
            nodes[st.id]?.node.removeFromParentNode()
            let n = EquipmentModels.model(st.type)
            if st.flow { n.addChildNode(EquipmentModels.airflow()) }
            n.opacity = st.ghost ? 0.55 : (st.planned ? 0.6 : 1)
            n.simdPosition = st.position
            n.simdEulerAngles = [0, st.yaw, 0]
            scene?.rootNode.addChildNode(n)
            nodes[st.id] = (st, n)
        }
    }

    /// A simple studio environment for the PBR materials: bright above, dark below.
    static let environment: UIImage = {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0.95, alpha: 1).cgColor, UIColor(white: 0.55, alpha: 1).cgColor, UIColor(white: 0.12, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
        }
    }()
}
