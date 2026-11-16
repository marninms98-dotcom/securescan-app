//
//  StudioScenes.swift
//  SecureScan
//
//  The Studio harness's scenes as plain data: where the synthetic camera
//  stands, what it looks at, which saved marks are in the world and what the
//  reticle readout says. The DEBUG Studio (Capture/Studio.swift) shows them
//  through the real HUD; the unit tests lay each one out with the same
//  OverlayLayout code and check that nothing overlaps.
//  The room: the demo job's bedroom, 3.45 x 2.80 m, floor y = 0, x right, z = plan y.
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

struct StudioSceneData {
    var name: String
    var camera: WorldVec
    var target: WorldVec
    var marks: [OverlayMark] = []
    /// The reticle's readout as the HUD would show it (nil = hidden).
    var reticle: String? = nil
}

enum StudioScenes {
    static let fovY = 62.0
    /// The camera viewport on an iPhone 16 Pro (402 pt wide, 3:4) - the CI simulator.
    static let viewport = ScreenVec(402, 536)

    /// Walls have two sides (docs/MARKING.md H): the "next room" is behind w1 (z < 0).
    static let sides = ["through-wall-hidden", "cavity-leak-side-a", "cavity-leak-side-b", "strip-out-other-side-hidden"]

    static let marking = ["hover-skirting", "scrub-skirting", "strip-back-dragging", "cabinet-hover", "cabinet-selected",
                          "floor-carpet", "floor-vinyl", "floor-timber", "floor-tile", "moisture-tideline",
                          "source-suspected", "source-confirmed", "airflow-drag", "suggestion-chip"]

    static let all = marking + sides + ["mode-moisture", "mode-stripout", "mode-equipment", "mode-source", "scan-start",
                      "equipment-model-preview", "equipment-model-placed",
                      "aim-wall", "aim-wall-bright", "aim-skirting", "aim-nothing", "reading-tray", "reading-saved", "line-progress",
                      "line-tray-skirting", "lining-band-done", "area-progress", "area-tray", "photo-taken", "photo-preview-card",
                      "photo-viewer", "photo-zoom-toggle", "review-drawer", "equipment-place", "equipment-airflow", "source-tray",
                      "room-name-tray", "scan-coaching", "visit-remeasure", "scope-on-site", "needs-fix"]

    /// The synthetic bedroom (3.45 x 2.80 m), as the capture screen knows it.
    static let walls: [WorldWall] = {
        let W = 3.45, D = 2.80, H = SimulatedScan.wallHeight
        return [WorldWall(id: "w1", a: PlanVec(0, 0), b: PlanVec(W, 0), height: H),
                WorldWall(id: "w2", a: PlanVec(W, 0), b: PlanVec(W, D), height: H),
                WorldWall(id: "w3", a: PlanVec(W, D), b: PlanVec(0, D), height: H),
                WorldWall(id: "w4", a: PlanVec(0, D), b: PlanVec(0, 0), height: H)]
    }()

    static var world: CaptureWorld {
        CaptureWorld(floorY: 0, walls: walls, rooms: [WorldRoom(name: "Bedroom", polygon: [PlanVec(0, 0), PlanVec(3.45, 0), PlanVec(3.45, 2.8), PlanVec(0, 2.8)])],
                     openings: openings, objects: objects)
    }

    /// The room's door (w4) and window (w1), as RoomPlan would give them.
    static let openings: [WorldOpening] = [
        WorldOpening(id: "door1", kind: "door", wallId: "w4", t0: (2.8 - 2.57) / 2.8, t1: (2.8 - 1.75) / 2.8, bottom: 0, top: 2.04),
        WorldOpening(id: "win1", kind: "window", wallId: "w1", t0: 0.7 / 3.45, t1: 1.9 / 3.45, bottom: 0.95, top: 2.05),
    ]

    /// A kitchen run on the right wall (w2: a base cabinet, the sink cabinet, an oven) and a vanity
    /// on the left wall (w4), so cabinetry can be shown. Front faces into the room.
    static let objects: [WorldObject] = [
        WorldObject(id: "k1", category: "storage", center: WorldVec(3.16, 0.435, 0.65), size: WorldVec(0.6, 0.87, 0.58), yaw: -.pi / 2),
        WorldObject(id: "k2", category: "sink", center: WorldVec(3.16, 0.435, 1.25), size: WorldVec(0.6, 0.87, 0.58), yaw: -.pi / 2),
        WorldObject(id: "k3", category: "oven", center: WorldVec(3.16, 0.435, 1.85), size: WorldVec(0.6, 0.87, 0.58), yaw: -.pi / 2),
        WorldObject(id: "v1", category: "sink", center: WorldVec(0.23, 0.425, 0.65), size: WorldVec(0.8, 0.85, 0.46), yaw: .pi / 2),
    ]

