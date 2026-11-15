//
//  FilesTab.swift
//  SecureScan
//
//  Share plan.json / model.usdz, job summary, and "Regenerate plan from scan".
//

import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: JobViewModel
    @State private var confirmRegenerate = false

    var body: some View {
        List {
            if vm.canReturnVisit {
                Section {
                    Button { vm.openReturnVisit() } label: {
                        Label("Return visit — find my points in the camera", systemImage: "viewfinder.circle")
                            .font(.headline)
                    }
                    Button { vm.remeasureOnPlan() } label: {
                        Label("Re-measure on the plan", systemImage: "square.split.2x2")
                    }
                } header: {
                    Text("Back on site")
                } footer: {
                    Text("Return visit lines the camera up with this job's plan (two corners, or automatically), then shows every saved point on its wall so you can re-measure it, log new items, mark equipment removed and removals done. Re-measure on the plan works on any phone.")
                }
            }
            Section("Job") {
                LabeledContent("Address", value: vm.meta?.displayAddress ?? "–")
                if let ref = vm.meta?.jobRef, !ref.isEmpty { LabeledContent("Job ref", value: ref) }
                LabeledContent("Rooms", value: "\(vm.meta?.roomCount ?? 0)")
                LabeledContent("Total floor area", value: String(format: "%.1f m²", vm.meta?.totalArea ?? 0))
                LabeledContent("Readings", value: "\(vm.meta?.readingCount ?? 0)")
                if let note = vm.meta?.note {
                    Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.orange)
                }
            }

            if !vm.recordings.isEmpty {
                Section {
                    ForEach(vm.recordings, id: \.file) { rec in
                        VoiceRow(rec: rec, busy: vm.voiceStatus != nil) { vm.transcribeAgain(rec) }
                    }
                } header: {
                    Text("Voice notes")
                } footer: {
                    Text("The audio is always kept in the job folder. Notes appear with the plan's site notes; corrections you make there are kept if you transcribe again.")
                }
            }

            Section("Share") {
                if vm.hasPlan {
                    ShareLink(item: vm.folder.planURL) { Label("Share plan.json", systemImage: "doc.text") }
                } else {
                    Text("No plan.json yet").foregroundStyle(.secondary)
                }
                if vm.hasModel {
                    ShareLink(item: vm.folder.modelURL) { Label("Share model.usdz (3D)", systemImage: "cube") }
                }
                Text("For the full job pack (summary, plans, photos, audio, 3D) use Export › Job pack on the Plan tab.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    confirmRegenerate = true
                } label: {
                    HStack {
                        Label("Regenerate plan from scan", systemImage: "arrow.triangle.2.circlepath")
                        if vm.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(vm.busy)
                if let msg = vm.message { Text(msg).font(.footnote) }
            } footer: {
                Text("Rebuilds walls, doors, rooms and the positions of readings and sources from the saved scan. Your markup, room names, address, job ref, site notes and edits to readings are kept.")
            }

            Section {
                Text("Files are also visible in the Files app under On My iPhone › SecureScan › Jobs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { vm.recordings = JobFiles.loadVoice(vm.folder) }
        .confirmationDialog("Regenerate the plan?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate") { vm.regenerate() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct VoiceRow: View {
    let rec: VoiceRecording
    let busy: Bool
    let transcribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: "waveform")
                Spacer()
                Text(stateText).font(.footnote).foregroundStyle(rec.state == "failed" ? Color.orange : Color.secondary)
            }
            if let e = rec.error, rec.state == "failed" {
                Text(e).font(.caption).foregroundStyle(.secondary)
            }
            if rec.state == "failed" || rec.state == "transcribed" {
                let label: String = rec.state == "failed" ? "Transcribe again" : "Transcribe again (keeps your corrections)"
                Button(label) { transcribe() }
                    .font(.callout)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        var t = rec.number
        if let d = ISOTime.date(rec.startedAt) { t += " · " + d.formatted(date: .omitted, time: .shortened) }
        if let s = rec.duration { t += " · " + RecordToggle.elapsed(s) }
        return t
    }

    private var stateText: String {
        switch rec.state {
        case "recording": return "Recording"
        case "saved": return "Waiting to transcribe"
        case "transcribed": return "\(rec.noteCount ?? 0) note\(rec.noteCount == 1 ? "" : "s")"
        default: return "Not transcribed"
        }
    }
}
