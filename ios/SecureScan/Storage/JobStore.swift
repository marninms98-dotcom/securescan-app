//
//  JobStore.swift
//  SecureScan
//
//  Storage layout (docs/SPEC.md): Documents/Jobs/<uuid>/
//    plan.json           the plan document (Contract 1)
//    model.usdz          3D model (absent for demo jobs / failed exports)
//    rooms/<n>.json      each CapturedRoom, JSON-encoded (n = 1, 2, ...)
//    readings-raw.json   raw world-space log of readings / moisture-line marks /
//                        photos / sources
//    photos/<id>.jpg     frame captured with each logged item
//    audio/NNN.m4a       voice recordings (audio/NNN.wav while recording)
//    voice.json          index of the recordings (start time, state)
//    plan-frame.json     plan <-> world transform of the last plan build (3D tab)
//    thumb.png           list thumbnail
//    job.json            small metadata file for the jobs list (app-private)
//

import Foundation
import SwiftUI

struct JobMeta: Codable, Identifiable, Hashable {
    var id: UUID
    var address: String
    var jobRef: String
    var createdAt: Date
    var roomCount: Int
    var totalArea: Double
    var readingCount: Int
    var note: String?          // e.g. "3D model could not be built: ..."
    var demo: Bool?            // true for "Create demo job"
    /// Ids of marks the plan could not place (they stay in readings-raw.json; needs-fix.json has
    /// the plain sentence and the fix). Absent / empty = none. Read this, not the note's wording.
    var unplaced: [String]? = nil

    var displayAddress: String { address.isEmpty ? "Untitled job" : address }
}

/// One item logged during a scan, in ARKit world space. Written as it is
/// logged so nothing is lost if the scan or the merge later fails.
struct RawReading: Codable, Identifiable {
    var id: String
    var seq: Int                   // capture order across all kinds
    var kind: String               // "reading" | "boundary" | "photo" | "source" | "equipment" | "removal" | "floorType"
    var value: Double?
    var material: String
    var reference: Bool
    var note: String
    var takenAt: String
    var roomIndex: Int             // 0-based room being scanned when logged
    var cameraPosition: [Double]   // [x, y, z]
    var cameraForward: [Double]    // [x, y, z], unit
    var hit: [Double]?             // ARKit raycast hit [x, y, z]
    var hitKind: String?           // "existingPlaneGeometry" | "estimatedPlane"
    var photoFile: String?         // relative to the job folder
    var resolved: [Double]?        // resolved world point, written by PlanBuilder runs
    // v1.1 round 3 (all optional, so older files still decode):
    var hitNormal: [Double]? = nil         // surface normal at the raycast hit
    var endCameraPosition: [Double]? = nil // removal: the "End here" tap
    var endCameraForward: [Double]? = nil
    var endHit: [Double]? = nil
    var heightMm: Double? = nil            // removal height (mm)
    var corners: [[Double]]? = nil         // flooring removal: corner taps, 9 numbers each (camera, forward, hit)
    var wholeRoom: Bool? = nil
    var floorType: String? = nil
    var underlay: Bool? = nil
}

/// The plan transform of the last build, so plan items (including ones added
/// by hand in the editor) can be placed in the 3D model's world space.
struct PlanFrame: Codable {
    var angle: Double
    var offset: [Double]          // [x, y]
    var floorY: Double?

    var transform: PlanTransform {
        PlanTransform(angle: angle, offset: PlanVec(offset.count > 0 ? offset[0] : 0, offset.count > 1 ? offset[1] : 0))
    }
}

struct RawReadingsFile: Codable {
    var version: Int
    var readings: [RawReading]
}

struct JobFolder: Hashable {
    let url: URL
    var planURL: URL { url.appendingPathComponent("plan.json") }
    var modelURL: URL { url.appendingPathComponent("model.usdz") }
    var roomsDir: URL { url.appendingPathComponent("rooms", isDirectory: true) }
    var photosDir: URL { url.appendingPathComponent("photos", isDirectory: true) }
    var rawReadingsURL: URL { url.appendingPathComponent("readings-raw.json") }
    var thumbURL: URL { url.appendingPathComponent("thumb.png") }
    var audioDir: URL { url.appendingPathComponent("audio", isDirectory: true) }
    var voiceIndexURL: URL { url.appendingPathComponent("voice.json") }
    var frameURL: URL { url.appendingPathComponent("plan-frame.json") }
    /// ARWorldMap of the first scan (NSKeyedArchiver, secure coding), for return visits.
    var worldMapURL: URL { url.appendingPathComponent("worldmap.bin") }
    /// Everything logged on return visits, in each session's own world space, with its alignment.
    var revisitLogURL: URL { url.appendingPathComponent("revisit-log.json") }
    var metaURL: URL { url.appendingPathComponent("job.json") }

