//
//  ScanExtras.swift
//  SecureScan
//
//  Things decided on the capture screen that readings-raw.json has no field
//  for (its item shapes are a fixed contract): the room names chosen in the
//  room-name tray, and the airflow direction of air movers placed while
//  scanning. Kept beside it in scan-extras.json and applied when the plan is
//  built (JobProcessor.buildPlan). Also needs-fix.json: marks the plan could
//  not place, in plain words, for the Items tab.
//

import Foundation
import simd

struct ScanExtras: Codable, Equatable {
    var version = 1
    /// 1-based room number -> name ("1": "Bedroom + Ensuite").
    var roomNames: [String: String] = [:]
    /// Item id -> horizontal world direction [dx, dz] (scan world space).
    var airflow: [String: [Double]] = [:]
    /// The moisture model's corrections made in the camera (Moisture > Adjust), in scan world space.
    var modelTweaks: [LiveTweak]? = nil

    static func url(_ folder: JobFolder) -> URL { folder.url.appendingPathComponent("scan-extras.json") }

    static func load(_ folder: JobFolder) -> ScanExtras {
        guard let data = try? Data(contentsOf: url(folder)),
              let x = try? JSONDecoder().decode(ScanExtras.self, from: data) else { return ScanExtras() }
        return x
    }

    func save(_ folder: JobFolder) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url(folder), options: .atomic) }
    }

    func direction(_ id: String) -> WorldVec? {
        guard let d = airflow[id], d.count == 2 else { return nil }
        return WorldVec(d[0], 0, d[1])
    }
}

/// A mark the plan could not place: shown in Items with a plain sentence and a fix.
struct NeedsFix: Codable, Equatable {
    var id: String
    var sentence: String
    var fix: String

    static func url(_ folder: JobFolder) -> URL { folder.url.appendingPathComponent("needs-fix.json") }

    static func load(_ folder: JobFolder) -> [NeedsFix] {
        guard let data = try? Data(contentsOf: url(folder)) else { return [] }
        return (try? JSONDecoder().decode([NeedsFix].self, from: data)) ?? []
    }

    static func save(_ list: [NeedsFix], _ folder: JobFolder) {
        if list.isEmpty { try? FileManager.default.removeItem(at: url(folder)); return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: url(folder), options: .atomic) }
    }
}
