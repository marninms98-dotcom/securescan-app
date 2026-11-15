//
//  Torch.swift
//  SecureScan
//
//  The torch, while ARKit (or RoomPlan) owns the back camera. ARKit runs the
//  back wide camera; its AVCaptureDevice can still take a torch setting
//  through lockForConfiguration. ARKit may switch the torch off when it
//  reconfigures the session (a new room, the 0.5x hand-off), so the button
//  shows the device's real state each time it is read.
//

import AVFoundation
import SwiftUI

enum Torch {
    private static var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    static var available: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return device?.hasTorch ?? false
        #endif
    }

    static var isOn: Bool { device?.torchMode == .on }

    /// Turns the torch on or off; false when the camera refused.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard let d = device, d.hasTorch else { return false }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if on {
                guard d.isTorchModeSupported(.on) else { return false }
                try d.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 0.8))
            } else {
                d.torchMode = .off
            }
            return true
        } catch {
            return false
        }
    }
}
