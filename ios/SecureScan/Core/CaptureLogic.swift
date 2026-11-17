//
//  CaptureLogic.swift
//  SecureScan
//
//  The pure rules behind the one capture screen (docs/UX2.md), shared by the
//  classic scan, the live scan, return visits, "See scope on site" and the
//  Studio harness:
//    * CaptureWorld / AimInterpreter - what the reticle is on (surface,
//      height, wall, room), snapping to wall ends, the reticle label;
//    * MarkIntent - one Mark tool: what a line or area means from where it
//      was aimed (skirting / wall lining / moisture line / wet floor / ...);
//    * CaptureCopy - every word on the screen (primary button, labels);
//    * CaptureStack - what was captured this session (count, undo groups);
//    * EquipmentGuard - no second air mover on top of the first;
//    * PlainWords - processing problems in plain, never-blaming words;
//    * RoomNaming - the room-name chips and RoomPlan's section suggestion;
//    * FloorEstimate - the floor height while a room is being scanned.
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

// MARK: - The world the reticle is aimed into (world space, y up)

struct WorldWall: Equatable {
    var id: String
    /// Ends in world (x, z).
    var a: PlanVec
    var b: PlanVec
    var height: Double
    var length: Double { simd_distance(a, b) }
}

struct WorldRoom: Equatable {
    var name: String
    /// Floor outline in world (x, z).
    var polygon: [PlanVec]
}

struct CaptureWorld: Equatable {
    var floorY: Double?
    var walls: [WorldWall] = []
    var rooms: [WorldRoom] = []
    /// Doors, windows and openings on the walls; RoomPlan's objects (docs/MARKING.md).
    var openings: [WorldOpening] = []
    var objects: [WorldObject] = []

    static let empty = CaptureWorld(floorY: nil)

    /// The nearest wall line to a world (x, z) point within `maxDistance`.
    func nearestWall(to p: PlanVec, maxDistance: Double) -> (wall: WorldWall, distance: Double, t: Double)? {
        var best: (WorldWall, Double, Double)? = nil
        for w in walls where w.length > 1e-6 {
            let d = PlanBuilder.distanceToSegment(p, w.a, w.b)
            guard d <= maxDistance, d < (best?.1 ?? .infinity) else { continue }
            best = (w, d, min(max(PlanBuilder.projectParam(p, w.a, w.b), 0), 1))
        }
        return best.map { (wall: $0.0, distance: $0.1, t: $0.2) }
    }

    func room(containing p: PlanVec) -> WorldRoom? {
        rooms.first { $0.polygon.count >= 3 && FloorArea.inside(p, $0.polygon) }
    }
}

/// One camera sample: pose and the centre raycast.
struct AimSample: Equatable {
    var camera: WorldVec
    var forward: WorldVec
    var hit: WorldVec?
    var normal: WorldVec?
    var tracking: Bool = true
}

/// What the reticle is on, after interpretation.
struct Aim: Equatable {
    var hit: WorldVec?
    var surface: Reticle.Surface?
    /// Metres above the floor (nil until the floor is known).
    var height: Double?
    var wall: WorldWall?
    var wallT: Double?
    var distanceToWall: Double?
    var room: String?
    /// The hit was moved onto a wall end / corner.
    var snapped = false
    /// Why nothing can be placed (tracking, nothing hit).
    var blocked: String?

    static let none = Aim(blocked: CaptureCopy.pointAtSurface)

    /// On a wall within 150 mm of the floor, or on the floor within 150 mm of a wall.
    var inSkirtingZone: Bool {
        guard hit != nil else { return false }
        if surface == .wall, let h = height { return h <= MarkIntent.skirtingBand }
        if surface == .floor, let d = distanceToWall { return d <= MarkIntent.skirtingBand }
        return false
    }
}

enum AimInterpreter {
    /// A wall line this close to an upright hit is "the wall" (else a cabinet).
    static let wallDistance = 0.25
    /// Wall ends and corners snap within this distance (metres, along the wall).
    static let snapDistance = 0.15

