//
//  MarkupGeometry.swift
//  SecureScan
//
//  Small pure helpers for the 3D view: which moisture-line marks join up, and
//  how far back the camera must be to see the whole model. simd only - unit
//  tested.
//

import Foundation
import simd

enum MoistureLines {
    struct Mark {
        var id: String
        var wallId: String?
        var wallT: Double?
    }

    /// Ids of kind "boundary" marks grouped per wall, each group in wallT
    /// order. Only walls with 2+ marks form a line. Walls in order of first
    /// appearance.
    static func lines(_ marks: [Mark]) -> [[String]] {
        var order: [String] = []
        var byWall: [String: [Mark]] = [:]
        for m in marks {
            guard let w = m.wallId, m.wallT != nil else { continue }
            if byWall[w] == nil { order.append(w) }
            byWall[w, default: []].append(m)
        }
        return order.compactMap { w in
            let ms = byWall[w]!.enumerated().sorted { a, b in
                let ta = a.element.wallT!, tb = b.element.wallT!
                return ta == tb ? a.offset < b.offset : ta < tb
            }.map { $0.element.id }
            return ms.count >= 2 ? ms : nil
        }
    }
}

enum CameraFit {
    /// Unit direction from the target towards the camera, for an elevated
    /// three-quarter view: `azimuth` degrees round from +Z towards +X,
    /// `elevation` degrees above the horizon.
    static func direction(azimuthDegrees: Double, elevationDegrees: Double) -> SIMD3<Double> {
        let az = azimuthDegrees * .pi / 180, el = elevationDegrees * .pi / 180
        return simd_normalize(SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el)))
    }

    /// Smallest distance from `target` along `direction` at which every point
    /// fits inside the view (tanH / tanV = tangent of half the horizontal /
    /// vertical field of view), keeping `margin` (0.9 = 10 % border).
    static func distance(points: [SIMD3<Double>], target: SIMD3<Double>, direction: SIMD3<Double>,
                         tanH: Double, tanV: Double, margin: Double = 0.88) -> Double {
        guard !points.isEmpty else { return 5 }
        let back = simd_normalize(direction)                  // camera looks along -back
        let worldUp = SIMD3<Double>(0, 1, 0)
        var right = simd_cross(worldUp, back)
        if simd_length(right) < 1e-6 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(back, right)
        func fits(_ d: Double) -> Bool {
            let cam = target + back * d
            for p in points {
                let v = p - cam
                let z = -simd_dot(v, back)                    // depth in front of the camera
                guard z > 0.05 else { return false }
                if abs(simd_dot(v, right)) / z > tanH * margin { return false }
                if abs(simd_dot(v, up)) / z > tanV * margin { return false }
            }
            return true
        }
        var lo = 0.1, hi = 1.0
        while !fits(hi) && hi < 10_000 { hi *= 2 }
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if fits(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }
}
