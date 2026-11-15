//
//  SettingsView.swift
//  SecureScan
//
//  Settings: "Show prices" behind the office PIN (set by the owner the first
//  time it is turned on). A convenience lock, not security - see PriceLock.
//

import SwiftUI

struct SettingsView: View {
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
                    if showPrices {
                        Button("Change office PIN") { pin = ""; pin2 = ""; problem = nil; asking = .change }
                    }
                } footer: {
                    Text(showPrices
                         ? "This phone shows rates and totals, and can make the Quote."
                         : "Prices are hidden: the crew can scope a job (Scope of works) without seeing any money. Turning prices on needs the office PIN.")
                }
                Section {
                    Toggle("Mark while scanning", isOn: $markWhileScanning)
                } footer: {
                    Text("New: scan the room and log readings, lines, photos and the scope on one screen. Off: the classic scan, then Mark up this room. Try it on a phone first.")
                }
                Section {
                    Text("The office PIN keeps prices off the crew's screens. It is a convenience lock, not security.")
                        .font(.footnote).foregroundStyle(.secondary)
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
