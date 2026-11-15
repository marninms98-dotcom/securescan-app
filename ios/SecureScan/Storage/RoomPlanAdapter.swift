//
//  RoomPlanAdapter.swift
//  SecureScan
//
//  The ONLY place that turns RoomPlan types into PlanBuilder's plain input
//  types. Uses iOS 17 members: Surface.parentIdentifier, Surface.polygonCorners,
//  CapturedRoom.floors, CapturedRoom.sections.
//

import Foundation
import RoomPlan
import simd

enum RoomPlanAdapter {

    static func room(_ r: CapturedRoom) -> PBRoom {
        PBRoom(walls: r.walls.map(surface),
               doors: r.doors.map(surface),
               windows: r.windows.map(surface),
               openings: r.openings.map(surface),
               floors: r.floors.map(surface),
               objects: r.objects.map(object),
               sectionLabels: r.sections.map { label($0.label) })
    }

    static func surface(_ s: CapturedRoom.Surface) -> PBSurface {
        PBSurface(id: s.identifier, parentId: s.parentIdentifier, transform: s.transform,
                  dimensions: s.dimensions, polygonCorners: s.polygonCorners)
    }

    static func object(_ o: CapturedRoom.Object) -> PBObject {
        PBObject(category: category(o.category), transform: o.transform, dimensions: o.dimensions)
    }

    /// RoomPlan category -> the exact strings listed in SPEC Contract 1.
    static func category(_ c: CapturedRoom.Object.Category) -> String {
        switch c {
        case .bed: return "bed"
        case .sofa: return "sofa"
        case .chair: return "chair"
        case .table: return "table"
        case .storage: return "storage"
        case .refrigerator: return "refrigerator"
        case .stove: return "stove"
        case .sink: return "sink"
        case .toilet: return "toilet"
        case .bathtub: return "bathtub"
        case .washerDryer: return "washerDryer"
        case .dishwasher: return "dishwasher"
        case .oven: return "oven"
        case .fireplace: return "fireplace"
        case .television: return "television"
        case .stairs: return "stairs"
        @unknown default: return "storage"
        }
    }

    static func label(_ l: CapturedRoom.Section.Label) -> String {
        switch l {
        case .bedroom: return "bedroom"
        case .bathroom: return "bathroom"
        case .kitchen: return "kitchen"
        case .livingRoom: return "livingRoom"
        case .diningRoom: return "diningRoom"
        case .unidentified: return "unidentified"
        @unknown default: return "unidentified"
        }
    }
}
