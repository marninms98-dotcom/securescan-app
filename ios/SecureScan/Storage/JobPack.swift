//
//  JobPack.swift
//  SecureScan
//
//  "Job pack" export (docs/SPEC.md addendum v1.4, Contract 2 `exportPack`):
//  the editor's files (summary.md, PNGs, CSV, HTML, photos/...) plus the job's
//  own plan.json, audio/*.m4a and model.usdz, zipped into
//  "<address>-job-pack.zip". Zipping uses the system (NSFileCoordinator with
//  .forUploading on a folder produces a .zip) - no third-party code.
//  Runs on a background queue; `progress` is called from that queue.
//

import Foundation

/// Hands the (possibly tens of MB) editor payload to the background queue.
final class PackPayload: @unchecked Sendable {
    let files: [[String: Any]]
    init(_ files: [[String: Any]]) { self.files = files }
}

enum JobPackError: LocalizedError {
    case nothing
    case zip(String)
    var errorDescription: String? {
        switch self {
        case .nothing: return "The job pack was empty."
        case .zip(let s): return "The job pack could not be zipped (\(s))."
        }
    }
}

enum JobPack {

    struct Output {
        var zip: URL
        var skipped: [String]      // names refused (unsafe paths) or unreadable
    }

    /// `extra`: files made by the app for the pack (the report PDF), as
    /// (name in the pack, file).
    static func build(payload: PackPayload, folder: JobFolder, address: String, extra: [(String, URL)] = [],
                      progress: (Double, String) -> Void) throws -> Output {
        let fm = FileManager.default
        let base = PackNames.packBaseName(address: address)
        let work = fm.temporaryDirectory.appendingPathComponent("packs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dir = work.appendingPathComponent(base, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // The job's own files, added after the editor's (they win on a clash).
        var own: [(String, URL)] = []
        if folder.hasPlan { own.append(("plan.json", folder.planURL)) }
        for f in JobFiles.audioFiles(folder) {
            let name = (f as NSString).lastPathComponent
            if name.hasPrefix("part-") { continue }
            let isM4A = f.hasSuffix(".m4a")
            // A WAV goes in only if its conversion never finished (never lose audio).
            let wavOnly = f.hasSuffix(".wav") && !fm.fileExists(atPath: folder.url.appendingPathComponent((f as NSString).deletingPathExtension + ".m4a").path)
            if isM4A || wavOnly { own.append((f, folder.url.appendingPathComponent(f))) }
        }
        if folder.hasModel { own.append(("model.usdz", folder.modelURL)) }
        for (name, url) in extra {
            if let rel = PackNames.safeRelativePath(name) { own.append((rel, url)) }
        }

        let total = Double(payload.files.count + own.count + 1)
        var done = 0.0
        var skipped: [String] = []
        var written = 0

        for item in payload.files {
            let rawName = (item["filename"] as? String) ?? ""
            guard let rel = PackNames.safeRelativePath(rawName) else {
                skipped.append(rawName)
                continue
            }
            progress(done / total, "Adding \(rel)…")
            var b64 = (item["base64"] as? String) ?? ""
            if b64.hasPrefix("data:"), let comma = b64.firstIndex(of: ",") {
                b64 = String(b64[b64.index(after: comma)...])
            }
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                skipped.append(rel)
                continue
            }
            let dest = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            written += 1
            done += 1
        }
        for (rel, src) in own {
            progress(done / total, "Adding \(rel)…")
            let dest = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
            written += 1
            done += 1
        }
        guard written > 0 else { throw JobPackError.nothing }

        progress(done / total, "Zipping…")
        let zipURL = work.appendingPathComponent(base + ".zip")
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { tmp in
            do { try fm.copyItem(at: tmp, to: zipURL) } catch { copyError = error }
        }
        if let e = coordError ?? copyError.map({ $0 as NSError }) { throw JobPackError.zip(e.localizedDescription) }
        guard fm.fileExists(atPath: zipURL.path) else { throw JobPackError.zip("no file") }
        progress(1, "Done")
        return Output(zip: zipURL, skipped: skipped)
    }
}