    // Points on the walls used by several scenes.
    static let onSkirting = WorldVec(0.55, 0.06, 0.0)
    static let onWall = WorldVec(1.15, 0.30, 0.0)
    static let onSideWall = WorldVec(0.0, 0.45, 0.65)

    static func pin(_ id: String, _ p: WorldVec, _ v: Double, _ n: Int, faded: Bool = false, selected: Bool = false) -> OverlayMark {
        var m = OverlayMark(id: id, style: .reading(status: OverlayBuild.status(v, reference: false), reference: false), points: [p],
                            value: CaptureCopy.number(v), tag: CaptureCopy.readingTag(n))
        m.faded = faded
        m.selected = selected
        return m
    }

    static func projector(_ d: StudioSceneData) -> PinholeProjector {
        PinholeProjector(position: d.camera, lookAt: d.target, fovYDegrees: fovY, viewport: viewport)
    }

    /// A scene as the screen shows it: equipment drawn as 3D models (the overlay keeps their
    /// tags), the live airflow arrow replaced by the model's own airflow.
    static func data(_ name: String) -> StudioSceneData {
        var d = raw(name)
        d.marks = d.marks.filter { $0.id != "draft-airflow" }.compactMap { m in
            var m = m
            if case .equipment(let type, _) = m.style { m.modelHeight = OverlayLayout.equipmentHeight(type); m.airflow = nil }
            // Marks behind a wall, or on the far side of theirs, are not drawn (docs/MARKING.md H).
            return Visibility.prepare(m, camera: d.camera, world: world)
        }
        return d
    }

