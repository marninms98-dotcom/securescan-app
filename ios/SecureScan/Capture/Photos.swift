//
//  Photos.swift
//  SecureScan
//
//  Seeing what you shot:
//    * PhotoCardView   - springs up bottom-left after the shutter for 2.5 s,
//                        showing the photo, with Retake; tap opens the viewer
//    * PhotoViewer     - full screen, black: every photo of the job, newest
//                        first, swipe through, pinch to zoom; Retake, Caption,
//                        Delete (with Undo); closes back to the camera as it was
//    * ZoomToggle      - the 0.5x / 1x capsule above the shutter
//    * UltraWideCaptureView - the 0.5x hand-off: ARKit's world tracking does
//                        not offer the ultra-wide camera, so the AR session is
//                        paused, the ultra-wide camera takes the photo through
//                        AVFoundation, and the AR session resumes; the photo is
//                        pinned where the reticle was when 0.5x was tapped.
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - The card after the shutter

struct PhotoCardView: View {
    let card: PhotoCard
    let onOpen: () -> Void
    let onRetake: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let img = card.image {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            DS.Color.ink.opacity(0.6)
                        }
                    }
                    .frame(width: 99, height: 132)
                    .clipped()
                    Text(card.tag).font(DS.Font.captionBold).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(DS.Color.ink.opacity(0.7)))
                        .padding(6)
                }
                .frame(width: 99, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(DSPressStyle())
            .accessibilityLabel("Open \(card.tag)")
            SecondaryButton("Retake", icon: "arrow.counterclockwise", action: onRetake)
                .padding(.top, 8)
        }
        .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity),
                                removal: .scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity)))
    }
}

// MARK: - The 0.5x / 1x toggle

struct ZoomToggle: View {
    let state: ZoomState
    @Binding var ultra: Bool
    var vertical = false
    let onBlocked: (String) -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            dot(".5", on: ultra, dim: state != .available) {
                if case .blocked(let why) = state { onBlocked(why); return }
                ultra = true
            }
            dot("1×", on: !ultra, dim: false) { ultra = false }
        }
        .padding(2)
        .dsCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ultra ? "Zoom 0.5 times" : "Zoom 1 times")
    }

    private func dot(_ t: String, on: Bool, dim: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: on ? 14 : 13, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(on ? DS.Color.modeOn : Color.white.opacity(dim ? 0.4 : 0.9))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(on ? 0.55 : 0.25)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSPressStyle())
    }
}

// MARK: - The viewer

struct PhotoViewer: View {
    @ObservedObject var hud: CaptureHUDModel
    let startId: String
    @State private var photos: [JobPhoto] = []
    @State private var index = 0
    @State private var pendingDelete: JobPhoto?
    @State private var deleteTask: Task<Void, Never>?
    @State private var captioning = false
    @State private var caption = ""