    static func interpret(_ s: AimSample, world: CaptureWorld, snapEnds: Bool = true) -> Aim {
        guard s.tracking else { return Aim(blocked: CaptureCopy.findingRoom) }
        guard var hit = s.hit else { return Aim(blocked: CaptureCopy.pointAtSurface) }
        if simd_distance(hit, s.camera) < 0.12 { return Aim(blocked: CaptureCopy.moveBack) }
        let ny: Double = s.normal.map { simd_length($0) > 1e-9 ? simd_normalize($0).y : 0 } ?? 0
        let p = PlanVec(hit.x, hit.z)
        let near = world.nearestWall(to: p, maxDistance: 1.0)
        let height = world.floorY.map { hit.y - $0 }
        // Upright and more than 25 cm off the nearest wall line = a cabinet; no wall near (or none
        // found yet) = a wall. Facing up with the floor unknown = the floor.
        let surface = Reticle.surface(normalY: ny, height: height ?? 0, distanceToWall: abs(ny) < 0.7 ? near?.distance : nil)
        var aim = Aim(hit: hit, surface: surface, height: height.map { max(0, $0) })
        aim.room = world.room(containing: p)?.name
        if let n = near {
            aim.distanceToWall = n.distance
            if surface == .wall && n.distance <= wallDistance {
                aim.wall = n.wall
                aim.wallT = n.t
                if snapEnds {
                    let snapped = WallEndSnap.snapPoint(hit, wallA: WorldVec(n.wall.a.x, hit.y, n.wall.a.y),
                                                        wallB: WorldVec(n.wall.b.x, hit.y, n.wall.b.y), tolerance: snapDistance)
                    if snapped != hit {
                        hit = snapped
                        aim.hit = hit
                        aim.snapped = true
                        aim.wallT = n.t < 0.5 ? 0 : 1
                    }
                }
            }
        }
        return aim
    }
}

// MARK: - The Mark tool: lines and areas by intent

enum WorkContext: String, Equatable { case inspect, scope }

enum MarkMeaning: String, CaseIterable, Equatable {
    case skirting, wallLining, cabinetry, moistureLine, wetFloor, liftFlooring

    var title: String {
        switch self {
        case .skirting: return "Remove skirting"
        case .wallLining: return "Remove wall lining"
        case .cabinetry: return "Remove cabinetry"
        case .moistureLine: return "Moisture line"
        case .wetFloor: return "Wet floor"
        case .liftFlooring: return "Lift flooring"
        }
    }

    /// The tag on the mark in the world ("Skirting · 2.35 m").
    var tag: String {
        switch self {
        case .skirting: return "Skirting"
        case .wallLining: return "Wall lining"
        case .cabinetry: return "Cabinetry"
        case .moistureLine: return "Moisture line"
        case .wetFloor: return "Wet floor"
        case .liftFlooring: return "Flooring"
        }
    }

    var isArea: Bool { self == .wetFloor || self == .liftFlooring }
    /// A removal (red) rather than an observation (blue).
    var isRemoval: Bool { self != .moistureLine && self != .wetFloor }
    /// The removal item key in readings-raw.json / plan.json.
    var removalItem: String? {
        switch self {
        case .skirting: return "skirting"
        case .wallLining: return "plasterboard"
        case .cabinetry: return "cabinetry"
        case .liftFlooring: return "flooring"
        default: return nil
        }
    }
}

enum MarkShape: Equatable { case line, area }

/// One tap of a mark (where it landed and what was under it).
struct MarkPoint: Equatable {
    var world: WorldVec
    var surface: Reticle.Surface?
    var height: Double?
    var distanceToWall: Double?
    var wallId: String?

    init(world: WorldVec, surface: Reticle.Surface?, height: Double?, distanceToWall: Double?, wallId: String? = nil) {
        self.world = world
        self.surface = surface
        self.height = height
        self.distanceToWall = distanceToWall
        self.wallId = wallId
    }

    init(aim: Aim) {
        self.init(world: aim.hit ?? .zero, surface: aim.surface, height: aim.height,
                  distanceToWall: aim.distanceToWall, wallId: aim.wall?.id)
    }

    var plan: PlanVec { PlanVec(world.x, world.z) }

    /// Wall within 150 mm of the floor, or floor within 150 mm of a wall.
    var nearFloorLine: Bool {
        switch surface {
        case .wall?: return (height ?? 1) <= MarkIntent.skirtingBand
        case .floor?: return (distanceToWall ?? 9) <= MarkIntent.skirtingBand
        default: return false
        }
    }

