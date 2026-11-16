//
//  SyncConfig.swift
//  SecureScan
//
//  Where SecureSuite lives: the Supabase project URL and its publishable
//  (anon) key. Never in source: Info.plist carries SECURESCAN_SUPABASE_URL /
//  SECURESCAN_SUPABASE_KEY, filled at build time from the build settings
//  SUPABASE_URL / SUPABASE_ANON_KEY (empty by default, set by the TestFlight
//  workflow from repository secrets). Empty = the app is local only, exactly
//  as before (docs/SYNC.md). Pure; compiled into the unit tests.
//

import Foundation

struct SyncConfig: Equatable {
    /// https://<project>.supabase.co, no trailing slash.
    let baseURL: URL
    /// The publishable key, sent as the `apikey` header.
    let anonKey: String

    static let urlInfoKey = "SECURESCAN_SUPABASE_URL"
    static let keyInfoKey = "SECURESCAN_SUPABASE_KEY"

    /// From the app's Info.plist dictionary; nil when sync is not configured.
    static func fromInfo(_ info: [String: Any]?) -> SyncConfig? {
        parse(url: info?[urlInfoKey] as? String, key: info?[keyInfoKey] as? String)
    }

    /// nil when either value is empty, still an unexpanded "$(…)" build setting,
    /// or the URL is not usable (https only; plain http only for a local dev stack).
    static func parse(url rawURL: String?, key rawKey: String?) -> SyncConfig? {
        let key = clean(rawKey)
        var text = clean(rawURL)
        guard !text.isEmpty, !key.isEmpty, !key.contains(" ") else { return nil }
        let lower = text.lowercased()
        if lower.contains("://") {
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        } else {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        return SyncConfig(baseURL: url, anonKey: key)
    }

    /// Trims spaces and stray quotes; an unexpanded build setting counts as empty.
    static func clean(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("$(") || t.contains("${") { return "" }
        return t
    }
}
