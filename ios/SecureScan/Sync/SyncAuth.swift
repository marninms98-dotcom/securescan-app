//
//  SyncAuth.swift
//  SecureScan
//
//  The SecureSuite session: signed in with email + password, kept in the
//  Keychain (this device only, readable after first unlock so a background
//  sync can refresh it), refreshed shortly before it runs out. One refresh
//  at a time: Supabase rotates refresh tokens, so two parallel refreshes
//  with the same token would sign the user out.
//

import Foundation
import Security

enum SessionKeychain {
    private static let service = "com.secureworkswa.securescan.securesuite"
    private static let account = "session"

    static func load() -> SyncSession? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(SyncSession.self, from: data)
    }

    @discardableResult
    static func save(_ s: SyncSession) -> Bool {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let data = try? e.encode(s) else { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
    }
}

actor SyncAuth {
    static let shared = SyncAuth()

    private var session: SyncSession?
    private var loaded = false
    private var refreshing: Task<SyncSession, Error>?

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        session = SessionKeychain.load()
    }

    func current() -> SyncSession? {
        ensureLoaded()
        return session
    }

    func signIn(client: SupabaseClient, email: String, password: String) async throws -> SyncSession {
        ensureLoaded()
        let json = try await client.signIn(email: email, password: password)
        guard let s = SyncSession.from(json: json) else { throw SyncError.badResponse }
        session = s
        SessionKeychain.save(s)
        return s
    }

    /// A usable access token, refreshed first when it is about to run out.
    func validToken(client: SupabaseClient) async throws -> String {
        ensureLoaded()
        guard let s = session else { throw SyncError.notSignedIn }
        if !s.needsRefresh() { return s.accessToken }
        return try await refreshed(client: client).accessToken
    }

    /// After a 401: refresh even if the clock says the token is still good.
    func forceRefresh(client: SupabaseClient) async throws -> String {
        ensureLoaded()
        return try await refreshed(client: client).accessToken
    }

    private func refreshed(client: SupabaseClient) async throws -> SyncSession {
        if let running = refreshing { return try await running.value }
        guard let s = session else { throw SyncError.notSignedIn }
        let task = Task { () throws -> SyncSession in
            let json = try await client.refresh(refreshToken: s.refreshToken)
            guard let fresh = SyncSession.from(json: json, previous: s) else { throw SyncError.badResponse }
            return fresh
        }
        refreshing = task
        do {
            let fresh = try await task.value
            refreshing = nil
            session = fresh
            SessionKeychain.save(fresh)
            return fresh
        } catch let e as SyncError {
            refreshing = nil
            if case .http(let code, _) = e, code == 400 || code == 401 || code == 403 {
                // The refresh token was revoked or already used: signed out.
                session = nil
                SessionKeychain.clear()
                throw SyncError.notSignedIn
            }
            throw e
        } catch {
            refreshing = nil
            throw SyncError.wrap(error)
        }
    }

    func signOut(client: SupabaseClient?) async {
        ensureLoaded()
        let token = session?.accessToken
        session = nil
        SessionKeychain.clear()
        if let client, let token { await client.signOut(accessToken: token) }
    }
}
