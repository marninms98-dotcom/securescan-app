//
//  VoiceProcessor.swift
//  SecureScan
//
//  After a recording: WAV -> AAC mono .m4a, recovery of recordings that were
//  cut off, transcription, and merging the notes into plan.json
//  (markup.notes, docs/SPEC.md addendum v1.4). All of it runs off the main
//  thread.
//

import Foundation
import AVFoundation

enum VoiceProcessor {

    /// Shorter recordings are treated as an accidental tap and removed.
    static let minimumDuration = 0.3

    static func url(_ folder: JobFolder, _ relative: String) -> URL {
        folder.url.appendingPathComponent(relative)
    }

    // MARK: Convert

    /// Converts audio/NNN.wav to audio/NNN.m4a (AAC mono). The WAV is deleted
    /// only when the .m4a is complete; on failure the WAV is kept and the
    /// recording marked "failed" (its audio is still in the job folder).
    static func convert(folder: JobFolder, file: String) {
        let wavRel = (file as NSString).deletingPathExtension + ".wav"
        let wav = url(folder, wavRel), m4a = url(folder, file)
        let fm = FileManager.default
        guard fm.fileExists(atPath: wav.path) else {
            JobFiles.updateVoice(folder) { list in
                guard let i = list.firstIndex(where: { $0.file == file }), list[i].state == "recording" else { return }
                if fm.fileExists(atPath: m4a.path) { list[i].state = "saved" } else { list.remove(at: i) }
            }
            return
        }
        WAVRepair.repairFile(at: wav)       // harmless on a complete file
        do {
            let seconds = try encodeAAC(wav: wav, to: m4a)
            if seconds < minimumDuration {
                try? fm.removeItem(at: m4a)
                try? fm.removeItem(at: wav)
                JobFiles.updateVoice(folder) { list in list.removeAll { $0.file == file } }
                return
            }
            try? fm.removeItem(at: wav)
            JobFiles.updateVoice(folder) { list in
                if let i = list.firstIndex(where: { $0.file == file }) {
                    list[i].state = "saved"
                    list[i].duration = seconds
                    list[i].error = nil
                }
            }
        } catch {
            JobFiles.updateVoice(folder) { list in
                if let i = list.firstIndex(where: { $0.file == file }) {
                    list[i].state = "failed"
                    list[i].error = "The recording couldn't be converted (\(error.localizedDescription)); the audio is kept as \(wavRel)."
                }
            }
        }
    }

    static func encodeAAC(wav: URL, to m4a: URL) throws -> Double {
        let part = m4a.deletingLastPathComponent().appendingPathComponent("part-" + m4a.lastPathComponent)
        try? FileManager.default.removeItem(at: part)
        let seconds = try writeAAC(from: wav, to: part)
        try? FileManager.default.removeItem(at: m4a)
        try FileManager.default.moveItem(at: part, to: m4a)
        return seconds
    }

    /// The output file is closed when it goes out of scope at the end.
    private static func writeAAC(from wav: URL, to out: URL) throws -> Double {
        let input = try AVAudioFile(forReading: wav)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw TranscriptionError.failed("Out of memory")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return format.sampleRate > 0 ? Double(input.length) / format.sampleRate : 0
    }

    // MARK: Recover

    /// Finishes recordings that were cut off (app killed / crashed while
    /// recording), and indexes stray WAV files. `activeFile` is the one being
    /// recorded right now, which is left alone.
    static func recover(folder: JobFolder, activeFile: String?) {
        let index = JobFiles.loadVoice(folder)
        for rec in index where rec.state == "recording" && rec.file != activeFile {
            convert(folder: folder, file: rec.file)
        }
        let known = Set(JobFiles.loadVoice(folder).map(\.wavFile))
        let activeWav = activeFile.map { ($0 as NSString).deletingPathExtension + ".wav" }
        for f in JobFiles.audioFiles(folder) where f.hasSuffix(".wav") && !known.contains(f) && f != activeWav {
            let name = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
            guard Int(name) != nil else { continue }
            let file = (f as NSString).deletingPathExtension + ".m4a"
            let created = (try? url(folder, f).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            JobFiles.updateVoice(folder) { list in
                list.append(VoiceRecording(file: file, startedAt: ISOTime.string(created, fractional: true),
                                           duration: nil, state: "recording"))
            }
            convert(folder: folder, file: file)
        }
    }

    // MARK: Transcribe + merge

    /// Transcribes one recording and groups the words into notes.
    static func transcribe(folder: JobFolder, recording rec: VoiceRecording) async -> Result<[GroupedNote], Error> {
        let m4a = url(folder, rec.file), wav = url(folder, rec.wavFile)
        let source = FileManager.default.fileExists(atPath: m4a.path) ? m4a : wav
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(TranscriptionError.failed("The audio file is missing."))
        }
        do {
            let segments = try await Transcriber.transcribe(url: source)
            let notes = NoteGrouper.group(segments)
            if notes.isEmpty { return .failure(TranscriptionError.failed("No speech was recognised in this recording. The audio is kept.")) }
            return .success(notes)
        } catch {
            return .failure(error)
        }
    }

    /// Writes the result into plan.json and voice.json. On failure the
    /// recording gets one "not transcribed" note (empty text) so the audio is
    /// listed with the job's notes, and can be transcribed again later.
    static func apply(folder: JobFolder, recording rec: VoiceRecording, result: Result<[GroupedNote], Error>) throws {
        if !folder.hasPlan { _ = try? JobProcessor.buildPlan(folder: folder, modelNote: nil) }
        guard let data = try? Data(contentsOf: folder.planURL),
              var doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranscriptionError.failed("The plan could not be read.")
        }
        let start = ISOTime.date(rec.startedAt) ?? Date()
        var markup = doc["markup"] as? [String: Any] ?? [:]
        let existing = markup["notes"] as? [[String: Any]] ?? []
        let notes: [GroupedNote]?
        switch result {
        case .success(let n): notes = n
        case .failure: notes = nil
        }
        markup["notes"] = VoiceNoteMerger.merge(existing: existing, audio: rec.file, recordingStart: start, notes: notes)
        doc["markup"] = markup
        try PlanDocument.data(doc).write(to: folder.planURL, options: .atomic)

        JobFiles.updateVoice(folder) { list in
            guard let i = list.firstIndex(where: { $0.file == rec.file }) else { return }
            switch result {
            case .success(let n):
                list[i].state = "transcribed"
                list[i].noteCount = n.count
                list[i].error = nil
            case .failure(let e):
                list[i].state = "failed"
                list[i].error = e.localizedDescription
            }
        }
    }
}