    private var current: JobPhoto? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if photos.isEmpty {
                Text("No photos yet").font(DS.Font.body).foregroundStyle(DS.Color.onCameraSecondary)
            } else {
                TabView(selection: $index) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { i, p in
                        ZoomableImage(load: p.load).tag(i).ignoresSafeArea()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                header
                Spacer()
                if let p = pendingDelete { undoBar(p) }
                if captioning { captionBar } else { bottomBar }
            }
        }
        .dsSurface(.camera)
        .statusBarHidden()
        .onAppear(perform: load)
        .onDisappear { commitDelete() }
    }

    private func load() {
        photos = hud.engine.jobPhotos()
        index = photos.firstIndex { $0.id == startId } ?? 0
    }

    private var header: some View {
        ZStack {
            HStack {
                IconButton("xmark", label: "Close") { commitDelete(); hud.viewerStart = nil }
                Spacer()
            }
            if let p = current {
                VStack(spacing: 1) {
                    Text("\(p.title) of \(photos.count)").font(DS.Font.calloutBold).monospacedDigit()
                    Text([p.place, p.caption].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.Font.caption).foregroundStyle(DS.Color.onCameraSecondary).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(minHeight: DS.Size.icon)
                .dsCapsule()
                .padding(.horizontal, DS.Size.icon + DS.Space.gap)
            }
        }
        .padding(.horizontal, DS.Space.margin)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: DS.Space.gap) {
            SecondaryButton("Retake", icon: "arrow.counterclockwise") {
                guard let p = current else { return }
                commitDelete()
                hud.beginRetake(p.id)
            }
            SecondaryButton("Caption", icon: "text.bubble") {
                caption = current?.caption ?? ""
                captioning = true
            }
            Spacer(minLength: 0)
            SecondaryButton("Delete", icon: "trash", role: .destructive) { delete() }
        }
        .padding(.horizontal, DS.Space.margin)
        .padding(.bottom, 8)
        .disabled(current == nil)
    }

    private var captionBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.tight) {
                    ForEach(["Overview", "Damage", "Source", "Inspection opening"], id: \.self) { c in
                        Chip(c, selected: caption == c) { caption = c }
                    }
                }
                .padding(.horizontal, DS.Space.margin)
            }
            .mask(FadeEdge())
            HStack(spacing: DS.Space.tight) {
                TextField("", text: $caption, prompt: Text("Caption").foregroundStyle(DS.Color.onCameraSecondary))
                    .font(DS.Font.body).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: DS.Size.minTarget)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(0.14)))
                SecondaryButton("Save") {
                    if let p = current { hud.caption(p.id, caption) }
                    captioning = false
                    load()
                }
            }
            .padding(.horizontal, DS.Space.margin)
        }
        .padding(.bottom, 8)
    }

    private func undoBar(_ p: JobPhoto) -> some View {
        HStack {
            Text("\(p.title) deleted").font(DS.Font.calloutBold).foregroundStyle(.white)
            Spacer()
            SecondaryButton("Undo", icon: "arrow.uturn.backward") {
                deleteTask?.cancel()
                pendingDelete = nil
                load()
                index = photos.firstIndex { $0.id == p.id } ?? index
            }
        }
        .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 4)
        .dsCapsule()
        .padding(.horizontal, DS.Space.margin)
        .padding(.bottom, DS.Space.tight)
    }

    /// Delete with a 5 s Undo; the item really goes when the window closes.
    private func delete() {
        guard let p = current else { return }
        commitDelete()
        pendingDelete = p
        photos.removeAll { $0.id == p.id }
        index = min(index, max(photos.count - 1, 0))
        DS.Haptic.undo()
        deleteTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            commitDelete()
        }
    }

    private func commitDelete() {
        guard let p = pendingDelete else { return }
        pendingDelete = nil
        deleteTask?.cancel()
        hud.deletePhoto(p.id)
    }
}

/// Pinch and double-tap zoom over one photo (UIScrollView: the native feel).
struct ZoomableImage: UIViewRepresentable {
    let load: () -> UIImage?

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.backgroundColor = .black
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.delegate = context.coordinator
        let iv = UIImageView(image: load())
        iv.contentMode = .scaleAspectFit
        iv.frame = sv.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sv.addSubview(iv)
        context.coordinator.imageView = iv
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(tap)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            sv.setZoomScale(sv.zoomScale > 1 ? 1 : 2.5, animated: true)
        }
    }
}

// MARK: - 0.5x: the ultra-wide hand-off

/// The back ultra-wide camera through AVFoundation (used while the AR session is paused).
final class UltraWideCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    static var exists: Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "securescan.ultrawide")
    private var completion: ((Data?) -> Void)?
    @Published var running = false

    func start() {
        queue.async { [self] in
            guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.maxPhotoQualityPrioritization = .quality
            }
            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async { self.running = true }
        }
    }

    func stop() { queue.async { [self] in session.stopRunning() } }

    func capture(_ done: @escaping (Data?) -> Void) {
        completion = done
        queue.async { [self] in
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async { self.completion?(data); self.completion = nil }
    }
}

struct UltraWidePreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        if let c = v.preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}
}

/// Full screen while the ultra-wide camera takes the photo; then back to the AR camera.
struct UltraWideCaptureView: View {
    let onDone: (CapturedPhoto?) -> Void
    @StateObject private var camera = UltraWideCamera()
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            UltraWidePreview(session: camera.session).ignoresSafeArea()
            VStack {
                HStack {
                    IconButton("xmark", label: "Back to 1×") { camera.stop(); onDone(nil) }
                    Spacer()
                    CameraCapsule(text: "0.5× photo", icon: "camera.aperture")
                    Spacer()
                    Color.clear.frame(width: DS.Size.icon, height: DS.Size.icon)
                }
                .padding(.horizontal, DS.Space.margin)
                Spacer()
                PrimaryButton(busy ? "Saving…" : "Take 0.5× photo", icon: "camera.fill", enabled: camera.running && !busy) {
                    busy = true
                    camera.capture { data in
                        camera.stop()
                        onDone(data.flatMap(PhotoCapture.encode(jpeg:)))
                    }
                }
                .padding(.horizontal, DS.Space.margin)
                .padding(.bottom, DS.Space.tight)
            }
        }
        .dsSurface(.camera)
        .statusBarHidden()
        .onAppear { camera.start() }
    }
}
