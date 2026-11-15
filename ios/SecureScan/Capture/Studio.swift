//
//  Studio.swift
//  SecureScan
//
//  DEBUG / simulator only. Launch with SECURESCAN_STUDIO=<scene> and the app
//  shows the REAL CaptureHUD + OverlayRenderer over a synthetic camera view:
//  an SCNView of the demo job's bedroom (3.45 x 2.80 m, 2.4 m walls, door,
//  window, drawers) with plain lit materials - no photos. A PinholeProjector
//  matches the SCNView's camera exactly, the aim comes from a ray cast into
//  the same box room, and each scene scripts the HUD's state. CI screenshots
//  every scene into ci-screenshots/studio-<scene>.png.
//

#if DEBUG
import SwiftUI
import SceneKit
import Metal
import UIKit
import simd

enum StudioLaunch {
    /// The scene asked for by the launch environment, if any.
    static var scene: String? {
        let s = ProcessInfo.processInfo.environment["SECURESCAN_STUDIO"]
        return (s?.isEmpty ?? true) ? nil : s
    }

    static var scenes: [String] { StudioScenes.all }
}

/// The synthetic room (world: floor y = 0, x right, z = plan y; metres).
enum StudioRoom {
    static let width = 3.45, depth = 2.80, height = SimulatedScan.wallHeight
    static let walls: [WorldWall] = [
        WorldWall(id: "w1", a: PlanVec(0, 0), b: PlanVec(width, 0), height: height),
        WorldWall(id: "w2", a: PlanVec(width, 0), b: PlanVec(width, depth), height: height),
        WorldWall(id: "w3", a: PlanVec(width, depth), b: PlanVec(0, depth), height: height),
        WorldWall(id: "w4", a: PlanVec(0, depth), b: PlanVec(0, 0), height: height),
    ]
    static let world = CaptureWorld(floorY: 0, walls: walls,
                                    rooms: [WorldRoom(name: "Bedroom", polygon: [PlanVec(0, 0), PlanVec(width, 0), PlanVec(width, depth), PlanVec(0, depth)])])
    /// Drawers against w3 (x 2.30...3.15, z 2.35...2.80, 0.80 high).
    static let drawers = (x0: 2.30, x1: 3.15, z0: 2.35, z1: 2.80, h: 0.80)
    /// The doorway in w4 (z 1.75...2.57, 2.04 high): open, dark beyond.
    static let door = (z0: 1.75, z1: 2.57, h: 2.04)

    /// The nearest surface along a ray, with its normal; nil through the doorway or outside.
    static func raycast(origin o: WorldVec, dir d: WorldVec) -> (WorldVec, WorldVec)? {
        var best: (Double, WorldVec)? = nil
        func consider(_ t: Double, _ n: WorldVec, _ ok: (WorldVec) -> Bool) {
            guard t > 0.01, t < (best?.0 ?? .infinity) else { return }
            let p = o + d * t
            if ok(p) { best = (t, n) }
        }
        if abs(d.y) > 1e-9 {
            consider((0 - o.y) / d.y, WorldVec(0, 1, 0)) { $0.x >= 0 && $0.x <= width && $0.z >= 0 && $0.z <= depth }
            consider((height - o.y) / d.y, WorldVec(0, -1, 0)) { $0.x >= 0 && $0.x <= width && $0.z >= 0 && $0.z <= depth }
            consider((drawers.h - o.y) / d.y, WorldVec(0, 1, 0)) { $0.x >= drawers.x0 && $0.x <= drawers.x1 && $0.z >= drawers.z0 && $0.z <= drawers.z1 }
        }
        if abs(d.z) > 1e-9 {
            consider((0 - o.z) / d.z, WorldVec(0, 0, 1)) { $0.x >= 0 && $0.x <= width && $0.y >= 0 && $0.y <= height }
            consider((depth - o.z) / d.z, WorldVec(0, 0, -1)) { $0.x >= 0 && $0.x <= width && $0.y >= 0 && $0.y <= height }
            consider((drawers.z0 - o.z) / d.z, WorldVec(0, 0, -1)) { $0.x >= drawers.x0 && $0.x <= drawers.x1 && $0.y <= drawers.h && $0.y >= 0 }
        }
        if abs(d.x) > 1e-9 {
            consider((0 - o.x) / d.x, WorldVec(1, 0, 0)) {
                $0.z >= 0 && $0.z <= depth && $0.y >= 0 && $0.y <= height && !($0.z > door.z0 && $0.z < door.z1 && $0.y < door.h)
            }
            consider((width - o.x) / d.x, WorldVec(-1, 0, 0)) { $0.z >= 0 && $0.z <= depth && $0.y >= 0 && $0.y <= height }
            consider((drawers.x0 - o.x) / d.x, WorldVec(-1, 0, 0)) { $0.z >= drawers.z0 && $0.z <= drawers.z1 && $0.y >= 0 && $0.y <= drawers.h }
        }
        guard let b = best else { return nil }
        return (o + d * b.0, b.1)
    }
}

