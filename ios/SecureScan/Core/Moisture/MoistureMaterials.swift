//
//  MoistureMaterials.swift
//  SecureScan
//
//  Material and source defaults for the moisture model (docs/MOISTURE.md
//  explains every number). Lengths are "wicking lengths": at steady state the
//  wetness falls by e (about 2.7x) every `wick` metres away from wet material.
//  `dryHours` is the drying time constant. Capacities are litres of free
//  water one square metre takes up before water runs on.
//

import Foundation

struct MoistFloorMaterial: Equatable {
    var wick: Double          // m, lateral wicking length
    var dryHours: Double
    var capacity: Double      // L/m² of free water held (soaked up, sitting, mopped) before it runs on
    var wetLevel: Double      // wetness of a flooded cell (0…1)
}

struct MoistLining: Equatable {
    var name: String
    var wickAlong: Double     // m, along the wall
    var wickUp: Double        // m, capillary rise
    var dryHours: Double
    var toCavity: Double      // coupling face <-> cavity through the lining (0…1)
    var toFloor: Double       // coupling face base <-> floor beside it
    var toPlate: Double       // coupling face base <-> bottom plate / wall base
    var underSkirting: Double // how freely free water passes between plate and this side's floor
    var capacity: Double      // L/m²
    var wetLevel: Double
    var fallSpeed: Double     // m/h, slow downward drift of moisture in the lining
}

struct MoistCore: Equatable {
    var wickAlong: Double
    var wickPlate: Double     // along the bottom plate / wall base
    var wickUp: Double
    var dryHours: Double
    var fallSpeed: Double     // m/h, gravity inside the wall
    var capacity: Double      // L/m² above the base
    var plateCapacity: Double // L/m² at the base row
    var wetLevel: Double
    var freePlate: Bool       // free water runs along the base and out under the skirting
}

enum MoistMaterials {

    static func floor(_ c: MoistCovering) -> MoistFloorMaterial {
        switch c {
        case .carpet:   return MoistFloorMaterial(wick: 1.10, dryHours: 72, capacity: 4.0, wetLevel: 1.0)   // carpet + underlay soak it up
        case .timber:   return MoistFloorMaterial(wick: 0.50, dryHours: 96, capacity: 3.5, wetLevel: 0.9)
        case .laminate: return MoistFloorMaterial(wick: 0.60, dryHours: 96, capacity: 3.5, wetLevel: 0.9)
        case .vinyl:    return MoistFloorMaterial(wick: 0.45, dryHours: 72, capacity: 4.0, wetLevel: 0.75)  // spreads under the sheet
        case .tile:     return MoistFloorMaterial(wick: 0.30, dryHours: 36, capacity: 5.0, wetLevel: 0.6)   // sits, is mopped, drains
        case .concrete: return MoistFloorMaterial(wick: 0.40, dryHours: 120, capacity: 4.0, wetLevel: 0.8)
        case .other:    return MoistFloorMaterial(wick: 0.55, dryHours: 72, capacity: 3.5, wetLevel: 0.85)
        }
    }

    static let plasterboard = MoistLining(name: "plasterboard", wickAlong: 0.35, wickUp: 0.45, dryHours: 48, toCavity: 0.4,
                                          toFloor: 1.0, toPlate: 1.0, underSkirting: 0.5, capacity: 0.1, wetLevel: 0.9, fallSpeed: 0.02)
    /// Tiles on a waterproofing membrane (wet areas): little passes either way.
    static let tiled = MoistLining(name: "tiled", wickAlong: 0.15, wickUp: 0.10, dryHours: 48, toCavity: 0.02,
                                   toFloor: 0.08, toPlate: 0.12, underSkirting: 0.04, capacity: 0.05, wetLevel: 0.5, fallSpeed: 0.02)
    /// Hard plaster / render on masonry.
    static let render = MoistLining(name: "render", wickAlong: 0.35, wickUp: 0.55, dryHours: 96, toCavity: 0.8,
                                    toFloor: 0.8, toPlate: 1.0, underSkirting: 0.3, capacity: 0.3, wetLevel: 0.9, fallSpeed: 0.01)

    static func lining(_ name: String?) -> MoistLining? {
        switch name?.lowercased() {
        case "plasterboard", "gyprock", "drywall": return plasterboard
        case "tiled", "tile", "tiles", "waterproofed", "membrane": return tiled
        case "render", "hardplaster", "hard plaster", "plaster": return render
        default: return nil
        }
    }

    /// Framed (stud) wall: an air gap with a timber bottom plate.
    static let stud = MoistCore(wickAlong: 0.25, wickPlate: 0.8, wickUp: 0.15, dryHours: 120, fallSpeed: 0.5,
                                capacity: 0.2, plateCapacity: 1.0, wetLevel: 1.0, freePlate: true)
    /// Solid masonry (single brick): the "cavity" layer is the brick core.
    static let masonry = MoistCore(wickAlong: 0.40, wickPlate: 0.40, wickUp: 0.50, dryHours: 168, fallSpeed: 0.05,
                                   capacity: 3.0, plateCapacity: 3.0, wetLevel: 0.9, freePlate: false)