    static func raw(_ name: String) -> StudioSceneData {
        let wallSide = WorldVec(3.3, 1.5, 1.0)
        let corner = WorldVec(0.6, 1.5, 1.9)
        switch name {
        // Walls have two sides (docs/MARKING.md H).
        case "through-wall-hidden", "cavity-leak-side-a", "cavity-leak-side-b", "strip-out-other-side-hidden":
            func onWall(_ m: OverlayMark, _ side: String) -> OverlayMark { var m = m; m.wallId = "w1"; m.side = side; return m }
            var leak = OverlayMark(id: "s9", style: .source, points: [WorldVec(2.6, 0.55, 0.0)], tag: "Leak · inside wall")
            leak = onWall(leak, WallSide.cavity)
            let inside = onWall(pin("r1", WorldVec(2.3, 0.4, 0.0), 22, 1), WallSide.a)
            let behind = onWall(pin("r9", WorldVec(1.0, 0.5, 0.0), 31, 9), WallSide.b)
            let nextRoomUnit = OverlayMark(id: "a9", style: .equipment(type: "airMover", planned: false), points: [WorldVec(1.5, 0, -1.2)],
                                           airflow: WorldVec(1, 0, 0), tag: "AM-09")
            let lining = onWall(OverlayMark(id: "x1", style: .lining, points: [WorldVec(0.3, 0, 0), WorldVec(2.2, 0, 0)], top: 0.6,
                                            tag: "Strip wall to 600 · 1.90 m"), WallSide.a)
            let outerSkirting = onWall(OverlayMark(id: "x2", style: .skirting, points: [WorldVec(1.0, 0, 0), WorldVec(2.4, 0, 0)],
                                                   tag: "Skirting · 1.40 m"), WallSide.b)
            switch name {
            case "through-wall-hidden":
                // From inside: the next room's air mover and the reading on the far face don't show.
                return StudioSceneData(name: name, camera: WorldVec(2.3, 1.45, 2.4), target: WorldVec(1.4, 0.6, 0.0),
                                       marks: [inside, behind, nextRoomUnit])
            case "cavity-leak-side-a":
                return StudioSceneData(name: name, camera: WorldVec(2.0, 1.45, 2.2), target: WorldVec(2.4, 0.6, 0.0), marks: [leak, inside])
            case "cavity-leak-side-b":
                // The same leak from the other room: drawn on this face, the inside reading hidden.
                return StudioSceneData(name: name, camera: WorldVec(2.0, 1.45, -2.2), target: WorldVec(2.4, 0.6, 0.0), marks: [leak, inside, behind])
            default:
                return StudioSceneData(name: name, camera: WorldVec(1.7, 1.45, -2.3), target: WorldVec(1.7, 0.45, 0.0),
                                       marks: [lining, outerSkirting, behind])
            }
        // Marking by component (docs/MARKING.md).
        case "hover-skirting":
            return StudioSceneData(name: name, camera: WorldVec(2.6, 1.4, 2.3), target: WorldVec(1.25, 0.04, 0.0))
        case "scrub-skirting":
            return StudioSceneData(name: name, camera: WorldVec(2.6, 1.4, 2.3), target: WorldVec(1.6, 0.04, 0.0))
        case "strip-back-dragging":
            return StudioSceneData(name: name, camera: WorldVec(2.3, 1.45, 2.5), target: WorldVec(1.5, 0.75, 0.0))
        case "cabinet-hover", "cabinet-selected":
            return StudioSceneData(name: name, camera: WorldVec(0.9, 1.5, 1.6), target: WorldVec(name == "cabinet-hover" ? 2.87 : 2.6, 0.5, 1.25))
        case "floor-carpet", "floor-vinyl", "floor-timber", "floor-tile":
            return StudioSceneData(name: name, camera: WorldVec(0.5, 1.55, 2.65), target: WorldVec(1.9, 0, 1.1))
        case "moisture-tideline":
            return StudioSceneData(name: name, camera: WorldVec(2.3, 1.45, 2.4), target: WorldVec(1.3, 0.55, 0.0))
        case "source-suspected", "source-confirmed":
            var src = OverlayMark(id: "s1", style: .source, points: [WorldVec(0.05, 1.02, 0.65)],
                                  tag: "Vanity · \(name == "source-confirmed" ? "Confirmed" : "Suspected")")
            src.confirmed = name == "source-confirmed"
            var wash = OverlayMark(id: "m1", style: .moistureWash, points: [WorldVec(0, 0.42, 1.30), WorldVec(0, 0.38, 1.45), WorldVec(0, 0.45, 1.6), WorldVec(0, 0.36, 1.72)],
                                   tag: "Moisture to 450 mm")
            wash.floorLevel = 0
            return StudioSceneData(name: name, camera: WorldVec(2.4, 1.45, 1.6), target: WorldVec(0.2, 0.8, 0.95), marks: [src, wash])
        case "airflow-drag":
            return StudioSceneData(name: name, camera: WorldVec(2.9, 1.5, 2.6), target: WorldVec(1.1, 0, 0.9), marks: [
                OverlayMark(id: "a1", style: .equipment(type: "airMover", planned: false), points: [WorldVec(1.6, 0, 1.3)],
                            airflow: simd_normalize(WorldVec(-1, 0, -0.4)), tag: "AM-01"),
            ])
        case "suggestion-chip":
            return StudioSceneData(name: name, camera: WorldVec(2.6, 1.4, 2.3), target: WorldVec(1.0, 0.5, 0.0),
                                   marks: [pin("r1", WorldVec(0.6, 0.08, 0.0), 28, 1), pin("r2", WorldVec(2.1, 0.1, 0.0), 24, 2)])
        case "mode-moisture":
            return StudioSceneData(name: name, camera: WorldVec(2.9, 1.45, 2.0), target: WorldVec(1.45, 0.24, 0.0), marks: [
                pin("r1", WorldVec(0.55, 0.62, 0.0), 12, 1), pin("r2", WorldVec(2.05, 0.42, 0.0), 19, 2), pin("r3", WorldVec(1.95, 0.08, 0.0), 31, 3),
            ], reticle: "Wall · 0.24 m up")
        case "mode-stripout":
            return StudioSceneData(name: name, camera: WorldVec(1.7, 1.4, 2.3), target: WorldVec(3.38, 0.05, 0.0), marks: [
                OverlayMark(id: "draft-line", style: .skirting, points: [WorldVec(1.1, 0, 0.0), WorldVec(3.45, 0, 0.0)], tag: "Skirting · 2.35 m"),
            ])
        case "mode-equipment":
            let unit = WorldVec(1.55, 0, 1.35), tgt = WorldVec(0.55, 0, 0.75)
            return StudioSceneData(name: name, camera: WorldVec(2.95, 1.45, 2.55), target: tgt, marks: [
                OverlayMark(id: "a3", style: .equipment(type: "airMover", planned: false), points: [unit], tag: "AM-03"),
            ])
        case "mode-source":
            return StudioSceneData(name: name, camera: WorldVec(2.6, 1.5, 2.2), target: WorldVec(0.0, 0.3, 1.2), reticle: "Wall · 0.30 m up")
        case "scan-start":
            return StudioSceneData(name: name, camera: WorldVec(3.05, 1.45, 2.55), target: WorldVec(1.2, 0.9, 0.0))
        case "equipment-model-preview":
            return StudioSceneData(name: name, camera: WorldVec(2.9, 1.45, 2.6), target: WorldVec(1.45, 0, 1.0))
        case "equipment-model-placed":
            return StudioSceneData(name: name, camera: WorldVec(3.25, 1.55, 2.7), target: WorldVec(1.32, 0.45, 0.0), marks: [
                OverlayMark(id: "a1", style: .equipment(type: "airMover", planned: false), points: [WorldVec(1.55, 0, 1.2)],
                            airflow: simd_normalize(WorldVec(-0.7, 0, -1)), tag: "AM-01"),
                OverlayMark(id: "d1", style: .equipment(type: "dehumidifier", planned: false), points: [WorldVec(2.3, 0, 0.4)], tag: "DH-01"),
            ])
        case "aim-wall", "aim-wall-bright", "photo-zoom-toggle":
            return StudioSceneData(name: name, camera: wallSide, target: WorldVec(1.55, 0.32, 0),
                                   marks: [pin("r1", onSkirting, 10, 1)], reticle: name == "photo-zoom-toggle" ? nil : "Wall · 0.32 m up")
        case "aim-skirting":
            return StudioSceneData(name: name, camera: wallSide, target: WorldVec(1.25, 0.05, 0), reticle: "Skirting")
        case "aim-nothing":
            return StudioSceneData(name: name, camera: WorldVec(3.05, 1.45, 2.55), target: WorldVec(0, 1.0, 2.2))
        case "reading-tray":
            return StudioSceneData(name: name, camera: WorldVec(2.6, 1.5, 2.4), target: WorldVec(1.5, 0.1, 0.6))
        case "reading-saved":
            return StudioSceneData(name: name, camera: WorldVec(3.3, 1.5, 0.5), target: WorldVec(1.5, 0, 0.75),
                                   marks: [pin("r1", onSkirting, 10, 1), pin("r2", onWall, 18, 2), pin("r3", onSideWall, 26, 3)], reticle: "Floor")
        case "line-progress":
            return StudioSceneData(name: name, camera: WorldVec(3.3, 1.5, 0.5), target: WorldVec(1.9, 0.05, 0), reticle: "Skirting")
        case "line-tray-skirting":
            return StudioSceneData(name: name, camera: WorldVec(3.0, 1.5, 2.6), target: WorldVec(1.25, 0.05, 0.25))
        case "lining-band-done":
            return StudioSceneData(name: name, camera: WorldVec(2.4, 1.4, 1.4), target: WorldVec(0.0, 0.3, 0.9), marks: [
                OverlayMark(id: "x1", style: .lining, points: [WorldVec(0.0, 0, 0.25), WorldVec(0.0, 0, 1.55)], top: 0.6, tag: "Wall lining · 1.30 m"),
                OverlayMark(id: "x2", style: .skirting, points: [WorldVec(0.30, 0, 0.0), WorldVec(2.10, 0, 0.0)], tag: "Skirting · 1.80 m"),
                pin("r1", WorldVec(0.0, 0.40, 1.3), 24, 1),
            ], reticle: "Wall · 0.30 m up")
        case "area-progress":
            return StudioSceneData(name: name, camera: WorldVec(0.3, 1.5, 2.45), target: WorldVec(1.05, 0, 1.6))
        case "area-tray":
            return StudioSceneData(name: name, camera: WorldVec(1.3, 1.5, 2.6), target: WorldVec(1.38, 0, 1.6))
        case "photo-taken", "photo-preview-card":
            return StudioSceneData(name: name, camera: WorldVec(2.4, 1.45, 2.4), target: WorldVec(1.0, 0.55, 0.0), marks: [
                OverlayMark(id: "p1", style: .photo, points: [WorldVec(1.4, 0.9, 0.0)], tag: "P1"),
                pin("r1", onSkirting, 10, 1),
            ])
        case "photo-viewer":
            return StudioSceneData(name: name, camera: wallSide, target: WorldVec(1.55, 0.32, 0))
        case "review-drawer":
            return StudioSceneData(name: name, camera: corner, target: WorldVec(0.7, 0.2, 0.4), marks: [
                pin("r1", onSkirting, 10, 1), pin("r2", onWall, 18, 2, selected: true), pin("r3", onSideWall, 26, 3),
                OverlayMark(id: "x1", style: .skirting, points: [WorldVec(0.3, 0, 0.0), WorldVec(1.0, 0, 0.0)], tag: "Skirting · 0.70 m"),
            ])
        case "equipment-place":
            return StudioSceneData(name: name, camera: WorldVec(0.3, 1.4, 2.0), target: WorldVec(1.2, 0, 1.0), marks: [
                OverlayMark(id: "d1", style: .equipment(type: "dehumidifier", planned: false), points: [WorldVec(2.0, 0, 0.6)], tag: "DH 1"),
            ])
        case "equipment-airflow":
            // The airflow points from the unit to where the reticle is on the floor.
            let cam = WorldVec(2.9, 1.45, 2.6), tgt = WorldVec(0.9, 0, 1.1), unit = WorldVec(0.96, 0, 0.52)
            let f = simd_normalize(WorldVec(tgt.x - unit.x, 0, tgt.z - unit.z))
            return StudioSceneData(name: name, camera: cam, target: tgt, marks: [
                OverlayMark(id: "a1", style: .equipment(type: "airMover", planned: false), points: [unit], tag: "AM 1"),
                OverlayMark(id: "draft-airflow", style: .equipment(type: "airMover", planned: false), points: [unit], airflow: f, tag: nil),
            ])
        case "source-tray":
            return StudioSceneData(name: name, camera: WorldVec(2.6, 1.5, 2.4), target: WorldVec(0.5, 0.25, 1.2))
        case "room-name-tray":
            return StudioSceneData(name: name, camera: WorldVec(2.4, 1.5, 2.4), target: WorldVec(1.0, 0.55, 0.6))
        case "scan-coaching":
            return StudioSceneData(name: name, camera: WorldVec(2.9, 1.5, 2.6), target: WorldVec(1.7, 1.2, 0.0), reticle: "Wall · 1.20 m up")
        case "visit-remeasure":
            return StudioSceneData(name: name, camera: WorldVec(2.7, 1.4, 0.5), target: onWall + WorldVec(0, 0, 0.05), marks: [
                pin("r1", onSkirting, 9, 1), pin("r2", onWall, 18, 2, faded: true, selected: true), pin("r3", onSideWall, 26, 3, faded: true),
            ])
        case "scope-on-site":
            var am = OverlayMark(id: "a1", style: .equipment(type: "airMover", planned: true), points: [WorldVec(1.2, 0, 1.3)],
                                 airflow: simd_normalize(WorldVec(-1, 0, -0.8)), tag: "AM-1")
            am.selected = true
            var x2 = OverlayMark(id: "x2", style: .skirting, points: [WorldVec(0.4, 0, 0.0), WorldVec(2.3, 0, 0.0)], tag: "X2 · Skirting")
            x2.faded = true
            return StudioSceneData(name: name, camera: WorldVec(3.3, 1.4, 2.6), target: WorldVec(1.2, 0, 1.3), marks: [
                am,
                OverlayMark(id: "x1", style: .lining, points: [WorldVec(0.0, 0, 0.3), WorldVec(0.0, 0, 1.5)], top: 0.6, tag: "X1 · Wall lining"),
                x2,
                OverlayMark(id: "f1", style: .liftFlooring, points: [WorldVec(0.3, 0, 0.6), WorldVec(1.6, 0, 0.6), WorldVec(1.6, 0, 1.9), WorldVec(0.3, 0, 1.9)],
                            tag: "F1 · Carpet 1.7 m²"),
            ])
        case "needs-fix":
            return StudioSceneData(name: name, camera: corner, target: WorldVec(0.7, 0.2, 0.4),
                                   marks: [pin("r1", onSkirting, 10, 1), pin("r2", onWall, 18, 2)])
        default:
            return StudioSceneData(name: name, camera: WorldVec(3.05, 1.45, 2.55), target: WorldVec(1.0, 0.6, 0.0))
        }
    }
}
