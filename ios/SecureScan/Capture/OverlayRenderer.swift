//
//  OverlayRenderer.swift
//  SecureScan
//
//  Draws every mark as a crisp 2D vector over the camera, projected from
//  world space each frame (SwiftUI Canvas in a TimelineView). The same code
//  runs over RoomCaptureView, our ARSCNView and the Studio's SCNView, so the
//  marks look identical everywhere and can be reviewed off-device.
//  Styles per docs/UX2.md "What is drawn in the world".
//

import SwiftUI
import ARKit
import simd

/// ARKit's camera as a Projector (portrait, aspect-fill viewport like ARSCNView).
struct ARCameraProjector: Projector {
    let camera: ARCamera
    let viewport: ScreenVec
    let viewMatrix: simd_float4x4

    init(camera: ARCamera, viewport: CGSize) {
        self.camera = camera
        self.viewport = ScreenVec(Double(viewport.width), Double(viewport.height))
        self.viewMatrix = camera.viewMatrix(for: .portrait)
    }

    var cameraPosition: WorldVec {
        let t = camera.transform.columns.3
        return WorldVec(Double(t.x), Double(t.y), Double(t.z))
    }

    func view(_ w: WorldVec) -> WorldVec {
        let c = viewMatrix * SIMD4<Float>(Float(w.x), Float(w.y), Float(w.z), 1)
        return WorldVec(Double(c.x), Double(c.y), Double(-c.z))
    }

    /// The finger's ray: the screen point back through ARKit's projection for this viewport.
    func worldRay(_ s: ScreenVec) -> WorldVec? {
        let vp = CGSize(width: viewport.x, height: viewport.y)
        let proj = camera.projectionMatrix(for: .portrait, viewportSize: vp, zNear: 0.01, zFar: 100)
        let ndc = SIMD4<Float>(Float(2 * s.x / viewport.x - 1), Float(1 - 2 * s.y / viewport.y), 1, 1)
        var v = proj.inverse * ndc
        guard abs(v.w) > 1e-9 else { return nil }
        v /= v.w
        let dirCam = SIMD4<Float>(v.x, v.y, v.z, 0)
        let w = viewMatrix.inverse * dirCam
        let d = WorldVec(Double(w.x), Double(w.y), Double(w.z))
        return simd_length(d) > 1e-9 ? simd_normalize(d) : nil
    }

    func screen(_ w: WorldVec) -> ScreenVec {
        let p = camera.projectPoint(SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)), orientation: .portrait,
                                    viewportSize: CGSize(width: viewport.x, height: viewport.y))
        return ScreenVec(Double(p.x), Double(p.y))
    }
}

/// The overlay: marks from the HUD model, projected with the engine's camera.
/// The overlay is drawn in two passes around the 3D equipment layer: lines and areas under
/// the models (they lie on the floor and walls), pins, glyphs and every label over them.
enum OverlayPass { case under, over }

