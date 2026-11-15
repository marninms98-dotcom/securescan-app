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

    static let all = ["mode-moisture", "mode-stripout", "mode-equipment", "mode-source", "scan-start",
                      "equipment-model-preview", "equipment-model-placed",
                      "aim-wall", "aim-wall-bright", "aim-skirting", "aim-nothing", "reading-tray", "reading-saved", "line-progress",
                      "line-tray-skirting", "lining-band-done", "area-progress", "area-tray", "photo-taken", "photo-preview-card",
                      "photo-viewer", "photo-zoom-toggle", "review-drawer", "equipment-place", "equipment-airflow", "source-tray",
                      "room-name-tray", "scan-coaching", "visit-remeasure", "scope-on-site", "needs-fix"]

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
        d.marks = d.marks.filter { $0.id != "draft-airflow" }.map { m in
            var m = m
            if case .equipment(let type, _) = m.style { m.modelHeight = OverlayLayout.equipmentHeight(type); m.airflow = nil }
            return m
        }
        return d
    }

    static func raw(_ name: String) -> StudioSceneData {
        let wallSide = WorldVec(3.3, 1.5, 1.0)
        let corner = WorldVec(0.6, 1.5, 1.9)
        switch name {
        case "mode-moisture":
            return StudioSceneData(name: name, camera: WorldVec(2.9, 1.45, 2.0), target: WorldVec(1.45, 0.24, 0.0), marks: [
                pin("r1", WorldVec(0.55, 0.62, 0.0), 12, 1), pin("r2", WorldVec(2.45, 0.32, 0.0), 19, 2), pin("r3", WorldVec(1.95, 0.08, 0.0), 31, 3),
            ], reticle: "Wall · 0.24 m up")
        case "mode-stripout":
            return StudioSceneData(name: name, camera: WorldVec(1.7, 1.4, 2.3), target: WorldVec(3.45, 0.05, 0.0), marks: [
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
            return StudioSceneData(name: name, camera: WorldVec(2.9, 1.5, 2.6), target: WorldVec(1.3, 0.25, 0.55), marks: [
                OverlayMark(id: "a1", style: .equipment(type: "airMover", planned: false), points: [WorldVec(0.85, 0, 1.0)],
                            airflow: simd_normalize(WorldVec(-0.6, 0, -1)), tag: "AM-01"),
                OverlayMark(id: "d1", style: .equipment(type: "dehumidifier", planned: false), points: [WorldVec(2.35, 0, 0.55)], tag: "DH-01"),
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
            return StudioSceneData(name: name, camera: WorldVec(3.3, 1.5, 0.5), target: WorldVec(0.8, 0.35, 0.2),
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