    /// Floor-to-floor factor for a threshold type (1 = no hindrance, 0 = blocked).
    static func thresholdFactor(_ type: String) -> Double {
        switch type.lowercased() {
        case "none", "flush", "": return 1.0
        case "strip", "bar", "trim": return 0.35
        case "ramp", "reducer": return 0.25
        case "step", "raised", "hob": return 0.10
        case "sealed", "seal", "silicone", "waterstop": return 0.02
        case "barrier", "blocked": return 0
        default: return 0.35
        }
    }

    /// A doorway with no threshold recorded.
    static func doorwayFactor(_ x: MoistCovering, _ y: MoistCovering) -> Double { x == y ? 0.7 : 0.35 }
}

/// Default behaviour of each kind of source.
struct MoistSourceProfile: Equatable {
    enum Placement: String { case floor, face, cavity }
    var placement: Placement
    var litres: Double        // free water retained by the building at "moderate"
    var hours: Double         // typical age when inspected
}

enum MoistSourceProfiles {
    static func profile(_ t: MoistSourceType) -> MoistSourceProfile {
        switch t {
        case .flexiHose: return MoistSourceProfile(placement: .floor, litres: 40, hours: 24)
        case .appliance: return MoistSourceProfile(placement: .floor, litres: 25, hours: 24)
        case .shower:    return MoistSourceProfile(placement: .cavity, litres: 1.5, hours: 720)
        case .pipe:      return MoistSourceProfile(placement: .cavity, litres: 6, hours: 72)
        case .roof:      return MoistSourceProfile(placement: .face, litres: 4, hours: 48)
        case .window:    return MoistSourceProfile(placement: .face, litres: 2, hours: 48)
        case .unknown:   return MoistSourceProfile(placement: .floor, litres: 8, hours: 72)
        }
    }

    /// light / moderate / heavy / severe, or a number.
    static func intensity(_ any: Any?) -> Double? {
        if let n = MoistNum.number(any) { return n > 0 ? n : nil }
        switch (any as? String)?.lowercased() {
        case "light", "slow", "minor": return 0.35
        case "moderate", "medium": return 1
        case "heavy", "major": return 3
        case "severe", "flood": return 8
        default: return nil
        }
    }

    static func intensityName(_ x: Double) -> String {
        x < 0.6 ? "light" : x < 1.8 ? "moderate" : x < 5 ? "heavy" : "severe"
    }
}

/// Meter value (%) <-> model wetness (0…1). Wetness 0.2 = the damp threshold,
/// 0.4 = the wet threshold, 0 = the dry baseline (reference readings, else
/// two thirds of the damp threshold), 1 = soaked (wet + 2 x (wet - damp) + 10).
struct MoistScale: Equatable {
    static let dampLevel = 0.2
    static let wetLevel = 0.4

    var base: Double
    var damp: Double
    var wet: Double
    var saturated: Double

    init(thresholds t: MoistThresholds, references: [Double] = []) {
        damp = t.damp
        wet = max(t.wet, t.damp + 0.5)
        let refs = references.filter { $0 < t.damp }.sorted()
        let median = refs.isEmpty ? nil : refs[refs.count / 2]
        base = min(median ?? t.damp * 2 / 3, damp - 0.5)
        saturated = wet + 2 * (wet - damp) + 10
    }

    func wetness(_ v: Double) -> Double {
        if v <= base { return 0 }
        if v < damp { return MoistScale.dampLevel * (v - base) / (damp - base) }
        if v < wet { return MoistScale.dampLevel + (MoistScale.wetLevel - MoistScale.dampLevel) * (v - damp) / (wet - damp) }
        return min(1, MoistScale.wetLevel + (1 - MoistScale.wetLevel) * (v - wet) / (saturated - wet))
    }

    /// The meter value a wetness corresponds to (indicative only).
    func value(_ w: Double) -> Double {
        if w <= 0 { return base }
        if w < MoistScale.dampLevel { return base + (damp - base) * w / MoistScale.dampLevel }
        if w < MoistScale.wetLevel { return damp + (wet - damp) * (w - MoistScale.dampLevel) / (MoistScale.wetLevel - MoistScale.dampLevel) }
        return wet + (saturated - wet) * (min(w, 1) - MoistScale.wetLevel) / (1 - MoistScale.wetLevel)
    }

    static func state(_ w: Double) -> MoistState { w >= wetLevel ? .wet : w >= dampLevel ? .damp : .dry }

    func state(value v: Double) -> MoistState { v >= wet ? .wet : v >= damp ? .damp : .dry }
}