    func roomURL(_ n: Int) -> URL { roomsDir.appendingPathComponent("\(n).json") }

    /// rooms/*.json sorted numerically (1, 2, ... 10).
    func roomFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: roomsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { (Int($0.deletingPathExtension().lastPathComponent) ?? 0) < (Int($1.deletingPathExtension().lastPathComponent) ?? 0) }
    }

    var hasPlan: Bool { FileManager.default.fileExists(atPath: planURL.path) }
    var hasModel: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
}

enum JobFiles {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Jobs", isDirectory: true)
    }

    static func folder(for id: UUID) -> JobFolder {
        JobFolder(url: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func readMeta(_ f: JobFolder) -> JobMeta? {
        guard let data = try? Data(contentsOf: f.metaURL) else { return nil }
        return try? decoder().decode(JobMeta.self, from: data)
    }

    static func writeMeta(_ m: JobMeta, _ f: JobFolder) throws {
        try encoder().encode(m).write(to: f.metaURL, options: .atomic)
    }

    static func create(address: String, jobRef: String, demo: Bool = false) throws -> JobMeta {
        let meta = JobMeta(id: UUID(), address: address, jobRef: jobRef, createdAt: Date(),
                           roomCount: 0, totalArea: 0, readingCount: 0, note: nil, demo: demo ? true : nil)
        let f = folder(for: meta.id)
        let fm = FileManager.default
        try fm.createDirectory(at: f.roomsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: f.photosDir, withIntermediateDirectories: true)
        try writeMeta(meta, f)
        return meta
    }

    static func listMetas() -> [JobMeta] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var out: [JobMeta] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let f = JobFolder(url: dir)
            if let m = readMeta(f) {
                out.append(m)
            } else {
                // Folder without job.json (e.g. crash before it was written): still list it.
                let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                out.append(JobMeta(id: id, address: "", jobRef: "", createdAt: created,
                                   roomCount: f.roomFiles().count, totalArea: 0, readingCount: 0, note: nil, demo: nil))
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id).url)
    }

    // MARK: Raw readings

    static func loadRawReadings(_ f: JobFolder) -> [RawReading] {
        guard let data = try? Data(contentsOf: f.rawReadingsURL),
              let file = try? decoder().decode(RawReadingsFile.self, from: data) else { return [] }
        return file.readings
    }

    static func saveRawReadings(_ r: [RawReading], _ f: JobFolder) throws {
        let data = try encoder().encode(RawReadingsFile(version: 1, readings: r))
        try data.write(to: f.rawReadingsURL, options: .atomic)
    }

    static func loadFrame(_ f: JobFolder) -> PlanFrame? {
        guard let data = try? Data(contentsOf: f.frameURL) else { return nil }
        return try? decoder().decode(PlanFrame.self, from: data)
    }

    // MARK: Voice recordings index

    static func loadVoice(_ f: JobFolder) -> [VoiceRecording] {
        guard let data = try? Data(contentsOf: f.voiceIndexURL),
              let index = try? decoder().decode(VoiceIndex.self, from: data) else { return [] }
        return index.recordings
    }

    static func saveVoice(_ r: [VoiceRecording], _ f: JobFolder) throws {
        let data = try encoder().encode(VoiceIndex(version: 1, recordings: r))
        try data.write(to: f.voiceIndexURL, options: .atomic)
    }

    private static let voiceLock = NSLock()

    /// Read-modify-write of voice.json, serialised across threads (the
    /// recorder on the main thread, conversions and transcriptions in the
    /// background).
    static func updateVoice(_ f: JobFolder, _ change: (inout [VoiceRecording]) -> Void) {
        voiceLock.lock()
        defer { voiceLock.unlock() }
        var list = loadVoice(f)
        change(&list)
        try? saveVoice(list, f)
    }

    /// Audio files in audio/ (relative paths, "audio/001.m4a").
    static func audioFiles(_ f: JobFolder) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: f.audioDir, includingPropertiesForKeys: nil)) ?? []
        return files.map { "audio/" + $0.lastPathComponent }.sorted()
    }

    static func hasAudio(_ f: JobFolder) -> Bool { !audioFiles(f).isEmpty || !loadVoice(f).isEmpty }
}

/// The jobs list state.
@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()
    @Published private(set) var jobs: [JobMeta] = []

    func reload() { jobs = JobFiles.listMetas() }

    func delete(_ id: UUID) {
        try? JobFiles.delete(id)
        reload()
    }
}
