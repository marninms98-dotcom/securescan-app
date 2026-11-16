//
//  FilesTab.swift
//  SecureScan
//
//  Job › Files: the job's facts, share actions, voice recordings, and the
//  maintenance actions under "Advanced".
//

import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: JobViewModel
    @State private var confirmRegenerate = false
    @State private var showAdvanced = false

    var body: some View {
        List {
            Section("Job") {
                fact("Address", vm.meta?.displayAddress ?? "–")
                if let ref = vm.meta?.jobRef, !ref.isEmpty { fact("Job / claim ref", ref) }
                fact("Rooms", "\(vm.meta?.roomCount ?? 0)")
                fact("Floor area", String(format: "%.1f m²", vm.meta?.totalArea ?? 0))
                fact("Readings", "\(vm.meta?.readingCount ?? 0)")
                if let v = vm.visitInfo { fact("Visit", "\(v.n) · \(v.label.isEmpty ? v.type.capitalized : v.label)") }
                fact("Started", (vm.meta?.createdAt ?? Date()).formatted(date: .abbreviated, time: .shortened))
            }

            Section("Share") {
                Button { vm.makeJobPack() } label: {
                    rowLabel("Job pack", systemImage: "shippingbox")
                }
                .disabled(!vm.hasPlan || vm.makingDocument)
                if vm.hasPlan {
                    ShareLink(item: vm.folder.planURL) { rowLabel("Plan file (plan.json)", systemImage: "doc.text") }
                }
                if vm.hasModel {
                    ShareLink(item: vm.folder.modelURL) { rowLabel("3D model (USDZ)", systemImage: "cube") }
                }
            }

            if !vm.recordings.isEmpty {
                Section("Voice recordings") {
                    ForEach(vm.recordings, id: \.file) { rec in
                        VoiceRow(rec: rec, busy: vm.voiceStatus != nil) { vm.transcribeAgain(rec) }
                    }
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    Button { confirmRegenerate = true } label: {
                        HStack {
                            rowLabel("Rebuild plan from scan", systemImage: "arrow.triangle.2.circlepath")
                            if vm.busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(vm.busy)
                    if let msg = vm.message {
                        Text(msg).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("Files app › On My iPhone › SecureScan › Jobs")
                        .font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                } label: {
                    Text("Advanced").font(DS.Font.body)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .onAppear { vm.recordings = JobFiles.loadVoice(vm.folder) }
        .confirmationDialog("Rebuild the plan from the scan?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Rebuild") { vm.regenerate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your marks, names and edits are kept.")
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).lineLimit(2).monospacedDigit()
        } label: {
            Text(title)
        }
        .font(DS.Font.body)
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(DS.Color.accent)
        }
        .font(DS.Font.body)
    }
}

struct VoiceRow: View {
    let rec: VoiceRecording
    let busy: Bool
    let transcribe: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.body).monospacedDigit()
                Text(stateText).font(DS.Font.caption).foregroundStyle(rec.state == "failed" ? DS.Color.damp : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if rec.state == "failed" || rec.state == "transcribed" {
                Button(rec.state == "failed" ? "Retry" : "Redo") { transcribe() }
                    .font(DS.Font.callout.weight(.semibold))
                    .foregroundStyle(DS.Color.accent)
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        }
    }

    private var title: String {
        var t = "Recording " + (Int(rec.number).map(String.init) ?? rec.number)
        if let d = ISOTime.date(rec.startedAt) { t += " · " + d.formatted(date: .omitted, time: .shortened) }
        if let s = rec.duration { t += " · " + MicButton.elapsed(s) }
        return t
    }

    private var stateText: String {
        switch rec.state {
        case "recording": return "Recording"
        case "saved": return "Waiting to transcribe"
        case "transcribed": return "\(rec.noteCount ?? 0) note\(rec.noteCount == 1 ? "" : "s") on the plan"
        default: return rec.error ?? "Not transcribed"
        }
    }
}
