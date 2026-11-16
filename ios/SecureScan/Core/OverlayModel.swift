//
//  OverlayModel.swift
//  SecureScan
//
//  What the capture overlay draws, in world space, independent of how it is
//  drawn (Capture/OverlayRenderer.swift) and of which engine saved it.
//  Builders here turn the saved plan's markers (return visits, scope) into
//  overlay marks; the scan engines build theirs from readings-raw.json.
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

struct OverlayMark: Identifiable, Equatable {
    enum Style: Equatable {
        /// Moisture reading pin; status "dry" | "elevated" | "wet" | "none"; reference = hollow ring.
        case reading(status: String, reference: Bool)
        case photo
        /// Leak source: blue drop with a pulsing ring.
        case source
        /// Drying equipment on the floor; planned = outline only.
        case equipment(type: String, planned: Bool)
        /// Removal: skirting along the wall base (points = the two ends at floor level).
        case skirting
        /// Removal: wall lining band from the floor to `top` (points = the two ends at floor level).
        case lining
        /// Moisture line along a wall (points = the line).
        case moisture
        /// Floor areas (points = the outline at floor level).
        case wetFloor
        case liftFlooring
        /// In progress: a line from the start to the reticle.
        case lineDraft
        /// In progress: an area from the corners to the reticle.
        case areaDraft
        /// The reading being typed (frozen at the captured point).
        case readingDraft
        /// Cabinetry to remove: a box (points = its 8 corners, bottom 4 then top 4).
        case cabinet
        /// The component under the reticle before any tap (docs/MARKING.md B).
        case hover(HoverKind)
        /// Moisture extent on a wall: blue wash from the floor (`floorLevel`) up to the tide line
        /// (points = the tide line, wall order) with a wavy top edge.
        case moistureWash
        /// A small glass readout at a point ("0.6 m to wall end", "600 mm").
        case readout
        /// An air mover's coverage on the floor (points = [unit], airflow = direction).
        case airflowCone
    }

    enum HoverKind: Equatable {
        /// A wall's base edge (points = the two ends at floor level).
        case skirting
        /// A wall face (points = the quad), white; `faceBlue` in moisture's colour.
        case face, faceBlue
        /// An object's box (8 corners).
        case box
        /// A room's floor (outline).
        case floor
        /// A water-entry candidate (points = [the point]); `selected` = the one hovered.
        case ring
    }

    var id: String
    var style: Style
    /// Pin / glyph: one point. Line: two. Polyline / polygon: n.
    var points: [WorldVec]
    /// Lining bands: the cut height above the floor (metres).
    var top: Double? = nil
    /// Equipment: unit horizontal airflow direction (world).
    var airflow: WorldVec? = nil
    /// Text inside a pin ("18").
    var value: String? = nil
    /// The tag capsule ("R2", "Skirting · 2.35 m", "Shower leak").
    var tag: String? = nil
    var selected = false
    /// Earlier visit / already done: drawn quieter.
    var faded = false
    var needsFix = false
    /// Equipment drawn as a 3D model of this height (m): the overlay keeps the tag only,
    /// and lays it out above the model. nil = the 2D glyph.
    var modelHeight: Double? = nil
    /// A draft drawn in strip-out red instead of the accent.
    var removal = false
    /// Flooring: "carpet" | "vinyl" | "timber" | "tile" (the pattern); nil = plain.
    var floorType: String? = nil
    /// Moisture wash: the floor's height (world y).
    var floorLevel: Double? = nil
    /// Water source: confirmed (solid) rather than suspected (outlined ripple).
    var confirmed = false
    /// Strip-back: the cut line's handle is shown (it can be dragged).
    var handle = false
    /// Wall-attached marks: the wall and the side they are on ("a" / "b" by the wall's normal,
    /// "cavity" = inside the wall, shown on whichever face you look at). docs/MARKING.md H.
    var wallId: String? = nil
    var side: String? = nil
}

enum OverlayBuild {
    /// Status words the overlay colours by.
    static func status(_ v: Double?, reference: Bool, damp: Double = 15, wet: Double = 20) -> String {
        if reference { return "reference" }
        guard let v else { return "none" }
        return v < damp ? "dry" : (v < wet ? "elevated" : "wet")
    }

