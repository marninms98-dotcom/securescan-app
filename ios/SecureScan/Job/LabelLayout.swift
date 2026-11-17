//
//  LabelLayout.swift
//  SecureScan
//
//  Screen-space labels for the 3D tab: every label's anchor is projected to
//  the screen, then labels are placed one by one, most important first
//  (selected, then wet > damp > dry, then the rest), at the first spot round
//  their anchor that is inside the view and clear of the floating controls,
//  the other pins and the labels already placed. A label with no free spot
//  is hidden rather than drawn over another, and labels never climb into a
//  column above their pin: in a dense room the less important ones go (pins
//  closer together than `cluster` keep one label, the most important).
//  Pure CoreGraphics.
//

import CoreGraphics

enum LabelLayout {
    struct Item: Equatable {
        var id: String
        var anchor: CGPoint
        var size: CGSize
        var priority: Int
        /// The anchor is in front of the camera and on screen.
        var onScreen = true
    }

    /// Radius kept clear round every pin head (points).
    static let pinClear: CGFloat = 8
    /// Gap between a pin and its label.
    static let gap: CGFloat = 6
    /// Pins closer than this on screen share one label (the most important; selected wins).
    static let cluster: CGFloat = 22

    /// Label frames by id (hidden labels are absent).
    static func layout(_ items: [Item], in bounds: CGRect, obstacles: [CGRect]) -> [String: CGRect] {
        let pins = items.filter(\.onScreen).map {
            CGRect(x: $0.anchor.x - pinClear, y: $0.anchor.y - pinClear, width: 2 * pinClear, height: 2 * pinClear)
        }
        var placed: [CGRect] = []
        var out: [String: CGRect] = [:]
        let order = items.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
        }
        var labelled: [(CGPoint, Int)] = []
        for (_, it) in order where it.onScreen {
            if it.priority < 100, labelled.contains(where: { hypot($0.0.x - it.anchor.x, $0.0.y - it.anchor.y) < cluster }) { continue }
            let ownPin = CGRect(x: it.anchor.x - pinClear, y: it.anchor.y - pinClear, width: 2 * pinClear, height: 2 * pinClear)
            for r in candidates(it) {
                guard bounds.contains(r) else { continue }
                if obstacles.contains(where: { $0.intersects(r) }) { continue }
                if placed.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(r) }) { continue }
                if pins.contains(where: { $0 != ownPin && $0.intersects(r) }) { continue }
                placed.append(r)
                out[it.id] = r
                labelled.append((it.anchor, it.priority))
                break
            }
        }
        return out
    }

    /// Above, then right, left, below, then above to either side (never stacked higher).
    static func candidates(_ it: Item) -> [CGRect] {
        let w = it.size.width, h = it.size.height, a = it.anchor
        let up = pinClear + gap
        let c: [CGRect] = [
            CGRect(x: a.x - w / 2, y: a.y - up - h, width: w, height: h),
            CGRect(x: a.x + up, y: a.y - h / 2, width: w, height: h),
            CGRect(x: a.x - up - w, y: a.y - h / 2, width: w, height: h),
            CGRect(x: a.x - w / 2, y: a.y + up, width: w, height: h),
            CGRect(x: a.x + up * 0.6, y: a.y - up - h, width: w, height: h),
            CGRect(x: a.x - up * 0.6 - w, y: a.y - up - h, width: w, height: h),
        ]
        return c
    }
}