/// A scripted engine: the synthetic room, its camera, and canned saved items.
@MainActor
final class StudioEngine: ObservableObject, CaptureEngine {
    var camera = WorldVec(3.05, 1.45, 2.55)
    /// The bright-room variant (white walls, strong light).
    var bright = false
    var target = WorldVec(1.0, 0.6, 0.0)
    let fovY = StudioScenes.fovY
    var noHit = false

    var roomName = "Bedroom"
    var phaseText = "Scanning"
    var coaching: String? = nil
    var quietActions: [QuietAction] = [QuietAction(id: "roomDone", title: "Room done"), QuietAction(id: "finish", title: "Finish")]
    var showsTools = true
    var busyText: String? = nil
    var isReturnVisit = false
    var isScopeOnSite = false
    var recordingSince: Date? = nil
    var canRenameRoom: Bool { !isReturnVisit && !isScopeOnSite }
    var sections: [String] = []
    var saved: [OverlayMark] = []
    var units: [EquipmentGuard.Unit] = []
    var override: EnginePrimary? = nil
    var world: CaptureWorld { StudioRoom.world }

    private(set) lazy var hud = CaptureHUDModel(engine: self)

    var projectorFor: (CGSize) -> PinholeProjector {
        { [camera, target, fovY] size in
            PinholeProjector(position: camera, lookAt: target, fovYDegrees: fovY, viewport: ScreenVec(Double(size.width), Double(size.height)))
        }
    }

    func perform(quiet id: String) {}
    func requestClose() {}
    func toggleRecording() {}
    func renameRoom(_ name: String) { roomName = name }
    func roomSections() -> [String] { sections }

    func aimSample() -> AimSample? {
        let f = simd_normalize(target - camera)
        if noHit { return AimSample(camera: camera, forward: f, hit: nil, normal: nil) }
        let h = StudioRoom.raycast(origin: camera, dir: f)
        return AimSample(camera: camera, forward: f, hit: h?.0, normal: h?.1)
    }

    func projector(viewport: CGSize) -> Projector? { projectorFor(viewport) }
    func overlayMarks() -> [OverlayMark] { saved }

    func shot(photo: Bool) -> CaptureShot? {
        let s = aimSample()
        return CaptureShot(id: CaptureIDs.new("st-"), takenAt: "", camera: camera, forward: s?.forward ?? WorldVec(0, 0, -1), hit: s?.hit, normal: s?.normal)
    }

    func save(_ d: CaptureDraft) async -> Result<SavedCapture, PlainWords.Problem> { .failure(PlainWords.problem("")) }
    func remove(ids: [String]) {}
    func edit(id: String, _ e: ItemEdit) {}
    func equipmentUnits() -> [EquipmentGuard.Unit] { units }
    func setAirflow(id: String, direction: WorldVec) -> Bool { true }
    func primaryOverride(tool: CaptureTool, aim: Aim) -> EnginePrimary? { override }
    var zoomState: ZoomState { .available }
    var photos: [JobPhoto] = []
    func jobPhotos() -> [JobPhoto] { photos }
    func replacePhoto(id: String, photo: Task<CapturedPhoto?, Never>) async -> Bool { true }

    /// Aim the camera so the screen centre lands on `p`.
    func look(at p: WorldVec, from c: WorldVec? = nil) {
        if let c { camera = c }
        target = p
    }
}

// MARK: - The scenes

