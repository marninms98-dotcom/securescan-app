//
//  ScanCaptureControlling.swift
//  SecureScan
//
//  What ScanModel needs from a scan camera: the classic RoomCaptureView
//  screen (ScanViewController) or the live screen (LiveScanViewController).
//  Both report finished rooms with ScanModel.roomProcessed(_:error:) and
//  publish the room found so far, so the capture screen can aim, snap and
//  draw against real walls while scanning.
//

import Foundation
import ARKit

@MainActor
protocol ScanCaptureControlling: AnyObject {
    var arSession: ARSession? { get }
    func startRoom()
    func finishRoom()
    func shutdown()
    func saveWorldMap(to url: URL, timeout: Double) async -> Bool
    /// Rooms finished in this session plus the one being scanned (session world space).
    var liveWorld: CaptureWorld { get }
    /// RoomPlan's section labels of the room being scanned.
    var liveSections: [String] { get }
    /// RoomPlan's latest coaching, in plain words (nil = none).
    var coaching: String? { get }
}

extension ScanCaptureControlling {
    func saveWorldMap(to url: URL) async -> Bool { await saveWorldMap(to: url, timeout: 4) }
}
