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

    func screen(_ w: WorldVec) -> ScreenVec {
        let p = camera.projectPoint(SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)), orientation: .portrait,
                                    viewportSize: CGSize(width: viewport.x, height: viewport.y))
        return ScreenVec(Double(p.x), Double(p.y))
    }
}

/// The overlay: marks from the HUD model, projected with the engine's camera.
struct OverlayRenderer: View {
    @ObservedObject var hud: CaptureHUDModel

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas(rendersAsynchronously: false) { ctx, size in
                    guard let proj = hud.engine.projector(viewport: size) else { return }
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    OverlayPainter(ctx: ctx, proj: proj, size: size, time: t).draw(hud.allMarks(), reticleLabel: hud.reticleText)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
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

    var measure: OverlayLayout.Measure {
        let c = ctx
        func m(_ t: String) -> CGSize { c.resolve(Text(t).font(DS.Font.captionBold).monospacedDigit()).measure(in: CGSize(width: 300, height: 40)) }
        return OverlayLayout.Measure(tag: { let s = m($0); return CGSize(width: s.width + 18, height: s.height + 8) },
                                     pinTag: { let s = m($0); return CGSize(width: s.width + 10, height: s.height + 1) },
                                     reticle: { let s = m($0); return CGSize(width: s.width + 24, height: max(30, s.height + 12)) })
    }

    func draw(_ marks: [OverlayMark], reticleLabel: String?) {
        let plan = OverlayLayout.plan(marks, projector: proj, reticleLabel: reticleLabel, measure: measure)
        let order: (OverlayMark) -> Int = { m in
            switch m.style {
            case .wetFloor, .liftFlooring, .areaDraft: return 0
            case .lining: return 1
            case .skirting, .moisture, .lineDraft: return 2
            case .equipment: return 3
            default: return 4
            }
        }
        let sorted = marks.sorted { order($0) < order($1) }
        // Shapes and symbols.
        for m in sorted {
            var c = ctx
            if m.faded { c.opacity = 0.5 }
            shape(m, plan: plan, in: &c)
        }
        // Labels on top of every shape.
        for m in sorted {
            guard let r = plan.labels[m.id], let t = m.tag else { continue }
            var c = ctx
            if m.faded { c.opacity = 0.6 }
            capsule(t, in: r, fill: tagFill(m), c: &c)
        }
        if let r = plan.labels["reticle"], let t = reticleLabel {
            var c = ctx
            capsule(t, in: r, fill: DS.Color.ink.opacity(0.72), c: &c, font: DS.Font.captionBold)
        }
        for m in sorted where m.selected { edgeArrowIfNeeded(m) }
    }

    func tagFill(_ m: OverlayMark) -> Color {
        switch m.style {
        case .skirting, .lining, .liftFlooring: return DS.Color.remove
        case .moisture, .wetFloor, .source: return DS.Color.source
        case .equipment(_, let planned): return planned ? DS.Color.ink.opacity(0.8) : DS.Color.equip
        default: return DS.Color.ink.opacity(0.8)
        }
    }

    func capsule(_ text: String, in r: CGRect, fill: Color, c: inout GraphicsContext, font: Font = DS.Font.captionBold) {
        let label = c.resolve(Text(text).font(font).monospacedDigit().foregroundColor(.white))
        let shape = Capsule().path(in: r)
        c.fill(shape, with: .color(fill))
        c.stroke(shape, with: .color(.white.opacity(0.25)), lineWidth: 1)
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
            let pr = 13 + 18 * phase
            c.stroke(Circle().path(in: CGRect(x: pt.x - pr, y: pt.y - pr, width: pr * 2, height: pr * 2)),
                     with: .color(DS.Color.source.opacity(0.9 * (1 - phase))), lineWidth: 2)
            c.fill(Circle().path(in: r), with: .color(DS.Color.source))
            c.stroke(Circle().path(in: r), with: .color(.white), lineWidth: 2)
            symbol("drop.fill", in: r.insetBy(dx: 7, dy: 6), c: &c)
        case .equipment(let type, let planned):
            guard let p = m.points.first else { return }
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
            c.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            c.stroke(line, with: .color(DS.Color.remove), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            endTicks(a, b, color: DS.Color.remove, in: &c)
        case .lining:
            guard m.points.count >= 2 else { return }
            let top = m.top ?? 0.6
            let a = m.points[0], b = m.points[1]
            let sp = proj.projectPolygon([a, b, b + WorldVec(0, top, 0), a + WorldVec(0, top, 0)])
            guard sp.count >= 3 else { return }
            let shape = path(sp, closed: true)
            c.fill(shape, with: .color(DS.Color.remove.opacity(0.28)))
            hatch(shape, color: DS.Color.remove.opacity(0.55), in: &c)
            c.stroke(shape, with: .color(DS.Color.remove), style: StrokeStyle(lineWidth: m.selected ? 3 : 2, lineJoin: .round))
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
            c.fill(shape, with: .color(col.opacity(lift ? 0.22 : 0.3)))
            if lift { hatch(shape, color: col.opacity(0.5), spacing: 11, in: &c) }
            c.stroke(shape, with: .color(col), style: StrokeStyle(lineWidth: m.selected ? 3.5 : 2.5, lineJoin: .round))
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
            if sp.count >= 3 { c.fill(path(sp, closed: true), with: .color(DS.Color.accent.opacity(0.22))) }
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
                c.fill(Circle().path(in: rect), with: .color(i == 0 ? DS.Color.accent : .white))
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

    /// Reading pin at its planned place: 30 pt circle, white ring, value inside, stem to the
    /// surface point, sequence tag tucked beside it.
    func drawPin(_ pin: OverlayLayout.Pin, value: String, fill: Color, hollow: Bool, tagText: String?, selected: Bool, in c: inout GraphicsContext) {
        let s = pin.anchor, centre = pin.centre
        var stem = Path(); stem.move(to: s); stem.addLine(to: CGPoint(x: centre.x, y: centre.y + 15))
        c.stroke(stem, with: .color(DS.Color.ink.opacity(0.5)), lineWidth: 3)
        c.stroke(stem, with: .color(.white), lineWidth: 1)
        c.fill(Circle().path(in: CGRect(x: s.x - 2.5, y: s.y - 2.5, width: 5, height: 5)), with: .color(.white))
        let r = pin.circle
        if selected { c.stroke(Circle().path(in: r.insetBy(dx: -4, dy: -4)), with: .color(DS.Color.accent), lineWidth: 3) }
        c.fill(Circle().path(in: r.insetBy(dx: -1, dy: -1)), with: .color(DS.Color.ink.opacity(0.3)))
        c.fill(Circle().path(in: r), with: .color(fill))
        c.stroke(Circle().path(in: r), with: .color(.white), lineWidth: hollow ? 3 : 2)
        let text = c.resolve(Text(value).font(DS.Font.value(value.count > 3 ? 11 : 14)).foregroundColor(.white))
        c.draw(text, at: centre, anchor: .center)
        if let tagText, let tr = pin.tag {
            let label = c.resolve(Text(tagText).font(DS.Font.captionBold).foregroundColor(.white))
            c.fill(Capsule().path(in: tr), with: .color(DS.Color.ink.opacity(0.82)))
            c.stroke(Capsule().path(in: tr), with: .color(.white.opacity(0.35)), lineWidth: 1)
            c.draw(label, at: CGPoint(x: tr.midX, y: tr.midY), anchor: .center)
        }
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