enum StudioScript {
    static func entry(_ id: String, _ kind: String, _ title: String, _ detail: String, photo: Bool = false) -> CaptureStack.Entry {
        CaptureStack.Entry(id: id, ids: [id], kind: kind, title: title, detail: detail, hasPhoto: photo)
    }

    static func glyph(_ kind: String) -> UIImage? { nil }

    /// Camera, saved marks and units from the shared scene data; then the HUD state per scene.
    @MainActor
    static func run(_ scene: String, _ e: StudioEngine) {
        let d = StudioScenes.data(scene)
        let hud = e.hud
        let shot = StudioShots.image
        let p = StudioScenes.self
        func final() { e.look(at: d.target, from: d.camera); e.saved = d.marks.filter { $0.id != "draft-airflow" } }
        // The job's photos (rendered from the synthetic room, newest first).
        e.photos = (1...5).reversed().map { n in
            JobPhoto(id: "p\(n)", title: "Photo \(n)", place: n % 2 == 0 ? "Bedroom · floor" : "Bedroom · wall \(String(format: "%.1f", 0.3 + Double(n) * 0.25)) m up",
                     caption: n == 2 ? "Damage" : "", load: { shot(n, CGSize(width: 900, height: 1200)) })
        }
        switch scene {
        case "aim-wall", "aim-wall-bright":
            e.recordingSince = Date().addingTimeInterval(-42)
            hud.studioAdd(entry("r1", "reading", "R1 · 10%", "Skirting · Bedroom", photo: true), thumb: shot(1, nil))
        case "aim-skirting":
            hud.tool = .mark
        case "aim-nothing":
            e.noHit = true
        case "reading-tray":
            e.look(at: WorldVec(1.55, 0.32, 0.0), from: d.camera)
            hud.tick()
            hud.studioPending(e.shot(photo: false)!)
            hud.readingMaterial = "wall"
            hud.readingText = "18"
            hud.tray = .reading
        case "reading-saved":
            for (i, v) in [10, 18, 26].enumerated() {
                hud.studioAdd(entry("r\(i + 1)", "reading", "R\(i + 1) · \(v)%", i == 0 ? "Skirting · Bedroom" : "Wall · Bedroom", photo: true), thumb: shot(i + 1, nil))
            }
            hud.studioUndo(true)
        case "line-progress":
            hud.tool = .mark
            hud.studioMark(points: [MarkPoint(world: WorldVec(0.6, 0.05, 0.0), surface: .wall, height: 0.05, distanceToWall: 0, wallId: "w1")],
                           shape: nil, start: .line)
        case "line-tray-skirting":
            hud.tool = .mark
            let a = MarkPoint(world: WorldVec(0.6, 0.05, 0.0), surface: .wall, height: 0.05, distanceToWall: 0, wallId: "w1")
            let b = MarkPoint(world: WorldVec(1.9, 0.04, 0.0), surface: .wall, height: 0.04, distanceToWall: 0, wallId: "w1")
            hud.studioMark(points: [a, b], shape: .line, start: .line)
            hud.tray = .mark
        case "lining-band-done":
            hud.tool = .mark
            hud.studioAdd(entry("x2", "mark", "Skirting · 1.80 m", "Bedroom", photo: true), thumb: shot(2, nil))
            hud.studioAdd(entry("x1", "mark", "Wall lining · 1.30 m", "Bedroom", photo: true), thumb: shot(3, nil))
            hud.studioUndo(true)
        case "area-progress", "area-tray":
            hud.tool = .mark
            let all = [WorldVec(1.0, 0, 1.0), WorldVec(1.7, 0, 0.95), WorldVec(1.75, 0, 1.55), WorldVec(1.05, 0, 1.6)]
            let pts = (scene == "area-tray" ? all : Array(all.prefix(3))).map { MarkPoint(world: $0, surface: .floor, height: 0, distanceToWall: 0.7) }
            if scene == "area-tray" {
                hud.context = .scope
                hud.studioMark(points: pts, shape: .area, start: .area)
                hud.floorType = "carpet"
                hud.underlay = true
                hud.tray = .mark
            } else {
                hud.studioMark(points: pts, shape: nil, start: .area)
            }
        case "photo-taken", "photo-preview-card":
            hud.tool = .photo
            hud.studioAdd(entry("r1", "reading", "R1 · 10%", "Skirting · Bedroom", photo: true), thumb: shot(1, nil))
            hud.studioAdd(entry("p5", "photo", "P5", "Bedroom", photo: true), thumb: shot(5, nil))
            hud.studioUndo(true)
            if scene == "photo-preview-card" {
                final()
                hud.photoCard = PhotoCard(id: "p5", tag: "Photo 5", image: shot(5, CGSize(width: 480, height: 640)))
                return
            }
        case "photo-viewer":
            hud.tool = .photo
            hud.studioAdd(entry("p5", "photo", "P5", "Bedroom", photo: true), thumb: shot(5, nil))
            final()
            hud.viewerStart = "p3"
            return
        case "photo-zoom-toggle":
            hud.tool = .photo
            hud.zoomUltra = true
            hud.studioAdd(entry("p5", "photo", "P5", "Bedroom", photo: true), thumb: shot(5, nil))
        case "review-drawer", "needs-fix":
            hud.studioAdd(entry("r1", "reading", "R1 · 10%", "Skirting · Bedroom", photo: true), thumb: shot(1, nil))
            hud.studioAdd(entry("r2", "reading", "R2 · 18%", "Wall · Bedroom", photo: true), thumb: shot(2, nil))
            if scene == "review-drawer" {
                hud.studioAdd(entry("p1", "photo", "P1", "Bedroom", photo: true), thumb: shot(3, nil))
                hud.studioAdd(entry("x1", "mark", "Skirting · 0.70 m", "Bedroom", photo: true), thumb: shot(4, nil))
                hud.studioAdd(entry("r3", "reading", "R3 · 26%", "Wall · Bedroom", photo: true), thumb: shot(5, nil))
            } else {
                var fix = entry("x9", "mark", "Skirting · 2.40 m", "Bedroom", photo: true)
                fix.needsFix = PlainWords.problem("The start and end are on different walls.").sentence
                hud.studioAdd(fix, thumb: shot(4, nil))
            }
            final()
            hud.tick()
            hud.openReview()
            hud.reviewSelected = scene == "review-drawer" ? "r2" : "x9"
            return
        case "equipment-place":
            hud.tool = .equipment
            e.units = [EquipmentGuard.Unit(id: "d1", type: "dehumidifier", pos: PlanVec(2.0, 0.6), hasAirflow: false, tag: "DH 1")]
            hud.studioAdd(entry("d1", "equipment", "Dehumidifier 1", "Bedroom", photo: true), thumb: shot(2, nil))
        case "equipment-airflow":
            hud.tool = .equipment
            e.units = [EquipmentGuard.Unit(id: "a1", type: "airMover", pos: PlanVec(1.6, 1.4), hasAirflow: false, tag: "AM 1")]
            hud.studioAdd(entry("a1", "equipment", "Air mover 1", "Bedroom", photo: true), thumb: shot(2, nil))
            hud.studioAirflow("a1")
        case "source-tray":
            e.look(at: WorldVec(0.0, 0.55, 1.1), from: d.camera)
            hud.tick()
            hud.studioPending(e.shot(photo: false)!)
            hud.sourceCause = "Shower"
            hud.tray = .source
        case "room-name-tray":
            e.phaseText = "Marking"
            e.roomName = "Room 1"
            e.sections = ["bedroom", "bathroom"]
            e.quietActions = [QuietAction(id: "next", title: "Next room"), QuietAction(id: "finish", title: "Finish")]
            final()
            hud.tick()
            hud.askRoomName()
            return
        case "scan-coaching":
            e.coaching = "Move closer to the wall"
            e.recordingSince = Date().addingTimeInterval(-128)
        case "visit-remeasure":
            e.isReturnVisit = true
            e.quietActions = []
            e.phaseText = "Visit 2 · 1 of 3"
            e.roomName = ""
            hud.tool = .remeasure
            hud.studioAdd(entry("m1", "remeasure", "R1 · 9%", "was 10%", photo: true), thumb: shot(1, nil))
            e.override = EnginePrimary(title: CaptureCopy.remeasure("R2"), action: {})
            e.coaching = "R3 is to your left"
        case "scope-on-site":
            e.isScopeOnSite = true
            e.quietActions = []
            e.phaseText = "Scope · 1 of 4 done"
            e.roomName = ""
            hud.tool = .done
            e.override = EnginePrimary(title: "Mark placed · AM-1", action: {})
        default:
            break
        }
        _ = p
        final()
    }
}

