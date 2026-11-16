//
//  MoistureTypes.swift
//  SecureScan
//
//  The moisture model's inputs and settings (docs/MOISTURE.md). Pure value
//  types, Foundation + simd only, no UIKit. Everything is in metres, plan
//  coordinates as in docs/SPEC.md (x right, y down the page).
//
//  Wall sides (docs/MARKING.md convention): a wall runs a -> b, its direction
//  is d = (b - a) / |b - a| and its normal is n = (-d.y, d.x) (the editor's
//  `perp`). Side "a" is the +n side (the editor's side +1), side "b" the -n
//  side (-1). "cavity" is inside the wall.
//

import Foundation
import simd

typealias MoistVec = SIMD2<Double>

/// Which layer of the building a cell or a mark is on.
enum MoistSurface: String, Equatable {
    case floor, face, cavity
}

/// A wall side. `.cavity` = inside the wall.
enum MoistSide: String, Equatable {
    case a, b, cavity

    /// "a" / "b" / "cavity", and the editor's +1 / -1.
    static func parse(_ any: Any?) -> MoistSide? {
        if let s = any as? String {
            if let side = MoistSide(rawValue: s.lowercased()) { return side }
            if s == "+1" || s == "1" { return MoistSide.a }
            if s == "-1" { return MoistSide.b }
            return nil
        }
        if let n = MoistNum.number(any) {
            if n > 0 { return MoistSide.a }
            if n < 0 { return MoistSide.b }
        }
        return nil
    }

    /// +1 for a, -1 for b, 0 for the cavity.
    var sign: Double { self == .a ? 1 : self == .b ? -1 : 0 }
}

/// Dry / damp (elevated) / wet, by the job's thresholds.
enum MoistState: String, Equatable {
    case dry, damp, wet
}

/// Where a cell's value comes from. Reports keep these apart.
enum MoistProvenance: String, Equatable {
    case measured     // within reach of a moisture reading (backed by a meter)
    case estimated    // physics only — a guide, not a measurement
    case scoper       // set by the scoper's own correction
}

enum MoistNum {
    /// Reads a JSON number whether it arrived as Int, Double or NSNumber.
    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d.isFinite ? d : nil }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        return nil
    }

    static func point(_ any: Any?) -> MoistVec? {
        guard let a = any as? [Any], a.count >= 2, let x = number(a[0]), let y = number(a[1]) else { return nil }
        return MoistVec(x, y)
    }

    static func points(_ any: Any?) -> [MoistVec] {
        guard let a = any as? [Any] else { return [] }
        return a.compactMap { point($0) }
    }

    static func r3(_ x: Double) -> Double { x.isFinite ? (x * 1000).rounded() / 1000 : 0 }
    static func r2(_ x: Double) -> Double { x.isFinite ? (x * 100).rounded() / 100 : 0 }
}

// MARK: - Geometry

struct MoistWall: Equatable {
    var id: String
    var a: MoistVec
    var b: MoistVec
    var height: Double = 2.4

    var length: Double { simd_length(b - a) }
    var dir: MoistVec { let l = length; return l > 1e-9 ? (b - a) / l : MoistVec(1, 0) }
    /// The editor's perp(d): side "a" is this way.
    var normal: MoistVec { let d = dir; return MoistVec(-d.y, d.x) }
    func point(along s: Double) -> MoistVec { a + dir * s }
    /// Metres along the wall of the foot of `p`.
    func along(_ p: MoistVec) -> Double { simd_dot(p - a, dir) }
    /// Signed distance of `p` from the wall line (+ = side a).
    func offset(_ p: MoistVec) -> Double { simd_dot(p - a, normal) }
}

struct MoistOpening: Equatable {
    var id: String
    var type: String          // door | window | opening
    var wallId: String?
    var a: MoistVec
    var b: MoistVec
    var sill: Double = 0
    var height: Double = 2.04

    var isPassage: Bool { type == "door" || type == "opening" }
}

struct MoistRoom: Equatable {
    var id: String
    var name: String = ""
    var polygon: [MoistVec]
}

/// Floor coverings (markup.floors[].type).
enum MoistCovering: String, CaseIterable, Equatable {
    case carpet, timber, laminate, vinyl, tile, concrete, other

    static func parse(_ s: String?) -> MoistCovering {
        guard let s = s?.lowercased() else { return .other }
        if let c = MoistCovering(rawValue: s) { return c }
        if s.contains("carpet") { return .carpet }
        if s.contains("tile") { return .tile }
        if s.contains("vinyl") || s.contains("lino") { return .vinyl }
        if s.contains("lamin") { return .laminate }
        if s.contains("timber") || s.contains("wood") || s.contains("board") { return .timber }
        if s.contains("concrete") || s.contains("slab") { return .concrete }
        return .other
    }
}

struct MoistFloorZone: Equatable {
    var id: String
    var polygon: [MoistVec]
    var covering: MoistCovering
}

/// Where two floor finishes meet (markup.floorThresholds).
struct MoistFloorThreshold: Equatable {
    var id: String
    var a: MoistVec
    var b: MoistVec
    var type: String          // none | strip | ramp | step | sealed
}

