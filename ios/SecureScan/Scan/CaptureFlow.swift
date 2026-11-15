//
//  CaptureFlow.swift
//  SecureScan
//
//  The multi-tap captures shared by the scan screen and Return visit:
//    * wall removal: "Start here" (the Log frame) -> "End here" -> details
//    * flooring removal: corner taps on the floor (or Whole room) -> details
//  The screen owns the camera; this only keeps the state and the live
//  same-wall check (Core RemovalCheck).
//

import Foundation
import SwiftUI
import simd

/// A finished removal, ready for the screen to save.
struct RemovalDraft {
    var start: PendingLog
    var end: FrameCapture?
    var corners: [FrameCapture]
    var wholeRoom: Bool
    var item: String
    var heightMm: Int
    var note: String
    var floorType: String?
    var underlay: Bool
}

@MainActor
final class CaptureFlow: ObservableObject {
    enum Mode: Equatable { case idle, wallEnd, floorCorners }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var item = "plasterboard"
    @Published private(set) var cornerCount = 0
    @Published var showWallDetails = false
    @Published var showFloorDetails = false
    @Published var problem: String?
    /// Set when the end looked like a different wall; "Use anyway" accepts it.
    @Published private(set) var canUseAnyway = false

    private(set) var start: PendingLog?
    private(set) var end: FrameCapture?
    private(set) var corners: [FrameCapture] = []
    private(set) var wholeRoom = false
    private var questionableEnd: FrameCapture?

    var isBusy: Bool { mode != .idle || showWallDetails || showFloorDetails }

    static func vec(_ v: SIMD3<Float>?) -> WorldVec? { v.map { WorldVec(Double($0.x), Double($0.y), Double($0.z)) } }

    func begin(item: String, start: PendingLog) {
        cancel()
        self.item = item
        self.start = start
        mode = item == "flooring" ? .floorCorners : .wallEnd
    }

    /// "End here". Returns false when the end looks like a different wall
    /// (then `problem` explains, and `useEndAnyway()` accepts it).
    @discardableResult
    func setEnd(_ c: FrameCapture) -> Bool {
        guard let s = start else { return false }
        let same = RemovalCheck.sameWall(startHit: Self.vec(s.capture.hit), startNormal: Self.vec(s.capture.hitNormal),
                                         endHit: Self.vec(c.hit), endNormal: Self.vec(c.hitNormal))
        if same == false {
            questionableEnd = c
            canUseAnyway = true
            problem = "That looks like a different wall from the start. Point at the end of the same wall and tap End here again."
            return false
        }
        accept(c)
        return true
    }

    func useEndAnyway() {
        guard let c = questionableEnd else { return }
        accept(c)
    }

    private func accept(_ c: FrameCapture) {
        end = c
        questionableEnd = nil
        canUseAnyway = false
        problem = nil
        mode = .idle
        showWallDetails = true
    }

    /// Straight-line length of the stretch in metres, when both taps hit something.
    var lengthText: String? {
        guard let a = start?.capture.hit, let b = end?.hit else { return nil }
        let d = simd_distance(SIMD2<Float>(a.x, a.z), SIMD2<Float>(b.x, b.z))
        return String(format: "about %.1f m", d)
    }

    func addCorner(_ c: FrameCapture) {
        corners.append(c)
        cornerCount = corners.count
        problem = nil
    }

    func undoCorner() {
        guard !corners.isEmpty else { return }
        corners.removeLast()
        cornerCount = corners.count
    }

    func finishCorners() {
        guard corners.count >= 3 else {
            problem = "Tap at least 3 corners of the floor section."
            return
        }
        mode = .idle
        showFloorDetails = true
    }

    func useWholeRoom() {
        wholeRoom = true
        corners = []
        cornerCount = 0
        mode = .idle
        showFloorDetails = true
    }

    func cancel() {
        mode = .idle
        start = nil
        end = nil
        corners = []
        cornerCount = 0
        wholeRoom = false
        questionableEnd = nil
        canUseAnyway = false
        showWallDetails = false
        showFloorDetails = false
        problem = nil
    }

    /// The finished removal; the flow is reset.
    func finish(item: String, heightMm: Int, note: String, floorType: String?, underlay: Bool) -> RemovalDraft? {
        guard let s = start else { cancel(); return nil }
        let d = RemovalDraft(start: s, end: end, corners: corners, wholeRoom: wholeRoom, item: item, heightMm: heightMm,
                             note: note, floorType: floorType, underlay: underlay)
        cancel()
        return d
    }
}

/// The bar shown on the camera screen while a removal is being marked.
struct CaptureFlowBar: View {
    @ObservedObject var flow: CaptureFlow
    let onEndHere: () -> Void
    let onCorner: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Cancel") { flow.cancel() }.font(.headline)
            }
            if let p = flow.problem {
                Text(p).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                if flow.canUseAnyway {
                    Button("Use it anyway") { flow.useEndAnyway() }.buttonStyle(.bordered)
                }
            }
            switch flow.mode {
            case .wallEnd:
                Button(action: onEndHere) {
                    Label("End here", systemImage: "scope").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            case .floorCorners:
                HStack(spacing: 10) {
                    Button(action: onCorner) {
                        Label("Add corner", systemImage: "plus.viewfinder").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    Button { flow.finishCorners() } label: {
                        Text("Done").font(.title3.bold()).frame(minWidth: 70, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.cornerCount < 3)
                }
                HStack {
                    Button("Undo corner") { flow.undoCorner() }.disabled(flow.cornerCount == 0)
                    Spacer()
                    Button("Whole room") { flow.useWholeRoom() }
                }
                .font(.headline)
            case .idle:
                EmptyView()
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var title: String {
        switch flow.mode {
        case .wallEnd: return "Removal · \(RemovalItems.name(flow.item)): point at the END"
        case .floorCorners: return "Flooring: tap each corner · \(flow.cornerCount) so far"
        case .idle: return ""
        }
    }
}
