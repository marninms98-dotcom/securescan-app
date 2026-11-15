//
//  AppSettings.swift
//  SecureScan
//
//  Things remembered app-wide, across jobs (docs/SPEC.md v1.5 / v1.6):
//    * markup.brand  - logo, accent, name, tagline, contact. Stored when the
//      editor saves a plan whose brand differs; injected into a plan that has
//      no brand before it is handed to the editor, so new jobs start with it.
//    * markup.rateCard - { auto: {key: rate}, manual: [{desc, unit, rate}] }
//      (editor v1.6): remembered and injected exactly like the brand, so new
//      jobs start with the owner's rates.
//  The pure parts are unit tested; storage is a small JSON file in
//  Application Support (not shown in the Files app).
//

import Foundation

enum AppSettings {
    static let brandKey = "brand"
    static let rateCardKey = "rateCard"
    /// Markup keys remembered app-wide.
    static let rememberedKeys = [brandKey, rateCardKey]

    // MARK: Pure

    /// The remembered values that should change after `plan` was saved:
    /// every remembered key whose value in plan.markup is an object that
    /// differs from what is stored. Empty when nothing changed.
    static func changes(plan: [String: Any], stored: [String: Any]) -> [String: Any] {
        guard let markup = plan["markup"] as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for key in rememberedKeys {
            guard let v = markup[key] as? [String: Any], !v.isEmpty else { continue }
            if let old = stored[key] as? [String: Any], NSDictionary(dictionary: old).isEqual(to: v) { continue }
            out[key] = v
        }
        return out
    }

    /// `plan` with every remembered value it lacks added to its markup.
    /// Returns nil when nothing needed adding (the plan is used as it is).
    static func injected(plan: [String: Any], stored: [String: Any]) -> [String: Any]? {
        var markup = plan["markup"] as? [String: Any] ?? [:]
        var changed = false
        for key in rememberedKeys {
            guard let v = stored[key] as? [String: Any], !v.isEmpty else { continue }
            if markup[key] is [String: Any] { continue }
            markup[key] = v
            changed = true
        }
        guard changed else { return nil }
        var doc = plan
        doc["markup"] = markup
        return doc
    }

    // MARK: Storage

    private static let lock = NSLock()

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("app-settings.json")
    }

    static func load() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return d
    }

    /// Remembers what changed in a saved plan. Returns true if anything was stored.
    @discardableResult
    static func remember(from plan: [String: Any]) -> Bool {
        let stored = load()
        let diff = changes(plan: plan, stored: stored)
        guard !diff.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        var next = stored
        for (k, v) in diff { next[k] = v }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: next).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