    /// A saved plan's markers (Revisit.markers) -> overlay marks in this session's world.
    static func marks(_ markers: [Revisit.Marker], walls: [PlanWall], alignment: PlanTransform, floorY: Double,
                      removalTags: [String: String] = [:]) -> [OverlayMark] {
        let byId = Dictionary(walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func w(_ p: PlanVec, _ h: Double) -> WorldVec { alignment.world(p, y: floorY + h) }
        var out: [OverlayMark] = []
        var lines: [String: [(t: Double, p: WorldVec, current: Bool)]] = [:]
        for m in markers {
            switch m.kind {
            case "reading":
                let n = m.label.components(separatedBy: " ").first ?? ""
                var mk = OverlayMark(id: m.id, style: .reading(status: m.status == "reference" ? "none" : m.status, reference: m.status == "reference"),
                                     points: [w(m.pos, m.height)], value: m.value.map(CaptureCopy.number), tag: "R" + n.replacingOccurrences(of: "R", with: ""))
                mk.faded = !m.measured
                out.append(mk)
            case "photo":
                out.append(OverlayMark(id: m.id, style: .photo, points: [w(m.pos, m.height)], tag: m.label))
            case "source":
                out.append(OverlayMark(id: m.id, style: .source, points: [w(m.pos, max(m.height, 0.05))], tag: m.label))
            case "equipment":
                let dir = m.dir.map { Airflow.worldDirection($0, transform: alignment) }
                out.append(OverlayMark(id: m.id, style: .equipment(type: m.type ?? "other", planned: false), points: [w(m.pos, 0)],
                                       airflow: dir, tag: m.label))
            case "boundary":
                if let wid = m.wallId, let t = m.wallT {
                    lines[wid, default: []].append((t, w(m.pos, m.height), m.measured))
                }
            case "affected":
                if let poly = m.polygon {
                    out.append(OverlayMark(id: m.id, style: .wetFloor, points: poly.map { w($0, 0.01) },
                                           tag: "\(m.label) · \(CaptureCopy.area(FloorArea.area(poly)))"))
                }
            case "removal":
                if let poly = m.polygon {
                    var mk = OverlayMark(id: m.id, style: .liftFlooring, points: poly.map { w($0, 0.01) },
                                         tag: "Flooring · \(CaptureCopy.area(FloorArea.area(poly)))")
                    mk.faded = m.done
                    out.append(mk)
                } else if let wid = m.wallId, let wall = byId[wid], let t0 = m.t0, let t1 = m.t1 {
                    let a = wall.a + (wall.b - wall.a) * t0, b = wall.a + (wall.b - wall.a) * t1
                    let len = abs(t1 - t0) * wall.length
                    let skirting = m.label.contains("skirting")
                    var mk = OverlayMark(id: m.id, style: skirting ? .skirting : .lining, points: [w(a, 0), w(b, 0)],
                                         top: skirting ? nil : (m.top ?? 0.6),
                                         tag: removalTags[m.id].map { "\($0) · " }.map { $0 + (skirting ? "Skirting" : "Wall lining") }
                                            ?? "\(skirting ? "Skirting" : "Wall lining") · \(CaptureCopy.length(len))")
                    mk.faded = m.done
                    out.append(mk)
                }
            default:
                break
            }
        }
        for (wid, pts) in lines.sorted(by: { $0.key < $1.key }) where pts.count >= 2 {
            let sorted = pts.sorted { $0.t < $1.t }
            var mk = OverlayMark(id: "line-\(wid)", style: .moisture, points: sorted.map(\.p), tag: "Moisture line")
            mk.faded = !sorted.contains { $0.current }
            out.append(mk)
        }
        return out
    }

    /// "See scope on site": the scope items -> overlay marks (planned equipment as outlines).
    static func marks(scope items: [ScopeItem], walls: [PlanWall], alignment: PlanTransform, floorY: Double) -> [OverlayMark] {
        let byId = Dictionary(walls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func w(_ p: PlanVec, _ h: Double) -> WorldVec { alignment.world(p, y: floorY + h) }
        return items.compactMap { it -> OverlayMark? in
            switch it.kind {
            case .equipment:
                var mk = OverlayMark(id: it.id, style: .equipment(type: it.equipmentType ?? "other", planned: !it.done),
                                     points: [w(it.pos, 0)], airflow: it.dir.map { Airflow.worldDirection($0, transform: alignment) },
                                     tag: it.tag)
                mk.faded = false
                return mk
            case .floor:
                guard let poly = it.polygon, poly.count >= 3 else { return nil }
                var mk = OverlayMark(id: it.id, style: .liftFlooring, points: poly.map { w($0, 0.01) }, tag: it.tag)
                mk.faded = it.done
                return mk
            case .wall:
                guard let wid = it.wallId, let wall = byId[wid], let t0 = it.t0, let t1 = it.t1 else { return nil }
                let a = wall.a + (wall.b - wall.a) * t0, b = wall.a + (wall.b - wall.a) * t1
                let skirting = it.title.contains("skirting")
                var mk = OverlayMark(id: it.id, style: skirting ? .skirting : .lining, points: [w(a, 0), w(b, 0)],
                                     top: skirting ? nil : it.top, tag: it.tag)
                mk.faded = it.done
                return mk
            }
        }
    }
}
