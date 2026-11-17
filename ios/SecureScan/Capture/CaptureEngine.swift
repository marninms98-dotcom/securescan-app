//
//  CaptureEngine.swift
//  SecureScan
//
//  The one view-model protocol behind the one CaptureHUD. An engine owns a
//  camera and a place to save things; the HUD owns everything the user sees
//  and touches. Engines:
//    * ScanModel        - the first visit (classic RoomCaptureView scan, or
//                         the live scan on our own ARSCNView); readings-raw.json
//    * RevisitModel     - return visits and "See scope on site"; plan.json
//    * StudioEngine     - DEBUG only: a synthetic room for screenshots
//

import SwiftUI
import UIKit
import simd

/// A photo taken with a tap: the plan's preview, the full-resolution file and a thumbnail.
struct CapturedPhoto: @unchecked Sendable {
    /// Max 1280 px long edge, JPEG 0.7 (embedded in plan.json, as before).
    var preview: Data?
    /// Full resolution (high-resolution frame when the session gives one), JPEG 0.85.
    var full: Data?
    /// ~200 px, for the capture stack and the review cards.
    var thumb: UIImage?
    /// ~600 px, for the preview card that springs up after the shutter.
    var card: UIImage? = nil
}

/// One photo of the job, for the full-screen viewer.
struct JobPhoto: Identifiable {
    var id: String
    /// "Photo 7"
    var title: String
    /// "Bedroom · wall 0.8 m up"
    var place: String
    var caption: String
    /// The full-resolution file when there is one, else the plan preview.
    var load: () -> UIImage?
}

/// The 0.5x photo: not on this phone / not right now (and why) / ready.
enum ZoomState: Equatable {
    case unavailable
    case blocked(String)
    case available
}

/// Everything captured in the instant of a tap.
struct CaptureShot {
    var id: String
    var takenAt: String
    var camera: WorldVec
    var forward: WorldVec
    var hit: WorldVec?
    var normal: WorldVec?
    var hitKind: String?
    var photo: Task<CapturedPhoto?, Never>?
    /// What the reticle was on.
    var aim: Aim = .none

    /// The same tap re-aimed at another point (snapping, whole wall, skirting snap).
    func aimed(at p: WorldVec) -> CaptureShot {
        var s = self
        s.hit = p
        if simd_length(p - camera) > 1e-6 { s.forward = simd_normalize(p - camera) }
        return s
    }
}

struct MarkDraft {
    var meaning: MarkMeaning
    /// The taps: a line has two, an area its corners.
    var shots: [CaptureShot]
    var heightMm: Int
    var floorType: String?
    var underlay: Bool
    var wholeRoom: Bool
    var length: Double?
    var area: Double?
    /// The removal note ("Kick board only").
    var note = ""
}

enum CaptureDraft {
    case reading(CaptureShot, value: Double, material: String, reference: Bool)
    case photo(CaptureShot, caption: String)
    case source(CaptureShot, cause: String, note: String, confirmed: Bool, inside: Bool)
    case equipment(CaptureShot, type: String, asset: String)
    case mark(MarkDraft)
}

struct SavedCapture {
    var entry: CaptureStack.Entry
    /// An air mover just placed (the HUD then offers "Set airflow").
    var airflowFor: String? = nil
}

/// A button the engine takes over (alignment, re-measure, mark done, scope).
struct EnginePrimary {
    var title: String
    var enabled = true
    var tint: Color = DS.Color.accent
    /// SF Symbol on the round action button.
    var icon: String = "checkmark"
    /// The white Camera-style "Start" shutter instead of the accent action.
    var start = false
    var action: () -> Void
}

/// The camera for the 3D layer (equipment models): world -> camera and camera -> clip,
/// for the viewport's size and orientation (portrait).
struct Camera3D {
    var view: simd_float4x4
    var projection: simd_float4x4

