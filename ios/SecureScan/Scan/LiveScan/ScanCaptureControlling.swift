//
//  ScanCaptureControlling.swift
//  SecureScan
//
//  What ScanModel needs from a scan camera: the classic RoomCaptureView
//  screen (ScanViewController) or the new "mark while scanning" screen
//  (LiveScanViewController). Both report finished rooms with
//  ScanModel.roomProcessed(_:error:).
//

import Foundation
import ARKit

@MainActor
protocol ScanCaptureControlling: AnyObject {
    var arSession: ARSession? { get }
    func startRoom()
    func finishRoom()
    func shutdown()
    func captureFrame() -> FrameCapture?
    func saveWorldMap(to url: URL, timeout: Double) async -> Bool
}

extension ScanCaptureControlling {
    func saveWorldMap(to url: URL) async -> Bool { await saveWorldMap(to: url, timeout: 4) }
}

extension ScanViewController: ScanCaptureControlling {}
