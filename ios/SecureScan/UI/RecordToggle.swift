//
//  RecordToggle.swift
//  SecureScan
//
//  The voice-note record control used outside the camera (job screen toolbar /
//  dock), in the design system's style: a mic IconButton, or a red dot with
//  the elapsed time while recording. Plus the one compatibility shim the job
//  screen still references (MarkupControls.accent) until it moves to DS.
//

import SwiftUI

struct RecordToggle: View {
    @ObservedObject var recorder: VoiceRecorder
    /// Kept for the existing call sites; both sizes now use the 44 pt control.
    var compact: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if recorder.isRecording, let start = recorder.startedAt {
                    HStack(spacing: 6) {
                        Circle().fill(DS.Color.wet).frame(width: 9, height: 9)
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(Self.elapsed(ctx.date.timeIntervalSince(start))).font(DS.Font.calloutBold).monospacedDigit()
                        }
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 17, weight: .semibold)).frame(width: DS.Size.icon)
                }
            }
            .frame(minHeight: DS.Size.icon)
            .contentShape(Capsule())
        }
        .buttonStyle(DSPressStyle())
        .accessibilityLabel(recorder.isRecording ? "Stop recording voice note" : "Record voice note")
    }

    static func elapsed(_ t: TimeInterval) -> String { Readout.elapsed(t) }
}

/// Compatibility: the job screen tints "See scope on site" with this. Prefer DS.Color.
enum MarkupControls {
    static func accent(_ w: WorkMode) -> Color {
        switch w {
        case .inspect, .monitor: return DS.Color.accent
        case .quote: return DS.Color.equip
        }
    }
}
