//
//  VoiceNotes.swift
//  SecureScan
//
//  Pure logic for spoken site notes (docs/SPEC.md addendum v1.4, markup.notes):
//    * VoiceRecording   - one entry of voice.json (the job's recordings index)
//    * NoteGrouper      - time-stamped words/phrases -> notes split at pauses
//    * VoiceNoteMerger  - put a recording's notes into markup.notes, keeping
//                         notes the user corrected (edited: true)
//    * ChunkPlanner     - where to cut a long recording for the older
//                         recogniser (at the quietest moment near each limit)
//    * WAVRepair        - fix the size fields of a WAV file whose recording was
//                         cut off (app killed), so the audio is never lost
//  Foundation only - unit tested.
//

import Foundation

// MARK: - Recordings index (voice.json)

/// One recording. `file` is the final AAC file ("audio/001.m4a"); while it is
/// being recorded the audio lives in the same name with ".wav".
struct VoiceRecording: Codable, Equatable {
    var file: String
    /// When recording started (ISO 8601, may have fractional seconds).
    var startedAt: String
    var duration: Double?
    /// "recording" (wav being written, or cut off) | "saved" (m4a, waiting for
    /// transcription) | "transcribed" | "failed" (audio kept, text missing).
    var state: String
    var error: String?
    var noteCount: Int?

    var wavFile: String { (file as NSString).deletingPathExtension + ".wav" }
    /// "001" from "audio/001.m4a".
    var number: String { ((file as NSString).lastPathComponent as NSString).deletingPathExtension }
}

struct VoiceIndex: Codable {
    var version: Int = 1
    var recordings: [VoiceRecording] = []

    /// Next free "audio/NNN.m4a", considering the index and any files on disk.
    static func nextFile(existing: [VoiceRecording], filesOnDisk: [String]) -> String {
        var used = Set<Int>()
        for r in existing { if let n = Int(r.number) { used.insert(n) } }
        for f in filesOnDisk {
            if let n = Int(((f as NSString).lastPathComponent as NSString).deletingPathExtension) { used.insert(n) }
        }
        let next = (used.max() ?? 0) + 1
        return String(format: "audio/%03ld.m4a", next)
    }
}

// MARK: - Time stamps

enum ISOTime {
    static func string(_ date: Date, fractional: Bool = false) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Parses ISO 8601 with or without fractional seconds.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Grouping

/// A recognised word or phrase, seconds from the start of the recording.
struct TimedSegment: Equatable {
    var text: String
    var start: Double
    var duration: Double
    var end: Double { start + max(0, duration) }
}

/// One note: text plus its span within the recording (seconds).
struct GroupedNote: Equatable {
    var text: String
    var start: Double
    var end: Double
}

enum NoteGrouper {
    /// Splits at a silence of `pause` seconds or more; a note longer than
    /// `softMax` is also split at the next sentence end, and never runs past
    /// `hardMax`.
    static func group(_ segments: [TimedSegment], pause: Double = 1.6,
                      softMax: Double = 30, hardMax: Double = 60) -> [GroupedNote] {
        let segs = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.start.isFinite }
            .sorted { $0.start < $1.start }
        var notes: [GroupedNote] = []
        var pieces: [String] = []
        var start = 0.0, end = 0.0

        func flush() {
            guard !pieces.isEmpty else { return }
            let text = join(pieces)
            if !text.isEmpty { notes.append(GroupedNote(text: text, start: start, end: end)) }
            pieces = []
        }

        for s in segs {
            if !pieces.isEmpty {
                let gap = s.start - end
                let length = end - start
                let sentenceEnded = pieces.last.map(endsSentence) ?? false
                if gap >= pause || length >= hardMax || (length >= softMax && sentenceEnded) {
                    flush()
                }
            }
            if pieces.isEmpty { start = s.start; end = s.end }
            pieces.append(s.text)
            end = max(end, s.end)
        }
        flush()
        return notes
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return c == "." || c == "!" || c == "?"
    }

    /// Joins words with single spaces (no space before punctuation) and
    /// capitalises the first letter.
    static func join(_ pieces: [String]) -> String {
        var out = ""
        for raw in pieces {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = p.first else { continue }
            if out.isEmpty || ".,!?;:%)'’".contains(first) {
                out += p
            } else {
                out += " " + p
            }
        }
        guard let f = out.first else { return out }
        return f.uppercased() + out.dropFirst()
    }
}

// MARK: - Merging into markup.notes

enum VoiceNoteMerger {

    /// "v001-03" for note 3 of audio/001.m4a. 0 = the "not transcribed" note.
    static func noteID(audio: String, index: Int) -> String {
        let num = ((audio as NSString).lastPathComponent as NSString).deletingPathExtension
        return String(format: "v%@-%02ld", num, index)
    }

    static func r1(_ x: Double) -> Double { x.isFinite ? (x * 10).rounded() / 10 : 0 }

