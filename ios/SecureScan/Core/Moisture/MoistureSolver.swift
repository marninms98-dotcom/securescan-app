//
//  MoistureSolver.swift
//  SecureScan
//
//  The two physics steps (docs/MOISTURE.md, "Physics"):
//
//  1. Free water ("like water in Minecraft"): from each source, liquid water
//     runs the cheapest way - straight down inside a wall or down a face,
//     along the bottom plate, out under the skirting, across the floor - and
//     every cell it reaches soaks up its capacity until the source's volume is
//     used up. Those cells are flooded (pinned at their wet level).
//  2. Wicking and drying: from the flooded cells moisture spreads by
//     capillarity (along floors, up wall faces, through linings) and is lost
//     by drying. Solved to steady state of
//         sum_j k_ji w_j - (sum_j k_ij + dry_i + 1/hours) w_i = 0
//     by projected successive over-relaxation, wetness kept in [lo_i, hi_i]
//     (0…1, narrowed by readings and the scoper's corrections). The 1/hours
//     term is the Laplace-transform form of "only `hours` have passed": young
//     leaks have not wicked as far yet.
//
//  Fixed iteration caps and tolerances, cells always visited in index order:
//  same input, same output.
//

import Foundation

struct MoistConductance {
    var inFrom: [Int]       // CSR (grid.inStart) position -> sending cell
    var inK: [Double]       // CSR position -> conductance into the cell
    var denom: [Double]     // per cell: total outflow + drying + 1/hours
    var omega: [Double]     // per cell over-relaxation
}

enum MoistSolver {

    /// Over-relaxation per surface. Floors and faces are symmetric diffusion and
    /// take strong over-relaxation; the cavity's gravity links make it one-sided,
    /// where anything much above 1 oscillates.
    static func omega(_ s: MoistSurface) -> Double { s == .floor ? 1.85 : s == .face ? 1.6 : 1.1 }

    static func conductance(_ g: MoistGrid, params: MoistParams, hours: Double) -> MoistConductance {
        let n = g.count
        var scale = Array(repeating: 1.0, count: 8)
        scale[MoistGrid.LinkClass.floor.rawValue] = params.floorSpread * params.floorSpread
        scale[MoistGrid.LinkClass.faceUp.rawValue] = params.rise * params.rise
        scale[MoistGrid.LinkClass.lining.rawValue] = params.lining
        var inFrom = Array(repeating: 0, count: g.inLink.count)
        var inK = Array(repeating: 0.0, count: g.inLink.count)
        var out = Array(repeating: 0.0, count: n)
        for p in 0..<g.inLink.count {
            let l = g.links[g.inLink[p]]
            let k = l.k0 * scale[l.cls.rawValue] + l.kg
            inFrom[p] = l.from
            inK[p] = k
            out[l.from] += k
        }
        let s = hours > 0 ? 1 / hours : 0
        var denom = Array(repeating: 1.0, count: n)
        var om = Array(repeating: 1.0, count: n)
        for i in 0..<n { denom[i] = out[i] + g.cells[i].dryRate + s; om[i] = omega(g.cells[i].surface) }
        return MoistConductance(inFrom: inFrom, inK: inK, denom: denom, omega: om)
    }

    // MARK: Free water

    /// Floods from `start` until `litres` are soaked up. Returns (cell, wetness) in the order reached.
    static func flood(_ g: MoistGrid, start: Int, litres: Double) -> [(cell: Int, wet: Double)] {
        guard start >= 0, start < g.count, litres > 0 else { return [] }
        var dist = Array(repeating: Double.infinity, count: g.count)
        var done = Array(repeating: false, count: g.count)
        var heap = MoistHeap()
        dist[start] = 0
        heap.push(0, start)
        var left = litres
        var out: [(cell: Int, wet: Double)] = []
        while left > 1e-9, let top = heap.pop() {
            let d = top.0
            if done[top.1] || d > dist[top.1] { continue }
            // Every cell at the same cost fills together, so ties never favour one side.
            var group = [top.1]
            done[top.1] = true
            while let next = heap.peek, next.0 <= d + 1e-9 {
                _ = heap.pop()
                if !done[next.1] && next.0 <= dist[next.1] { done[next.1] = true; group.append(next.1) }
            }
            var need = 0.0
            for c in group { need += max(g.cells[c].capacity, 1e-6) }
            let frac = min(1, left / need)
            left -= need * frac
            for c in group { out.append((c, g.cells[c].wetLevel * frac)) }
            for c in group {
                for e in g.flowStart[c]..<g.flowStart[c + 1] {
                    let to = g.flowTo[e]
                    let nd = d + g.flowCost[e]
                    if !done[to] && nd < dist[to] - 1e-12 { dist[to] = nd; heap.push(nd, to) }
                }
            }
        }
        return out
    }

