//
//  VoiceRecorder.swift
//  SecureScan
//
//  Records spoken site notes: audio only, mono, into the job's audio/ folder.
//  One recorder for the whole app (only one recording at a time).
//
//  Never lose audio:
//   * While recording, audio is written straight to disk as 16 kHz 16-bit
//     PCM (audio/NNN.wav) by AVAudioRecorder. If the app is killed, the WAV's
//     size fields are repaired on the next open (WAVRepair) and nothing
//     recorded before that moment is lost. An AAC .m4a written live would be
//     unreadable after a crash (its index is written only when it is closed).
//   * When a recording stops it is converted to AAC mono audio/NNN.m4a (spec)
//     and the WAV is deleted only after the .m4a is complete.
//   * Audio session: .playAndRecord + .mixWithOthers + .defaultToSpeaker. It
//     records alongside the RoomPlan/ARKit session (which does not capture
//     audio - providesAudioData is off) and does not stop other audio.
//     UIBackgroundModes "audio" lets it keep recording when the screen locks.
//   * An interruption (phone call) or the recorder stopping on its own closes
//     the current file; recording continues in a new file afterwards
//     (`ensureRunning`, also called after Next room).
//

import Foundation
import AVFoundation

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = VoiceRecorder()

    /// The user wants to be recording (stays true across file changes).
    @Published private(set) var isRecording = false
    /// Start of this recording session, for the elapsed-time display.
    @Published private(set) var startedAt: Date?
    @Published var problem: String?

    private(set) var folder: JobFolder?
    /// "audio/001.m4a" whose WAV is being written now.
    private(set) var activeFile: String?
    private var recorder: AVAudioRecorder?
    private var conversions: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated { self?.handleInterruption(raw) }
        })
    }

    func isRecordingJob(_ folder: JobFolder) -> Bool { isRecording && self.folder == folder }
    func activeFileFor(_ folder: JobFolder) -> String? { self.folder == folder ? activeFile : nil }

    // MARK: Start / stop

    @discardableResult
    func start(folder: JobFolder) async -> Bool {
        if isRecording { return self.folder == folder }
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "SecureScan isn't allowed to use the microphone. Turn it on in Settings › SecureScan › Microphone."
            return false
        }
        self.folder = folder
        guard startSegment() else {
            self.folder = nil
            return false
        }
        startedAt = Date()
        isRecording = true
        return true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        startedAt = nil
        closeSegment()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Recording should be on but the recorder stopped (interruption, RoomPlan
    /// reconfiguring the session between rooms...): carry on in a new file.
    func ensureRunning() {
        guard isRecording else { return }
        if let r = recorder, r.isRecording { return }
        closeSegment()
        if !startSegment() {
            isRecording = false
            startedAt = nil
        }
    }

    /// Waits until every closed recording has been converted to .m4a.
    func waitForConversions() async {
        let pending = conversions
        conversions = []
        for t in pending { await t.value }
    }

    // MARK: Files

    private func startSegment() -> Bool {
        guard let folder else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: folder.audioDir, withIntermediateDirectories: true)
            var chosen = ""
            JobFiles.updateVoice(folder) { list in
                chosen = VoiceIndex.nextFile(existing: list, filesOnDisk: JobFiles.audioFiles(folder))
                list.append(VoiceRecording(file: chosen, startedAt: ISOTime.string(Date(), fractional: true),
                                           duration: nil, state: "recording", error: nil, noteCount: nil))
            }
            let entry = VoiceRecording(file: chosen, startedAt: "", duration: nil, state: "recording")
            let url = folder.url.appendingPathComponent(entry.wavFile)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            let began = Date()
            guard r.record() else {
                JobFiles.updateVoice(folder) { list in list.removeAll { $0.file == chosen } }
                try? FileManager.default.removeItem(at: url)
                problem = "The microphone couldn't start recording."
                return false
            }
            // The start time is when audio actually began.
            JobFiles.updateVoice(folder) { list in
                if let i = list.firstIndex(where: { $0.file == chosen }) {
                    list[i].startedAt = ISOTime.string(began, fractional: true)
                }
            }
            recorder = r
            activeFile = chosen
            return true
        } catch {
            problem = "Couldn't start recording: \(error.localizedDescription)"
            return false
        }
    }

    /// Closes the current WAV and converts it to .m4a in the background.
    private func closeSegment() {
        guard let folder else { return }
        if let r = recorder {
            let duration = r.currentTime
            r.stop()
            if let file = activeFile, duration > 0 {
                JobFiles.updateVoice(folder) { list in
                    if let i = list.firstIndex(where: { $0.file == file }) { list[i].duration = duration }
                }
            }
        }
        recorder = nil
        guard let file = activeFile else { return }
        activeFile = nil
        conversions.append(Task.detached(priority: .userInitiated) {
            VoiceProcessor.convert(folder: folder, file: file)
        })
    }

    private func handleInterruption(_ raw: UInt) {
        guard isRecording, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began: closeSegment()
        case .ended: ensureRunning()
        @unknown default: break
        }
    }

    // MARK: AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let r = self.recorder, ObjectIdentifier(r) == id else { return }
            // Stopped by the system, not by us: close it; ensureRunning restarts.
            self.closeSegment()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let r = self.recorder, ObjectIdentifier(r) == id else { return }
            self.closeSegment()
            self.ensureRunning()
        }
    }
}
