//
//  MoistureHUD.swift
//  SecureScan
//
//  The moisture model on the capture screen (docs/MOISTURE.md, docs/MARKING.md I):
//  re-solved off the main thread whenever a reading, source, tide line or the
//  scoper's correction changes (debounced, cached by the inputs' hash), drawn in
//  the blue wash in Moisture mode (measured solid, estimated lighter with a fine
//  dashed edge, the scoper's own corrections solid with a pencil), a glass chip
//  with the model's state, and Moisture > Adjust: a Wet / Dry brush, the tide line
//  and "No spread past here", each re-fitting the model. The model's strip-out
//  suggestions feed the one suggestion chip.
//

import SwiftUI
import simd

extension CaptureHUDModel {

    // MARK: Solving

    /// The model's input in this session's world: the marks plus the scoper's corrections.
    func modelPlan() -> [String: Any] {
        let w = engine.world
        let tweaks = engine.savedModelTweaks() + modelTweaks.compactMap { $0.tweak(walls: w.walls) }
        return MoistureLive.plan(world: w, marks: engine.overlayMarks(), tweaks: tweaks)
    }

    /// Called on every tick: re-solve when something the model reads has changed.
    func updateModel() {
        let w = engine.world
        guard !w.walls.isEmpty else { return }
        let sig = MoistureLive.signature(world: w, marks: engine.overlayMarks(), tweaks: modelTweaks.count &* 31 &+ (modelTweaks.last?.points.count ?? 0))
        guard sig != modelSignature else { return }
        modelSignature = sig
        let plan = modelPlan()
        modelRunner.schedule(plan: plan, options: MoistureLive.options(live: true)) { [weak self] s in self?.apply(s) }
    }

    /// Solve now, on this thread (the Studio's scripted scenes).
    func solveModelNow() {
        modelSignature = MoistureLive.signature(world: engine.world, marks: engine.overlayMarks(), tweaks: modelTweaks.count &* 31 &+ (modelTweaks.last?.points.count ?? 0))
        apply(modelRunner.solveNow(plan: modelPlan(), options: MoistureLive.options(live: true)))
    }

    func apply(_ s: MoistureSolve) {
        model = s
        modelMarks = MoistureMarks.marks(s.draw, world: engine.world)
        offerModelSuggestion()
    }

    /// The model is drawn in Moisture mode (and while adjusting it).
    var showsModel: Bool { tool == .moisture && model != nil && tray == nil }

    /// The glass chip's words, nil when there's nothing to say yet.
    var modelChip: MoistureWords.State? {
        guard showsModel, let m = model, display.showsTools, suggestion == nil else { return nil }
        if m.readingCount == 0 && m.result.sources.isEmpty { return nil }
        return m.words
    }

    /// The second source's spot, for the chip's arrow.
    var modelHintPoint: WorldVec? { modelMarks.first { $0.style == .modelHint }?.points.first }

    // MARK: Suggestions

    /// The model's strip-out suggestions, most certain first, as the one suggestion chip.
    func offerModelSuggestion() {
        guard offersModelSuggestions, suggestion == nil, !adjusting, tray == nil, let m = model else { return }
        let w = engine.world
        let ranked = m.report.suggestions.enumerated().sorted { a, b in
            (a.element.confidence?.score ?? 0, -a.offset) > (b.element.confidence?.score ?? 0, -b.offset)
        }
        for (_, s) in ranked {
            guard let text = MoistureWords.suggestion(s) else { continue }
            let kind: Suggestion.Kind
            switch s.kind {
            case .stripLining, .removeSkirting:
                guard let id = s.wallId, let wall = w.wall(id), wall.length > 0, let f = s.from, let t = s.to else { continue }
                let t0 = max(0, min(1, f / wall.length)), t1 = max(0, min(1, t / wall.length))
                // Already marked there: nothing to suggest.
                if s.kind == .removeSkirting ? hasRemoval(.skirting, wall: wall) : hasRemoval(.lining, wall: wall) { continue }
                kind = s.kind == .removeSkirting ? .modelSkirting(wallId: id, t0: t0, t1: t1)
                                                 : .modelStrip(wallId: id, t0: t0, t1: t1, mm: s.cutHeightMm ?? 600)
            case .liftFlooring:
                guard let poly = s.polygons.max(by: { MoistGeom.area($0) < MoistGeom.area($1) }), poly.count >= 3 else { continue }
                if engine.overlayMarks().contains(where: { $0.style == .liftFlooring }) { continue }
                kind = .modelFloor(polygon: poly.map { PlanVec($0.x, $0.y) }, covering: s.covering?.rawValue ?? "carpet",
                                   key: s.roomId ?? "floor")
            case .inspectCavity:
                continue
            }
            let sg = Suggestion(kind: kind, text: text, action: "Mark")
            guard !modelOffered.contains(sg.key), !dismissedSuggestions.contains(sg.key) else { continue }
            modelOffered.insert(sg.key)
            offer(sg)
            return
        }
    }

    private func hasRemoval(_ style: OverlayMark.Style, wall: WorldWall) -> Bool {
        engine.overlayMarks().contains { m in
            guard m.style == style, m.points.count >= 2 else { return false }
            let mid = (m.points[0] + m.points[1]) / 2
            return PlanBuilder.distanceToSegment(PlanVec(mid.x, mid.z), wall.a, wall.b) < 0.3
        }
    }