struct OverlayRenderer: View {
    @ObservedObject var hud: CaptureHUDModel
    var pass: OverlayPass = .over

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas(rendersAsynchronously: false) { ctx, size in
                    guard let proj = hud.engine.projector(viewport: size) else { return }
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    OverlayPainter(ctx: ctx, proj: proj, size: size, time: t).draw(hud.allMarks(), reticleLabel: hud.reticleText, pass: pass)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// The drawing itself: shapes from the marks, everything with a footprint from the layout plan.
struct OverlayPainter {
    var ctx: GraphicsContext
    let proj: Projector
    let size: CGSize
    let time: Double

    func cg(_ s: ScreenVec) -> CGPoint { CGPoint(x: s.x, y: s.y) }

    func path(_ pts: [ScreenVec], closed: Bool) -> Path {
        var p = Path()
        guard let f = pts.first else { return p }
        p.move(to: cg(f))
        for q in pts.dropFirst() { p.addLine(to: cg(q)) }
        if closed { p.closeSubpath() }
        return p
    }

    func status(_ s: String) -> Color { s == "none" || s == "reference" ? DS.Color.grey(6) : DS.Color.status(s) }

    /// A tag's words: the noun bold, the rest (after " · ") lighter - "Wall 0.24 m up".
    static func tagText(_ s: String, color: Color = .white) -> Text {
        let parts = s.components(separatedBy: " · ")
        let head = Text(parts[0]).font(.system(size: 13, weight: .semibold)).foregroundColor(color)
        guard parts.count > 1 else { return head.monospacedDigit() }
        let rest = Text("  " + parts.dropFirst().joined(separator: " · ")).font(.system(size: 12, weight: .medium))
            .foregroundColor(color.opacity(0.72))
        return (head + rest).monospacedDigit()
    }

    var measure: OverlayLayout.Measure {
        let c = ctx
        func m(_ t: String) -> CGSize { c.resolve(Self.tagText(t)).measure(in: CGSize(width: 320, height: 40)) }
        return OverlayLayout.Measure(tag: { let s = m($0); return CGSize(width: s.width + 22, height: max(26, s.height + 10)) },
                                     pinTag: { let s = m($0); return CGSize(width: s.width + 12, height: s.height + 4) },
                                     reticle: { let s = m($0); return CGSize(width: s.width + 24, height: max(28, s.height + 12)) })
    }

    static func isUnder(_ m: OverlayMark) -> Bool {
        switch m.style {
        case .wetFloor, .liftFlooring, .areaDraft, .lining, .skirting, .moisture, .lineDraft,
             .cabinet, .moistureWash, .airflowCone, .modelArea, .modelEdge: return true
        case .hover(let k): return k != .ring
        default: return false
        }
    }

    func draw(_ marks: [OverlayMark], reticleLabel: String?, pass: OverlayPass = .over) {
        let plan = OverlayLayout.plan(marks, projector: proj, reticleLabel: reticleLabel, measure: measure)
        let order: (OverlayMark) -> Int = { m in
            switch m.style {
            case .airflowCone: return -1
            case .modelArea: return -1
            case .modelEdge: return 0
            case .wetFloor, .liftFlooring, .areaDraft, .hover(.floor): return 0
            case .moistureWash, .hover(.face), .hover(.faceBlue): return 1
            case .lining: return 1
            case .skirting, .moisture, .lineDraft: return 2
            case .equipment: return 3
            default: return 4
            }
        }
        let sorted = marks.sorted { order($0) < order($1) }
        // Shapes and symbols.
        for m in sorted where Self.isUnder(m) == (pass == .under) {
            var c = ctx
            if m.faded { c.opacity = 0.5 }
            shape(m, plan: plan, in: &c)
        }
        guard pass == .over else { return }
        // Labels on top of every shape.
        for m in sorted {
            guard let r = plan.labels[m.id], let t = OverlayLayout.displayTag(m) else { continue }
            var c = ctx
            if m.faded { c.opacity = 0.6 }
            capsule(t, in: r, fill: tagFill(m), c: &c)
        }
        if let r = plan.labels["reticle"], let t = reticleLabel {
            var c = ctx
            capsule(t, in: r, fill: Self.glass, c: &c)
        }
        for m in sorted where m.selected { edgeArrowIfNeeded(m) }
    }

    /// The glass look in the overlay (a Canvas can't blur): the dark tint, a little stronger.
    static let glass = Color(hex: 0x1C1C1E, opacity: 0.62)

    func tagFill(_ m: OverlayMark) -> Color {
        switch m.style {
        case .skirting, .lining, .liftFlooring, .cabinet: return DS.Color.remove.opacity(0.88)
        case .moisture, .wetFloor, .source, .modelHint: return DS.Color.source.opacity(0.88)
        default: return Self.glass
        }
    }

    func capsule(_ text: String, in r: CGRect, fill: Color, c: inout GraphicsContext) {
        let label = c.resolve(Self.tagText(text))
        let shape = Capsule().path(in: r)
        var s = c
        s.addFilter(.shadow(color: .black.opacity(0.25), radius: 6, y: 3))
        s.fill(shape, with: .color(fill))
        c.stroke(shape, with: .color(.white.opacity(0.24)), lineWidth: 0.5)
        c.draw(label, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
    }

    func symbol(_ name: String, in r: CGRect, color: Color = .white, c: inout GraphicsContext) {
        var img = c.resolve(Image(systemName: name))
        img.shading = .color(color)
        let s = img.size
        guard s.width > 0, s.height > 0 else { return }
        let k = min(r.width / s.width, r.height / s.height)
        let w = s.width * k, h = s.height * k
        c.draw(img, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }

    func hatch(_ shape: Path, color: Color, spacing: CGFloat = 9, in c: inout GraphicsContext) {
        let b = shape.boundingRect
        guard b.width > 1, b.height > 1, b.width < 6000, b.height < 6000 else { return }
        var h = c
        h.clip(to: shape)
        var lines = Path()
        var x = b.minX - b.height
        while x < b.maxX {
            lines.move(to: CGPoint(x: x, y: b.maxY))
            lines.addLine(to: CGPoint(x: x + b.height, y: b.minY))
            x += spacing
        }
        h.stroke(lines, with: .color(color), lineWidth: 1.5)
    }

    // MARK: Styles

    func shape(_ m: OverlayMark, plan: OverlayLayout.Plan, in c: inout GraphicsContext) {
        switch m.style {
        case .reading(let st, let reference):
            guard let pin = plan.pins[m.id] else { return }
            drawPin(pin, value: m.value ?? "", fill: reference ? DS.Color.ink.opacity(0.55) : status(st), hollow: reference,
                    tagText: m.tag, selected: m.selected, in: &c)
        case .readingDraft:
            guard let pin = plan.pins[m.id] else { return }
            let v = Double(m.value ?? "")
            let fill = v.map { status(OverlayBuild.status($0, reference: false)) } ?? DS.Color.ink.opacity(0.6)
            drawPin(pin, value: m.value ?? "–", fill: fill, hollow: false, tagText: nil, selected: true, in: &c)
        case .photo:
            guard let r = plan.glyphs[m.id] else { return }
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous).path(in: r)
            c.fill(shape, with: .color(DS.Color.ink.opacity(0.8)))
            c.stroke(shape, with: .color(m.selected ? DS.Color.accent : .white.opacity(0.9)), lineWidth: m.selected ? 2.5 : 1.5)
            symbol("camera.fill", in: r.insetBy(dx: 5, dy: 6), c: &c)
        case .source:
            guard let r = plan.glyphs[m.id] else { return }
            let pt = CGPoint(x: r.midX, y: r.midY)
            let phase = (time.truncatingRemainder(dividingBy: 2)) / 2
            if m.side == WallSide.cavity {
                // Inside the wall: a faint dashed outline on the face, the same from both rooms.
                let box = RoundedRectangle(cornerRadius: 10, style: .continuous).path(in: r.insetBy(dx: -14, dy: -14))
                c.fill(box, with: .color(DS.Color.source.opacity(0.12)))
                c.stroke(box, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            if m.confirmed {
                // Confirmed: a solid disc behind the drop, and the ripple.
                c.fill(Circle().path(in: CGRect(x: pt.x - 24, y: pt.y - 24, width: 48, height: 48)), with: .color(DS.Color.source.opacity(0.35)))
            } else {
                // Suspected: outlined ripple rings.
                for (rr, op) in [(20.0, 0.6), (30.0, 0.35)] {
                    c.stroke(Circle().path(in: CGRect(x: pt.x - rr, y: pt.y - rr, width: rr * 2, height: rr * 2)),
                             with: .color(DS.Color.source.opacity(op)), lineWidth: 2)
                }
            }
            let pr = 13 + 18 * phase
            c.stroke(Circle().path(in: CGRect(x: pt.x - pr, y: pt.y - pr, width: pr * 2, height: pr * 2)),
                     with: .color(DS.Color.source.opacity(0.9 * (1 - phase))), lineWidth: 2)
            c.fill(Circle().path(in: r), with: .color(DS.Color.source))
            c.stroke(Circle().path(in: r), with: .color(.white), lineWidth: 2)
            symbol("drop.fill", in: r.insetBy(dx: 7, dy: 6), c: &c)
        case .equipment(let type, let planned):
            guard m.modelHeight == nil, let p = m.points.first else { return }
            if let d = m.airflow { airflow(from: p, dir: d, planned: planned, in: &c) }
            guard let r = plan.glyphs[m.id] else { return }
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous).path(in: r)
            if planned {
                c.fill(shape, with: .color(DS.Color.ink.opacity(0.6)))
                c.stroke(shape, with: .color(DS.Color.equip), lineWidth: 2.5)
            } else {
                c.fill(shape, with: .color(DS.Color.equip))
                c.stroke(shape, with: .color(.white), lineWidth: m.selected ? 3 : 2)
            }
            symbol(Self.equipmentGlyph(type), in: r.insetBy(dx: 8, dy: 8), color: planned ? DS.Color.equip : .white, c: &c)
            if m.selected { c.stroke(RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: r.insetBy(dx: -4, dy: -4)), with: .color(DS.Color.accent), lineWidth: 2.5) }
        case .skirting:
            guard m.points.count >= 2, let seg = proj.projectSegment(m.points[0] + WorldVec(0, 0.04, 0), m.points[1] + WorldVec(0, 0.04, 0)) else { return }
            let a = cg(seg.0), b = cg(seg.1)
            var line = Path(); line.move(to: a); line.addLine(to: b)
            // 7 pt red with a dark casing; white end caps (the start ringed in red).
            c.stroke(line, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            c.stroke(line, with: .color(DS.Color.remove), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            cutTicks(m.points[0] + WorldVec(0, 0.04, 0), m.points[1] + WorldVec(0, 0.04, 0), in: &c)
            if proj.depth(m.points[0]) > proj.near { endCap(a, ring: true, in: &c) }
            if proj.depth(m.points[1]) > proj.near { endCap(b, ring: m.id != "draft-line" && m.id != "draft-run", in: &c) }
        case .lining:
            guard m.points.count >= 2 else { return }
            let top = m.top ?? 0.6
            let a = m.points[0], b = m.points[1]
            let sp = proj.projectPolygon([a, b, b + WorldVec(0, top, 0), a + WorldVec(0, top, 0)])
            guard sp.count >= 3 else { return }
            let shape = path(sp, closed: true)
            // Strip-back (flood cut): red wash + white hatch, red outline, the cut line dashed white.
            c.fill(shape, with: .color(DS.Color.remove.opacity(0.26)))
            hatch(shape, color: .white.opacity(0.5), spacing: 9, in: &c)
            c.stroke(shape, with: .color(DS.Color.remove), style: StrokeStyle(lineWidth: m.selected ? 3 : 2, lineJoin: .round))
            if let cut = proj.projectSegment(a + WorldVec(0, top, 0), b + WorldVec(0, top, 0)) {
                var cl = Path(); cl.move(to: cg(cut.0)); cl.addLine(to: cg(cut.1))
                c.stroke(cl, with: .color(.black.opacity(0.3)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                c.stroke(cl, with: .color(.white), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, dash: [9, 6]))
                if m.handle {
                    let mid = CGPoint(x: (cut.0.x + cut.1.x) / 2, y: (cut.0.y + cut.1.y) / 2)
                    let hr = CGRect(x: mid.x - 17, y: mid.y - 11, width: 34, height: 22)
                    var sh = c
                    sh.addFilter(.shadow(color: .black.opacity(0.3), radius: 4, y: 1))
                    sh.fill(Capsule().path(in: hr), with: .color(.white))
                    var ch = Path()
                    ch.move(to: CGPoint(x: mid.x - 6, y: mid.y - 2)); ch.addLine(to: CGPoint(x: mid.x, y: mid.y - 7)); ch.addLine(to: CGPoint(x: mid.x + 6, y: mid.y - 2))
                    ch.move(to: CGPoint(x: mid.x - 6, y: mid.y + 2)); ch.addLine(to: CGPoint(x: mid.x, y: mid.y + 7)); ch.addLine(to: CGPoint(x: mid.x + 6, y: mid.y + 2))
                    c.stroke(ch, with: .color(DS.Color.ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
        case .moisture:
            for run in proj.projectPolyline(m.points) {
                let p = path(run, closed: false)
                c.stroke(p, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                c.stroke(p, with: .color(DS.Color.source), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                waveTicks(run, in: &c)
            }
        case .wetFloor, .liftFlooring:
            let sp = proj.projectPolygon(m.points)
            guard sp.count >= 3 else { return }
            let shape = path(sp, closed: true)
            let lift = m.style == .liftFlooring
            let col = lift ? DS.Color.remove : DS.Color.source
            c.fill(shape, with: .color(col.opacity(0.3)))
            if lift { floorPattern(m.floorType, polygon: m.points, clip: shape, in: &c) }
            c.stroke(shape, with: .color(col), style: StrokeStyle(lineWidth: m.selected ? 3.5 : 2.5, lineJoin: .round))
        case .cabinet:
            cabinetBox(m.points, removal: true, in: &c)
        case .hover(let k):
            hover(k, m, in: &c)
        case .moistureWash:
            moistureWash(m, in: &c)
        case .readout:
            break
        case .modelArea(let prov):
            modelArea(m, provenance: prov, in: &c)
        case .modelEdge(let prov):
            for run in proj.projectPolyline(m.points) {
                let p = path(run, closed: false)
                if prov == "brushWet" || prov == "brushDry" {
                    // The Adjust brush's stroke: a broad soft band (blue = wet, white = dry).
                    c.stroke(p, with: .color((prov == "brushWet" ? DS.Color.source : Color.white).opacity(0.42)),
                             style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                    c.stroke(p, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [2, 5]))
                } else if prov == "barrier" {
                    c.stroke(p, with: .color(DS.Color.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    c.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    if run.count >= 2 {
                        for q in [run[0], run[run.count - 1]] { endCap(cg(q), ring: false, in: &c) }
                    }
                } else if prov == "estimated" {
                    c.stroke(p, with: .color(DS.Color.tide.opacity(0.95)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 4]))
                } else {
                    c.stroke(p, with: .color(DS.Color.ink.opacity(0.28)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    c.stroke(p, with: .color(DS.Color.tide), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
        case .modelHint:
            guard let r = plan.glyphs[m.id] else { return }
            let pulse = 0.5 + 0.5 * sin(time * 3)
            let ring = Circle().path(in: r.insetBy(dx: -3 * pulse, dy: -3 * pulse))
            c.stroke(ring, with: .color(DS.Color.ink.opacity(0.3)), style: StrokeStyle(lineWidth: 4.5))
            c.stroke(ring, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, dash: [5, 4]))
            c.fill(Circle().path(in: r.insetBy(dx: 9, dy: 9)), with: .color(DS.Color.source))
            c.stroke(Circle().path(in: r.insetBy(dx: 9, dy: 9)), with: .color(.white), lineWidth: 1.5)
        case .airflowCone:
            guard let p = m.points.first, let d = m.airflow else { return }
            let h = simd_length(WorldVec(d.x, 0, d.z)) > 1e-9 ? simd_normalize(WorldVec(d.x, 0, d.z)) : WorldVec(1, 0, 0)
            let base = WorldVec(p.x, p.y + 0.005, p.z)
            var poly = [base]
            for k in 0...12 {
                let a = (-30.0 + 5.0 * Double(k)) * .pi / 180
                let r = WorldVec(h.x * cos(a) - h.z * sin(a), 0, h.x * sin(a) + h.z * cos(a))
                poly.append(base + r * 2.5)
            }
            let sp = proj.projectPolygon(poly)
            guard sp.count >= 3 else { return }
            c.fill(path(sp, closed: true), with: .color(DS.Color.airflow.opacity(0.10)))
        case .lineDraft:
            guard m.points.count >= 2, let seg = proj.projectSegment(m.points[0], m.points[1]) else { return }
            let a = cg(seg.0), b = cg(seg.1)
            var line = Path(); line.move(to: a); line.addLine(to: b)
            c.stroke(line, with: .color(DS.Color.ink.opacity(0.6)), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
            c.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if proj.depth(m.points[0]) > proj.near { startCap(a, in: &c) }
        case .areaDraft:
            let pts = m.points
            guard pts.count >= 2 else { return }
            let corners = Array(pts.dropLast())          // the last point is the reticle
            let sp = proj.projectPolygon(pts)
            if sp.count >= 3 { c.fill(path(sp, closed: true), with: .color((m.removal ? DS.Color.remove : DS.Color.accent).opacity(0.22))) }
            for run in proj.projectPolyline(corners) {
                let pth = path(run, closed: false)
                c.stroke(pth, with: .color(DS.Color.ink.opacity(0.5)), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                c.stroke(pth, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let last = corners.last, let seg = proj.projectSegment(last, pts[pts.count - 1]) {
                var e = Path(); e.move(to: cg(seg.0)); e.addLine(to: cg(seg.1))
                c.stroke(e, with: .color(DS.Color.ink.opacity(0.4)), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                c.stroke(e, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if corners.count >= 2, let seg = proj.projectSegment(pts[pts.count - 1], corners[0]) {
                var e = Path(); e.move(to: cg(seg.0)); e.addLine(to: cg(seg.1))
                c.stroke(e, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            for (i, q) in corners.enumerated() {
                guard let s = proj.project(q) else { continue }
                let r: CGFloat = i == 0 ? 6 : 4.5
                let rect = CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)
                c.fill(Circle().path(in: rect), with: .color(i == 0 ? (m.removal ? DS.Color.remove : DS.Color.accent) : .white))
                c.stroke(Circle().path(in: rect), with: .color(.white), lineWidth: 2)
            }
        }
    }

    static func equipmentGlyph(_ type: String) -> String {
        switch type {
        case "airMover": return "fan.fill"
        case "dehumidifier": return "dehumidifier.fill"
        case "airScrubber": return "air.purifier.fill"
        case "heater": return "heater.vertical.fill"
        default: return "shippingbox.fill"
        }
    }

    /// Reading pin: 34 pt solid status fill, 2.5 pt white ring, the value in white bold. On its
    /// point; when it had to step aside, a thin stem goes back to the point.
    func drawPin(_ pin: OverlayLayout.Pin, value: String, fill: Color, hollow: Bool, tagText: String?, selected: Bool, in c: inout GraphicsContext) {
        let s = pin.anchor, centre = pin.centre
        let d = hypot(s.x - centre.x, s.y - centre.y)
        if d >= OverlayLayout.stemMin {
            // A short stem from the circle's edge to the point.
            let edge = CGPoint(x: centre.x + (s.x - centre.x) / d * OverlayLayout.pinRadius,
                               y: centre.y + (s.y - centre.y) / d * OverlayLayout.pinRadius)
            var stem = Path(); stem.move(to: s); stem.addLine(to: edge)
            c.stroke(stem, with: .color(DS.Color.ink.opacity(0.45)), lineWidth: 3)
            c.stroke(stem, with: .color(.white), lineWidth: 1.2)
            c.fill(Circle().path(in: CGRect(x: s.x - 2.5, y: s.y - 2.5, width: 5, height: 5)), with: .color(.white))
        }
        let r = pin.circle
        if selected { c.stroke(Circle().path(in: r.insetBy(dx: -4.5, dy: -4.5)), with: .color(DS.Color.accent), lineWidth: 3) }
        var sh = c
        sh.addFilter(.shadow(color: .black.opacity(0.35), radius: 5, y: 2))
        sh.fill(Circle().path(in: r), with: .color(fill))
        c.stroke(Circle().path(in: r.insetBy(dx: 1.25, dy: 1.25)), with: .color(.white), lineWidth: hollow ? 3.5 : 2.5)
        let text = c.resolve(Text(value).font(.system(size: value.count > 3 ? 11 : 13, weight: .bold)).monospacedDigit().foregroundColor(.white))
        c.draw(text, at: centre, anchor: .center)
        if let tagText, let tr = pin.tag {
            let label = c.resolve(Text(tagText).font(DS.Font.captionBold).foregroundColor(.white))
            c.fill(Capsule().path(in: tr), with: .color(DS.Color.ink.opacity(0.82)))
            c.stroke(Capsule().path(in: tr), with: .color(.white.opacity(0.35)), lineWidth: 1)
            c.draw(label, at: CGPoint(x: tr.midX, y: tr.midY), anchor: .center)
        }
    }

    /// Skirting "cut" ticks: short white verticals every 0.5 m along the line.
    func cutTicks(_ a: WorldVec, _ b: WorldVec, in c: inout GraphicsContext) {
        let len = simd_distance(a, b)
        guard len > 0.5 else { return }
        var ticks = Path()
        var s = 0.5
        while s < len - 0.1 {
            let p = a + (b - a) * (s / len)
            if let q = proj.project(p) {
                ticks.move(to: CGPoint(x: q.x, y: q.y - 4.5))
                ticks.addLine(to: CGPoint(x: q.x, y: q.y + 4.5))
            }
            s += 0.5
        }
        c.stroke(ticks, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// A box as a wireframe: removal red (25 % fill on its silhouette, an "×" badge) or the
    /// white hover outline.
    func cabinetBox(_ corners: [WorldVec], removal: Bool, in c: inout GraphicsContext) {
        guard corners.count == 8 else { return }
        let sp = corners.map { proj.project($0) }
        let pts = sp.compactMap { $0 }.map(cg)
        guard pts.count >= 4 else { return }
        let hull = PlanBuilder.convexHull(pts.map { PlanVec(Double($0.x), Double($0.y)) }).map { CGPoint(x: $0.x, y: $0.y) }
        var sil = Path()
        if let f = hull.first { sil.move(to: f); for q in hull.dropFirst() { sil.addLine(to: q) }; sil.closeSubpath() }
        let col: Color = removal ? DS.Color.remove : .white
        c.fill(sil, with: .color(col.opacity(removal ? 0.25 : 0.10)))
        var edges = Path()
        for (i, j) in [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
            guard let seg = proj.projectSegment(corners[i], corners[j]) else { continue }
            edges.move(to: cg(seg.0)); edges.addLine(to: cg(seg.1))
        }
        if removal { c.stroke(edges, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 4, lineCap: .round)) }
        c.stroke(edges, with: .color(removal ? col : col.opacity(0.9)), style: StrokeStyle(lineWidth: removal ? 2 : 1.5, lineCap: .round))
        // The "x" badge on the front face, a little below its top edge (clear of a benchtop).
        let front = [corners[0], corners[1], corners[4], corners[5]]
        let badgeAt = (front[0] + front[1]) * 0.15 + (front[2] + front[3]) * 0.35
        if removal, let q = proj.project(badgeAt) {
            let r = CGRect(x: q.x - 9, y: q.y - 9, width: 18, height: 18)
            c.fill(Circle().path(in: r), with: .color(DS.Color.remove))
            c.stroke(Circle().path(in: r), with: .color(.white), lineWidth: 1.5)
            var x = Path()
            x.move(to: CGPoint(x: q.x - 4, y: q.y - 4)); x.addLine(to: CGPoint(x: q.x + 4, y: q.y + 4))
            x.move(to: CGPoint(x: q.x + 4, y: q.y - 4)); x.addLine(to: CGPoint(x: q.x - 4, y: q.y + 4))
            c.stroke(x, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    /// The hovered component, before any tap: a soft white highlight in the mode's style.
    func hover(_ k: OverlayMark.HoverKind, _ m: OverlayMark, in c: inout GraphicsContext) {
        switch k {
        case .skirting:
            guard m.points.count >= 2, let seg = proj.projectSegment(m.points[0] + WorldVec(0, 0.03, 0), m.points[1] + WorldVec(0, 0.03, 0)) else { return }
            let a = cg(seg.0), b = cg(seg.1)
            var line = Path(); line.move(to: a); line.addLine(to: b)
            var glow = c
            glow.addFilter(.blur(radius: 3))
            glow.stroke(line, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            c.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
            for (p, w) in [(a, m.points[0]), (b, m.points[1])] where proj.depth(w) > proj.near {
                c.stroke(Rectangle().path(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.white), lineWidth: 2)
            }
        case .face, .faceBlue:
            let sp = proj.projectPolygon(m.points)
            guard sp.count >= 3 else { return }
            let col: Color = k == .faceBlue ? DS.Color.tide : .white
            c.fill(path(sp, closed: true), with: .color(col.opacity(0.06)))
            c.stroke(path(sp, closed: true), with: .color(col.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        case .box:
            cabinetBox(m.points, removal: false, in: &c)
        case .floor:
            let sp = proj.projectPolygon(m.points)
            guard sp.count >= 3 else { return }
            let outline = path(sp, closed: true)
            var glow = c
            glow.addFilter(.blur(radius: 3))
            glow.stroke(outline, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
            c.stroke(outline, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        case .ring:
            guard let p = m.points.first, let s = proj.project(p) else { return }
            let r = CGRect(x: s.x - 24, y: s.y - 24, width: 48, height: 48)
            c.stroke(Circle().path(in: r), with: .color(.white.opacity(m.selected ? 0.9 : 0.55)), lineWidth: m.selected ? 2 : 1.5)
        }
    }

    /// The moisture model's wet area: measured solid, estimated lighter, the scoper's own
    /// correction solid with a small pencil glyph (docs/MOISTURE.md "Honest by design").
    func modelArea(_ m: OverlayMark, provenance prov: String, in c: inout GraphicsContext) {
        let sp = proj.projectPolygon(m.points)
        guard sp.count >= 3 else { return }
        let shape = path(sp, closed: true)
        c.fill(shape, with: .color(DS.Color.source.opacity(prov == "estimated" ? 0.17 : 0.36)))
        guard prov == "scoper" else { return }
        let xs = sp.map(\.x), ys = sp.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 - x0 > 30, y1 - y0 > 20 else { return }
        let ctr = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
        let r = CGRect(x: ctr.x - 11, y: ctr.y - 11, width: 22, height: 22)
        c.fill(Circle().path(in: r), with: .color(Self.glass))
        symbol("pencil", in: r.insetBy(dx: 5, dy: 5), c: &c)
    }

    /// Moisture extent on a wall: a blue wash from the floor up to a soft wavy tide line.
    func moistureWash(_ m: OverlayMark, in c: inout GraphicsContext) {
        guard m.points.count >= 2 else { return }
        let fy = m.floorLevel ?? (m.points.map(\.y).min() ?? 0)
        let top = m.points.compactMap { proj.project($0) }
        let base = m.points.map { WorldVec($0.x, fy, $0.z) }.compactMap { proj.project($0) }
        guard top.count == m.points.count, base.count == m.points.count else { return }
        // The wavy top: a gentle sine along the line (4 pt, 28 pt wavelength).
        var wavy: [CGPoint] = []
        var run = 0.0
        for i in 1..<top.count {
            let a = top[i - 1], b = top[i]
            let d = b - a
            let len = simd_length(d)
            guard len > 0.5 else { continue }
            let u = d / len, n = ScreenVec(-u.y, u.x)
            var s = 0.0
            while s < len {
                let p = a + u * s + n * (4 * sin((run + s) / 28 * 2 * .pi))
                wavy.append(cg(p))
                s += 4
            }
            run += len
        }
        if let last = top.last { wavy.append(cg(last)) }
        var wash = Path()
        guard let f = wavy.first else { return }
        wash.move(to: f)
        for q in wavy.dropFirst() { wash.addLine(to: q) }
        for q in base.reversed() { wash.addLine(to: cg(q)) }
        wash.closeSubpath()
        if !m.lineOnly { c.fill(wash, with: .color(DS.Color.source.opacity(0.32))) }
        var edge = Path()
        edge.move(to: f)
        for q in wavy.dropFirst() { edge.addLine(to: q) }
        c.stroke(edge, with: .color(DS.Color.tide), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    /// The flooring material's pattern, laid in the world on the floor (so it foreshortens like
    /// the real thing), clipped to the area: carpet stipple, vinyl hatch, timber planks, tile grid.
    func floorPattern(_ type: String?, polygon: [WorldVec], clip: Path, in c: inout GraphicsContext) {
        guard polygon.count >= 3 else { return }
        var g = c
        g.clip(to: clip)
        let y = polygon[0].y + 0.002
        let xs = polygon.map(\.x), zs = polygon.map(\.z)
        guard let x0 = xs.min(), let x1 = xs.max(), let z0 = zs.min(), let z1 = zs.max(), (x1 - x0) * (z1 - z0) < 80 else { return }
        var lines = Path()
        func seg(_ a: WorldVec, _ b: WorldVec) {
            guard let s = proj.projectSegment(a, b) else { return }
            lines.move(to: cg(s.0)); lines.addLine(to: cg(s.1))
        }
        switch type {
        case "carpet"?:
            var dots = Path()
            var i = 0
            var z = z0
            while z <= z1 {
                var x = x0 + (i % 2 == 0 ? 0 : 0.035)
                while x <= x1 {
                    if let s = proj.project(WorldVec(x, y, z)) {
                        let r = (i + Int(x * 100)) % 3 == 0 ? 0.9 : 1.1
                        dots.addEllipse(in: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2))
                    }
                    x += 0.07
                }
                z += 0.07
                i += 1
            }
            g.fill(dots, with: .color(.white.opacity(0.5)))
            return
        case "timber"?:
            // Planks along the longer side: 0.14 m boards, butt joints every 0.9 m, staggered.
            let alongX = (x1 - x0) >= (z1 - z0)
            var k = 0
            var v = alongX ? z0 : x0
            let vEnd = alongX ? z1 : x1
            while v <= vEnd {
                if alongX { seg(WorldVec(x0, y, v), WorldVec(x1, y, v)) } else { seg(WorldVec(v, y, z0), WorldVec(v, y, z1)) }
                var u = (alongX ? x0 : z0) + (k % 2 == 0 ? 0.0 : 0.45)
                while u <= (alongX ? x1 : z1) {
                    if alongX { seg(WorldVec(u, y, v), WorldVec(u, y, v + 0.14)) } else { seg(WorldVec(v, y, u), WorldVec(v + 0.14, y, u)) }
                    u += 0.9
                }
                v += 0.14
                k += 1
            }
            g.stroke(lines, with: .color(.white.opacity(0.5)), lineWidth: 1.2)
        case "tile"?:
            var x = x0
            while x <= x1 { seg(WorldVec(x, y, z0), WorldVec(x, y, z1)); x += 0.3 }
            var z = z0
            while z <= z1 { seg(WorldVec(x0, y, z), WorldVec(x1, y, z)); z += 0.3 }
            g.stroke(lines, with: .color(.white.opacity(0.45)), lineWidth: 1)
        default:
            // Vinyl / LVP and anything else: a fine diagonal hatch.
            let span = (x1 - x0) + (z1 - z0)
            var s = -span
            while s <= span {
                seg(WorldVec(x0 + s, y, z0), WorldVec(x0 + s + (z1 - z0), y, z1))
                s += 0.12
            }
            g.stroke(lines, with: .color(.white.opacity(0.5)), lineWidth: 1.4)
        }
    }

    /// A line's end: a white dot (ringed in red at the start).
    func endCap(_ p: CGPoint, ring: Bool, in c: inout GraphicsContext) {
        let r: CGFloat = ring ? 8 : 6
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        c.fill(Circle().path(in: rect), with: .color(.white))
        if ring { c.stroke(Circle().path(in: rect.insetBy(dx: 1.5, dy: 1.5)), with: .color(DS.Color.remove), lineWidth: 3) }
    }

    func startCap(_ p: CGPoint, in c: inout GraphicsContext) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        c.stroke(Circle().path(in: r.insetBy(dx: -3, dy: -3)), with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        c.fill(Circle().path(in: r), with: .color(.white))
    }

    func endTicks(_ a: CGPoint, _ b: CGPoint, color: Color, in c: inout GraphicsContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let nx = -dy / len * 9, ny = dx / len * 9
        for p in [a, b] {
            var t = Path()
            t.move(to: CGPoint(x: p.x - nx, y: p.y - ny))
            t.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny))
            c.stroke(t, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            c.stroke(t, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// Small wave ticks under a moisture line, every ~18 pt.
    func waveTicks(_ run: [ScreenVec], in c: inout GraphicsContext) {
        var ticks = Path()
        for i in 1..<max(run.count, 1) {
            let a = run[i - 1], b = run[i]
            let d = b - a
            let len = simd_length(d)
            guard len > 1 else { continue }
            let u = d / len, n = ScreenVec(-u.y, u.x)
            var s = 9.0
            while s < len {
                let p = a + u * s
                let n2 = n.y < 0 ? -n : n
                ticks.move(to: cg(p + n2 * 3))
                ticks.addQuadCurve(to: cg(p + n2 * 3 + u * 8), control: cg(p + n2 * 8 + u * 4))
                s += 18
            }
        }
        c.stroke(ticks, with: .color(DS.Color.source.opacity(0.9)), lineWidth: 1.5)
    }

    /// Air mover airflow: a slim tapered arrow lying on the floor, from the unit, 1.0 m.
    func airflow(from p: WorldVec, dir: WorldVec, planned: Bool, in c: inout GraphicsContext) {
        let sp = proj.projectPolygon(OverlayLayout.arrow(from: p, dir: dir))
        guard sp.count >= 3 else { return }
        let shape = path(sp, closed: true)
        c.fill(shape, with: .color(DS.Color.equip.opacity(planned ? 0.18 : 0.4)))
        c.stroke(shape, with: .color(DS.Color.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        c.stroke(shape, with: .color(planned ? DS.Color.equip : .white), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    /// A selected item off screen: an edge chip pointing at it ("R3 ←").
    func edgeArrowIfNeeded(_ m: OverlayMark) {
        guard let p = m.points.first else { return }
        if let s = proj.project(p), proj.onScreen(s, inset: 24) { return }
        let dir = proj.offscreenDirection(p)
        let centre = ScreenVec(Double(size.width) / 2, Double(size.height) / 2)
        let box = ScreenVec(Double(size.width) / 2 - 70, Double(size.height) / 2 - 140)
        let k = min(abs(box.x / max(abs(dir.x), 1e-6)), abs(box.y / max(abs(dir.y), 1e-6)))
        let at = centre + dir * k
        let arrow: String
        if abs(dir.x) > abs(dir.y) { arrow = dir.x > 0 ? "→" : "←" } else { arrow = dir.y > 0 ? "↓" : "↑" }
        let text = "\(m.tag ?? "Item") \(arrow)"
        let sz = measure.tag(text)
        var c = ctx
        capsule(text, in: CGRect(x: at.x - sz.width / 2, y: at.y - sz.height / 2, width: sz.width, height: sz.height), fill: DS.Color.accent, c: &c)
    }
}
