//
//  SupabaseClient.swift
//  SecureScan
//
//  SecureSuite's HTTP APIs (Supabase Auth, PostgREST, Storage) over plain
//  URLSession: no third-party packages. Stateless apart from the session;
//  tokens come from SyncAuth. Every failure is a SyncError.
//

import Foundation

final class SupabaseClient: @unchecked Sendable {
    let config: SyncConfig
    private let session: URLSession

    init(config: SyncConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, token: String?, json: Any? = nil,
                         headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = URL(string: config.baseURL.absoluteString + path) else { throw SyncError.badResponse }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        // Signed-out calls carry only the apikey (a publishable key is not a JWT).
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }
            return (data, http.statusCode)
        } catch {
            throw SyncError.wrap(error)
        }
    }

    /// The parsed body of a 2xx reply (nil when empty), else the error.
    private func checked(_ data: Data, _ status: Int) throws -> Any? {
        let obj: Any? = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        guard (200..<300).contains(status) else { throw SyncError.fromReply(status: status, json: obj) }
        return obj
    }

    // MARK: Auth

    func signIn(email: String, password: String) async throws -> [String: Any] {
        let r = try request("POST", "/auth/v1/token?grant_type=password", token: nil,
                            json: ["email": email, "password": password])
        let (d, s) = try await send(r)
        guard let obj = try checked(d, s) as? [String: Any] else { throw SyncError.badResponse }
        return obj
    }

    func refresh(refreshToken: String) async throws -> [String: Any] {
        let r = try request("POST", "/auth/v1/token?grant_type=refresh_token", token: nil,
                            json: ["refresh_token": refreshToken])
        let (d, s) = try await send(r)
        guard let obj = try checked(d, s) as? [String: Any] else { throw SyncError.badResponse }
        return obj
    }

    /// Best effort: the session is forgotten on the phone either way.
    func signOut(accessToken: String) async {
        guard let r = try? request("POST", "/auth/v1/logout", token: accessToken) else { return }
        _ = try? await send(r)
    }

    // MARK: PostgREST

    /// `pathQuery` is already encoded, e.g. "scan_jobs?id=eq.<uuid>&select=id,revision".
    func rest(_ method: String, _ pathQuery: String, token: String, body: Any? = nil,
              prefer: String? = nil) async throws -> Any? {
        var headers: [String: String] = [:]
        if let prefer { headers["Prefer"] = prefer }
        let r = try request(method, "/rest/v1/" + pathQuery, token: token, json: body, headers: headers)
        let (d, s) = try await send(r)
        return try checked(d, s)
    }

    /// The reply as rows (PostgREST answers arrays).
    func rows(_ method: String, _ pathQuery: String, token: String, body: Any? = nil,
              prefer: String? = nil) async throws -> [[String: Any]] {
        let obj = try await rest(method, pathQuery, token: token, body: body, prefer: prefer)
        if obj == nil { return [] }
        if let list = obj as? [[String: Any]] { return list }
        if let one = obj as? [String: Any] { return [one] }
        throw SyncError.badResponse
    }

    // MARK: Storage (bucket scan-files)

    /// Uploads (or replaces) one object from a file on disk.
    func upload(file: URL, objectPath: String, contentType: String, token: String) async throws {
        var r = try request("POST", "/storage/v1/object/\(SyncPaths.bucket)/\(SyncPaths.urlEncoded(objectPath))",
                            token: token,
                            headers: ["x-upsert": "true", "Content-Type": contentType, "cache-control": "3600"])
        r.timeoutInterval = 300
        do {
            let (data, response) = try await session.upload(for: r, fromFile: file)
            guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }
            _ = try checked(data, http.statusCode)
        } catch {
            throw SyncError.wrap(error)
        }
    }

    /// Downloads one object to a new temporary file (the caller moves it).
    func download(objectPath: String, token: String) async throws -> URL {
        var r = try request("GET", "/storage/v1/object/authenticated/\(SyncPaths.bucket)/\(SyncPaths.urlEncoded(objectPath))",
                            token: token)
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 300
        do {
            let (tmp, response) = try await session.download(for: r)
            guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                let body = try? Data(contentsOf: tmp)
                try? FileManager.default.removeItem(at: tmp)
                throw SyncError.fromReply(status: http.statusCode,
                                          json: body.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            }
            // Keep it: URLSession may clean its own temporary file up.
            let mine = FileManager.default.temporaryDirectory.appendingPathComponent("securesuite-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: tmp, to: mine)
            return mine
        } catch {
            throw SyncError.wrap(error)
        }
    }
}
