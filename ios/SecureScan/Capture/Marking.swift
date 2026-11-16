//
//  Marking.swift
//  SecureScan
//
//  Marking by component (docs/MARKING.md), on the one HUD model:
//    * the hovered component (reticle), highlighted before any tap;
//    * tap = the whole component; a finger scrub paints part of it (constrained:
//      skirting along the wall base and round corners, strip-back over the wall face,
//      floor painting inside the room, the moisture tide line along a wall);
//    * dragging the strip-back cut line, dragging an air mover's airflow;
//    * Done = the drafts saved as the usual marks (removals, affected areas,
//      moisture lines - the data contracts don't change);
//    * the one suggestion chip after a capture.
//  The rules themselves are in Core/Components.swift (unit tested).
//

import SwiftUI
import simd

/// What two-finger tap / Undo restores.
struct MarkSnapshot {
    var run: WallRun?
    var strip: StripBack?
    var floorPaint: FloorPaint?
    var tide: TideLine?
}

/// What a finger drag on the viewport is doing.
enum DragMode: Equatable {
    case skirting, strip, floor, tide, cut
    case airflow(String)
}

extension CaptureHUDModel {

    // MARK: State

    /// Which component the current mode marks (nil = the reading / equipment flows).
    var hoverKind: Component.Kind? {
        guard tray == nil, retakeFor == nil, airflowFor == nil, markPoints.isEmpty, display.showsTools else { return nil }
        switch tool {
        case .stripOut:
            switch stripKind {
            case .skirting: return .skirting
            case .wallLining: return .wallFace
            case .cabinetry: return .cabinet
            case .liftFlooring: return .floor
            default: return nil
            }
        case .moisture:
            switch drawArmed {
            case .line?: return .wallFace
            case .area?: return .floor
            default: return nil
            }
        case .source: return .waterCandidate
        default: return nil
        }
    }

    var drafting: Bool { run != nil || strip != nil || cabinetPick != nil || floorPaint != nil || floorWhole != nil || tide != nil }

    var floorY: Double { engine.world.floorY ?? 0 }

    func clearMarkingDrafts() {
        run = nil; strip = nil; cabinetPick = nil; kickOnly = false
        floorPaint = nil; floorWhole = nil; tide = nil
        readout = nil; markUndo = []; dragMode = nil
    }

    /// Called every tick after the aim: the component under the reticle (a light tick when it changes).
    func updateHover() {
        guard let k = hoverKind, !drafting || k == .waterCandidate else {
            if hover != nil { hover = nil }
            return
        }
        let s = engine.aimSample()
        let h = ComponentIndex.hover(k, aim: aim, origin: s?.camera, dir: s?.forward, world: engine.world)
        if h != hover {
            if h != nil && h?.id != hover?.id { DS.Haptic.lock() }
            hover = h
        }
    }

    // MARK: Words