/// Stand-in "photos": the synthetic room rendered off screen from a few viewpoints (no real photos).
enum StudioShots {
    private static var cache: [String: UIImage] = [:]

    static let views: [(WorldVec, WorldVec)] = [
        (WorldVec(2.2, 1.3, 1.6), WorldVec(0.6, 0.2, 0.0)), (WorldVec(1.4, 1.2, 1.4), WorldVec(1.2, 0.3, 0.0)),
        (WorldVec(2.6, 1.4, 2.2), WorldVec(0.2, 0.4, 0.8)), (WorldVec(1.8, 1.5, 2.4), WorldVec(1.3, 0.0, 0.8)),
        (WorldVec(3.0, 1.4, 1.2), WorldVec(1.3, 0.9, 0.0)),
    ]


    static func image(_ n: Int, _ size: CGSize?) -> UIImage? {
        let sz = size ?? CGSize(width: 240, height: 320)
        let key = "\(n)-\(Int(sz.width))"
        if let i = cache[key] { return i }
        let v = views[(n - 1 + views.count) % views.count]
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        let scene = StudioSceneBuilder.scene()
        let cam = SCNNode()
        let c = SCNCamera()
        c.fieldOfView = 62
        c.zNear = 0.05
        cam.camera = c
        cam.simdPosition = SIMD3<Float>(v.0)
        cam.simdLook(at: SIMD3<Float>(v.1), up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
        scene.rootNode.addChildNode(cam)
        r.scene = scene
        r.pointOfView = cam
        let img = r.snapshot(atTime: 0, with: sz, antialiasingMode: .multisampling4X)
        cache[key] = img
        return img
    }
}

/// Stand-in thumbnails (no real photos): soft wall / skirting / floor bands.
enum StudioThumbs {
    static func make(_ i: Int) -> UIImage {
        let palettes: [(UInt32, UInt32)] = [(0xE9E5DE, 0xB8AC9B), (0xEDEAE4, 0xC7BBA8), (0xDAD5CC, 0x9C8F7E), (0xE3E7EA, 0xA9A096), (0xEFEBE5, 0xB3A694)]
        let p = palettes[i % palettes.count]
        let r = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180))
        return r.image { ctx in
            UIColor(Color(hex: p.0)).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 120 - CGFloat(i % 3) * 14))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 120 - CGFloat(i % 3) * 14, width: 240, height: 12))
            UIColor(Color(hex: p.1)).setFill()
            ctx.fill(CGRect(x: 0, y: 132 - CGFloat(i % 3) * 14, width: 240, height: 80))
            UIColor(white: 0.1, alpha: 0.75).setFill()
            ctx.fill(CGRect(x: 96 + CGFloat(i * 9 % 40), y: 70, width: 26, height: 48))
        }
    }
}

