//
//  NewJobFlow.swift
//  SecureScan
//
//  New scan: address pre-filled from a one-shot GPS fix + reverse geocode
//  (never blocks; editable), optional job ref, Start scanning -> ScanView.
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
    @State private var lastSuggestion = ""
    @State private var scanningJob: JobMeta?
    @State private var errorText: String?

    var body: some View {
        if let job = scanningJob {
            ScanView(job: job, onFinished: onComplete, onDiscarded: onCancel)
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Street address", text: $address, axis: .vertical)
                        .font(.title3)
                        .textInputAutocapitalization(.words)
                    if !location.status.isEmpty {
                        Text(location.status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Address") }

                Section {
                    TextField("Claim / job number (optional)", text: $jobRef)
                        .textInputAutocapitalization(.characters)
                } header: { Text("Job ref") }

                Section {
                    Text("Scan one room at a time: walk slowly around the walls, then tap Next room in the doorway. Tap Log to record a moisture reading, a moisture-line point, a photo or the water source at the crosshair. Tap Notes to record what you say as you go.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: start) {
                    Label("Start scanning", systemImage: "viewfinder")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
            .onAppear { location.start() }
            .onReceive(location.$suggestedAddress) { suggestion in
                // Fill in only if the user hasn't typed their own address.
                if let s = suggestion, address.isEmpty || address == lastSuggestion {
                    address = s
                    lastSuggestion = s
                }
            }
            .alert("Problem", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
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
    @Published var suggestedAddress: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var requested = false

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        handle(manager.authorizationStatus)
    }

    private func handle(_ s: CLAuthorizationStatus) {
        switch s {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !requested else { return }
            requested = true
            publish(status: "Finding address…")
            manager.requestLocation()
        default:
            publish(status: "Location is off — type the address.")
        }
    }

    /// nonisolated: called from CLGeocoder's completion handler, whatever thread
    /// or isolation the SDK gives it; it only hops to the main queue.
    nonisolated private func publish(status: String? = nil, address: String? = nil) {
        DispatchQueue.main.async {
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
                self.publish(status: "Couldn't look up the address — type it in.")
                return
            }
            let text = AddressFormatter.format(number: p.subThoroughfare, street: p.thoroughfare,
                                               suburb: p.locality, state: p.administrativeArea)
            self.publish(status: text.isEmpty ? "No street address found here — type it in." : "From GPS — check and edit if needed.",
                         address: text.isEmpty ? nil : text)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        publish(status: "Couldn't get a GPS fix — type the address.")
    }
}
