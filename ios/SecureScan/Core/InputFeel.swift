//
//  InputFeel.swift
//  SecureScan
//
//  The small rules behind fast AR inputs, kept pure so they are tested:
//  what the reticle says it is on, removal heights snapping to the usual
//  cuts, reading colours, the timed Undo chip, line / area readouts, the
//  mic timer, and what survives the app being killed mid-room.
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

/// What the reticle is on, said before the tap.
enum Reticle {
    enum Surface: String { case wall, floor, ceiling, cabinet, benchtop }

    /// From the hit's surface normal (y up), its height above the floor and,
    /// for upright surfaces, how far it is from the nearest scanned wall line
    /// (nil = no walls yet: treat it as a wall).
    static func surface(normalY: Double, height: Double, distanceToWall: Double?) -> Surface {
        if normalY > 0.7 { return height > 0.35 ? .benchtop : .floor }
        if normalY < -0.7 { return .ceiling }
        if let d = distanceToWall, d > 0.25 { return .cabinet }
        return .wall
    }

    static func name(_ s: Surface) -> String {
        switch s {
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .cabinet: return "Cabinet"
        case .benchtop: return "Benchtop"
        }
    }

    /// The reading material the surface suggests (nil: keep the last one).
    static func material(_ s: Surface) -> String? {
        switch s {
        case .wall: return nil              // wall or skirting: the user's choice stands
        case .floor: return "floor"
        case .ceiling: return "ceiling"
        case .cabinet, .benchtop: return "cabinetry"
        }
    }