    /// A pinhole camera (the Studio): vertical field of view, looking at a point.
    static func pinhole(position: WorldVec, lookAt: WorldVec, fovYDegrees: Double, viewport: CGSize, near: Float = 0.02, far: Float = 60) -> Camera3D {
        let eye = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
        let at = SIMD3<Float>(Float(lookAt.x), Float(lookAt.y), Float(lookAt.z))
        let f = simd_normalize(at - eye)
        var r = simd_cross(f, SIMD3<Float>(0, 1, 0))
        if simd_length(r) < 1e-5 { r = SIMD3<Float>(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        // Camera-to-world: x = right, y = up, z = backwards.
        let c2w = simd_float4x4(columns: (SIMD4<Float>(r, 0), SIMD4<Float>(u, 0), SIMD4<Float>(-f, 0), SIMD4<Float>(eye, 1)))
        let aspect = Float(max(viewport.width, 1) / max(viewport.height, 1))
        let t = 1 / tan(Float(fovYDegrees) * .pi / 360)
        let proj = simd_float4x4(columns: (SIMD4<Float>(t / aspect, 0, 0, 0), SIMD4<Float>(0, t, 0, 0),
                                           SIMD4<Float>(0, 0, (far + near) / (near - far), -1),
                                           SIMD4<Float>(0, 0, 2 * far * near / (near - far), 0)))
        return Camera3D(view: c2w.inverse, projection: proj)
    }
}

/// The quiet text buttons under the primary ("Room done", "Finish", "Next room").
struct QuietAction: Identifiable, Equatable {
    var id: String
    var title: String
    var enabled = true
    /// A filled accent pill ("Finish" once the job has a room) instead of an outline.
    var prominent = false
}

/// A one-line edit made in the review drawer.
enum ItemEdit {
    case reading(value: Double, material: String)
    case caption(String)
}

@MainActor
protocol CaptureEngine: AnyObject {
    // What the screen says
    var roomName: String { get }
    /// "Scanning", "Marking", "Visit 2 · 4 of 9".
    var phaseText: String { get }
    /// RoomPlan coaching or alignment guidance, as the capsule's second line.
    var coaching: String? { get }
    var quietActions: [QuietAction] { get }
    /// False while the engine shows its own card (alignment) or is busy.
    var showsTools: Bool { get }
    /// Shown over everything while the job is being built ("Drawing the floor plan…").
    var busyText: String? { get }
    var isReturnVisit: Bool { get }
    var isScopeOnSite: Bool { get }
    var recordingSince: Date? { get }
    var canRenameRoom: Bool { get }

    func perform(quiet id: String)
    func requestClose()
    func toggleRecording()
    func renameRoom(_ name: String)
    /// RoomPlan's section labels for the room being named.
    func roomSections() -> [String]

    // The world
    var world: CaptureWorld { get }
    func aimSample() -> AimSample?
    func projector(viewport: CGSize) -> Projector?
    /// Everything saved, in this session's world space.
    func overlayMarks() -> [OverlayMark]

    // Capture and save
    func shot(photo: Bool) -> CaptureShot?
    func save(_ d: CaptureDraft) async -> Result<SavedCapture, PlainWords.Problem>
    func remove(ids: [String])
    func edit(id: String, _ e: ItemEdit)
    /// Drying equipment already in this job (world x, z) - one air mover is never placed twice.
    func equipmentUnits() -> [EquipmentGuard.Unit]
    func setAirflow(id: String, direction: WorldVec) -> Bool

    /// The engine's own primary button for this tool and aim (nil = the HUD's).
    func primaryOverride(tool: CaptureTool, aim: Aim) -> EnginePrimary?
    /// The engine's own tray (alignment), shown instead of the tools.
    func customTray() -> AnyView?
    // Photos
    /// Every photo of the job, newest first.
    func jobPhotos() -> [JobPhoto]
    /// Retake: a new photo for the same item (same id, same pin).
    func replacePhoto(id: String, photo: Task<CapturedPhoto?, Never>) async -> Bool
    /// The 0.5x photo.
    var zoomState: ZoomState { get }
    /// 0.5x: record the pose for the pin, then hand the camera over (AR paused).
    func beginHandoff() -> CaptureShot?
    /// 0.5x done or cancelled: the AR session resumes on the same world.
    func endHandoff()
    /// A tray was closed without saving (re-measure cancelled).
    func trayCancelled()
    /// The camera for the 3D equipment layer (nil = no 3D: the 2D glyphs are drawn).
    func camera3D(viewport: CGSize) -> Camera3D?
    /// The torch button (back camera with a torch, AR running).
    var hasTorch: Bool { get }

    // The moisture model (docs/MOISTURE.md)
    /// The plan's earlier corrections, in this session's world.
    func savedModelTweaks() -> [MoistTweak]
    /// This session's corrections changed (keep them with the job).
    func modelTweaksChanged(_ tweaks: [LiveTweak])
    /// The simulator's demo camera: a finger on empty space turns it (false = not supported).
    func lookDrag(dx: Double, dy: Double) -> Bool
}

extension CaptureEngine {
    /// The moisture model's corrections already on the plan (in this session's world).
    func savedModelTweaks() -> [MoistTweak] { [] }
    /// The scoper's corrections this session changed (keep them with the job).
    func modelTweaksChanged(_ tweaks: [LiveTweak]) {}
    func lookDrag(dx: Double, dy: Double) -> Bool { false }
    var zoomState: ZoomState { .unavailable }
    func beginHandoff() -> CaptureShot? { nil }
    func endHandoff() {}
    func trayCancelled() {}
    func customTray() -> AnyView? { nil }
    var canRenameRoom: Bool { false }
    func roomSections() -> [String] { [] }
    func camera3D(viewport: CGSize) -> Camera3D? { nil }
    var hasTorch: Bool { Torch.available }
}

/// Shared helpers for engines.
enum CaptureIDs {
    static func new(_ prefix: String) -> String { prefix + UUID().uuidString.prefix(8).lowercased() }
}