    // MARK: Active cells

    /// Cells within `reach` metres (in hops of the cell size) of any seed. Others stay as they are.
    static func active(_ g: MoistGrid, seeds: [Int], reach: Double) -> [Bool] {
        var hops = Array(repeating: Int.max, count: g.count)
        var queue: [Int] = []
        for s in seeds where s >= 0 && s < g.count && hops[s] != 0 { hops[s] = 0; queue.append(s) }
        let limit = max(1, Int(reach / g.h))
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            let hc = hops[c]
            guard hc < limit else { continue }
            for p in g.inStart[c]..<g.inStart[c + 1] {
                let j = g.links[g.inLink[p]].from
                if hops[j] == Int.max { hops[j] = hc + 1; queue.append(j) }
            }
        }
        return hops.map { $0 != Int.max }
    }

    // MARK: Wicking

    /// Projected SOR. `pin[i] >= 0` fixes a cell (then kept inside [lo, hi]).
    static func solve(_ g: MoistGrid, _ k: MoistConductance, pin: [Double], lo: [Double], hi: [Double],
                      initial: [Double]?, active: [Bool], maxIterations: Int, tolerance: Double) -> (w: [Double], iterations: Int) {
        let n = g.count
        var w = initial ?? Array(repeating: 0.0, count: n)
        var order: [Int] = []
        order.reserveCapacity(n)
        for i in 0..<n {
            if pin[i] >= 0 {
                w[i] = min(max(pin[i], lo[i]), hi[i])
            } else if active[i] {
                w[i] = min(max(w[i], lo[i]), hi[i])
                order.append(i)
            } else {
                w[i] = min(max(0, lo[i]), hi[i])
            }
        }
        var iterations = 0
        w.withUnsafeMutableBufferPointer { W in
            k.inK.withUnsafeBufferPointer { K in
                k.inFrom.withUnsafeBufferPointer { F in
                    k.denom.withUnsafeBufferPointer { D in
                      k.omega.withUnsafeBufferPointer { OM in
                        g.inStart.withUnsafeBufferPointer { S in
                            lo.withUnsafeBufferPointer { LO in
                                hi.withUnsafeBufferPointer { HI in
                                    order.withUnsafeBufferPointer { O in
                                        for it in 0..<maxIterations {
                                            var maxDelta = 0.0
                                            for i in O {
                                                var acc = 0.0
                                                var p = S[i]
                                                let end = S[i + 1]
                                                while p < end { acc += K[p] * W[F[p]]; p += 1 }
                                                let old = W[i]
                                                var v = old + OM[i] * (acc / D[i] - old)
                                                if v < LO[i] { v = LO[i] }
                                                if v > HI[i] { v = HI[i] }
                                                let d = abs(v - old)
                                                if d > maxDelta { maxDelta = d }
                                                W[i] = v
                                            }
                                            iterations = it + 1
                                            if maxDelta < tolerance { break }
                                        }
                                    }
                                }
                            }
                        }
                      }
                    }
                }
            }
        }
        return (w, iterations)
    }
}

/// A small binary min-heap of (cost, cell); ties broken by cell index so the
/// flood order never depends on anything but the input.
struct MoistHeap {
    private var items: [(Double, Int)] = []

    var isEmpty: Bool { items.isEmpty }
    var peek: (Double, Int)? { items.first }

    private static func less(_ a: (Double, Int), _ b: (Double, Int)) -> Bool { a.0 < b.0 || (a.0 == b.0 && a.1 < b.1) }

    mutating func push(_ cost: Double, _ cell: Int) {
        items.append((cost, cell))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if MoistHeap.less(items[i], items[p]) { items.swapAt(i, p); i = p } else { break }
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && MoistHeap.less(items[l], items[m]) { m = l }
                if r < items.count && MoistHeap.less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m); i = m
            }
        }
        return top
    }
}