    /// Replaces the notes of one recording in `existing` (markup.notes):
    ///  * notes of other recordings and typed notes are untouched;
    ///  * notes of this recording the user corrected (`edited: true`) are kept,
    ///    and new notes that overlap them in the audio are left out;
    ///  * other notes of this recording are replaced by `notes`;
    ///  * `notes == nil` (transcription failed / unavailable) adds one note with
    ///    empty text and `transcribed: false`, unless an edited note of this
    ///    recording already exists.
    /// The result is in time order.
    static func merge(existing: [[String: Any]], audio: String, recordingStart: Date,
                      notes: [GroupedNote]?) -> [[String: Any]] {
        var kept: [[String: Any]] = []
        var editedRanges: [(Double, Double)] = []
        for n in existing {
            let isThis = (n["audio"] as? String) == audio
            let edited = (n["edited"] as? Bool) ?? false
            if !isThis { kept.append(n); continue }
            if edited {
                kept.append(n)
                let off = PlanDocument.number(n["audioOffset"]) ?? 0
                var len = 1.0
                if let t = ISOTime.date(n["t"] as? String), let e = ISOTime.date(n["end"] as? String) {
                    len = max(0.5, e.timeIntervalSince(t))
                }
                editedRanges.append((off, off + len))
            }
        }
        var usedIDs = Set(kept.compactMap { $0["id"] as? String })
        func unique(_ id: String) -> String {
            var candidate = id, k = 2
            while usedIDs.contains(candidate) { candidate = "\(id)-\(k)"; k += 1 }
            usedIDs.insert(candidate)
            return candidate
        }

        var fresh: [[String: Any]] = []
        if let notes {
            for (i, g) in notes.enumerated() {
                let overlapsEdit = editedRanges.contains { g.start < $0.1 && g.end > $0.0 }
                if overlapsEdit { continue }
                fresh.append([
                    "id": unique(noteID(audio: audio, index: i + 1)),
                    "t": ISOTime.string(recordingStart.addingTimeInterval(g.start)),
                    "end": ISOTime.string(recordingStart.addingTimeInterval(max(g.end, g.start))),
                    "text": g.text,
                    "source": "voice",
                    "audio": audio,
                    "audioOffset": r1(g.start),
                    "edited": false,
                ])
            }
        } else if editedRanges.isEmpty {
            fresh.append([
                "id": unique(noteID(audio: audio, index: 0)),
                "t": ISOTime.string(recordingStart),
                "text": "",
                "source": "voice",
                "audio": audio,
                "audioOffset": 0.0,
                "edited": false,
                "transcribed": false,
            ])
        }
        return Timeline.sortedByTime(kept + fresh, key: "t")
    }
}

// MARK: - Splitting long recordings

enum ChunkPlanner {
    /// Cut points (seconds) so no chunk is longer than `maxChunk`. Each cut is
    /// placed at the quietest frame between `minChunk` and `maxChunk` after the
    /// previous cut. `frameRMS[i]` is the loudness of frame i (`frameSeconds` long).
    static func splitPoints(frameRMS: [Float], frameSeconds: Double,
                            maxChunk: Double = 50, minChunk: Double = 30) -> [Double] {
        guard frameSeconds > 0, !frameRMS.isEmpty else { return [] }
        let total = Double(frameRMS.count) * frameSeconds
        var cuts: [Double] = []
        var last = 0.0
        while total - last > maxChunk {
            let lo = Int(((last + minChunk) / frameSeconds).rounded(.up))
            let hi = min(frameRMS.count - 1, Int(((last + maxChunk) / frameSeconds).rounded(.down)) - 1)
            var best = max(lo, 0)
            if lo <= hi {
                for i in lo...hi where frameRMS[i] < frameRMS[best] { best = i }
            }
            // Cut in the middle of the quiet frame.
            let cut = (Double(best) + 0.5) * frameSeconds
            guard cut > last + 1 else { break }
            cuts.append(cut)
            last = cut
        }
        return cuts
    }
}

// MARK: - WAV header repair

enum WAVRepair {
    struct Fix: Equatable {
        var riffSize: UInt32          // written at offset 4
        var dataSizeOffset: Int       // where the data chunk's size field is
        var dataSize: UInt32
    }

    /// Given the first bytes of a WAV file (at least up to the "data" chunk
    /// header) and the file's length, returns the size fields that make the
    /// file valid, or nil if this is not a RIFF/WAVE file. `blockAlign` keeps
    /// the data size a whole number of sample frames.
    static func fix(header: Data, fileLength: UInt64, blockAlign: Int = 2) -> Fix? {
        let h = [UInt8](header)
        guard h.count >= 12,
              String(bytes: h[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: h[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(h[o]) | UInt32(h[o + 1]) << 8 | UInt32(h[o + 2]) << 16 | UInt32(h[o + 3]) << 24
        }
        var pos = 12
        while pos + 8 <= h.count {
            let id = String(bytes: h[pos..<(pos + 4)], encoding: .ascii) ?? ""
            let size = Int(u32(pos + 4))
            if id == "data" {
                let dataStart = UInt64(pos + 8)
                guard fileLength >= dataStart else { return nil }
                var dataLen = fileLength - dataStart
                if blockAlign > 1 { dataLen -= dataLen % UInt64(blockAlign) }
                let clampedData = UInt32(min(dataLen, UInt64(UInt32.max - 64)))
                let riff = UInt32(min(dataStart - 8 + UInt64(clampedData), UInt64(UInt32.max)))
                return Fix(riffSize: riff, dataSizeOffset: pos + 4, dataSize: clampedData)
            }
            pos += 8 + size + (size % 2)      // chunks are word aligned
        }
        return nil
    }

    static func le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    /// Rewrites the size fields of a WAV file in place. Returns false if the
    /// file is not a WAV file it understands (it is then left untouched).
    @discardableResult
    static func repairFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: 4096),
              let fix = fix(header: header, fileLength: length) else { return false }
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: le(fix.riffSize))
            try handle.seek(toOffset: UInt64(fix.dataSizeOffset))
            try handle.write(contentsOf: le(fix.dataSize))
            return true
        } catch {
            return false
        }
    }
}
