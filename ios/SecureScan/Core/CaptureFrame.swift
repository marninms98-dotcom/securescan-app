//
//  CaptureFrame.swift
//  SecureScan
//
//  The capture screen's geometry and its haptic rules, as plain logic:
//    * CaptureFrame     - the framed viewport: a black top bar, the camera at
//                         3:4 (the sensor's own shape, so nothing is cropped
//                         on a modern iPhone), a black bottom panel;
//    * ModeStripLayout  - the Camera-style mode strip: item centres, the
//                         offset that centres the selected mode, the mode a
//                         drag lands on;
//    * HapticRateLimiter- at most one tick per interval (scan structure);
//    * StructureDiff    - which walls / doors / windows / objects are new.
//  Foundation + CoreGraphics only - unit tested.
//

import Foundation
import CoreGraphics

struct CaptureFrame: Equatable {
    /// Black top bar (status area + the bar's row), from the screen top.
    var top: CGFloat
    /// The camera viewport's height (full width).
    var viewport: CGFloat
    /// Black bottom panel, to the screen bottom.
    var bottom: CGFloat

    /// The row under the status area (Tips · title · mic · close).
    static let barRow: CGFloat = 56
    /// The bottom panel's content: modes 28 + 4 + controls 80 + 10 + pills 34 + 8 top.
    static let panelContent: CGFloat = 164
    /// The camera's shape (portrait 3:4).
    static let aspect: CGFloat = 4.0 / 3.0

    /// Full-screen size and safe-area insets -> the three bands. The viewport is 3:4 when the
    /// screen is tall enough, else shorter (the camera then fills it, cropped top and bottom).
    static func layout(width: CGFloat, height: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> CaptureFrame {
        let top = safeTop + barRow
        let minBottom = panelContent + safeBottom
        let vp = max(0, min(width * aspect, height - top - minBottom))
        return CaptureFrame(top: top, viewport: vp, bottom: max(0, height - top - vp))
    }
}

/// The mode strip: modes side by side with a fixed gap, the selected one centred.
struct ModeStripLayout: Equatable {
    var widths: [CGFloat]
    var gap: CGFloat = 26

    /// Centre of item `i` from the strip's leading edge.
    func centre(_ i: Int) -> CGFloat {
        guard widths.indices.contains(i) else { return 0 }
        var x: CGFloat = 0
        for k in 0..<i { x += widths[k] + gap }
        return x + widths[i] / 2
    }

    /// The strip's x offset that puts item `i` at the middle of a container `width` wide.
    func offset(selected i: Int, in width: CGFloat) -> CGFloat { width / 2 - centre(i) }

    /// The item nearest the middle after dragging `drag` points from `selected`.
    func landing(from selected: Int, drag: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        let x = centre(selected) - drag
        var best = 0
        var bestD = CGFloat.infinity
        for i in widths.indices {
            let d = abs(centre(i) - x)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}

/// At most one event per `interval` seconds.
struct HapticRateLimiter: Equatable {
    var interval: Double = 0.25
    private(set) var last: Double?

    init(interval: Double = 0.25) { self.interval = interval }

    /// True (and remembered) when an event at `t` may fire.
    mutating func allow(at t: Double) -> Bool {
        if let l = last, t - l < interval, t >= l { return false }
        last = t
        return true
    }
}

/// Which pieces of a growing scan are new: walls, doors, windows, openings and objects by
/// their identifiers. RoomPlan re-sends the whole room on every update; only new ids count.
struct StructureDiff: Equatable {
    private(set) var known: Set<String> = []

    /// Adds the room's current ids; returns how many were not seen before.
    mutating func add(_ ids: [String]) -> Int {
        var n = 0
        for id in ids where !known.contains(id) {
            known.insert(id)
            n += 1
        }
        return n
    }

    /// A new room starts (ids are per room).
    mutating func reset() { known = [] }
}
