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
                    OverlayPainter(ctx: ctx, proj: proj, size: size, time: t).draw(hud.allMarks())
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The drawing itself (pure SwiftUI GraphicsContext; no state).
struct OverlayPainter {
    var ctx: GraphicsContext
    let proj: Projector
    let size: CGSize
    let time: Double
    /// Labels already placed this frame: later ones move out of their way.
    let board = LabelBoard()

    /// Labels keep clear of the reticle and its readout.
    var reticleZone: CGRect {
        CGRect(x: size.width / 2 - 90, y: size.height / 2 - 70, width: 180, height: 110)
    }

    func draw(_ marks: [OverlayMark]) {
        // Floor and wall areas first, then lines, then pins (pins on top).
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
        var labels: [(CGRect, () -> Void)] = []
        for m in sorted {
            var c = ctx
            if m.faded { c.opacity = 0.5 }
            draw(m, in: &c, labels: &labels)
        }
        for m in sorted where m.selected { edgeArrowIfNeeded(m) }
    }

    // MARK: Helpers

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

    /// A tag capsule centred at `p`, nudged out of the reticle zone.
    func tag(_ text: String, at p: CGPoint, fill: Color, in c: inout GraphicsContext, above: Bool = true) {
        let label = c.resolve(Text(text).font(DS.Font.captionBold).monospacedDigit().foregroundColor(.white))
        let ts = label.measure(in: CGSize(width: 260, height: 40))
        var r = CGRect(x: p.x - ts.width / 2 - 9, y: p.y - (above ? ts.height + 12 : 0), width: ts.width + 18, height: ts.height + 8)
        // Never under the top bar, never off the sides, never on the reticle or another label.
        r.origin.x = min(max(r.minX, 10), size.width - r.width - 10)
        r.origin.y = min(max(r.minY, 112), size.height - r.height - 10)
        for _ in 0..<6 {
            if r.intersects(reticleZone) {
                r.origin.y = r.midY < reticleZone.midY ? reticleZone.minY - r.height - 4 : reticleZone.maxY + 4
                continue
            }
            guard let hit = board.rects.first(where: { $0.insetBy(dx: -3, dy: -3).intersects(r) }) else { break }
            r.origin.y = r.midY <= hit.midY ? hit.minY - r.height - 4 : hit.maxY + 4
        }
        board.rects.append(r)
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

    func draw(_ m: OverlayMark, in c: inout GraphicsContext, labels: inout [(CGRect, () -> Void)]) {
        switch m.style {
        case .reading(let st, let reference):
            guard let p = m.points.first, let s = proj.project(p) else { return }
            pin(at: cg(s), value: m.value ?? "", fill: reference ? DS.Color.ink.opacity(0.55) : status(st), hollow: reference,
                tagText: m.tag, selected: m.selected, in: &c)
        case .readingDraft:
            guard let p = m.points.first, let s = proj.project(p) else { return }
            let v = Double(m.value ?? "")
            let fill = v.map { status(OverlayBuild.status($0, reference: false)) } ?? DS.Color.ink.opacity(0.6)
            pin(at: cg(s), value: m.value ?? "–", fill: fill, hollow: false, tagText: nil, selected: true, in: &c)
        case .photo:
            guard let p = m.points.first, let s = proj.project(p) else { return }
            let r = CGRect(x: s.x - 11, y: s.y - 11, width: 22, height: 22)
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous).path(in: r)
            c.fill(shape, with: .color(DS.Color.ink.opacity(0.78)))
            c.stroke(shape, with: .color(m.selected ? DS.Color.accent : .white.opacity(0.85)), lineWidth: m.selected ? 2.5 : 1.5)
            symbol("camera.fill", in: r.insetBy(dx: 5, dy: 6), c: &c)
            if m.selected, let t = m.tag { tag(t, at: CGPoint(x: s.x, y: r.minY - 2), fill: DS.Color.ink.opacity(0.8), in: &c) }
        case .source:
            guard let p = m.points.first, let s = proj.project(p) else { return }
            let pt = cg(s)
            let phase = (time.truncatingRemainder(dividingBy: 2)) / 2
            let pr = 13 + 18 * phase
            c.stroke(Circle().path(in: CGRect(x: pt.x - pr, y: pt.y - pr, width: pr * 2, height: pr * 2)),
                     with: .color(DS.Color.source.opacity(0.9 * (1 - phase))), lineWidth: 2)
            let r = CGRect(x: pt.x - 13, y: pt.y - 13, width: 26, height: 26)
            c.fill(Circle().path(in: r), with: .color(DS.Color.source))
            c.stroke(Circle().path(in: r), with: .color(.white), lineWidth: 2)
            symbol("drop.fill", in: r.insetBy(dx: 7, dy: 6), c: &c)
            if let t = m.tag { tag(t, at: CGPoint(x: pt.x, y: pt.y - 16), fill: DS.Color.source, in: &c) }
        case .equipment(let type, let planned):
            guard let p = m.points.first else { return }
            if let d = m.airflow { airflow(from: p, dir: d, planned: planned, live: m.id == "draft-airflow", in: &c) }
            guard m.id != "draft-airflow", let s = proj.project(p + WorldVec(0, 0.17, 0)) else { return }
            let r = CGRect(x: s.x - 17, y: s.y - 17, width: 34, height: 34)
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous).path(in: r)
            if planned {
                c.fill(shape, with: .color(DS.Color.ink.opacity(0.45)))
                c.stroke(shape, with: .color(DS.Color.equip), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            } else {
                c.fill(shape, with: .color(DS.Color.equip))
                c.stroke(shape, with: .color(.white), lineWidth: m.selected ? 3 : 2)
            }
            symbol(Self.equipmentGlyph(type), in: r.insetBy(dx: 8, dy: 8), color: planned ? DS.Color.equip : .white, c: &c)
            if let t = m.tag { tag(t, at: CGPoint(x: s.x, y: r.maxY + 4), fill: planned ? DS.Color.ink.opacity(0.75) : DS.Color.equip, in: &c, above: false) }
        case .skirting:
            guard m.points.count >= 2, let seg = proj.projectSegment(m.points[0] + WorldVec(0, 0.04, 0), m.points[1] + WorldVec(0, 0.04, 0)) else { return }
            let a = cg(seg.0), b = cg(seg.1)
            var line = Path(); line.move(to: a); line.addLine(to: b)
            c.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            c.stroke(line, with: .color(DS.Color.remove), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            endTicks(a, b, color: DS.Color.remove, in: &c)
            if let t = m.tag { tag(t, at: CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 6), fill: DS.Color.remove, in: &c) }
        case .lining:
            guard m.points.count >= 2 else { return }
            let top = m.top ?? 0.6
            let a = m.points[0], b = m.points[1]
            let quad = [a, b, b + WorldVec(0, top, 0), a + WorldVec(0, top, 0)]
            let sp = proj.projectPolygon(quad)
            guard sp.count >= 3 else { return }
            let shape = path(sp, closed: true)
            c.fill(shape, with: .color(DS.Color.remove.opacity(0.28)))
            hatch(shape, color: DS.Color.remove.opacity(0.55), in: &c)
            c.stroke(shape, with: .color(DS.Color.remove), lineWidth: m.selected ? 3 : 2)
            if let t = m.tag, let tl = proj.project(quad[3]), let tr = proj.project(quad[2]) {
                let left = tl.x < tr.x ? tl : tr
                tag(t, at: CGPoint(x: left.x + 60, y: min(tl.y, tr.y) - 2), fill: DS.Color.remove, in: &c)
            }
        case .moisture:
            for run in proj.projectPolyline(m.points) {
                let p = path(run, closed: false)
                c.stroke(p, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                c.stroke(p, with: .color(DS.Color.source), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                waveTicks(run, in: &c)
            }
            if let t = m.tag, let last = m.points.last, let s = proj.project(last) {
                tag(t, at: CGPoint(x: s.x, y: s.y - 8), fill: DS.Color.source, in: &c)
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
            if let t = m.tag, let ctr = centroid(m.points), let s = proj.project(ctr) {
                tag(t, at: CGPoint(x: s.x, y: s.y + 10), fill: col, in: &c)
            }
        case .lineDraft:
            guard m.points.count >= 2, let seg = proj.projectSegment(m.points[0], m.points[1]) else { return }
            let a = cg(seg.0), b = cg(seg.1)
            var line = Path(); line.move(to: a); line.addLine(to: b)
            c.stroke(line, with: .color(DS.Color.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            c.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if proj.depth(m.points[0]) > proj.near { startCap(a, in: &c) }
            if let t = m.tag { tag(t, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 4), fill: DS.Color.ink.opacity(0.8), in: &c) }
        case .areaDraft:
            let pts = m.points
            guard pts.count >= 2 else { return }
            let corners = Array(pts.dropLast())          // the last point is the reticle
            let sp = proj.projectPolygon(pts)
            if sp.count >= 3 {
                let shape = path(sp, closed: true)
                c.fill(shape, with: .color(DS.Color.accent.opacity(0.22)))
            }
            let fixed = proj.projectPolyline(corners)
            for run in fixed {
                c.stroke(path(run, closed: false), with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let last = corners.last, let seg = proj.projectSegment(last, pts[pts.count - 1]) {
                var e = Path(); e.move(to: cg(seg.0)); e.addLine(to: cg(seg.1))
                c.stroke(e, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
            }
            if corners.count >= 2, let seg = proj.projectSegment(pts[pts.count - 1], corners[0]) {
                var e = Path(); e.move(to: cg(seg.0)); e.addLine(to: cg(seg.1))
                c.stroke(e, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 6]))
            }
            for (i, q) in corners.enumerated() {
                guard let s = proj.project(q) else { continue }
                let r: CGFloat = i == 0 ? 6 : 4.5
                let rect = CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)
                c.fill(Circle().path(in: rect), with: .color(i == 0 ? DS.Color.accent : .white))
                c.stroke(Circle().path(in: rect), with: .color(.white), lineWidth: 2)
            }
            if let t = m.tag, let ctr = centroid(pts), let s = proj.project(ctr) {
                tag(t, at: CGPoint(x: s.x, y: s.y + 10), fill: DS.Color.ink.opacity(0.8), in: &c)
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

    func centroid(_ p: [WorldVec]) -> WorldVec? {
        guard !p.isEmpty else { return nil }
        return p.reduce(WorldVec(0, 0, 0), +) / Double(p.count)
    }

    /// Reading pin: 30 pt circle above the surface point, white 2 pt ring, value inside,
    /// sequence tag below, 1 pt stem to the point.
    func pin(at s: CGPoint, value: String, fill: Color, hollow: Bool, tagText: String?, selected: Bool, in c: inout GraphicsContext) {
        let lift: CGFloat = 46
        let centre = CGPoint(x: s.x, y: s.y - lift)
        var stem = Path(); stem.move(to: s); stem.addLine(to: CGPoint(x: s.x, y: centre.y + 15))
        c.stroke(stem, with: .color(DS.Color.ink.opacity(0.5)), lineWidth: 3)
        c.stroke(stem, with: .color(.white), lineWidth: 1)
        c.fill(Circle().path(in: CGRect(x: s.x - 2.5, y: s.y - 2.5, width: 5, height: 5)), with: .color(.white))
        if let tagText {
            let label = c.resolve(Text(tagText).font(DS.Font.captionBold).foregroundColor(.white))
            let ts = label.measure(in: CGSize(width: 80, height: 30))
            let r = CGRect(x: s.x - ts.width / 2 - 6, y: centre.y + 18, width: ts.width + 12, height: ts.height + 2)
            c.fill(Capsule().path(in: r), with: .color(DS.Color.ink.opacity(0.75)))
            c.draw(label, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
        }
        let r = CGRect(x: centre.x - 15, y: centre.y - 15, width: 30, height: 30)
        board.rects.append(r.insetBy(dx: -2, dy: -2))
        if selected {
            c.stroke(Circle().path(in: r.insetBy(dx: -4, dy: -4)), with: .color(DS.Color.accent), lineWidth: 3)
        }
        c.fill(Circle().path(in: r.insetBy(dx: -1, dy: -1)), with: .color(DS.Color.ink.opacity(0.25)))
        c.fill(Circle().path(in: r), with: .color(fill))
        c.stroke(Circle().path(in: r), with: .color(.white), lineWidth: hollow ? 3 : 2)
        let text = c.resolve(Text(value).font(DS.Font.value(value.count > 3 ? 11 : 14)).foregroundColor(.white))
        c.draw(text, at: centre, anchor: .center)
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
                let n2 = n.y < 0 ? -n : n                    // ticks hang below
                ticks.move(to: cg(p + n2 * 3))
                ticks.addQuadCurve(to: cg(p + n2 * 3 + u * 8), control: cg(p + n2 * 8 + u * 4))
                s += 18
            }
        }
        c.stroke(ticks, with: .color(DS.Color.source.opacity(0.9)), lineWidth: 1.5)
    }

    /// Air mover airflow: a tapered arrow on the floor, 1.2 m long.
    func airflow(from p: WorldVec, dir: WorldVec, planned: Bool, live: Bool, in c: inout GraphicsContext) {
        let d = simd_normalize(WorldVec(dir.x, 0, dir.z))
        let side = WorldVec(-d.z, 0, d.x)
        let y = WorldVec(0, 0.01, 0)
        let base = p + y
        let s0 = 0.25, s1 = 0.95, tip = 1.2
        let poly = [base + d * s0 + side * 0.06, base + d * s1 + side * 0.03, base + d * s1 + side * 0.15, base + d * tip,
                    base + d * s1 - side * 0.15, base + d * s1 - side * 0.03, base + d * s0 - side * 0.06]
        let sp = proj.projectPolygon(poly)
        guard sp.count >= 3 else { return }
        let shape = path(sp, closed: true)
        if planned {
            c.stroke(shape, with: .color(DS.Color.equip), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [6, 4]))
        } else {
            c.fill(shape, with: .color(DS.Color.equip.opacity(live ? 0.95 : 0.85)))
            c.stroke(shape, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }

    /// A selected item off screen: an edge chip pointing at it ("R3 ←").
    func edgeArrowIfNeeded(_ m: OverlayMark) {
        guard let p = m.points.first else { return }
        if let s = proj.project(p), proj.onScreen(s, inset: 24) { return }
        let dir = proj.offscreenDirection(p)
        let centre = ScreenVec(Double(size.width) / 2, Double(size.height) / 2)
        // Walk from the centre to the safe edge box.
        let box = ScreenVec(Double(size.width) / 2 - 70, Double(size.height) / 2 - 140)
        let k = min(abs(box.x / max(abs(dir.x), 1e-6)), abs(box.y / max(abs(dir.y), 1e-6)))
        let at = centre + dir * k
        let arrow: String
        if abs(dir.x) > abs(dir.y) { arrow = dir.x > 0 ? "→" : "←" } else { arrow = dir.y > 0 ? "↓" : "↑" }
        var c = ctx
        tag("\(m.tag ?? "Item") \(arrow)", at: cg(at), fill: DS.Color.accent, in: &c, above: false)
    }
}

/// Label rectangles placed in one frame (shared by the painter's copies).
final class LabelBoard {
    var rects: [CGRect] = []
}