// MARK: - Sources

enum MoistSourceType: String, CaseIterable, Equatable {
    case flexiHose, shower, pipe, roof, window, appliance, unknown

    /// From a free-text label ("Burst flexi hose", "Shower mixer", …).
    static func infer(_ label: String) -> MoistSourceType {
        let s = label.lowercased()
        if s.contains("flexi") || s.contains("hose") { return .flexiHose }
        if s.contains("shower") || s.contains("mixer") || s.contains("bath") || s.contains("spout") { return .shower }
        if s.contains("roof") || s.contains("ceiling") || s.contains("gutter") { return .roof }
        if s.contains("window") || s.contains("door frame") || s.contains("sliding") { return .window }
        if s.contains("wash") || s.contains("dishwasher") || s.contains("appliance") || s.contains("fridge")
            || s.contains("hot water") || s.contains("hws") || s.contains("tap") { return .appliance }
        if s.contains("pipe") || s.contains("plumb") || s.contains("burst") { return .pipe }
        return .unknown
    }
}

struct MoistSource: Equatable {
    var id: String
    var label: String = ""
    var type: MoistSourceType
    var pos: MoistVec
    var wallId: String?
    var height: Double?
    /// nil = decide from the type (shower/pipe -> cavity, window/roof -> face, else floor).
    var side: MoistSide?
    /// "floor" forces a floor source even when it sits on a wall line.
    var onFloor: Bool = false
    /// Multiplier on the type's default volume (1 = moderate).
    var intensity: Double = 1
    /// True when the scoper set the intensity: the fit leaves it alone.
    var intensityFixed: Bool = false
}

// MARK: - Readings

struct MoistReading: Equatable {
    enum Kind: String { case reading, boundary }
    var id: String
    var n: Int?
    var kind: Kind = .reading
    var value: Double?
    var material: String = ""
    var pos: MoistVec
    var wallId: String?
    var height: Double?
    var side: MoistSide?
    var cam: MoistVec?
    var reference: Bool = false

    var label: String { n.map { "Reading \($0)" } ?? (kind == .boundary ? "Moisture line mark" : "Reading \(id)") }
    var isTiled: Bool { let m = material.lowercased(); return m.contains("tile") || m.contains("tiling") }
}

// MARK: - Scoper tweaks

/// One correction by the scoper, stored in markup.moistureModel.tweaks so
/// another phone or the report reproduces the same result. Applied in order.
struct MoistTweak: Equatable {
    enum Kind: String {
        case brush          // paint cells wet / damp / dry (hard constraint, re-fits)
        case tideLine       // drag the tide line on a wall face: points = (along m, height m)
        case floorOutline   // drag the wet floor boundary: points = polygon (plan)
        case barrier        // "no spread past here" on the floor: points = [a, b]
        case source         // adjust a source: intensity / type / placement
        case lining         // a wall face's lining: plasterboard | tiled | render
        case construction   // a wall's build: stud | masonry
    }
    var id: String
    var kind: Kind
    var surface: MoistSurface?
    var wallId: String?
    var side: MoistSide?
    var points: [MoistVec] = []
    var radius: Double = 0.25
    var state: MoistState?
    var sourceId: String?
    var intensity: Double?
    var sourceType: String?
    var placement: String?
    var value: String?          // lining / construction value
    var at: String?
}

// MARK: - Settings, parameters, input

/// The fitted (or default) model parameters. Multipliers are on the
/// material defaults; volumes in litres of free water per source.
struct MoistParams: Equatable {
    var floorSpread: Double = 1      // wicking length on floors
    var rise: Double = 1             // capillary rise up wall faces
    var lining: Double = 1           // how easily water passes face <-> cavity
    var volumes: [String: Double] = [:]   // source id -> litres

    static let bounds = (min: 0.4, max: 2.5)
}

struct MoistOptions: Equatable {
    var cellSize: Double = 0.10
    var fitCellSize: Double = 0.20
    var maxWallHeight: Double = 1.2
    /// Hours since the event; nil = the sources' typical age.
    var hoursSinceEvent: Double?
    /// Fit parameters to readings (false = defaults / stored params only).
    var fit: Bool = true
    /// Cells beyond this graph distance from any wet seed are not iterated.
    var reach: Double = 4.5
    /// Readings pull cells within this radius (same surface).
    var readingRadius: Double = 0.4
    var maxIterations: Int = 220
    var fitIterations: Int = 80
}

struct MoistThresholds: Equatable {
    var damp: Double = 15
    var wet: Double = 20
}

struct MoistInput: Equatable {
    var walls: [MoistWall] = []
    var openings: [MoistOpening] = []
    var rooms: [MoistRoom] = []
    var floors: [MoistFloorZone] = []
    var floorThresholds: [MoistFloorThreshold] = []
    var sources: [MoistSource] = []
    var readings: [MoistReading] = []
    var thresholds = MoistThresholds()
    var tweaks: [MoistTweak] = []
    var options = MoistOptions()
}
