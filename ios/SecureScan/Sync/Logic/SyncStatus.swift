//
//  SyncStatus.swift
//  SecureScan
//
//  What a job's sync looks like to the user (card glyph, Files tab line), the
//  errors the sync code raises, and every sentence it shows: few, plain,
//  never blaming (docs/UX2.md). Pure; compiled into the unit tests.
//

import Foundation

enum SyncStatus: Equatable {
    /// No SecureSuite in this build (local only): nothing is shown.
    case off
    case signedOut
    case synced(Date?)
    /// Changes on this phone not sent yet.
    case pending
    case syncing(String?)
    case offline
    case error(String)
    /// Changes on SecureSuite wait until the job screen is closed (they are merged into plan.json).
    case waitingForClose
    case archived
    case removed

    var title: String {
        switch self {
        case .off: return "Cloud sync not configured"
        case .signedOut: return "Not signed in"
        case .synced: return "Saved to SecureSuite"
        case .pending: return "Waiting to sync"
        case .syncing: return "Syncing…"
        case .offline: return "Waiting for network"
        case .error: return "Couldn't sync"
        case .waitingForClose: return "New changes on SecureSuite"
        case .archived: return "Archived on SecureSuite"
        case .removed: return "Removed from SecureSuite"
        }
    }

    /// The second line (nil = none).
    func detail(now: Date = Date(), calendar: Calendar = .current) -> String? {
        switch self {
        case .off: return "Jobs stay on this iPhone"
        case .signedOut: return "Sign in to save this job to SecureSuite"
        case .synced(let d): return d.map { "Last synced " + SyncStatus.when($0, now: now, calendar: calendar) }
        case .pending: return "Changes on this iPhone go up next"
        case .syncing(let t): return t
        case .offline: return "Changes upload when you're back online"
        case .error(let reason): return reason
        case .waitingForClose: return "They're added when you leave this job"
        case .archived: return "Changes on this iPhone are no longer sent"
        case .removed: return "This copy stays on this iPhone"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "icloud.slash"
        case .signedOut: return "lock.icloud"
        case .synced: return "checkmark.icloud"
        case .pending: return "icloud.and.arrow.up"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "icloud.slash"
        case .error: return "exclamationmark.icloud"
        case .waitingForClose: return "icloud.and.arrow.down"
        case .archived: return "archivebox"
        case .removed: return "icloud.slash"
        }
    }

    enum Tone { case quiet, active, good, warning }

    var tone: Tone {
        switch self {
        case .synced: return .good
        case .syncing, .waitingForClose: return .active
        case .error: return .warning
        default: return .quiet
        }
    }

    /// "3:04 pm" today, "Yesterday 3:04 pm", else "14 Nov 3:04 pm".
    static func when(_ d: Date, now: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.timeZone = calendar.timeZone
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        let time = f.string(from: d)
        if calendar.isDate(d, inSameDayAs: now) { return time }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "yesterday " + time }
        f.dateFormat = "d MMM"
        return f.string(from: d) + " " + time
    }
}

enum SyncError: Error, Equatable {
    case notConfigured
    case notSignedIn
    case offline
    case cancelled
    /// HTTP status and the server's own message.
    case http(Int, String)
    case badResponse
    /// The row kept changing under this phone.
    case busy
    case local(String)

    static func wrap(_ error: Error) -> SyncError {
        if let e = error as? SyncError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError { return from(urlError: u.code) }
        return .local(error.localizedDescription)
    }

    static func from(urlError code: URLError.Code) -> SyncError {
        switch code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
            return .offline
        default: return .local("Network error (\(code.rawValue))")
        }
    }

    /// Status and message from an error reply. Supabase Storage answers 400
    /// with its own `statusCode` in the body ("403" for row-level security,
    /// "InvalidJWT" for an expired token): use those.
    static func fromReply(status: Int, json: Any?) -> SyncError {
        let d = json as? [String: Any]
        let message = [d?["message"], d?["msg"], d?["error_description"], d?["error"], d?["hint"]]
            .compactMap { $0 as? String }.first ?? ""
        var code = status
        if let inner = SyncJSON.int(d?["statusCode"]), inner >= 400 { code = inner }
        let low = (message + " " + ((d?["error"] as? String) ?? "")).lowercased()
        if low.contains("invalidjwt") || low.contains("jwt expired") || low.contains("\"exp\" claim") || low.contains("exp claim") {
            code = 401
        }
        return .http(code, message)
    }
}

enum SyncWords {
    static let enterBoth = "Enter your email and password."
    static let badEmail = "That email address doesn't look right."

    /// One short line under the sign-in fields.
    static func signIn(_ e: SyncError) -> String {
        switch e {
        case .offline: return "No internet connection. Try again when online."
        case .notConfigured: return "Cloud sync isn't set up in this build."
        case .http(let status, let message):
            let low = message.lowercased()
            if low.contains("not confirmed") { return "This account isn't confirmed yet." }
            if status == 429 || low.contains("rate limit") { return "Too many tries. Wait a minute and try again." }
            if status >= 500 { return "SecureSuite isn't answering. Try again soon." }
            if status == 400 || status == 401 || status == 403 || low.contains("invalid login") { return "Wrong email or password." }
            return "Couldn't sign in. Try again."
        default: return "Couldn't sign in. Try again."
        }
    }

    /// The reason in the Files tab line (short; the retry time is added by the caller).
    static func sync(_ e: SyncError) -> String {
        switch e {
        case .notConfigured: return "Cloud sync not configured"
        case .notSignedIn: return "Not signed in"
        case .offline: return "No connection"
        case .cancelled: return "Paused"
        case .busy: return "The job kept changing on SecureSuite"
        case .badResponse: return "Unexpected reply from SecureSuite"
        case .local(let m): return m
        case .http(let status, let message):
            let low = message.lowercased()
            if status == 401 { return "Sign-in expired" }
            if status == 403 || low.contains("row-level security") || low.contains("permission") { return "SecureSuite refused access" }
            if status == 404 && low.contains("bucket") { return "File storage isn't set up" }
            if status == 413 || low.contains("too large") || low.contains("maximum allowed size") { return "A file is too big to upload" }
            if status >= 500 { return "SecureSuite isn't answering" }
            return "SecureSuite said no (\(status))"
        }
    }

    static func validateSignIn(email: String, password: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty || password.isEmpty { return enterBoth }
        let parts = e.split(separator: "@")
        if parts.count != 2 || !parts[1].contains(".") || e.contains(" ") { return badEmail }
        return nil
    }
}
