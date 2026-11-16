//
//  OverlayLayout.swift
//  SecureScan
//
//  Where every overlay label, pin and glyph goes on screen, in one pass with
//  ONE obstacle set: pins (circle + tag), photo / source glyphs, equipment
//  boxes, airflow arrows' bounds, the reticle and its label, and the tags of
//  lines and areas. Pins and glyphs that land on each other step apart;
//  labels move to the nearest free spot inside the safe area; a label whose
//  anchor is off screen is not shown. The renderer draws from this plan and
//  the tests check the same plans for overlaps.
//  Foundation + CoreGraphics + simd only - unit tested.
//

import Foundation
import CoreGraphics
import simd

enum OverlayLayout {
    /// Limits for labels inside the camera viewport (points): below the instruction card,
    /// above the sub-picker, inside the side margins.
    static let margin: CGFloat = 12
    static let topLimit: CGFloat = 60
    static let bottomLimit: CGFloat = 64
    static let pinLift: CGFloat = 0
    static let pinRadius: CGFloat = 17

    /// The 3D models' heights (m): air mover 0.40, dehumidifier 0.75, air scrubber 0.60, heater 0.40.
    static func equipmentHeight(_ type: String) -> Double {
        switch type {
        case "dehumidifier": return 0.75
        case "airScrubber": return 0.60
        default: return 0.40
        }
    }

    /// The words on a mark's tag as drawn: the noun first ("Skirting · 2.35 m"); equipment
    /// adds its type ("AM-03 · Air mover"); reading tags only when selected.
    static func displayTag(_ m: OverlayMark) -> String? {
        switch m.style {
        case .equipment(let type, _):
            guard let t = m.tag, !t.isEmpty else { return nil }
            return "\(t) · \(CaptureCopy.equipmentName(type))"
        case .reading, .readingDraft:
            return m.selected ? m.tag : nil
        default:
            return m.tag
        }
    }

    struct Pin: Equatable {
        var anchor: CGPoint          // the surface point
        var centre: CGPoint          // the circle
        var tag: CGRect?             // the sequence capsule
        var bounds: CGRect { tag.map { circle.union($0) } ?? circle }
        var circle: CGRect { CGRect(x: centre.x - pinRadius, y: centre.y - pinRadius, width: 2 * pinRadius, height: 2 * pinRadius) }
    }

    struct Plan: Equatable {
        var pins: [String: Pin] = [:]
        /// Photo / source glyphs and equipment boxes.
        var glyphs: [String: CGRect] = [:]
        /// Airflow arrows' screen bounds.
        var arrows: [String: CGRect] = [:]
        /// Tag capsules (key = mark id; the reticle label is "reticle").
        var labels: [String: CGRect] = [:]
        var reticle: CGRect = .zero
        /// Glyphs that are 3D models' footprints: the reticle may sit on a model (aiming at it).
        var models: Set<String> = []

        /// Everything that must not overlap anything else.
        var solids: [(String, CGRect)] {
            var out: [(String, CGRect)] = []
            for (k, p) in pins { out.append(("pin:" + k, p.bounds)) }
            for (k, g) in glyphs { out.append(("glyph:" + k, g)) }
            for (k, l) in labels { out.append(("label:" + k, l)) }
            out.append(("reticle-ring", reticle))
            return out
        }

        /// Pairs that overlap (empty = a clean layout). Arrows are only checked against labels.
        func overlaps() -> [String] {
            var out: [String] = []
            let s = solids
            let onModel: (String, String) -> Bool = { a, b in
                a == "reticle-ring" && b.hasPrefix("glyph:") && models.contains(String(b.dropFirst(6)))
            }
            for i in s.indices { for j in s.indices where j > i {
                if onModel(s[i].0, s[j].0) || onModel(s[j].0, s[i].0) { continue }
                if s[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(s[j].1.insetBy(dx: 0.5, dy: 0.5)) { out.append("\(s[i].0) × \(s[j].0)") }
            } }
            for (k, a) in arrows { for (l, r) in labels where a.intersects(r) && l != k { out.append("arrow:\(k) × label:\(l)") } }
            return out
        }
    }

