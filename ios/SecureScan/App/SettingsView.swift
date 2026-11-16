//
//  SettingsView.swift
//  SecureScan
//
//  Settings: "Show prices" behind the office PIN (set by the owner the first
//  time it is turned on; a convenience lock, not security - see PriceLock),
//  the scan engine, a demo job, version.
//

import SwiftUI

struct SettingsView: View {
    /// "Add a demo job": the jobs list makes it and opens it.
    var onAddDemo: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showPrices = PriceLock.pricesVisible
    @State private var asking: Ask?
    @State private var pin = ""
    @State private var pin2 = ""
    @State private var problem: String?
    @AppStorage("markWhileScanning") private var markWhileScanning = false

    enum Ask: Identifiable {
        case setNew, enter, change
        var id: Int { hashValue }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String ?? "–"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show prices", isOn: Binding(get: { showPrices }, set: { on in
                        if on {
                            pin = ""; pin2 = ""; problem = nil
                            asking = PriceLock.hasPIN ? .enter : .setNew
                        } else {
                            PriceLock.pricesVisible = false
                            showPrices = false
                        }
                    }))
                    .tint(DS.Color.accent)
                    if showPrices {
                        Button("Change office PIN") { pin = ""; pin2 = ""; problem = nil; asking = .change }
                    }
                } header: {
                    Text("Prices")
                } footer: {
                    Text(showPrices ? "Rates and quotes show on this iPhone." : "Crew see the scope, not the money.")
                }

                Section {
                    Picker("Scan engine", selection: $markWhileScanning) {
                        Text("Classic").tag(false)
                        Text("Scan and mark").tag(true)
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                } header: {
                    Text("Scanning")
                } footer: {
                    Text(markWhileScanning ? "Mark readings and removals while the room scans." : "Scan each room first, then mark it up.")
                }

                if let onAddDemo {
                    Section {
                        Button("Add a demo job", action: onAddDemo)
                    } footer: {
                        Text("A sample house to try the plan, 3D and documents.")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("LiDAR scanning", value: JobsListView.lidarSupported ? "Available" : "Not on this iPhone")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $asking) { ask in pinSheet(ask) }
        }
    }

    private func pinSheet(_ ask: Ask) -> some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(ask == .enter ? "Office PIN" : "New office PIN (4–8 digits)", text: $pin)
                        .keyboardType(.numberPad)
                    if ask != .enter {
                        SecureField("Same PIN again", text: $pin2).keyboardType(.numberPad)
                    }
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle(ask == .enter ? "Office PIN" : (ask == .setNew ? "Set the office PIN" : "Change the office PIN"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { asking = nil } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { confirm(ask) } }
            }
        }
        .presentationDetents([.medium])
    }

    private func confirm(_ ask: Ask) {
        switch ask {
        case .enter:
            guard PriceLock.check(pin) else { problem = "That isn't the office PIN."; return }
        case .setNew, .change:
            guard PinRule.valid(pin) else { problem = "Use 4 to 8 digits."; return }
            guard pin == pin2 else { problem = "The two PINs don't match."; return }
            guard PriceLock.setPIN(pin) else { problem = "The PIN couldn't be saved."; return }
        }
        if ask != .change {
            PriceLock.pricesVisible = true
            showPrices = true
        }
        asking = nil
    }
}
