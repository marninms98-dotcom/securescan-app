//
//  NewJobFlow.swift
//  SecureScan
//
//  New job: address (typed, or "Use current location": a one-shot GPS fix +
//  reverse geocode; location permission is asked only on that tap), optional
//  job / claim number, Start -> the scan engine chosen in Settings.
//

import SwiftUI
import CoreLocation
import AVFoundation

struct NewJobFlow: View {
    let onComplete: (UUID) -> Void
    let onCancel: () -> Void

    @StateObject private var location = LocationFetcher()
    @State private var address = ""
    @State private var jobRef = ""
    @State private var scanningJob: JobMeta?
    @State private var errorText: String?
    @State private var needAddress = false
    @FocusState private var addressFocused: Bool
    /// "Scan and mark together (new)"; default from Settings › Mark while scanning.
    @State private var live = UserDefaults.standard.bool(forKey: "markWhileScanning")

    var body: some View {
        if let job = scanningJob {
            if live {
                LiveScanView(job: job, onFinished: onComplete, onDiscarded: onCancel, onClassic: { live = false })
            } else {
                ScanView(job: job, onFinished: onComplete, onDiscarded: onCancel)
            }
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Street address", text: $address, axis: .vertical)
                        .font(DS.Font.body)
                        .textInputAutocapitalization(.words)
                        .lineLimit(1...3)
                        .focused($addressFocused)
                        .onChange(of: address) { _, a in if !a.isEmpty { needAddress = false } }
                    Button { location.request() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "location.fill")
                                .foregroundStyle(DS.Color.accent)
                            Text("Use current location")
                                .foregroundStyle(DS.Color.accent)
                            Spacer(minLength: 8)
                            if location.finding {
                                ProgressView()
                            } else if !location.status.isEmpty {
                                Text(location.status)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .font(DS.Font.body)
                    }
                    .disabled(location.finding)
                } header: {
                    Text("Address")
                } footer: {
                    if needAddress {
                        Text("Add the address to start.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.wet)
                    }
                }

                Section {
                    TextField("Optional", text: $jobRef)
                        .font(DS.Font.body)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Job or claim number")
                }
            }
            .navigationTitle("New job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PrimaryButton("Start", icon: "viewfinder") {
                    guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        withAnimation(DS.Motion.tray) { needAddress = true }
                        addressFocused = true
                        DS.Haptic.warning()
                        return
                    }
                    live = UserDefaults.standard.bool(forKey: "markWhileScanning")
                    start()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onReceive(location.$suggestedAddress) { suggestion in
                // The user asked for it: fill in the address (still editable).
                if let s = suggestion { address = s }
            }
            .alert("Can't start", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    /// RoomPlan shows only a black view if camera access is off, so check first.
    private func start() {
        let cameraOff = "SecureScan isn't allowed to use the camera, which scanning needs. Turn it on in Settings › SecureScan › Camera."
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            createJobAndScan()
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { createJobAndScan() } else { errorText = cameraOff }
            }
        default:
            errorText = cameraOff
        }
    }

    private func createJobAndScan() {
        do {
            scanningJob = try JobFiles.create(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                              jobRef: jobRef.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            errorText = "Couldn't create the job folder: \(error.localizedDescription)"
        }
    }
}

/// One-shot location + reverse geocode. Plain (non-actor) class; published
/// values are always set on the main queue. Never blocks the form.
final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var status = ""
    @Published var finding = false
    @Published var suggestedAddress: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    /// Set by the "Use current location" tap; permission is asked only then.
    private var wanted = false

    func request() {
        wanted = true
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        handle(manager.authorizationStatus)
    }

    private func handle(_ s: CLAuthorizationStatus) {
        guard wanted else { return }
        switch s {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            wanted = false
            publish(status: "", finding: true)
            manager.requestLocation()
        default:
            wanted = false
            publish(status: "Location is off", finding: false)
        }
    }

    /// nonisolated: called from CLGeocoder's completion handler, whatever thread
    /// or isolation the SDK gives it; it only hops to the main queue.
    nonisolated private func publish(status: String? = nil, address: String? = nil, finding: Bool? = false) {
        DispatchQueue.main.async {
            if let finding { self.finding = finding }
            if let status { self.status = status }
            if let address { self.suggestedAddress = address }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handle(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // CLGeocoder is deprecated from iOS 26 (MapKit's reverse geocoding
        // replaces it) but still works; kept for iOS 17 support.
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, error in
            guard let self else { return }
            guard let p = placemarks?.first, error == nil else {
                self.publish(status: "No address found")
                return
            }
            let text = AddressFormatter.format(number: p.subThoroughfare, street: p.thoroughfare,
                                               suburb: p.locality, state: p.administrativeArea)
            self.publish(status: text.isEmpty ? "No address found" : "",
                         address: text.isEmpty ? nil : text)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        publish(status: "No GPS fix")
    }
}