    /// "Wall · 1.20 m · Kitchen". Height is left out on the floor.
    static func describe(_ s: Surface, height: Double?, room: String?) -> String {
        var parts = [name(s)]
        if s != .floor, let h = height, h.isFinite { parts.append(String(format: "%.2f m", max(0, h))) }
        if let r = room, !r.isEmpty { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    /// The big button when there is nothing to hit: why, never silence.
    static func blocked(trackingNormal: Bool, hasHit: Bool, needsWall: Bool) -> String? {
        if !trackingNormal { return "Move slowly — finding the room" }
        if !hasHit { return needsWall ? "Point at a wall" : "Move closer to a surface" }
        return nil
    }
}

/// Removal heights snap to the usual cuts.
enum HeightSnap {
    /// Skirting 100, 300, 600, 1200 mm, or the full wall.
    static func targets(wallHeightMm: Double) -> [Double] { [100, 300, 600, 1200, wallHeightMm] }

    /// The nearest target within `tolerance` mm, else the value rounded to 10 mm.
    static func snap(_ mm: Double, wallHeightMm: Double = 2400, tolerance: Double = 75) -> Double {
        let clamped = min(max(mm, 0), wallHeightMm)
        if let t = targets(wallHeightMm: wallHeightMm).min(by: { abs($0 - clamped) < abs($1 - clamped) }), abs(t - clamped) <= tolerance {
            return t
        }
        return (clamped / 10).rounded() * 10
    }

    /// The height of the cut suggested by where the END was tapped: snapped when
    /// the tap was clearly up the wall (250 mm or more), else nil (item default).
    static func suggested(endHeightMetres h: Double?, wallHeightMm: Double = 2400) -> Int? {
        guard let h, h.isFinite, h * 1000 >= 250 else { return nil }
        return Int(snap(h * 1000, wallHeightMm: wallHeightMm))
    }

    static func label(_ mm: Double, wallHeightMm: Double = 2400) -> String {
        abs(mm - wallHeightMm) < 1 ? "Full height" : "\(Int(mm.rounded())) mm"
    }
}

/// Wall stretches snap to the wall's ends.
enum WallEndSnap {
    /// t (0...1 along a wall of `length` m) snapped to 0 or 1 within `tolerance` m.
    static func snap(_ t: Double, length: Double, tolerance: Double = 0.15) -> Double {
        let c = min(max(t, 0), 1)
        guard length > 1e-6 else { return c }
        if c * length <= tolerance { return 0 }
        if (1 - c) * length <= tolerance { return 1 }
        return c
    }
}

extension WallEndSnap {
    /// A world point near a wall (a = one end, b = the other, any height):
    /// moved onto the wall's end when it is within `tolerance` m of it
    /// (measured along the wall, horizontally); its height is kept.
    static func snapPoint(_ p: WorldVec, wallA a: WorldVec, wallB b: WorldVec, tolerance: Double = 0.15) -> WorldVec {
        let a2 = PlanVec(a.x, a.z), b2 = PlanVec(b.x, b.z), q = PlanVec(p.x, p.z)
        let len = simd_distance(a2, b2)
        guard len > 1e-6 else { return p }
        let t = simd_dot(q - a2, b2 - a2) / (len * len)
        let s = snap(t, length: len, tolerance: tolerance)
        guard s == 0 || s == 1 else { return p }
        let e = s == 0 ? a2 : b2
        return WorldVec(e.x, p.y, e.y)
    }

    /// "Whole wall": the two ends, pulled in by `inset` m so they land on the
    /// wall itself, at `height` (world y).
    static func wholeWall(a: WorldVec, b: WorldVec, y: Double, inset: Double = 0.03) -> (WorldVec, WorldVec) {
        let a2 = PlanVec(a.x, a.z), b2 = PlanVec(b.x, b.z)
        let len = simd_distance(a2, b2)
        let k = len > 2 * inset ? inset / len : 0
        let p = a2 + (b2 - a2) * k, q = b2 + (a2 - b2) * k
        return (WorldVec(p.x, y, p.y), WorldVec(q.x, y, q.y))
    }
}

/// Reading colours by threshold, as the plan draws them.
enum ReadingColour {
    static func status(_ v: Double?, reference: Bool = false, damp: Double = 15, wet: Double = 20) -> String {
        Revisit.status(v, reference: reference, damp: damp, wet: wet)
    }
}

/// The Undo chip: shown for a few seconds after each save.
struct UndoWindow: Equatable {
    var lastSave: Date?
    var seconds: Double = 6

    mutating func saved(at t: Date) { lastSave = t }
    mutating func used() { lastSave = nil }
    func visible(at now: Date) -> Bool {
        guard let s = lastSave else { return false }
        let age = now.timeIntervalSince(s)
        return age >= 0 && age < seconds
    }
}

/// Running readouts while drawing lines and areas.
enum Readout {
    static func length(_ pts: [WorldVec]) -> Double {
        guard pts.count > 1 else { return 0 }
        return (1..<pts.count).reduce(0.0) { acc, i in
            let a = pts[i - 1], b = pts[i]
            return acc + simd_length(SIMD2<Double>(b.x - a.x, b.z - a.z))
        }
    }

    static func lengthText(_ m: Double) -> String { String(format: "%.2f m", m) }

    /// Area of the floor outline (x, z), open or closed.
    static func areaText(_ pts: [WorldVec]) -> String {
        let poly = pts.map { PlanVec($0.x, $0.z) }
        return String(format: "%.1f m²", poly.count >= 3 ? FloorArea.area(poly) : 0)
    }

    /// "1:05", "12:40", "1:02:03".
    static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// What a job holds after the app was killed mid-room (shown on reopen).
enum Recovery {
    struct Summary: Equatable {
        var items: Int                  // every logged item on disk
        var inUnfinishedRoom: Int       // logged while scanning a room that never finished
        var photosMissing: Int          // photo expected but not on disk (killed before it was written)
    }

    /// raw: (roomIndex, photo expected, photo on disk) per item; roomsSaved: finished rooms.
    static func summary(_ raw: [(roomIndex: Int, photoExpected: Bool, photoOnDisk: Bool)], roomsSaved: Int) -> Summary {
        Summary(items: raw.count,
                inUnfinishedRoom: raw.filter { $0.roomIndex >= roomsSaved }.count,
                photosMissing: raw.filter { $0.photoExpected && !$0.photoOnDisk }.count)
    }

    /// Every item id in plan.json's markup lists.
    static func planIds(_ plan: [String: Any]) -> Set<String> {
        let markup = plan["markup"] as? [String: Any] ?? [:]
        var ids = Set<String>()
        for k in ["readings", "sources", "equipment", "removals", "affected", "floors"] {
            for x in markup[k] as? [[String: Any]] ?? [] { if let id = x["id"] as? String { ids.insert(id) } }
        }
        return ids
    }

    /// Saved items (readings-raw.json) that never made it into the plan.
    static func unplaced(rawIds: [String], planIds: Set<String>) -> [String] {
        rawIds.filter { !planIds.contains($0) }
    }

    /// The job screen's banner after the app was closed mid-scan.
    static func banner(unplaced n: Int) -> String {
        "\(n) item\(n == 1 ? "" : "s") from an unfinished room \(n == 1 ? "was" : "were") kept"
    }

    static func message(_ s: Summary) -> String? {
        guard s.inUnfinishedRoom > 0 else { return nil }
        var text = "The app closed while a room was being scanned. All \(s.items) logged item\(s.items == 1 ? " is" : "s are") kept"
        text += s.photosMissing > 0 ? ", but \(s.photosMissing) photo\(s.photosMissing == 1 ? "" : "s") didn't finish saving." : "."
        text += " That room's walls were not saved: \(s.inUnfinishedRoom) item\(s.inUnfinishedRoom == 1 ? "" : "s") from it will be placed against the rooms that were saved (or by position). Use Files › Regenerate plan."
        return text
    }
}