    var onFloorAwayFromWalls: Bool { surface == .floor && (distanceToWall ?? 9) > MarkIntent.skirtingBand }
}

enum MarkIntent {
    /// 150 mm: the skirting band above the floor / beside the wall.
    static let skirtingBand = 0.15
    /// Taps closer than this (horizontally) are the same tap.
    static let repeatTap = 0.05
    /// A floor area smaller than this is not an area.
    static let minArea = 0.1
    /// The reticle within this of the first corner closes the area.
    static let closeDistance = 0.3

    /// What the first tap starts: a line (on a wall, or the floor by a wall) or an area (open floor).
    static func startShape(_ first: MarkPoint) -> MarkShape {
        first.onFloorAwayFromWalls ? .area : .line
    }

    /// Repeated taps merged (consecutive within 5 cm, and a last tap back on the first).
    static func clean(_ pts: [MarkPoint]) -> [MarkPoint] {
        var out: [MarkPoint] = []
        for p in pts {
            if let last = out.last, simd_distance(last.plan, p.plan) < repeatTap, abs(last.world.y - p.world.y) < 0.1 { continue }
            out.append(p)
        }
        if out.count > 2, let f = out.first, let l = out.last, simd_distance(f.plan, l.plan) < repeatTap { out.removeLast() }
        return out
    }

    /// Area (m2) of the taps' floor outline.
    static func area(_ pts: [MarkPoint]) -> Double {
        pts.count >= 3 ? FloorArea.area(pts.map(\.plan)) : 0
    }

    /// The finished shape: a real area (3+ distinct corners, >= 0.1 m2), else
    /// a line between the two taps farthest apart (never an error, never dropped).
    static func shape(_ raw: [MarkPoint]) -> (shape: MarkShape, points: [MarkPoint])? {
        let pts = clean(raw)
        guard pts.count >= 2 else { return nil }
        if pts.count >= 3, area(pts) >= minArea, !FloorArea.selfIntersects(pts.map(\.plan)) { return (.area, pts) }
        var best = (0, 1, -1.0)
        for i in pts.indices { for j in pts.indices where j > i {
            let d = simd_distance(pts[i].world, pts[j].world)
            if d > best.2 { best = (i, j, d) }
        } }
        return (.line, [pts[best.0], pts[best.1]])
    }

    /// The meaning preselected in the tray; nil = ask ("Skirting run or floor area?").
    /// `remembered`: the last meaning the user chose for this kind of mark
    /// ("highLine" for a line up a wall, "area" for a floor area).
    static func defaultMeaning(shape: MarkShape, points: [MarkPoint], context: WorkContext,
                               remembered: [String: MarkMeaning] = [:]) -> MarkMeaning? {
        switch shape {
        case .area:
            return remembered["area"] ?? (context == .scope ? .liftFlooring : .wetFloor)
        case .line:
            if points.allSatisfy(\.nearFloorLine) { return .skirting }
            if points.allSatisfy(\.onFloorAwayFromWalls) || points.allSatisfy({ $0.surface == .floor }) { return nil }
            return remembered["highLine"] ?? (context == .scope ? .wallLining : .moistureLine)
        }
    }

    /// The key a choice is remembered under.
    static func memoryKey(shape: MarkShape, points: [MarkPoint]) -> String? {
        if shape == .area { return "area" }
        if points.allSatisfy(\.nearFloorLine) { return nil }
        return "highLine"
    }

    /// The chips offered for a shape (the default first).
    static func options(shape: MarkShape, default d: MarkMeaning?) -> [MarkMeaning] {
        let all: [MarkMeaning] = shape == .area ? [.wetFloor, .liftFlooring]
                                                : [.skirting, .moistureLine, .wallLining, .cabinetry]
        guard let d, let i = all.firstIndex(of: d) else { return all }
        var out = all
        out.remove(at: i)
        return [d] + out
    }

    /// Wall-lining cut heights offered (mm); "Full" is the wall height.
    static let liningChoices: [Int] = [300, 600, 1200]

    /// The cut preselected from how high the End tap was aimed (mm; `full` for Full).
    static func liningHeightMm(endHeight: Double?, fullMm: Int = 2400) -> Int {
        guard let h = endHeight, h.isFinite, h >= 0.25 else { return 600 }
        let mm = h * 1000
        for c in liningChoices where mm <= Double(c) + 60 { return c }
        return fullMm
    }

