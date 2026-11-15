//
//  PackNames.swift
//  SecureScan
//
//  File names for the job pack (docs/SPEC.md addendum v1.4, Contract 2
//  "exportPack"). The editor sends relative paths such as "summary.md" or
//  "photos/reading-3.jpg"; anything that could escape the pack folder is
//  refused. Foundation only - unit tested.
//

import Foundation

enum PackNames {

    static let maxPathLength = 200
    static let maxDepth = 4
    private static let badCharacters = CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)

    /// A safe relative path inside the pack, or nil if the name must be
    /// rejected: absolute paths, "~", "..", ".", empty components, backslashes,
    /// too deep or too long. Unsafe characters inside a component become "-".
    static func safeRelativePath(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxPathLength,
              !name.hasPrefix("/"), !name.hasPrefix("~"),
              !name.contains("\\"), !name.contains("\u{0}") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= maxDepth else { return nil }
        var clean: [String] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t != ".", t != ".." else { return nil }
            var c = t.components(separatedBy: badCharacters).joined(separator: "-")
            // A leading dot would hide the file in the Files app.
            while c.hasPrefix(".") { c.removeFirst() }
            guard !c.isEmpty else { return nil }
            clean.append(c)
        }
        return clean.joined(separator: "/")
    }

    /// "<address>-job-pack" (no extension), safe as a file name.
    static func packBaseName(address: String) -> String { fileBase(address: address) + "-job-pack" }

    /// "<address>-assessment-report.pdf", safe as a file name.
    static func reportFileName(address: String) -> String { fileBase(address: address) + "-assessment-report.pdf" }

    /// The address cleaned for use in a file name ("SecureScan" when empty).
    static func fileBase(address: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var a = address.components(separatedBy: bad).joined(separator: "-")
        a = a.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        a = a.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if a.isEmpty { a = "SecureScan" }
        if a.count > 100 { a = String(a.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return a
    }
}
