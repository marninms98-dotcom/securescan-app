//
//  Transcriber.swift
//  SecureScan
//
//  On-device transcription of a recorded voice note into time-stamped
//  segments (seconds from the start of the file). Nothing leaves the phone.
//
//  Which API (checked against Apple's documentation, Nov 2026):
//   * iOS 26+: SpeechAnalyzer + SpeechTranscriber (Speech framework). Built for
//     long-form audio and always on-device; the language model is a system
//     asset installed through AssetInventory (a one-off download the first
//     time, shared with other apps). Word times come from the
//     `audioTimeRange` attribute of each result's AttributedString.
//   * iOS 17-25 (and the fallback if the above fails, e.g. the model can't be
//     downloaded on site): SFSpeechRecognizer with
//     `requiresOnDeviceRecognition = true`, used only when
//     `supportsOnDeviceRecognition` is true (Apple: the request only honours
//     the on-device setting if that property is true - otherwise audio would
//     go to Apple's servers, which this app never allows). Apple documents a
//     one-minute limit on recognition tasks, so the file is fed in chunks of
//     at most 50 s cut at the quietest moment; segment times are offset by
//     each chunk's start. SFTranscriptionSegment gives timestamp/duration.
//  Locale: en-AU first, then en-GB, en-US, then the phone's own locale.
//  Authorisation: SFSpeechRecognizer.requestAuthorization
//  (NSSpeechRecognitionUsageDescription) is asked before either path.
//

import Foundation
import AVFoundation
import Speech
import CoreMedia

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is turned off for SecureScan (Settings › SecureScan › Speech Recognition). The audio is kept."
        case .unavailable(let s), .failed(let s):
            return s
        }
    }
}

enum Transcriber {
    static let preferredLocales = ["en-AU", "en-GB", "en-US"]

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// Time-stamped words / phrases of the recording at `url`.
    static func transcribe(url: URL) async throws -> [TimedSegment] {
        guard await authorize() else { throw TranscriptionError.notAuthorized }
        var modernError: Error? = nil
        if #available(iOS 26.0, *) {
            do {
                return try await ModernTranscriber.transcribe(url: url)
            } catch {
                modernError = error
            }
        }
        do {
            return try await LegacyTranscriber.transcribe(url: url)
        } catch {
            if let modernError {
                throw TranscriptionError.failed("Transcription failed (\(modernError.localizedDescription); \(error.localizedDescription)). The audio is kept.")
            }
            throw error
        }
    }
}

// MARK: - iOS 26+: SpeechAnalyzer / SpeechTranscriber

@available(iOS 26.0, *)
enum ModernTranscriber {
    static func transcribe(url: URL) async throws -> [TimedSegment] {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable("This iPhone doesn't support the new speech model.")
        }
        var chosen: Locale? = nil
        for id in Transcriber.preferredLocales + [Locale.current.identifier] {
            if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) {
                chosen = l
                break
            }
        }
        guard let locale = chosen else {
            throw TranscriptionError.unavailable("No English speech model is available.")
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)

        let collector = Task { () throws -> [TimedSegment] in
            var out: [TimedSegment] = []
            for try await result in transcriber.results {
                out.append(contentsOf: ModernTranscriber.segments(of: result.text, phraseRange: result.range))
            }
            return out
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try? await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// One segment per run carrying a time range (roughly per word); the whole
    /// phrase as one segment if the runs carry none.
    static func segments(of text: AttributedString, phraseRange: CMTimeRange) -> [TimedSegment] {
        var out: [TimedSegment] = []
        for run in text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = range.start.seconds, duration = range.duration.seconds
            guard start.isFinite else { continue }
            out.append(TimedSegment(text: piece, start: start, duration: duration.isFinite ? duration : 0))
        }
        if out.isEmpty {
            let whole = String(text.characters)
            let start = phraseRange.start.seconds, duration = phraseRange.duration.seconds
            if !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, start.isFinite {
                out.append(TimedSegment(text: whole, start: start, duration: duration.isFinite ? duration : 0))
            }
        }
        return out
    }
}

// MARK: - iOS 17+: SFSpeechRecognizer, on-device only

/// Resolves a continuation exactly once, from any thread.
final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { continuation = c }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

enum LegacyTranscriber {
    static let maxChunk = 50.0

    static func recognizer() -> SFSpeechRecognizer? {
        for id in Transcriber.preferredLocales + [Locale.current.identifier] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.supportsOnDeviceRecognition {
                return r
            }
        }
        return nil
    }

    static func transcribe(url: URL) async throws -> [TimedSegment] {
        guard let recognizer = recognizer() else {
            throw TranscriptionError.unavailable("On-device speech recognition isn't available on this iPhone. Turning on Dictation (Settings › General › Keyboard) may download it. The audio is kept.")
        }
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return [] }
        let frameSeconds = 0.1
        let rms = try loudness(file, frameSeconds: frameSeconds)
        let cuts = ChunkPlanner.splitPoints(frameRMS: rms, frameSeconds: frameSeconds, maxChunk: maxChunk, minChunk: 30)
        let edges: [AVAudioFramePosition] = [0] + cuts.map { AVAudioFramePosition($0 * rate) } + [file.length]

        var out: [TimedSegment] = []
        for i in 0..<(edges.count - 1) where edges[i + 1] > edges[i] {
            let offset = Double(edges[i]) / rate
            let segs = try await recognise(file: file, from: edges[i], to: edges[i + 1], recognizer: recognizer)
            out += segs.map { TimedSegment(text: $0.text, start: $0.start + offset, duration: $0.duration) }
        }
        return out
    }

    /// RMS loudness per frame of `frameSeconds`.
    static func loudness(_ file: AVAudioFile, frameSeconds: Double) throws -> [Float] {
        let format = file.processingFormat
        let frameLen = AVAudioFrameCount(max(1, format.sampleRate * frameSeconds))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLen) else { return [] }
        var out: [Float] = []
        file.framePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: frameLen)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            var sum: Float = 0
            if let ch = buf.floatChannelData?[0] {
                for k in 0..<n { sum += ch[k] * ch[k] }
            }
            out.append((sum / Float(n)).squareRoot())
        }
        file.framePosition = 0
        return out
    }

    static func recognise(file: AVAudioFile, from start: AVAudioFramePosition, to end: AVAudioFramePosition,
                          recognizer: SFSpeechRecognizer) async throws -> [TimedSegment] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        file.framePosition = start
        var remaining = end - start
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(8192), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { break }
            try file.read(into: buf, frameCount: n)
            if buf.frameLength == 0 { break }
            request.append(buf)
            remaining -= AVAudioFramePosition(buf.frameLength)
        }
        request.endAudio()
        let seconds = Double(end - start) / max(1, file.processingFormat.sampleRate)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TimedSegment], Error>) in
            let once = OnceBox(cont)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let segs = result.bestTranscription.segments.map {
                        TimedSegment(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    once.resume(.success(segs))
                } else if let error {
                    let ns = error as NSError
                    // "No speech detected" for a silent chunk is not a failure.
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                        once.resume(.success([]))
                    } else {
                        once.resume(.failure(TranscriptionError.failed("Transcription failed: \(error.localizedDescription). The audio is kept.")))
                    }
                }
            }
            // Never hang: give up well after the chunk should have finished.
            DispatchQueue.global().asyncAfter(deadline: .now() + max(60, seconds * 4)) {
                task.cancel()
                once.resume(.failure(TranscriptionError.failed("Transcription timed out. The audio is kept.")))
            }
        }
    }
}