    /// The default height of a removal of each kind (mm).
    static func defaultHeightMm(_ m: MarkMeaning) -> Int {
        switch m {
        case .skirting: return 100
        case .cabinetry: return 900
        case .wallLining: return 600
        default: return 0
        }
    }

    static let floorTypes: [(key: String, name: String)] = [("carpet", "Carpet"), ("timber", "Timber"), ("vinyl", "Vinyl"),
                                                            ("tile", "Tile"), ("other", "Other")]
}

// MARK: - Every word on the capture screen

/// The capture modes, picked on the swipeable strip (Photo is not a mode: the shutter is always there).
enum CaptureTool: String, CaseIterable, Equatable {
    case moisture, stripOut, equipment, source, remeasure

    var title: String {
        switch self {
        case .moisture: return "Moisture"
        case .stripOut: return "Strip-out"
        case .equipment: return "Equipment"
        case .source: return "Source"
        case .remeasure: return "Re-measure"
        }
    }

    var icon: String {
        switch self {
        case .moisture: return "humidity"
        case .stripOut: return "scissors"
        case .equipment: return "fan"
        case .source: return "drop"
        case .remeasure: return "arrow.triangle.2.circlepath"
        }
    }

    /// The marks this mode draws (moisture lines and wet areas, or strip-out).
    var markFamily: MarkFamily? {
        switch self {
        case .moisture: return .moisture
        case .stripOut: return .stripOut
        default: return nil
        }
    }

    /// The mode strip: first visit, return visit, "See scope on site".
    static func modes(returnVisit: Bool, scopeOnSite: Bool = false) -> [CaptureTool] {
        if scopeOnSite { return [.equipment, .stripOut] }
        return returnVisit ? [.remeasure, .moisture, .stripOut, .equipment] : [.moisture, .stripOut, .equipment, .source]
    }

    /// Kept for older call sites: the same list as `modes`.
    static func rail(returnVisit: Bool, scopeOnSite: Bool = false) -> [CaptureTool] { modes(returnVisit: returnVisit, scopeOnSite: scopeOnSite) }
}

/// Which marks a mode draws.
enum MarkFamily: Equatable { case moisture, stripOut }

extension MarkIntent {
    /// The removal note for the toe-kick choice (cabinetry).
    static let kickBoardNote = "Kick board only"

    /// Strip-out: what the reticle's spot suggests (the sub-picker follows it until the user picks).
    static func stripKind(_ p: MarkPoint?, remembered: [String: MarkMeaning] = [:]) -> MarkMeaning {
        guard let p, p.surface != nil else { return .skirting }
        if p.nearFloorLine { return .skirting }
        switch p.surface {
        case .floor?: return .liftFlooring
        case .cabinet?, .benchtop?: return .cabinetry
        default: return remembered["stripLine"] == .cabinetry ? .cabinetry : .wallLining
        }
    }

    /// Strip-out marks saved without the tray (Undo is there): the ones with nothing to set.
    static func savesDirectly(_ m: MarkMeaning) -> Bool { m == .skirting || m == .cabinetry || m == .moistureLine || m == .wetFloor }

    /// Moisture mode: a line is a moisture line, an area a wet floor (no question).
    /// Strip-out mode: by where it was aimed - skirting near the floor, wall lining higher up,
    /// flooring for an area; two floor taps away from the walls ask "Skirting run or floor area?".
    static func defaultMeaning(shape: MarkShape, points: [MarkPoint], family: MarkFamily,
                               remembered: [String: MarkMeaning] = [:]) -> MarkMeaning? {
        switch family {
        case .moisture: return shape == .area ? .wetFloor : .moistureLine
        case .stripOut:
            if shape == .area { return .liftFlooring }
            if points.allSatisfy(\.nearFloorLine) { return .skirting }
            if points.allSatisfy({ $0.surface == .floor }) { return nil }
            return remembered["stripLine"] == .cabinetry ? .cabinetry : .wallLining
        }
    }