    // MARK: Adjust

    static let adjustTools: [(key: String, title: String)] = [("wet", "Wet"), ("dry", "Dry"), ("tide", "Tide line"), ("barrier", "No spread")]

    func beginAdjust() {
        cancelMark()
        clearMarkingDrafts()
        drawArmed = nil
        hover = nil
        adjusting = true
        withAnimation(.easeInOut(duration: 0.2)) { suggestion = nil }
    }

    func endAdjust() {
        adjusting = false
        adjustStroke = nil
    }

    var adjustCard: String {
        switch adjustTool {
        case .wet: return "Paint where it is wet. The model re-fits."
        case .dry: return "Paint where it is dry. The model re-fits."
        case .tide: return "Drag along the wall at the tide line."
        case .barrier: return "Draw on the floor where water stops."
        }
    }

    var adjustCaption: String {
        let n = modelTweaks.count
        return n == 0 ? "Model · adjust" : (n == 1 ? "1 correction" : "\(n) corrections")
    }

    /// A finger came down in Adjust: start a stroke on the surface under it.
    func adjustBegan(at p: CGPoint, size: CGSize) -> Bool {
        guard let r = ray(at: p, size: size), let hit = engine.world.raycast(origin: r.0, dir: r.1, objects: false) else { return false }
        let onWall = hit.1.y < 0.7
        if adjustTool == .tide && !onWall { return false }
        if adjustTool == .barrier && onWall { return false }
        let wall = onWall ? WallSide.wall(at: hit.0, world: engine.world, within: 0.12) : nil
        if onWall && wall == nil { return false }
        adjustStroke = LiveTweak(id: "adj-" + UUID().uuidString.prefix(6).lowercased(), kind: adjustTool, onWall: onWall, points: [hit.0],
                                 floorY: floorY, from: PlanVec(r.0.x, r.0.z), wallId: wall?.id)
        DS.Haptic.selection()
        return true
    }

    func adjustMoved(to p: CGPoint, size: CGSize) {
        guard var s = adjustStroke, let r = ray(at: p, size: size), let hit = engine.world.raycast(origin: r.0, dir: r.1, objects: false) else { return }
        let onWall = hit.1.y < 0.7
        guard onWall == s.onWall else { return }
        if s.onWall, let id = s.wallId, WallSide.wall(at: hit.0, world: engine.world, within: 0.12)?.id != id { return }
        if s.kind == .barrier {
            s.points = [s.points[0], hit.0]
        } else if let last = s.points.last, simd_distance(last, hit.0) >= 0.08 {
            s.points.append(hit.0)
        }
        adjustStroke = s
    }

    func adjustEnded() {
        guard let s = adjustStroke else { return }
        adjustStroke = nil
        guard s.tweak(walls: engine.world.walls) != nil else { DS.Haptic.warning(); return }
        modelTweaks.append(s)
        engine.modelTweaksChanged(modelTweaks)
        DS.Haptic.save()
        updateModel()
    }

    /// A tap in Adjust: one dab of the brush (or a short tide line).
    func adjustTap(at p: CGPoint, size: CGSize) {
        guard adjustTool != .barrier, adjustBegan(at: p, size: size) else { return }
        adjustEnded()
    }

    func undoTweak() {
        guard !modelTweaks.isEmpty else { return }
        modelTweaks.removeLast()
        engine.modelTweaksChanged(modelTweaks)
        DS.Haptic.selection()
        updateModel()
    }

    /// The scoper's "No spread past here" lines (they stay drawn: the model can't show them).
    func barrierMarks() -> [OverlayMark] {
        modelTweaks.filter { $0.kind == .barrier && $0.points.count >= 2 }.map { t in
            OverlayMark(id: "model-barrier-\(t.id)", style: .modelEdge("barrier"),
                        points: [t.points[0], t.points[t.points.count - 1]].map { WorldVec($0.x, floorY + 0.01, $0.z) })
        }
    }

    /// The stroke being drawn, as a mark.
    func adjustMarks() -> [OverlayMark] {
        guard let s = adjustStroke else { return [] }
        switch s.kind {
        case .wet, .dry:
            var m = OverlayMark(id: "draft-brush", style: .modelEdge(s.kind == .wet ? "brushWet" : "brushDry"), points: s.points)
            m.wallId = s.wallId
            return [m]
        case .tide:
            var m = OverlayMark(id: "draft-tide", style: .moistureWash, points: s.points.sorted { a, b in
                guard let w = engine.world.wall(s.wallId) else { return a.x < b.x }
                return PlanBuilder.projectParam(PlanVec(a.x, a.z), w.a, w.b) < PlanBuilder.projectParam(PlanVec(b.x, b.z), w.a, w.b)
            }, tag: s.points.last.map { "Tide · \(Int(((($0.y - floorY) * 1000) / 10).rounded() * 10)) mm" })
            m.floorLevel = floorY
            return s.points.count >= 2 ? [m] : []
        case .barrier:
            guard s.points.count >= 2 else { return [] }
            return [OverlayMark(id: "draft-barrier", style: .lineDraft, points: [s.points[0], s.points[s.points.count - 1]], tag: "No spread past here")]
        }
    }
}