    func componentTitle(_ c: Component) -> String {
        let w = engine.world
        switch c.kind {
        case .skirting:
            let len = (c.t1 - c.t0) * (w.wall(c.wallId)?.length ?? 0)
            return "Skirting · \(CaptureCopy.length(len))"
        case .wallFace:
            let len = (c.t1 - c.t0) * (w.wall(c.wallId)?.length ?? 0)
            return "Wall · \(CaptureCopy.length(len))"
        case .cabinet:
            guard let ob = w.object(c.objectId) else { return "Cabinet" }
            return "\(ob.name.prefix(1).uppercased() + ob.name.dropFirst()) · \(CaptureCopy.length(ob.size.x))"
        case .floor:
            let poly = w.rooms.first { $0.name == c.roomName }?.polygon ?? []
            return "Floor · \(CaptureCopy.area(FloorArea.area(poly)))"
        case .waterCandidate:
            return w.object(c.objectId).map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() } ?? "Window sill"
        case .ceiling: return "Ceiling"
        }
    }

    var floorDraftPolygon: [PlanVec] { floorWhole ?? floorPaint?.outline ?? [] }
    var floorDraftArea: Double {
        if let w = floorWhole { return FloorArea.area(w) }
        return floorPaint?.area ?? 0
    }

    var stripFullMm: Int {
        let id = strip?.wallId ?? tide?.wallId
        return Int(((engine.world.wall(id)?.height ?? 2.4) * 1000).rounded())
    }

    /// The round button while marking by component (nil = the usual primary).
    var markingPrimary: Primary? {
        let w = engine.world
        if let r = run { return Primary(title: "Done · \(CaptureCopy.length(r.length(w)))", enabled: r.length(w) > 0.05) }
        if let s = strip { return Primary(title: "Done · \(CaptureCopy.area(s.area(w)))", enabled: abs(s.t1 - s.t0) > 0) }
        if let id = cabinetPick, let ob = w.object(id) {
            return Primary(title: "Done · \(CaptureCopy.length(ob.size.x))", enabled: true)
        }
        if floorPaint != nil || floorWhole != nil { return Primary(title: "Done · \(CaptureCopy.area(floorDraftArea))", enabled: floorDraftArea > 0.01) }
        if let t = tide { return Primary(title: "Done · \(t.maxMm) mm", enabled: t.points(w).count >= 2) }
        guard let h = hover else { return nil }
        switch h.kind {
        case .waterCandidate, .ceiling: return nil
        case .floor: return Primary(title: "Select floor · \(componentTitle(h).components(separatedBy: " · ").last ?? "")", enabled: true)
        default: return Primary(title: "Select \(componentTitle(h).lowercased().components(separatedBy: " · ").first ?? "")", enabled: true)
        }
    }

    var markingCard: String? {
        guard let k = hoverKind ?? (drafting ? (strip != nil ? .wallFace : run != nil ? .skirting : cabinetPick != nil ? .cabinet : tide != nil ? .wallFace : .floor) : nil) else { return nil }
        if k == .waterCandidate { return nil }
        return CaptureCopy.markingCard(kind: k, drafting: drafting, floorType: tool == .stripOut ? stripFloorType : nil, moisture: tool == .moisture)
    }

    // MARK: Tap = the whole component

    func selectWhole(_ c: Component) {
        let w = engine.world
        markUndo = []
        switch c.kind {
        case .skirting:
            run = WallRun(pieces: [WallPiece(wallId: c.wallId ?? "", tA: c.t0, tB: c.t1)])
        case .wallFace:
            if tool == .moisture {
                guard let wall = w.wall(c.wallId) else { return }
                var t = TideLine(wallId: wall.id)
                let h = max(aim.height ?? 0.3, 0.1)
                var u = c.t0
                while u <= c.t1 { t.add(t: u, height: h, wallLength: wall.length); u += TideLine.bucket / max(wall.length, 1e-9) }
                tide = t
            } else {
                strip = StripBack(wallId: c.wallId ?? "", t0: c.t0, t1: c.t1, heightMm: 600)
            }
        case .cabinet:
            cabinetPick = c.objectId
        case .floor:
            floorWhole = w.rooms.first { $0.name == c.roomName }?.polygon
        case .waterCandidate, .ceiling:
            beginSource(at: c.point)
            return
        }
        hover = nil
        DS.Haptic.selection()
    }

    // MARK: Fingers on the viewport

    func ray(at p: CGPoint, size: CGSize) -> (WorldVec, WorldVec)? {
        guard let proj = engine.projector(viewport: size), let d = proj.worldRay(ScreenVec(Double(p.x), Double(p.y))) else { return nil }
        return (proj.cameraPosition, d)
    }

    /// The component under a finger (for taps and the start of a scrub).
    func component(at p: CGPoint, size: CGSize) -> Component? {
        guard let k = hoverKind, let r = ray(at: p, size: size) else { return nil }
        let o = r.0, d = r.1
        let hit = engine.world.raycast(origin: o, dir: d)
        let a = AimInterpreter.interpret(AimSample(camera: o, forward: d, hit: hit?.0, normal: hit?.1), world: engine.world, snapEnds: false)
        return ComponentIndex.hover(k, aim: a, origin: o, dir: d, world: engine.world)
    }

    func tapAt(_ p: CGPoint, size: CGSize) {
        guard !drafting || hoverKind == .waterCandidate, let c = component(at: p, size: size) else { return }
        selectWhole(c)
    }

    /// A finger came down: is it the cut line, an airflow tip, or a scrub? (false = not ours)
    func dragBegan(at p: CGPoint, size: CGSize) -> Bool {
        guard tray == nil, let proj = engine.projector(viewport: size), let fr = ray(at: p, size: size) else { return false }
        let o = fr.0, d = fr.1
        let w = engine.world
        let fp = ScreenVec(Double(p.x), Double(p.y))
        // The strip-back cut line.
        if let s = strip, let wall = w.wall(s.wallId) {
            let a2 = wall.a + (wall.b - wall.a) * s.t0, b2 = wall.a + (wall.b - wall.a) * s.t1
            let y = floorY + Double(s.heightMm) / 1000
            if let seg = proj.projectSegment(WorldVec(a2.x, y, a2.y), WorldVec(b2.x, y, b2.y)),
               Self.distance(fp, seg.0, seg.1) <= 30 {
                markUndo.append(snapshot)
                dragMode = .cut
                return true
            }
        }
        // An air mover's airflow tip (or the unit).
        if tool == .equipment {
            for m in engine.overlayMarks() {
                guard case .equipment(let type, _) = m.style, type == "airMover", let u = m.points.first else { continue }
                let tip = u + (m.airflow ?? WorldVec(0, 0, 0)) * 1.0
                for q in [tip, u] {
                    if let s = proj.project(q), simd_distance(s, fp) <= 44 {
                        dragMode = .airflow(m.id)
                        return true
                    }
                }
            }
        }
        // A scrub on the component under the finger.
        guard let k = hoverKind, k != .cabinet, k != .waterCandidate else { return false }
        let c = component(at: p, size: size)
        markUndo.append(snapshot)
        switch k {
        case .skirting:
            if let r = run, let last = r.pieces.last, let c, c.wallId == last.wallId || r.pieces.contains(where: { $0.wallId == c.wallId }) {
                run = Scrub.extend(r, origin: o, dir: d, world: w)
            } else if let c {
                run = Scrub.start(c, origin: o, dir: d, world: w)
            } else { markUndo.removeLast(); return false }
            dragMode = .skirting
        case .wallFace:
            guard let c = c ?? (strip.map { Component(id: "", kind: .wallFace, wallId: $0.wallId) }), let wall = w.wall(c.wallId),
                  let h = Scrub.wallHit(origin: o, dir: d, wall: wall, floorY: floorY) else { markUndo.removeLast(); return false }
            let t = min(max(h.t, c.t0), c.t1)
            if tool == .moisture {
                if tide?.wallId != wall.id { tide = TideLine(wallId: wall.id) }
                tide?.add(t: t, height: h.h, wallLength: wall.length)
                dragMode = .tide
            } else {
                let mm = StripBack.snap(h.h * 1000, fullMm: Int(wall.height * 1000))
                strip = StripBack(wallId: wall.id, t0: t, t1: t, heightMm: max(mm, 300))
                dragMode = .strip
            }
        case .floor:
            guard let room = c.flatMap({ comp in w.rooms.first { $0.name == comp.roomName } }) ?? w.rooms.first,
                  abs(d.y) > 1e-6 else { markUndo.removeLast(); return false }
            let t = (floorY - o.y) / d.y
            guard t > 0 else { markUndo.removeLast(); return false }
            let fpw = o + d * t
            if floorPaint == nil || floorWhole != nil { floorWhole = nil; floorPaint = FloorPaint(room: room.polygon) }
            floorPaint?.paint(PlanVec(fpw.x, fpw.z))
            dragMode = .floor
        default:
            markUndo.removeLast()
            return false
        }
        hover = nil
        updateScrubReadout()
        return true
    }

    func dragMoved(to p: CGPoint, size: CGSize) {
        guard let mode = dragMode, let fr = ray(at: p, size: size) else { return }
        let o = fr.0, d = fr.1
        let w = engine.world
        switch mode {
        case .skirting:
            if let r = run { run = Scrub.extend(r, origin: o, dir: d, world: w) }
        case .strip:
            guard var s = strip, let wall = w.wall(s.wallId), let h = Scrub.wallHit(origin: o, dir: d, wall: wall, floorY: floorY) else { return }
            let segs = ComponentIndex.segments(wall, openings: w.openings)
            let seg = ComponentIndex.segment(containing: s.t0, segs)?.1 ?? (0, 1)
            let t = min(max(h.t, seg.0), seg.1)
            s.t0 = min(s.t0, t)
            s.t1 = max(s.t1, t)
            s.heightMm = max(s.heightMm, StripBack.snap(h.h * 1000, fullMm: Int(wall.height * 1000)))
            strip = s
        case .cut:
            guard var s = strip, let wall = w.wall(s.wallId), let h = Scrub.wallHit(origin: o, dir: d, wall: wall, floorY: floorY) else { return }
            let mm = StripBack.snap(h.h * 1000, fullMm: Int(wall.height * 1000))
            if mm != s.heightMm { DS.Haptic.selection() }
            s.heightMm = mm
            strip = s
        case .floor:
            guard abs(d.y) > 1e-6 else { return }
            let t = (floorY - o.y) / d.y
            guard t > 0 else { return }
            let q = o + d * t
            floorPaint?.paint(PlanVec(q.x, q.z))
        case .tide:
            guard var tl = tide, let wall = w.wall(tl.wallId), let h = Scrub.wallHit(origin: o, dir: d, wall: wall, floorY: floorY) else { return }
            let segs = ComponentIndex.segments(wall, openings: w.openings)
            guard ComponentIndex.segment(containing: min(max(h.t, 0), 1), segs) != nil else { return }
            tl.add(t: h.t, height: h.h, wallLength: wall.length)
            tide = tl
        case .airflow(let id):
            guard let m = engine.overlayMarks().first(where: { $0.id == id }), let u = m.points.first, abs(d.y) > 1e-6 else { return }
            let t = ((m.points.first?.y ?? floorY) - o.y) / d.y
            guard t > 0 else { return }
            let q = o + d * t
            let dir = WorldVec(q.x - u.x, 0, q.z - u.z)
            if simd_length(dir) > 0.2 { airflowDrag = (id, simd_normalize(dir)) }
        }
        updateScrubReadout()
    }

    func dragEnded() {
        if case .airflow(let id)? = dragMode, let a = airflowDrag, a.id == id {
            if engine.setAirflow(id: id, direction: a.dir) { DS.Haptic.save() }
            airflowDrag = nil
        }
        dragMode = nil
        updateScrubReadout()
    }

    /// Two-finger tap / the Undo pill: back one scrub step.
    func undoScrub() {
        if let s = markUndo.popLast() {
            run = s.run; strip = s.strip; floorPaint = s.floorPaint; tide = s.tide
            DS.Haptic.undo()
        } else if drafting {
            clearMarkingDrafts()
            DS.Haptic.undo()
        } else if !markPoints.isEmpty {
            undoMarkPoint()
        }
        updateScrubReadout()
    }

    var snapshot: MarkSnapshot { MarkSnapshot(run: run, strip: strip, floorPaint: floorPaint, tide: tide) }

    /// "0.6 m to wall end" at the run's head while scrubbing; "600 mm" by the cut line while dragging it.
    func updateScrubReadout() {
        let w = engine.world
        if dragMode == .skirting, let r = run, let last = r.pieces.last, let wall = w.wall(last.wallId), let left = Scrub.remaining(r, world: w) {
            let p = wall.a + (wall.b - wall.a) * last.tB
            readout = (WorldVec(p.x, floorY + 0.05, p.y), "\(CaptureCopy.length(left.metres)) to \(left.wallEnd ? "wall end" : "door")")
        } else if dragMode == .cut, let s = strip, let wall = w.wall(s.wallId) {
            let p = wall.a + (wall.b - wall.a) * max(s.t0, s.t1)
            readout = (WorldVec(p.x, floorY + Double(s.heightMm) / 1000, p.y), "\(s.heightMm) mm")
        } else if readout != nil {
            readout = nil
        }
    }

    static func distance(_ p: ScreenVec, _ a: ScreenVec, _ b: ScreenVec) -> Double {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
        return simd_distance(p, a + ab * t)
    }

    // MARK: Pills while drafting

    /// The bottom pills while a component draft is open (nil = the usual ones).
    var markingPills: (left: Pill?, caption: String?, right: Pill?)? {
        guard drafting else { return nil }
        let p = primary
        if cabinetPick != nil {
            return (Pill(id: "cancelDraft", title: "Cancel"), p.title, Pill(id: "kick", title: "Kick board", prominent: kickOnly))
        }
        if run != nil { return (Pill(id: "undoScrub", title: "Undo"), p.title, Pill(id: "wholeRun", title: "Whole run")) }
        if floorPaint != nil || floorWhole != nil { return (Pill(id: "undoScrub", title: "Undo"), p.title, Pill(id: "wholeRoom", title: "Whole room")) }
        if tide != nil { return (Pill(id: "undoScrub", title: "Undo"), p.title, Pill(id: "cancelDraft", title: "Cancel")) }
        return nil
    }

    /// The strip-back height row (replaces the pills): 300 / 600 / 900 / 1200 / Full.
    var heightChoices: [(mm: Int, title: String)] {
        StripBack.standards.map { (mm: $0, title: String($0)) } + [(mm: stripFullMm, title: "Full")]
    }

    func setStripHeight(_ mm: Int) {
        guard var s = strip else { return }
        markUndo.append(snapshot)
        s.heightMm = mm
        strip = s
        DS.Haptic.selection()
    }

    func tapMarkingPill(_ id: String) -> Bool {
        let w = engine.world
        switch id {
        case "undoScrub": undoScrub()
        case "cancelDraft": clearMarkingDrafts()
        case "kick": kickOnly.toggle(); DS.Haptic.selection()
        case "wholeRun":
            // Each wall in the run, its whole segment.
            guard let r = run else { return true }
            markUndo.append(snapshot)
            run = WallRun(pieces: r.pieces.compactMap { p in
                guard let wall = w.wall(p.wallId), let seg = ComponentIndex.segment(containing: p.tA, ComponentIndex.segments(wall, openings: w.openings))?.1 else { return nil }
                return WallPiece(wallId: p.wallId, tA: p.tB >= p.tA ? seg.0 : seg.1, tB: p.tB >= p.tA ? seg.1 : seg.0)
            })
        case "wholeRoom":
            markUndo.append(snapshot)
            let room = floorPaint.flatMap { fp in w.rooms.first { $0.polygon == fp.room } } ?? w.rooms.first
            floorPaint = nil
            floorWhole = room?.polygon
        default: return false
        }
        return true
    }

    // MARK: Done = saved as the usual marks

    func shotAt(_ p: WorldVec, from base: CaptureShot, first: Bool) -> CaptureShot {
        var s = base.aimed(at: p)
        if !first { s.id = CaptureIDs.new("ar-"); s.photo = nil }
        return s
    }

    func commitMarking() {
        let w = engine.world
        guard let base = takeShot(photo: true) else { return }
        let fy = floorY
        if let r = run {
            for (i, l) in r.lines(w).enumerated() {
                let a = WorldVec(l.0.x, fy + 0.05, l.0.z), b = WorldVec(l.1.x, fy + 0.05, l.1.z)
                let len = simd_distance(PlanVec(a.x, a.z), PlanVec(b.x, b.z))
                guard len > 0.05 else { continue }
                let shots = [shotAt(a, from: base, first: i == 0), shotAt(b, from: base, first: false)]
                persist(.mark(MarkDraft(meaning: .skirting, shots: shots, heightMm: MarkIntent.defaultHeightMm(.skirting), floorType: nil,
                                        underlay: false, wholeRoom: false, length: len, area: nil)))
            }
        } else if let s = strip, let wall = w.wall(s.wallId) {
            let a2 = wall.a + (wall.b - wall.a) * min(s.t0, s.t1), b2 = wall.a + (wall.b - wall.a) * max(s.t0, s.t1)
            let shots = [shotAt(WorldVec(a2.x, fy + 0.3, a2.y), from: base, first: true), shotAt(WorldVec(b2.x, fy + 0.3, b2.y), from: base, first: false)]
            persist(.mark(MarkDraft(meaning: .wallLining, shots: shots, heightMm: s.heightMm, floorType: nil, underlay: false, wholeRoom: false,
                                    length: simd_distance(a2, b2), area: s.area(w))))
        } else if let id = cabinetPick, let ob = w.object(id) {
            let ends: (WorldVec, WorldVec)
            if let st = ComponentIndex.wallStretch(ob, world: w) {
                let a2 = st.0.a + (st.0.b - st.0.a) * st.1, b2 = st.0.a + (st.0.b - st.0.a) * st.2
                ends = (WorldVec(a2.x, fy + 0.3, a2.y), WorldVec(b2.x, fy + 0.3, b2.y))
            } else {
                ends = (ob.corners[0], ob.corners[1])
            }
            var d = MarkDraft(meaning: .cabinetry, shots: [shotAt(ends.0, from: base, first: true), shotAt(ends.1, from: base, first: false)],
                              heightMm: kickOnly ? 150 : Int((ob.size.y * 1000).rounded()), floorType: nil, underlay: false, wholeRoom: false,
                              length: ob.size.x, area: nil)
            d.note = kickOnly ? MarkIntent.kickBoardNote : ""
            persist(.mark(d))
        } else if floorPaint != nil || floorWhole != nil {
            let poly = floorDraftPolygon
            guard poly.count >= 3 else { clearMarkingDrafts(); return }
            let shots = poly.enumerated().map { i, p in shotAt(WorldVec(p.x, fy, p.y), from: base, first: i == 0) }
            let moisture = tool == .moisture
            persist(.mark(MarkDraft(meaning: moisture ? .wetFloor : .liftFlooring, shots: shots, heightMm: 0,
                                    floorType: moisture ? nil : stripFloorType, underlay: !moisture && stripFloorType == "carpet" && underlayOn,
                                    wholeRoom: false, length: nil, area: FloorArea.area(poly))))
            if moisture {
                lastWetPolygon = poly
                offer(Suggest.afterWetFloor(floorType: stripFloorType, areaId: "wet-\(Int(FloorArea.area(poly) * 100))"))
            }
        } else if let t = tide {
            let pts = t.points(w)
            guard pts.count >= 2 else { clearMarkingDrafts(); return }
            let shots = pts.enumerated().map { i, p in shotAt(p, from: base, first: i == 0) }
            persist(.mark(MarkDraft(meaning: .moistureLine, shots: shots, heightMm: 0, floorType: nil, underlay: false, wholeRoom: false,
                                    length: nil, area: nil)))
            showToast("Moisture line set at \(t.maxMm) mm")
            offer(Suggest.afterTide(maxMm: t.maxMm, wallId: t.wallId))
        }
        clearMarkingDrafts()
    }

    // MARK: Suggestions

    func offer(_ s: Suggestion?) {
        guard let s, !dismissedSuggestions.contains(s.key) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { suggestion = s }
    }

    func dismissSuggestion() {
        if let s = suggestion { dismissedSuggestions.insert(s.key) }
        withAnimation(.easeInOut(duration: 0.2)) { suggestion = nil }
    }

    func acceptSuggestion() {
        guard let s = suggestion else { return }
        dismissedSuggestions.insert(s.key)
        suggestion = nil
        let w = engine.world
        select(.stripOut)
        floorTypesShown = false
        switch s.kind {
        case .skirtingWall(let id):
            stripPick = .skirting
            guard let wall = w.wall(id) else { return }
            run = WallRun(pieces: ComponentIndex.segments(wall, openings: w.openings).map { WallPiece(wallId: id, tA: $0.0, tB: $0.1) })
        case .stripWall(let id, let mm):
            stripPick = .wallLining
            guard let wall = w.wall(id) else { return }
            let segs = ComponentIndex.segments(wall, openings: w.openings)
            let seg = segs.max { ($0.1 - $0.0) < ($1.1 - $1.0) } ?? (0, 1)
            strip = StripBack(wallId: id, t0: seg.0, t1: seg.1, heightMm: mm ?? Int(wall.height * 1000))
        case .liftCarpet:
            stripPick = .liftFlooring
            floorTypesShown = true
            stripFloorType = "carpet"
            underlayOn = true
            floorWhole = lastWetPolygon
        case .removeCabinet(let id):
            stripPick = .cabinetry
            cabinetPick = id
        }
        DS.Haptic.selection()
    }

    /// After a reading or a source is saved: the obvious next mark, if any.
    func suggestAfter(_ d: CaptureDraft) {
        let w = engine.world
        switch d {
        case .reading(let s, let value, _, _):
            let a = s.aim
            let skirtingWalls = Set(engine.overlayMarks().compactMap { m -> String? in
                guard m.style == .skirting, m.points.count >= 2 else { return nil }
                let mid = (m.points[0] + m.points[1]) / 2
                return w.nearestWall(to: PlanVec(mid.x, mid.z), maxDistance: 0.4)?.wall.id
            })
            offer(Suggest.afterReading(value: value, height: a.height, wallId: a.wall?.id, wallsWithSkirting: skirtingWalls))
        case .source(let s, _, _, _, _):
            if let h = s.hit { offer(Suggest.afterSource(at: h, objects: w.objects)) }
        default:
            break
        }
    }

    // MARK: What the overlay draws for marking

    func markingMarks() -> [OverlayMark] {
        let w = engine.world
        let fy = floorY
        var out: [OverlayMark] = []
        func base(_ wall: WorldWall, _ t: Double, _ y: Double) -> WorldVec { let p = wall.a + (wall.b - wall.a) * t; return WorldVec(p.x, y, p.y) }
        // Water-entry rings in Source mode (the hovered one brighter).
        let cam = engine.aimSample()?.camera
        if tool == .source, tray == nil {
            for c in ComponentIndex.waterCandidates(w) {
                guard let p = c.point else { continue }
                if let cam, Visibility.occluded(p + simd_normalize(cam - p) * 0.05, camera: cam, world: w) { continue }
                var m = OverlayMark(id: "ring-\(c.id)", style: .hover(.ring), points: [p], tag: componentTitle(c))
                m.selected = c.id == hover?.id
                out.append(m)
            }
        }
        if let h = hover, !drafting {
            switch h.kind {
            case .skirting:
                if let wall = w.wall(h.wallId) {
                    out.append(OverlayMark(id: "hover", style: .hover(.skirting), points: [base(wall, h.t0, fy), base(wall, h.t1, fy)], tag: componentTitle(h)))
                }
            case .wallFace:
                if let wall = w.wall(h.wallId) {
                    let top = fy + wall.height
                    out.append(OverlayMark(id: "hover", style: .hover(tool == .moisture ? .faceBlue : .face),
                                           points: [base(wall, h.t0, fy), base(wall, h.t1, fy), base(wall, h.t1, top), base(wall, h.t0, top)],
                                           tag: componentTitle(h)))
                }
            case .cabinet:
                if let ob = w.object(h.objectId) { out.append(OverlayMark(id: "hover", style: .hover(.box), points: ob.corners, tag: componentTitle(h))) }
            case .floor:
                if let room = w.rooms.first(where: { $0.name == h.roomName }) {
                    out.append(OverlayMark(id: "hover", style: .hover(.floor), points: room.polygon.map { WorldVec($0.x, fy + 0.004, $0.y) }, tag: componentTitle(h)))
                }
            case .waterCandidate, .ceiling: break
            }
        }
        if let r = run {
            let total = CaptureCopy.length(r.length(w))
            for (i, l) in r.lines(w).enumerated() {
                out.append(OverlayMark(id: i == 0 ? "draft-run" : "draft-run-\(i)", style: .skirting, points: [l.0, l.1], tag: i == 0 ? "Skirting · \(total)" : nil))
            }
        }
        if let s = strip, let wall = w.wall(s.wallId) {
            var m = OverlayMark(id: "draft-strip", style: .lining, points: [base(wall, min(s.t0, s.t1), fy), base(wall, max(s.t0, s.t1), fy)],
                                top: Double(s.heightMm) / 1000,
                                tag: "Strip wall to \(s.heightMm >= stripFullMm ? "ceiling" : String(s.heightMm)) · \(CaptureCopy.area(s.area(w)))")
            m.handle = true
            out.append(m)
        }
        if let id = cabinetPick, let ob = w.object(id) {
            var corners = ob.corners
            if kickOnly { for i in 4..<8 { corners[i].y = corners[i - 4].y + 0.15 } }
            out.append(OverlayMark(id: "draft-cabinet", style: .cabinet, points: corners,
                                   tag: kickOnly ? "Kick board · \(CaptureCopy.length(ob.size.x))" : "Remove cabinetry · base \(CaptureCopy.length(ob.size.x))"))
        }
        if floorPaint != nil || floorWhole != nil {
            let poly = floorDraftPolygon
            if poly.count >= 3 {
                let moisture = tool == .moisture
                var m = OverlayMark(id: "draft-floor", style: moisture ? .wetFloor : .liftFlooring, points: poly.map { WorldVec($0.x, fy + 0.005, $0.y) },
                                    tag: "\(moisture ? "Wet floor" : CaptureCopy.floorName(stripFloorType, underlay: underlayOn)) · \(CaptureCopy.area(floorDraftArea))")
                m.floorType = moisture ? nil : stripFloorType
                out.append(m)
            }
        }
        if let t = tide {
            let pts = t.points(w, every: 0.1)
            if pts.count >= 2 {
                var m = OverlayMark(id: "draft-tide", style: .moistureWash, points: pts, tag: "Moisture to \(t.maxMm) mm")
                m.floorLevel = fy
                out.append(m)
            }
        }
        if let r = readout { out.append(OverlayMark(id: "readout", style: .readout, points: [r.point], tag: r.text)) }
        // Air movers' coverage on the floor (Equipment mode).
        if tool == .equipment {
            for m in engine.overlayMarks() {
                guard case .equipment(let type, _) = m.style, type == "airMover", let p = m.points.first else { continue }
                let dir = airflowDrag?.id == m.id ? airflowDrag?.dir : (airflowFor == m.id ? airflowPreview?.dir : m.airflow)
                guard let d = dir else { continue }
                out.append(OverlayMark(id: "cone-\(m.id)", style: .airflowCone, points: [p], airflow: d))
            }
        }
        return out
    }
}