    /// The chips for a finished shape in a family (the default first).
    static func options(shape: MarkShape, family: MarkFamily, default d: MarkMeaning?) -> [MarkMeaning] {
        let all: [MarkMeaning]
        switch (family, shape) {
        case (.moisture, .line): all = [.moistureLine]
        case (.moisture, .area): all = [.wetFloor]
        case (.stripOut, .line): all = [.skirting, .wallLining, .cabinetry]
        case (.stripOut, .area): all = [.liftFlooring]
        }
        guard let d, let i = all.firstIndex(of: d) else { return all }
        var out = all
        out.remove(at: i)
        return [d] + out
    }
}

enum CaptureCopy {
    static let findingRoom = "Move slowly — finding the room"
    static let pointAtSurface = "Point at a surface"
    static let moveBack = "Move back a little"
    static let moveCloser = "Move closer"

    static func number(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
    static func length(_ m: Double) -> String { String(format: "%.2f m", max(0, m)) }
    static func area(_ m2: Double) -> String { String(format: "%.1f m²", max(0, m2)) }

    /// The reticle label: "Wall · 0.32 m up", "Skirting", "Floor", "Ceiling", "Cabinet".
    static func reticle(_ aim: Aim) -> String? {
        guard aim.hit != nil, let s = aim.surface else { return nil }
        switch s {
        case .wall:
            if let h = aim.height, h <= MarkIntent.skirtingBand { return "Skirting" }
            if let h = aim.height { return "Wall · \(length(h)) up" }
            return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .cabinet: return "Cabinet"
        case .benchtop: return "Benchtop"
        }
    }

    /// The reading material the aim suggests.
    static func material(_ aim: Aim) -> String {
        switch aim.surface {
        case .wall?: return aim.inSkirtingZone ? "skirting" : "wall"
        case .floor?: return "floor"
        case .ceiling?: return "ceiling"
        case .cabinet?, .benchtop?: return "cabinetry"
        case nil: return "wall"
        }
    }

    static let materials: [(key: String, name: String)] = [("wall", "Wall"), ("skirting", "Skirting"), ("floor", "Floor"),
                                                           ("ceiling", "Ceiling"), ("cabinetry", "Cabinet"), ("other", "Other")]
    static func materialName(_ key: String) -> String { materials.first { $0.key == key }?.name ?? key.capitalized }

    static let addReading = "Add reading"
    static let takePhoto = "Take photo"
    static let startHere = "Start here"
    static let markSource = "Mark source here"
    static let setAirflow = "Set airflow"
    static let markDone = "Mark done"

    static func endHere(_ m: Double?) -> String { m.map { "End here · \(length($0))" } ?? "End here" }
    static func addCorner(_ area: Double?) -> String { area.map { "Add corner · \(CaptureCopy.area($0))" } ?? "Add corner" }
    static func closeArea(_ m2: Double) -> String { "Close area · \(area(m2))" }
    static func place(_ equipmentType: String) -> String { "Place \(equipmentName(equipmentType).lowercased())" }
    static func remeasure(_ tag: String) -> String { "Re-measure \(tag)" }
    static func saveReading(_ text: String) -> String { text.isEmpty ? "Type the reading" : "Save · \(text)%" }

    /// The primary button for a finished mark in the tray.
    static func saveMark(_ m: MarkMeaning?, length: Double?, area: Double?) -> String {
        guard let m else { return "Choose what it is" }
        if m.isArea, let a = area { return "Save · \(m.tag) \(CaptureCopy.area(a))" }
        if let l = length { return "Save · \(m.tag) \(CaptureCopy.length(l))" }
        return "Save · \(m.tag)"
    }

    static let equipment: [(key: String, name: String)] = [("airMover", "Air mover"), ("dehumidifier", "Dehumidifier"),
                                                           ("airScrubber", "Air scrubber"), ("heater", "Heater")]
    static func equipmentName(_ key: String) -> String { equipment.first { $0.key == key }?.name ?? "Equipment" }
    static let equipmentShort: [String: String] = ["airMover": "AM", "dehumidifier": "DH", "airScrubber": "AS", "heater": "HT", "other": "EQ"]

    /// Leak causes. "Unknown" is a choice the user makes, never a default.
    static let causes = ["Shower", "Flexi hose", "Pipe", "Roof", "Window", "Appliance", "Overflow", "Unknown"]

    /// First-run help: one line per mode, on the instruction card until the mode is first used.
    static func coach(_ t: CaptureTool) -> String? {
        switch t {
        case .moisture: return "Aim at the spot you metered, then tap"
        case .stripOut: return "Tap where it starts, then where it ends"
        case .equipment: return "Aim at the floor where it stands"
        case .source: return "Aim where the water comes in, then tap"
        case .remeasure: return "Aim at a saved point to measure it again"
        }
    }

    /// "Tips" in the top bar: one line per mode.
    static func tips(_ modes: [CaptureTool]) -> [(title: String, line: String)] {
        modes.compactMap { m in coach(m).map { (m.title, $0) } }
    }

    static let snappedEnd = "Snapped to wall end"
    /// Floor materials on the strip-out floor sub-picker (keys as raw `floorType`).
    static let floorMaterials: [(key: String, title: String)] = [("carpet", "Carpet"), ("vinyl", "Vinyl"), ("timber", "Timber"), ("tile", "Tile")]
    static func floorName(_ key: String, underlay: Bool) -> String {
        let n = floorMaterials.first { $0.key == key }?.title ?? "Flooring"
        return key == "carpet" && underlay ? "\(n) + underlay" : n
    }
    /// The instruction card while marking by component.
    static func markingCard(kind: Component.Kind, drafting: Bool, floorType: String?, moisture: Bool) -> String {
        switch kind {
        case .skirting: return drafting ? "Scrub along the skirting" : "Tap to take the whole run, or scrub along it"
        case .wallFace: return moisture ? "Scrub along the wall, up to where it's wet" : (drafting ? "Drag the cut line to height" : "Tap the wall, or scrub over the part to strip")
        case .cabinet: return drafting ? "Kick board only? Use the chip" : "Tap the cabinet to remove it"
        case .floor: return moisture ? "Scrub over the wet floor" : "Scrub over the wet \(floorType.flatMap { k in floorMaterials.first { $0.key == k }?.title.lowercased() } ?? "floor")"
        case .waterCandidate, .ceiling: return "Aim where the water comes in, then tap"
        }
    }
    static let aimAirflow = "Aim where the air should go"
    static let twistHint = "Twist with two fingers to turn it"
    static let wetLineStart = "Tap where the wet line starts"
    static let wetAreaStart = "Tap the corners of the wet area"

    /// The sub-picker under the viewport for each mode (empty = none).
    static func subPicker(_ t: CaptureTool) -> [(key: String, title: String)] {
        switch t {
        case .moisture: return [("reading", "Reading"), ("line", "Moisture line"), ("area", "Wet floor"), ("adjust", "Adjust")]
        case .stripOut: return [("skirting", "Skirting"), ("wallLining", "Wall"), ("cabinetry", "Cabinets"), ("liftFlooring", "Floor")]
        case .equipment: return [("airMover", "Air mover"), ("dehumidifier", "Dehumidifier"), ("airScrubber", "Scrubber"), ("heater", "Heater")]
        case .source, .remeasure: return []
        }
    }

    /// The top bar's second line: "Scanning · 2 readings", "Drying setup · 2 units".
    static func subtitle(phase: String, tool: CaptureTool, readings: Int, marks: Int, units: Int, fixed: Bool) -> String {
        if fixed { return phase }
        func n(_ k: Int, _ one: String, _ many: String) -> String { k == 1 ? "1 \(one)" : "\(k) \(many)" }
        switch tool {
        case .moisture, .remeasure: return readings > 0 ? "\(phase) · \(n(readings, "reading", "readings"))" : phase
        case .stripOut: return marks > 0 ? "\(phase) · \(n(marks, "item", "items"))" : phase
        case .equipment: return units > 0 ? "Drying setup · \(n(units, "unit", "units"))" : "Drying setup"
        case .source: return phase
        }
    }

    static func readingTag(_ n: Int) -> String { "R\(n)" }
    static func photoTag(_ n: Int) -> String { "P\(n)" }

    /// The capture stack's badge.
    static func stackBadge(_ n: Int) -> String? { n <= 0 ? nil : (n > 99 ? "99+" : String(n)) }

    /// The top capsule: "Scanning · Bedroom", "Marking · Ensuite", "Visit 2 · 4 of 9".
    static func phase(_ phase: String, room: String) -> String { room.isEmpty ? phase : "\(phase) · \(room)" }
    static func visit(_ n: Int, done: Int, total: Int) -> String { total > 0 ? "Visit \(n) · \(done) of \(total)" : "Visit \(n)" }
}

// MARK: - The capture stack (everything captured this session)

struct CaptureStack: Equatable {
    struct Entry: Equatable, Identifiable {
        var id: String               // the first item id of the group
        var ids: [String]            // every saved item id (a moisture line saves several points)
        var kind: String             // reading | photo | mark | equipment | source | remeasure | done
        var title: String            // "R3 · 18%"
        var detail: String           // "Wall · Bedroom"
        var hasPhoto: Bool
        var needsFix: String? = nil  // plain sentence when the item could not be placed
    }