    /// The text sizes the plan needs (the renderer measures; tests estimate).
    struct Measure {
        var tag: (String) -> CGSize        // world tags (13 pt semibold) incl. padding
        var pinTag: (String) -> CGSize     // the small sequence capsule
        var reticle: (String) -> CGSize    // the reticle readout capsule

        /// SF 13 pt semibold, about 7.3 pt a character.
        static let estimate = Measure(tag: { CGSize(width: CGFloat($0.count) * 7.3 + 18, height: 24) },
                                      pinTag: { CGSize(width: CGFloat($0.count) * 7.3 + 10, height: 17) },
                                      reticle: { CGSize(width: CGFloat($0.count) * 7.3 + 24, height: 30) })
    }

    // MARK: The plan

    static func plan(_ marks: [OverlayMark], projector proj: Projector, reticleLabel: String?, measure: Measure) -> Plan {
        let vp = CGSize(width: proj.viewport.x, height: proj.viewport.y)
        func cg(_ s: ScreenVec) -> CGPoint { CGPoint(x: s.x, y: s.y) }
        var plan = Plan()
        var obstacles: [CGRect] = []
        let centre = CGPoint(x: vp.width / 2, y: vp.height / 2)
        plan.reticle = CGRect(x: centre.x - 18, y: centre.y - 18, width: 36, height: 36)
        obstacles.append(plan.reticle)
        // The torch and 0.5x at the right edge, mid-height: labels keep clear of them.
        obstacles.append(edgeControls(vp))

        // 1. Glyphs and equipment boxes (fixed to their point), arrows' bounds.
        for m in marks {
            switch m.style {
            case .photo:
                if let p = m.points.first, let s = proj.project(p) { plan.glyphs[m.id] = CGRect(x: s.x - 11, y: s.y - 11, width: 22, height: 22) }
            case .source:
                if let p = m.points.first, let s = proj.project(p) { plan.glyphs[m.id] = CGRect(x: s.x - 13, y: s.y - 13, width: 26, height: 26) }
            case .equipment:
                guard let p = m.points.first else { continue }
                if let d = m.airflow {
                    let poly = arrow(from: p, dir: d)
                    let sp = proj.projectPolygon(poly)
                    if sp.count >= 3 { plan.arrows[m.id] = bounds(sp.map(cg)) }
                }
                if let h = m.modelHeight {
                    // The model's screen footprint: its box (0.6 m wide) from floor to top.
                    let toUnit = WorldVec(p.x - proj.cameraPosition.x, 0, p.z - proj.cameraPosition.z)
                    let side = simd_length(toUnit) > 1e-6 ? simd_normalize(WorldVec(-toUnit.z, 0, toUnit.x)) * 0.3 : WorldVec(0.3, 0, 0)
                    let corners = [p - side, p + side, p - side + WorldVec(0, h, 0), p + side + WorldVec(0, h, 0)]
                    let sp = corners.compactMap { proj.project($0) }
                    if sp.count == 4 { plan.glyphs[m.id] = bounds(sp.map(cg)).insetBy(dx: 4, dy: 4) }
                } else if m.id != "draft-airflow", let s = proj.project(p + WorldVec(0, 0.17, 0)) {
                    plan.glyphs[m.id] = CGRect(x: s.x - 17, y: s.y - 17, width: 34, height: 34)
                }
            default: break
            }
        }
        // Glyphs that land on each other (or on the reticle) step sideways (3D models stay put).
        let models = Set(marks.filter { $0.modelHeight != nil }.map(\.id))
        plan.models = models
        for id in plan.glyphs.keys.sorted() where !models.contains(id) {
            guard var r = plan.glyphs[id] else { continue }
            if r.intersects(plan.reticle) { r.origin.x = r.midX < plan.reticle.midX ? plan.reticle.minX - r.width - 6 : plan.reticle.maxX + 6 }
            for _ in 0..<4 {
                guard let hit = plan.glyphs.first(where: { $0.key != id && $0.key < id && $0.value.intersects(r) }) else { break }
                r.origin.x = hit.value.maxX + 6
            }
            plan.glyphs[id] = r
        }
        obstacles += plan.glyphs.values

        // 2. Pins: lifted above their point; coincident pins step apart; the tag at the lower right
        //    (lower left when that is clear and the right is not).
        var pinIds: [(String, CGPoint, String?)] = []
        for m in marks {
            switch m.style {
            case .reading, .readingDraft:
                if let p = m.points.first, let s = proj.project(p) { pinIds.append((m.id, cg(s), displayTag(m))) }
            default: break
            }
        }
        for (id, s, tagText) in pinIds {
            var c = CGPoint(x: s.x, y: s.y - pinLift)
            let ts = tagText.map(measure.pinTag)
            func pinAt(_ c: CGPoint, left: Bool) -> Pin {
                let tr = ts.map { t in CGRect(x: left ? c.x - 9 - t.width : c.x + 9, y: c.y + 5, width: t.width, height: t.height) }
                return Pin(anchor: s, centre: c, tag: tr)
            }
            var pin = pinAt(c, left: false)
            for k in 0..<8 {
                let blocked: (Pin) -> Bool = { p in obstacles.contains { $0.intersects(p.bounds) } }
                if !blocked(pin) { break }
                let left = pinAt(c, left: true)
                if !blocked(left) { pin = left; break }
                // Step sideways, alternating, further each time.
                let step = CGFloat(k / 2 + 1) * 40 * (k % 2 == 0 ? 1 : -1)
                c = CGPoint(x: s.x + step, y: s.y - pinLift)
                pin = pinAt(c, left: false)
            }
            plan.pins[id] = pin
            obstacles.append(pin.bounds)
        }

        // 3. The reticle's label: above it, else below, else beside.
        if let text = reticleLabel {
            let sz = measure.reticle(text)
            let cands = [CGPoint(x: centre.x - sz.width / 2, y: centre.y - 22 - sz.height),
                         CGPoint(x: centre.x - sz.width / 2, y: centre.y + 22),
                         CGPoint(x: centre.x + 22, y: centre.y - sz.height / 2),
                         CGPoint(x: centre.x - 22 - sz.width, y: centre.y - sz.height / 2)]
            let rects = cands.map { CGRect(origin: $0, size: sz) }
            let r = rects.first { r in !obstacles.contains { $0.intersects(r) } } ?? rects[0]
            plan.labels["reticle"] = r
            obstacles.append(r)
        }

        // 4. Tags of lines, areas, glyphs and equipment.
        obstacles += plan.arrows.values
        for m in marks {
            guard let text = displayTag(m) else { continue }
            var anchor: CGPoint? = nil
            var below = false
            var leading = false
            switch m.style {
            case .reading, .readingDraft: continue
            case .photo: if m.selected, let g = plan.glyphs[m.id] { anchor = CGPoint(x: g.midX, y: g.minY - 2) }
            case .source: if let g = plan.glyphs[m.id] { anchor = CGPoint(x: g.midX, y: g.minY - 3) }
            case .equipment:
                if let g = plan.glyphs[m.id] {
                    if m.modelHeight != nil { anchor = CGPoint(x: g.midX, y: g.minY - 6) }
                    else { anchor = CGPoint(x: g.midX, y: g.maxY + 3); below = true }
                }
            case .skirting, .lineDraft:
                guard m.points.count >= 2, let seg = proj.projectSegment(m.points[0], m.points[1]) else { continue }
                let (a, b) = clipToScreen(cg(seg.0), cg(seg.1), vp)
                anchor = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 6)
            case .lining:
                guard m.points.count >= 2 else { continue }
                let top = m.top ?? 0.6
                let quad = [m.points[0], m.points[1], m.points[1] + WorldVec(0, top, 0), m.points[0] + WorldVec(0, top, 0)]
                let sp = proj.projectPolygon(quad).map(cg)
                guard sp.count >= 3 else { continue }
                let bb = bounds(sp).intersection(CGRect(origin: .zero, size: vp))
                guard !bb.isNull, bb.width > 4 else { continue }
                anchor = CGPoint(x: bb.minX + 8, y: bb.minY + 8)
                leading = true
                below = true
            case .moisture:
                if let last = m.points.last, let s = proj.project(last) { anchor = CGPoint(x: s.x, y: s.y - 8) }
            case .wetFloor, .liftFlooring, .areaDraft:
                guard !m.points.isEmpty else { continue }
                let c = m.points.reduce(WorldVec(0, 0, 0), +) / Double(m.points.count)
                if let s = proj.project(c) { anchor = CGPoint(x: s.x, y: s.y + 12); below = true }
            }
            guard let a = anchor, a.x >= 0, a.x <= vp.width, a.y >= 0, a.y <= vp.height else { continue }
            let sz = measure.tag(text)
            let r0 = CGRect(x: leading ? a.x : a.x - sz.width / 2, y: below ? a.y : a.y - sz.height, width: sz.width, height: sz.height)
            let r = free(r0, obstacles: obstacles, viewport: vp)
            plan.labels[m.id] = r
            obstacles.append(r)
        }
        return plan
    }