// MARK: - The view

struct StudioView: View {
    let scene: String
    @StateObject private var engine: StudioEngine

    init(scene: String) {
        self.scene = scene
        let e = StudioEngine()
        e.bright = scene == "aim-wall-bright"
        _engine = StateObject(wrappedValue: e)
    }
    @State private var ready = false

    var body: some View {
        ZStack {
            StudioCameraView(engine: engine).ignoresSafeArea()
            // A slight lens vignette, so it reads as a camera feed.
            RadialGradient(colors: [.clear, .black.opacity(engine.bright ? 0.12 : 0.32)], center: .center, startRadius: 220, endRadius: 560)
                .ignoresSafeArea().allowsHitTesting(false)
            if ready { CaptureScreen(hud: engine.hud) }
        }
        .statusBarHidden()
        .background(Color.black)
        .onAppear {
            engine.hud.hintsEnabled = false
            StudioScript.run(scene, engine)
            engine.objectWillChange.send()
            engine.hud.tick()
            ready = true
        }
    }
}

/// The synthetic camera feed: the room in an SCNView whose camera matches the projector.
struct StudioCameraView: UIViewRepresentable {
    @ObservedObject var engine: StudioEngine

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = StudioSceneBuilder.scene(bright: engine.bright)
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.allowsCameraControl = false
        v.rendersContinuously = true
        let cam = SCNNode()
        cam.name = "camera"
        let c = SCNCamera()
        c.fieldOfView = CGFloat(engine.fovY)
        c.projectionDirection = .vertical
        c.zNear = 0.05
        c.zFar = 50
        cam.camera = c
        v.scene?.rootNode.addChildNode(cam)
        v.pointOfView = cam
        place(cam)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        if let cam = v.pointOfView { place(cam) }
    }

    private func place(_ cam: SCNNode) {
        cam.simdPosition = SIMD3<Float>(engine.camera)
        cam.simdLook(at: SIMD3<Float>(engine.target), up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
    }
}