    private(set) var entries: [Entry] = []

    var count: Int { entries.count }
    var last: Entry? { entries.last }
    /// The newest entry with a photo (the stack's thumbnail).
    var lastPhoto: Entry? { entries.last { $0.hasPhoto } }
    var needsFixCount: Int { entries.filter { $0.needsFix != nil }.count }

    mutating func add(_ e: Entry) { entries.append(e) }

    /// Undo: removes and returns the newest entry.
    mutating func popLast() -> Entry? { entries.popLast() }

    /// Deleting any item of a group removes the whole group.
    @discardableResult
    mutating func remove(id: String) -> Entry? {
        guard let i = entries.firstIndex(where: { $0.ids.contains(id) || $0.id == id }) else { return nil }
        return entries.remove(at: i)
    }

    mutating func update(id: String, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    /// Review order: anything needing a fix first, then newest first.
    var reviewOrder: [Entry] {
        entries.filter { $0.needsFix != nil }.reversed() + entries.filter { $0.needsFix == nil }.reversed()
    }
}

// MARK: - One air mover is one air mover

enum EquipmentGuard {
    struct Unit: Equatable {
        var id: String
        var type: String
        /// Floor position (world x, z, or plan - one space per call).
        var pos: PlanVec
        var hasAirflow: Bool
        var tag: String
    }

