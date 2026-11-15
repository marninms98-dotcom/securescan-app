//
//  ScanOpenMarker.swift
//  SecureScan
//
//  "scan-open" in the job folder while a scan screen is open; removed when
//  the scan finishes and its plan is built. Still there on the next open =
//  the app was closed mid-scan: the job screen offers to place what was kept.
//

import Foundation

enum ScanOpenMarker {
    static func url(_ folder: JobFolder) -> URL { folder.url.appendingPathComponent("scan-open") }
    static func exists(_ folder: JobFolder) -> Bool { FileManager.default.fileExists(atPath: url(folder).path) }
    static func mark(_ folder: JobFolder) { try? Data().write(to: url(folder), options: .atomic) }
    static func clear(_ folder: JobFolder) { try? FileManager.default.removeItem(at: url(folder)) }
}
