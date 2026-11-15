//
//  PhotoCapture.swift
//  SecureScan
//
//  The photo behind every tap. On a phone: ARSession.captureHighResolutionFrame
//  (iOS 16+) when the session gives one within 1.5 s, else the current camera
//  frame. Three outputs: the plan preview (max 1280 px long edge, JPEG 0.7 -
//  photoFile in readings-raw.json, unchanged), the full-resolution JPEG (0.85,
//  saved beside it as photos/<id>-full.jpg) and a small thumbnail.
//
//  0.5x: ARKit's world tracking does not offer the ultra-wide camera as a
//  video format on current iPhones (Apple: it is used internally and is not
//  configurable; iPhone 15 Pro Max lists only the wide camera). `ultraWideFormat`
//  checks at run time and the HUD shows the toggle only if a format exists,
//  and only on a session we configure ourselves (never during RoomPlan).
//

import Foundation
import ARKit
import CoreImage
import UIKit

enum PhotoCapture {

    /// Encodes the three outputs from a camera image (sensor orientation: landscape).
    static func encode(_ image: CIImage?, full: CIImage? = nil) -> CapturedPhoto? {
        guard let image else { return nil }
        let preview = FrameEncoder.jpeg(from: image, maxLongEdge: 1280, quality: 0.7)
        let fullData = FrameEncoder.jpeg(from: full ?? image, maxLongEdge: 100_000, quality: 0.85)
        let thumb = FrameEncoder.jpeg(from: image, maxLongEdge: 240, quality: 0.8).flatMap { UIImage(data: $0) }
        return CapturedPhoto(preview: preview, full: fullData, thumb: thumb)
    }

    /// The photo task for a tap: starts the high-resolution capture now.
    @MainActor
    static func task(session: ARSession?, frameImage: CIImage?) -> Task<CapturedPhoto?, Never> {
        let box = ImageBox(frameImage)
        guard let session else {
            return Task.detached(priority: .userInitiated) { encode(box.image) }
        }
        let wait = HighResWait()
        session.captureHighResolutionFrame { frame, _ in
            wait.resolve(frame.map { CIImage(cvPixelBuffer: $0.capturedImage) })
        }
        return Task.detached(priority: .userInitiated) {
            let high = await wait.value(timeout: 1.5)
            return encode(box.image, full: high)
        }
    }

    /// A video format on the ultra-wide camera for world tracking, if this device has one.
    static var ultraWideFormat: ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats.first { $0.captureDeviceType == .builtInUltraWideCamera }
    }
}

/// One-shot hand-over of the high-resolution image (completion or timeout, whichever first).
final class HighResWait: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CIImage?
    private var done = false
    private var waiter: CheckedContinuation<CIImage?, Never>?

    func resolve(_ img: CIImage?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        image = img
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: img)
    }

    func value(timeout: Double) async -> CIImage? {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resolve(nil) }
        return await withCheckedContinuation { (c: CheckedContinuation<CIImage?, Never>) in
            lock.lock()
            if done {
                let img = image
                lock.unlock()
                c.resume(returning: img)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }
}

/// Saves a tap's photo files beside each other in the job folder.
enum PhotoFiles {
    /// photos/<id>.jpg (preview) and photos/<id>-full.jpg. Returns false when the preview could not be written.
    static func write(_ p: CapturedPhoto, id: String, folder: JobFolder) -> Bool {
        try? FileManager.default.createDirectory(at: folder.photosDir, withIntermediateDirectories: true)
        guard let preview = p.preview,
              (try? preview.write(to: folder.photosDir.appendingPathComponent("\(id).jpg"), options: .atomic)) != nil else { return false }
        if let full = p.full { try? full.write(to: folder.photosDir.appendingPathComponent("\(id)-full.jpg"), options: .atomic) }
        return true
    }

    static func remove(id: String, folder: JobFolder) {
        try? FileManager.default.removeItem(at: folder.photosDir.appendingPathComponent("\(id).jpg"))
        try? FileManager.default.removeItem(at: folder.photosDir.appendingPathComponent("\(id)-full.jpg"))
    }
}