    static let radius = 0.5

    /// An existing unit of the same type within 0.5 m: select it instead of placing a second one.
    static func existing(type: String, at p: PlanVec, units: [Unit], radius: Double = radius) -> Unit? {
        units.filter { $0.type == type && simd_distance($0.pos, p) <= radius }
            .min { simd_distance($0.pos, p) < simd_distance($1.pos, p) }
    }

    /// The primary button when aiming at an existing unit.
    static func action(for u: Unit) -> String { u.hasAirflow ? "Re-aim airflow · \(u.tag)" : "\(CaptureCopy.setAirflow) · \(u.tag)" }
}

// MARK: - Problems in plain words

enum PlainWords {
    struct Problem: Error, Equatable {
        var sentence: String
        var fix: String
    }

    /// A processing rejection (PlanBuilder / FloorArea messages) -> a plain sentence and the fix.
    static func problem(_ reason: String) -> Problem {
        let r = reason.lowercased()
        if r.contains("too small") { return Problem(sentence: "This floor area is too small to draw.", fix: "Redraw the area") }
        if r.contains("at least 3 corners") { return Problem(sentence: "This floor area has only two corners.", fix: "Make it a line or add corners") }
        if r.contains("cross over") { return Problem(sentence: "The corners of this area cross over.", fix: "Redraw the area") }
        if r.contains("different walls") { return Problem(sentence: "This line runs across two walls.", fix: "Redraw it on one wall") }
        if r.contains("not on a wall") { return Problem(sentence: "One end of this line isn't on a wall.", fix: "Redraw the line") }
        if r.contains("too short") || r.contains("same place") { return Problem(sentence: "Both ends of this line are in the same spot.", fix: "Redraw the line") }
        if r.contains("no end") { return Problem(sentence: "This line has no end point.", fix: "Redraw the line") }
        if r.contains("scanned room") || r.contains("inside a room") { return Problem(sentence: "This area isn't inside a scanned room.", fix: "Draw its corners") }
        if r.contains("not aligned") { return Problem(sentence: "The camera isn't lined up with the plan yet.", fix: "Line up first") }
        return Problem(sentence: "This mark isn't on the plan yet.", fix: "Open it to fix")
    }