    /// Where the viewport's edge controls (torch, 0.5x) sit.
    static func edgeControls(_ vp: CGSize) -> CGRect {
        CGRect(x: vp.width - 66, y: vp.height / 2 - 84, width: 66, height: 168)
    }

    /// The nearest free spot for a label: as asked, then stepping up / down, then sideways; inside the screen.
    static func free(_ r0: CGRect, obstacles: [CGRect], viewport vp: CGSize) -> CGRect {
        func clamp(_ r: CGRect) -> CGRect {
            var r = r
            r.origin.x = min(max(r.minX, margin), vp.width - r.width - margin)
            r.origin.y = min(max(r.minY, topLimit), vp.height - r.height - bottomLimit)
            return r
        }
        let base = clamp(r0)
        let h = base.height + 4
        var cands = [base]
        for k in 1...6 {
            cands.append(clamp(base.offsetBy(dx: 0, dy: -CGFloat(k) * h)))
            cands.append(clamp(base.offsetBy(dx: 0, dy: CGFloat(k) * h)))
        }
        for k in 1...3 {
            cands.append(clamp(base.offsetBy(dx: CGFloat(k) * 60, dy: 0)))
            cands.append(clamp(base.offsetBy(dx: -CGFloat(k) * 60, dy: 0)))
        }
        return cands.first { c in !obstacles.contains { $0.insetBy(dx: -2, dy: -2).intersects(c) } } ?? base
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// The part of a screen segment inside the viewport (for anchoring a label on what is visible).
    static func clipToScreen(_ a: CGPoint, _ b: CGPoint, _ vp: CGSize) -> (CGPoint, CGPoint) {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        for (p, q) in [(-d.x, a.x), (d.x, vp.width - a.x), (-d.y, a.y), (d.y, vp.height - a.y)] {
            if p == 0 { if q < 0 { return (a, b) }; continue }
            let t = q / p
            if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
        }
        guard t0 <= t1 else { return (a, b) }
        return (CGPoint(x: a.x + d.x * t0, y: a.y + d.y * t0), CGPoint(x: a.x + d.x * t1, y: a.y + d.y * t1))
    }

    /// The airflow arrow on the floor: from the unit, 1.0 m, shaft 0.18 m, head 0.40 m wide.
    static func arrow(from p: WorldVec, dir: WorldVec) -> [WorldVec] {
        let d = simd_length(WorldVec(dir.x, 0, dir.z)) > 1e-9 ? simd_normalize(WorldVec(dir.x, 0, dir.z)) : WorldVec(1, 0, 0)
        let side = WorldVec(-d.z, 0, d.x)
        let base = p + WorldVec(0, 0.01, 0)
        let s0 = 0.2, s1 = 0.72, tip = 1.0
        return [base + d * s0 + side * 0.09, base + d * s1 + side * 0.09, base + d * s1 + side * 0.2, base + d * tip,
                base + d * s1 - side * 0.2, base + d * s1 - side * 0.09, base + d * s0 - side * 0.09]
    }
}