enum StudioSceneBuilder {
    static func mat(_ hex: UInt32, rough: CGFloat = 0.9, image: UIImage? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = image ?? UIColor(Color(hex: hex))
        m.lightingModel = .lambert
        _ = rough
        m.isDoubleSided = true
        return m
    }

    static func box(_ w: Double, _ h: Double, _ l: Double, at p: WorldVec, _ m: SCNMaterial) -> SCNNode {
        let b = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: 0.004)
        b.materials = [m]
        let n = SCNNode(geometry: b)
        n.simdPosition = SIMD3<Float>(p)
        return n
    }

    /// Carpet: fine noise so the floor reads as a surface, not a flat fill.
    static func carpet() -> UIImage {
        let size = 256
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        var seed: UInt32 = 12345
        func rnd() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
        return r.image { ctx in
            UIColor(red: 0.43, green: 0.415, blue: 0.40, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            for _ in 0..<5000 {
                let g = 0.34 + rnd() * 0.14
                UIColor(red: g + 0.06, green: g + 0.02, blue: g - 0.04, alpha: 0.5).setFill()
                ctx.fill(CGRect(x: rnd() * CGFloat(size), y: rnd() * CGFloat(size), width: 1.5, height: 1.5))
            }
        }
    }

    static func scene(bright: Bool = false) -> SCNScene {
        let s = SCNScene()
        let root = s.rootNode
        let W = StudioRoom.width, D = StudioRoom.depth, H = StudioRoom.height
        let wall = mat(bright ? 0xF4F2EE : 0xB9B2A6)
        let skirt = mat(0xF4F3EF, rough: 0.5)
        let floorM = mat(0, image: carpet())
        if bright { floorM.diffuse.contents = UIColor(red: 0.86, green: 0.83, blue: 0.78, alpha: 1) }
        floorM.diffuse.wrapS = .repeat
        floorM.diffuse.wrapT = .repeat
        floorM.diffuse.contentsTransform = SCNMatrix4MakeScale(4, 4, 1)
        root.addChildNode(box(W + 0.2, 0.02, D + 0.2, at: WorldVec(W / 2, -0.01, D / 2), floorM))
        root.addChildNode(box(W + 0.2, 0.02, D + 0.2, at: WorldVec(W / 2, H + 0.01, D / 2), mat(0xE6E3DD)))
        let t = 0.06
        root.addChildNode(box(W, H, t, at: WorldVec(W / 2, H / 2, -t / 2), wall))                          // w1
        root.addChildNode(box(t, H, D, at: WorldVec(W + t / 2, H / 2, D / 2), mat(bright ? 0xEDEAE4 : 0xAEA79B)))              // w2
        root.addChildNode(box(W, H, t, at: WorldVec(W / 2, H / 2, D + t / 2), wall))                       // w3
        // w4 with the doorway (z 1.75...2.57): three pieces.
        let d = StudioRoom.door
        let w4 = mat(bright ? 0xE9E6E0 : 0xA7A094)
        root.addChildNode(box(t, H, d.z0, at: WorldVec(-t / 2, H / 2, d.z0 / 2), w4))
        root.addChildNode(box(t, H, D - d.z1, at: WorldVec(-t / 2, H / 2, (d.z1 + D) / 2), w4))
        root.addChildNode(box(t, H - d.h, d.z1 - d.z0, at: WorldVec(-t / 2, (H + d.h) / 2, (d.z0 + d.z1) / 2), w4))
        let hall = mat(0x1E1C1A)
        hall.lightingModel = .constant
        root.addChildNode(box(0.6, d.h, d.z1 - d.z0 + 0.6, at: WorldVec(-0.36, d.h / 2, (d.z0 + d.z1) / 2), hall))  // dark hall beyond
        // Skirting (90 mm) round the room, not across the doorway.
        let sk = 0.09, st = 0.014
        root.addChildNode(box(W, sk, st, at: WorldVec(W / 2, sk / 2, st / 2), skirt))
        root.addChildNode(box(st, sk, D, at: WorldVec(W - st / 2, sk / 2, D / 2), skirt))
        root.addChildNode(box(W, sk, st, at: WorldVec(W / 2, sk / 2, D - st / 2), skirt))
        root.addChildNode(box(st, sk, d.z0, at: WorldVec(st / 2, sk / 2, d.z0 / 2), skirt))
        root.addChildNode(box(st, sk, D - d.z1, at: WorldVec(st / 2, sk / 2, (d.z1 + D) / 2), skirt))
        // Door frame.
        let frame = mat(0xF4F2EE, rough: 0.5)
        root.addChildNode(box(0.03, d.h + 0.05, 0.05, at: WorldVec(0.0, (d.h + 0.05) / 2, d.z0 - 0.025), frame))
        root.addChildNode(box(0.03, d.h + 0.05, 0.05, at: WorldVec(0.0, (d.h + 0.05) / 2, d.z1 + 0.025), frame))
        root.addChildNode(box(0.03, 0.05, d.z1 - d.z0 + 0.1, at: WorldVec(0.0, d.h + 0.025, (d.z0 + d.z1) / 2), frame))
        // Window in w1 (x 0.7...1.9, sill 0.95, 1.1 high).
        root.addChildNode(box(1.26, 1.16, 0.03, at: WorldVec(1.3, 0.95 + 0.55, 0.012), frame))
        let glass = mat(0xBFD3E0, rough: 0.15)
        glass.emission.contents = UIColor(red: 0.55, green: 0.66, blue: 0.76, alpha: 1)
        root.addChildNode(box(1.14, 1.04, 0.03, at: WorldVec(1.3, 0.95 + 0.55, 0.02), glass))
        root.addChildNode(box(0.03, 1.04, 0.035, at: WorldVec(1.3, 0.95 + 0.55, 0.03), frame))
        // Drawers.
        let dr = StudioRoom.drawers
        root.addChildNode(box(dr.x1 - dr.x0, dr.h, dr.z1 - dr.z0, at: WorldVec((dr.x0 + dr.x1) / 2, dr.h / 2, (dr.z0 + dr.z1) / 2), mat(0x8C6E52, rough: 0.6)))
        for k in 0..<3 {
            root.addChildNode(box(0.12, 0.018, 0.02, at: WorldVec((dr.x0 + dr.x1) / 2, 0.16 + Double(k) * 0.24, dr.z0 - 0.01), mat(0xD9D4CC, rough: 0.3)))
        }
        // Light: soft ambient + a ceiling light + window fill.
        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = bright ? 900 : 430
        amb.light?.color = UIColor(white: 1, alpha: 1)
        root.addChildNode(amb)
        let top = SCNNode(); top.light = SCNLight(); top.light?.type = .omni; top.light?.intensity = bright ? 900 : 480
        top.light?.attenuationStartDistance = 1.0
        top.light?.attenuationEndDistance = 6.0
        top.light?.color = UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1)
        top.simdPosition = SIMD3<Float>(Float(W / 2), Float(H - 0.2), Float(D / 2))
        root.addChildNode(top)
        let win = SCNNode(); win.light = SCNLight(); win.light?.type = .directional; win.light?.intensity = bright ? 600 : 260
        win.light?.color = UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
        win.simdLook(at: SIMD3<Float>(1.5, 0, 2.0), up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
        win.simdPosition = SIMD3<Float>(1.3, 1.6, 0.1)
        root.addChildNode(win)
        return s
    }
}
#endif