    /// job.json note for marks the plan could not place.
    static func jobNote(fixCount n: Int) -> String? {
        guard n > 0 else { return nil }
        return n == 1 ? "1 mark needs a quick fix — open Items" : "\(n) marks need a quick fix — open Items"
    }
}

// MARK: - Room names

enum RoomNaming {
    static let chips = ["Bedroom", "Ensuite", "Bathroom", "Kitchen", "Living", "Laundry", "Hall", "Robe"]

    /// RoomPlan section labels ("bedroom", "bathroom", "kitchen", "livingRoom",
    /// "diningRoom", "unidentified") -> names to offer first. Several sections
    /// become one combined name ("Bedroom + Ensuite"); splitting rooms is out of scope.
    static func suggestions(sectionLabels: [String]) -> [String] {
        var seen: [String] = []
        for l in sectionLabels {
            let n: String?
            switch l {
            case "bedroom": n = "Bedroom"
            case "bathroom": n = "Bathroom"
            case "kitchen": n = "Kitchen"
            case "livingRoom": n = "Living"
            case "diningRoom": n = "Dining"
            default: n = nil
            }
            if let n, !seen.contains(n) { seen.append(n) }
        }
        guard seen.count > 1 else { return seen }
        // A bathroom off a bedroom is an ensuite.
        let named = seen.contains("Bedroom") ? seen.map { $0 == "Bathroom" ? "Ensuite" : $0 } : seen
        return [named.joined(separator: " + ")] + named
    }

    static func preselected(sectionLabels: [String]) -> String? { suggestions(sectionLabels: sectionLabels).first }

    /// The chips in the tray: suggestions first, then the usual names (no repeats).
    static func chipList(sectionLabels: [String]) -> [String] {
        let s = suggestions(sectionLabels: sectionLabels)
        return s + chips.filter { !s.contains($0) }
    }
}

// MARK: - The floor while a room is scanned

enum FloorEstimate {
    /// The floor: the lowest upward-facing hit at least 0.6 m below the camera,
    /// else the RoomPlan floor if known, else camera height - 1.4 m.
    static func update(_ current: Double?, hit: WorldVec?, normalY: Double?, cameraY: Double) -> Double? {
        guard let h = hit, let ny = normalY, ny > 0.85, h.y < cameraY - 0.6 else { return current }
        guard let c = current else { return h.y }
        // Low outliers (a step down, noise) move the floor only a little at a time.
        return h.y < c ? max(h.y, c - 0.05) : c
    }

    static func fallback(cameraY: Double) -> Double { cameraY - 1.4 }
}

extension PlainWords {
    /// A room RoomPlan could not finish: never blaming, and what is kept.
    static func roomFailed(_ detail: String?) -> String {
        "That room didn't save — rooms already saved are kept"
    }
}

// MARK: - A quick check of a finished mark against the walls found so far

enum MarkCheck {
    /// The 0.4 m the plan builder allows between a removal end and its wall.
    static let wallReach = 0.4

    /// Why a mark would not land on the plan (shown in review as "needs a quick
    /// fix"); nil when it is fine or there are no walls to check against yet.
    static func problem(meaning: MarkMeaning, points: [WorldVec], world: CaptureWorld) -> PlainWords.Problem? {
        guard meaning == .skirting || meaning == .wallLining || meaning == .cabinetry, points.count >= 2, !world.walls.isEmpty else { return nil }
        let a = PlanVec(points[0].x, points[0].z), b = PlanVec(points[points.count - 1].x, points[points.count - 1].z)
        let wa = world.nearestWall(to: a, maxDistance: wallReach), wb = world.nearestWall(to: b, maxDistance: wallReach)
        guard let wa, let wb else { return PlainWords.problem("One end of the removal is not on a wall.") }
        if wa.wall.id == wb.wall.id { return nil }
        // Different nearest walls: fine when either end is also within reach of the other's wall (a corner).
        if PlanBuilder.distanceToSegment(b, wa.wall.a, wa.wall.b) <= wallReach || PlanBuilder.distanceToSegment(a, wb.wall.a, wb.wall.b) <= wallReach { return nil }
        return PlainWords.problem("The start and end are on different walls.")
    }
}
