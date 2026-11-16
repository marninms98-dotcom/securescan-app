//
//  SyncSession.swift
//  SecureScan
//
//  The signed-in SecureSuite session (Supabase Auth), who the user is, and
//  the retry timing. Pure; compiled into the unit tests. The session itself
//  is stored in the Keychain by SyncAuth.
//

import Foundation

struct SyncSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String

    /// Refresh this long before the access token runs out.
    static let refreshMargin: TimeInterval = 120

    func needsRefresh(now: Date = Date(), margin: TimeInterval = SyncSession.refreshMargin) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }

    func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

    /// From a /auth/v1/token response. Expiry: `expires_at` (seconds since
    /// 1970), else the access token's own `exp`, else now + `expires_in`
    /// (default one hour). `previous` fills the user when a refresh response
    /// leaves it out.
    static func from(json: [String: Any], now: Date = Date(), previous: SyncSession? = nil) -> SyncSession? {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        let user = json["user"] as? [String: Any]
        let userID = (user?["id"] as? String) ?? jwtClaim(access, "sub") ?? previous?.userID ?? ""
        guard !userID.isEmpty else { return nil }
        let email = (user?["email"] as? String) ?? previous?.email ?? ""
        let expiry: Date
        if let at = (json["expires_at"] as? NSNumber)?.doubleValue, at > 0 {
            expiry = Date(timeIntervalSince1970: at)
        } else if let exp = jwtExpiry(access) {
            expiry = exp
        } else {
            let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            expiry = now.addingTimeInterval(seconds)
        }
        return SyncSession(accessToken: access, refreshToken: refresh, expiresAt: expiry, userID: userID, email: email)
    }

    static func jwtExpiry(_ token: String) -> Date? {
        guard let exp = jwtPayload(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    static func jwtClaim(_ token: String, _ name: String) -> String? {
        jwtPayload(token)?[name] as? String
    }

    /// The JWT's middle part, base64url-decoded (not verified: only read for timing).
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Who is signed in (public.users), for Settings.
struct SyncProfile: Codable, Equatable {
    var userID: String
    var email: String
    var name: String
    var role: String
    var orgID: String

    /// "Admin", "Field tech" from "admin", "field_tech".
    var roleTitle: String { SyncText.title(role) }

    var displayName: String { name.isEmpty ? (email.isEmpty ? "SecureSuite user" : email) : name }

    var initials: String {
        let words = displayName.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let s = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    /// From a `users` row (`select=*`): `name`, else `full_name` / `display_name`.
    static func from(row: [String: Any], userID: String, email: String) -> SyncProfile {
        let name = (row["name"] as? String) ?? (row["full_name"] as? String) ?? (row["display_name"] as? String) ?? ""
        return SyncProfile(userID: userID, email: (row["email"] as? String) ?? email,
                           name: name.trimmingCharacters(in: .whitespaces),
                           role: (row["role"] as? String) ?? "", orgID: SyncJSON.string(row["org_id"]) ?? "")
    }
}

enum SyncBackoff {
    /// 15 s, 30 s, 1 min, 2 min … capped at 15 min.
    static func delay(attempt: Int, base: TimeInterval = 15, cap: TimeInterval = 900) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exp = min(attempt - 1, 16)
        return min(cap, base * pow(2, Double(exp)))
    }

    /// "in 2 min", "in 30 s".
    static func words(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "in \(max(1, Int(seconds.rounded()))) s" }
        return "in \(Int((seconds / 60).rounded())) min"
    }
}

enum SyncText {
    /// "in_progress" -> "In progress".
    static func title(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = t.first else { return "" }
        return first.uppercased() + t.dropFirst()
    }
}
