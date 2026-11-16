//
//  SyncTests.swift
//  SecureScanTests
//
//  SecureSuite sync, pure logic only (no backend in CI): configuration,
//  object paths, the files manifest diff, the plan and log merges, the
//  session's expiry, timestamps, the job picker's search, error wording.
//

import XCTest

final class SyncConfigTests: XCTestCase {

    func testEmptyOrUnexpandedMeansLocalOnly() {
        XCTAssertNil(SyncConfig.parse(url: nil, key: nil))
        XCTAssertNil(SyncConfig.parse(url: "", key: ""))
        XCTAssertNil(SyncConfig.parse(url: "https://abc.supabase.co", key: ""))
        XCTAssertNil(SyncConfig.parse(url: "", key: "sb_publishable_x"))
        XCTAssertNil(SyncConfig.parse(url: "$(SUPABASE_URL)", key: "$(SUPABASE_ANON_KEY)"))
        XCTAssertNil(SyncConfig.parse(url: "https://abc.supabase.co", key: "${SUPABASE_ANON_KEY}"))
        XCTAssertNil(SyncConfig.fromInfo(nil))
        XCTAssertNil(SyncConfig.fromInfo(["SECURESCAN_SUPABASE_URL": "", "SECURESCAN_SUPABASE_KEY": ""]))
    }

    func testURLIsCleaned() {
        let c = SyncConfig.parse(url: "  https://abc.supabase.co/ ", key: " sb_publishable_123 ")
        XCTAssertEqual(c?.baseURL.absoluteString, "https://abc.supabase.co")
        XCTAssertEqual(c?.anonKey, "sb_publishable_123")
        XCTAssertEqual(SyncConfig.parse(url: "abc.supabase.co", key: "k")?.baseURL.absoluteString, "https://abc.supabase.co")
        XCTAssertEqual(SyncConfig.parse(url: "\"https://abc.supabase.co\"", key: "'k'")?.anonKey, "k")
        let info: [String: Any] = ["SECURESCAN_SUPABASE_URL": "https://x.supabase.co", "SECURESCAN_SUPABASE_KEY": "key"]
        XCTAssertEqual(SyncConfig.fromInfo(info)?.baseURL.host, "x.supabase.co")
    }

    func testHTTPSOnlyExceptLocalDev() {
        XCTAssertNil(SyncConfig.parse(url: "http://abc.supabase.co", key: "k"))
        XCTAssertNil(SyncConfig.parse(url: "ftp://abc.supabase.co", key: "k"))
        XCTAssertNil(SyncConfig.parse(url: "https://", key: "k"))
        XCTAssertNil(SyncConfig.parse(url: "https://abc.supabase.co", key: "two words"))
        XCTAssertNotNil(SyncConfig.parse(url: "http://localhost:54321", key: "k"))
    }
}

final class SyncPathTests: XCTestCase {
    let org = "2C9A4F3E-7B61-4D2A-8E0F-5A3B1C9D7E42"
    let job = "6B1F3C2E-0D4A-4C55-9A51-2F7D1E8B9C10"

    func testObjectPathIsOrgThenJobThenRelativePath() {
        XCTAssertEqual(SyncPaths.objectPath(org: org, job: job, relative: "photos/r1-full.jpg"),
                       "2c9a4f3e-7b61-4d2a-8e0f-5a3b1c9d7e42/6b1f3c2e-0d4a-4c55-9a51-2f7d1e8b9c10/photos/r1-full.jpg")
        XCTAssertEqual(SyncPaths.objectPath(org: org.lowercased(), job: job, relative: "/rooms//1.json"),
                       "2c9a4f3e-7b61-4d2a-8e0f-5a3b1c9d7e42/6b1f3c2e-0d4a-4c55-9a51-2f7d1e8b9c10/rooms/1.json")
        XCTAssertEqual(SyncPaths.objectPath(org: org, job: job, relative: "./model.usdz")?.hasSuffix("/model.usdz"), true)
    }

    func testUnsafePathsAndBadIdsAreRefused() {
        XCTAssertNil(SyncPaths.objectPath(org: org, job: job, relative: "../other/plan.json"))
        XCTAssertNil(SyncPaths.objectPath(org: org, job: job, relative: "photos/../../x"))
        XCTAssertNil(SyncPaths.objectPath(org: org, job: job, relative: ""))
        XCTAssertNil(SyncPaths.objectPath(org: "", job: job, relative: "plan.json"))
        XCTAssertNil(SyncPaths.objectPath(org: "my-org", job: job, relative: "plan.json"))
        XCTAssertNil(SyncPaths.objectPath(org: org, job: "job-1", relative: "plan.json"))
    }

    func testURLEncodingKeepsSlashes() {
        XCTAssertEqual(SyncPaths.urlEncoded("a/b c/é.jpg"), "a/b%20c/%C3%A9.jpg")
        XCTAssertEqual(SyncPaths.urlEncoded("org/job/photos/P1-full.jpg"), "org/job/photos/P1-full.jpg")
    }

    func testWhatIsUploaded() {
        for p in ["readings-raw.json", "photos/r1.jpg", "photos/r1-full.jpg", "audio/001.m4a", "voice.json",
                  "rooms/1.json", "model.usdz", "thumb.png", "job.json", "securesuite.json", "worldmap.bin",
                  "plan.conflict-20261116-031505.json", "conflicts/20261116-031505/photos/a.jpg"] {
            XCTAssertTrue(SyncPaths.isSyncable(p), p)
        }
        // plan.json travels in the row; work in progress stays on the phone.
        for p in ["plan.json", "scan-open", "audio/002.wav", ".DS_Store", "photos/.tmp.jpg", "tmp/x.json", "a.part", "../x"] {
            XCTAssertFalse(SyncPaths.isSyncable(p), p)
        }
    }

    func testKinds() {
        XCTAssertEqual(SyncPaths.kind(for: "photos/r1.jpg"), "photo")
        XCTAssertEqual(SyncPaths.kind(for: "photos/r1-full.jpg"), "photo_full")
        XCTAssertEqual(SyncPaths.kind(for: "audio/001.m4a"), "audio")
        XCTAssertEqual(SyncPaths.kind(for: "voice.json"), "transcript")
        XCTAssertEqual(SyncPaths.kind(for: "readings-raw.json"), "readings")
        XCTAssertEqual(SyncPaths.kind(for: "rooms/2.json"), "room")
        XCTAssertEqual(SyncPaths.kind(for: "model.usdz"), "model")
        XCTAssertEqual(SyncPaths.kind(for: "thumb.png"), "thumbnail")
        XCTAssertEqual(SyncPaths.kind(for: "securesuite.json"), "link")
        XCTAssertEqual(SyncPaths.kind(for: "plan.conflict-20261116-031505.json"), "conflict")
        XCTAssertEqual(SyncPaths.kind(for: "conflicts/x/rooms/1.json"), "conflict")
        XCTAssertEqual(SyncPaths.contentType(for: "photos/a.JPG"), "image/jpeg")
        XCTAssertEqual(SyncPaths.contentType(for: "audio/001.m4a"), "audio/mp4")
        XCTAssertEqual(SyncPaths.contentType(for: "worldmap.bin"), "application/octet-stream")
    }

    func testConflictNames() {
        let d = Date(timeIntervalSince1970: 1_794_798_905)   // 2026-11-16 03:15:05 UTC
        XCTAssertEqual(SyncPaths.planConflictName(d), "plan.conflict-20261116-031505.json")
        XCTAssertEqual(SyncPaths.conflictCopyPath("rooms/3.json", date: d), "conflicts/20261116-031505/rooms/3.json")
        // Never inside rooms/ (JobFolder.roomFiles reads every .json there).
        XCTAssertFalse(SyncPaths.conflictCopyPath("rooms/3.json", date: d).hasPrefix("rooms/"))
    }
}

final class SyncManifestTests: XCTestCase {

    func testDiffDecidesPerFile() {
        let base = ["same": "a", "mine": "a", "theirs": "a", "both": "a", "deleted": "a"]
        let local = ["same": "a", "mine": "B", "theirs": "a", "both": "B", "new-here": "n"]
        let remote = ["same": "a", "mine": "a", "theirs": "C", "both": "C", "deleted": "a", "new-there": "t"]
        let d = SyncDiff.compute(local: local, remote: remote, base: base)
        XCTAssertEqual(d.upload, ["mine", "new-here"])
        XCTAssertEqual(d.download, ["new-there", "theirs"])
        XCTAssertEqual(d.conflicts, ["both"])
        XCTAssertEqual(d.removedHere, ["deleted"])
    }

    func testFirstSyncWithoutBase() {
        // Never synced: everything here goes up, everything only there comes down,
        // a file both have with different content is a conflict (never overwritten blindly).
        let d = SyncDiff.compute(local: ["a": "1", "b": "2"], remote: ["b": "3", "c": "4"], base: [:])
        XCTAssertEqual(d.upload, ["a"])
        XCTAssertEqual(d.download, ["c"])
        XCTAssertEqual(d.conflicts, ["b"])
        XCTAssertEqual(d.removedHere, [])
    }

    func testUnchangedIsNothing() {
        let same = ["plan-frame.json": "x", "photos/a.jpg": "y"]
        XCTAssertEqual(SyncDiff.compute(local: same, remote: same, base: same), SyncDiff())
        XCTAssertEqual(SyncDiff.compute(local: same, remote: same, base: [:]), SyncDiff())
    }

    func testManifestNeverDropsAnotherPhonesFile() {
        func e(_ p: String, _ s: String, _ b: Int = 1) -> SyncFileEntry { SyncFileEntry(path: p, kind: SyncPaths.kind(for: p), bytes: b, sha256: s, updatedAt: "") }
        let local = ["photos/mine.jpg": e("photos/mine.jpg", "m"), "job.json": e("job.json", "j2")]
        let remote = ["photos/theirs.jpg": e("photos/theirs.jpg", "t"), "job.json": e("job.json", "j1"),
                      "photos/deleted-here.jpg": e("photos/deleted-here.jpg", "d")]
        let m = SyncDiff.manifest(local: local, remote: remote, removedHere: ["photos/deleted-here.jpg"])
        XCTAssertEqual(m.map(\.path), ["job.json", "photos/mine.jpg", "photos/theirs.jpg"])
        XCTAssertEqual(m.first { $0.path == "job.json" }?.sha256, "j2")
    }

    func testUploadOrderSmallFirst() {
        let list = [SyncFileEntry(path: "model.usdz", kind: "model", bytes: 9_000_000, sha256: "a", updatedAt: ""),
                    SyncFileEntry(path: "readings-raw.json", kind: "readings", bytes: 4_000, sha256: "b", updatedAt: ""),
                    SyncFileEntry(path: "photos/a-full.jpg", kind: "photo_full", bytes: 3_000_000, sha256: "c", updatedAt: ""),
                    SyncFileEntry(path: "photos/a.jpg", kind: "photo", bytes: 200_000, sha256: "d", updatedAt: "")]
        XCTAssertEqual(SyncDiff.uploadOrder(list).map(\.path), ["readings-raw.json", "photos/a.jpg", "photos/a-full.jpg", "model.usdz"])
    }

    func testEntryJSONRoundTrip() {
        let e = SyncFileEntry(path: "photos/a.jpg", kind: "photo", bytes: 12, sha256: "ABC", updatedAt: "2026-11-16T03:00:00Z")
        XCTAssertEqual(e.json["updated_at"] as? String, "2026-11-16T03:00:00Z")
        let back = SyncFileEntry(json: e.json)
        XCTAssertEqual(back?.sha256, "abc")
        XCTAssertEqual(back?.bytes, 12)
        XCTAssertNil(SyncFileEntry(json: ["path": "../x", "sha256": "a"]))
        XCTAssertNil(SyncFileEntry(json: ["path": "a.jpg"]))
        let list = SyncFileEntry.list([e.json, ["junk": 1], "x"] as [Any])
        XCTAssertEqual(Array(list.keys), ["photos/a.jpg"])
    }

    func testConflictRules() {
        XCTAssertEqual(ConflictRule.rule(for: "readings-raw.json"), .mergeJSON)
        XCTAssertEqual(ConflictRule.rule(for: "voice.json"), .mergeJSON)
        XCTAssertEqual(ConflictRule.rule(for: "job.json"), .keepLocal)
        XCTAssertEqual(ConflictRule.rule(for: "thumb.png"), .keepLocal)
        XCTAssertEqual(ConflictRule.rule(for: "photos/a.jpg"), .keepBoth)
        XCTAssertEqual(ConflictRule.rule(for: "audio/001.m4a"), .keepBoth)
        XCTAssertEqual(ConflictRule.rule(for: "rooms/1.json"), .keepBoth)
    }

    func testHash() {
        XCTAssertEqual(SyncHash.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-hash-\(UUID().uuidString)")
        let big = Data(repeating: 7, count: 3 * (1 << 20) + 5)
        try? big.write(to: url)
        XCTAssertEqual(try? SyncHash.sha256(fileAt: url), SyncHash.sha256(big))
        try? FileManager.default.removeItem(at: url)
    }
}

final class PlanMergeTests: XCTestCase {

    private func plan(_ markup: [String: Any], updatedAt: String = "2026-11-16T01:00:00Z", walls: [[String: Any]] = []) -> [String: Any] {
        ["version": 1, "id": "job", "address": "14 Kingsway", "updatedAt": updatedAt, "walls": walls, "markup": markup]
    }

    func testUnionByIdKeepsEveryItem() {
        let local = plan(["readings": [["id": "r1", "value": 18], ["id": "r2", "value": 22]],
                          "sources": [["id": "s1", "label": "Shower"]]])
        let server = plan(["readings": [["id": "r1", "value": 18], ["id": "r3", "value": 30]],
                           "notes": [["id": "n1", "text": "Skirting swollen"]]])
        let r = PlanMerge.merge(local: local, server: server)
        let m = r.plan["markup"] as? [String: Any]
        XCTAssertEqual((m?["readings"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["r1", "r2", "r3"])
        XCTAssertEqual((m?["sources"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((m?["notes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(r.stats.fromServer, 2)
        XCTAssertTrue(PlanMerge.itemIDs(local).isSubset(of: PlanMerge.itemIDs(r.plan)))
        XCTAssertTrue(PlanMerge.itemIDs(server).isSubset(of: PlanMerge.itemIDs(r.plan)))
    }

    func testSameIdNewerWinsElseServer() {
        let local = plan(["readings": [
            ["id": "a", "value": 10, "takenAt": "2026-11-16T05:00:00Z"],   // newer here
            ["id": "b", "value": 11, "takenAt": "2026-11-16T01:00:00Z"],   // older here
            ["id": "c", "value": 12],                                     // no time
            ["id": "d", "value": 13, "updated": "2026-11-16T09:00:00Z", "takenAt": "2026-11-15T01:00:00Z"],
        ]])
        let server = plan(["readings": [
            ["id": "a", "value": 20, "takenAt": "2026-11-16T04:00:00Z"],
            ["id": "b", "value": 21, "takenAt": "2026-11-16T02:00:00Z"],
            ["id": "c", "value": 22],
            ["id": "d", "value": 23, "updated": "2026-11-16T08:00:00Z", "takenAt": "2026-11-15T01:00:00Z"],
        ]])
        let r = PlanMerge.merge(local: local, server: server)
        let values = ((r.plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]])?.map { ($0["id"] as? String ?? "", $0["value"] as? Int ?? 0) }
        XCTAssertEqual(values?.map(\.0), ["a", "b", "c", "d"])
        XCTAssertEqual(values?.map(\.1), [10, 21, 22, 13])
        XCTAssertEqual(r.stats.localKept, 2)
        XCTAssertEqual(r.stats.serverKept, 2)
    }

    func testReMeasurementsFromBothPhonesAreKept() {
        let local = plan(["readings": [["id": "m1", "value": 30, "takenAt": "2026-11-16T03:00:00Z",
                                        "history": [["visit": "v1", "value": 40, "takenAt": "2026-11-12T03:00:00Z"],
                                                    ["visit": "v3", "value": 30, "takenAt": "2026-11-16T03:00:00Z"]]]]])
        let server = plan(["readings": [["id": "m1", "value": 35, "takenAt": "2026-11-14T03:00:00Z",
                                         "history": [["visit": "v1", "value": 40, "takenAt": "2026-11-12T03:00:00Z"],
                                                     ["visit": "v2", "value": 35, "takenAt": "2026-11-14T03:00:00Z"]]]]])
        let r = PlanMerge.merge(local: local, server: server)
        let m1 = ((r.plan["markup"] as? [String: Any])?["readings"] as? [[String: Any]])?.first
        let visits = (m1?["history"] as? [[String: Any]])?.compactMap { $0["visit"] as? String }
        XCTAssertEqual(Set(visits ?? []), ["v1", "v2", "v3"])
        // The top-level value mirrors the latest visit.
        XCTAssertEqual(m1?["value"] as? Int, 30)
        XCTAssertEqual(m1?["takenAt"] as? String, "2026-11-16T03:00:00Z")
    }

    func testGeometryAndSettingsAreThisPhones() {
        let local = plan(["thresholds": ["damp": 15, "wet": 20], "readings": [[String: Any]]()],
                         walls: [["id": "w1", "a": [0, 0], "b": [3, 0]]])
        let server = plan(["thresholds": ["damp": 17, "wet": 25], "currentVisit": "v2", "readings": [[String: Any]]()],
                          walls: [["id": "w9", "a": [0, 0], "b": [9, 0]]])
        let r = PlanMerge.merge(local: local, server: server)
        XCTAssertEqual((r.plan["walls"] as? [[String: Any]])?.first?["id"] as? String, "w1")
        let m = r.plan["markup"] as? [String: Any]
        XCTAssertEqual((m?["thresholds"] as? [String: Any])?["damp"] as? Int, 15)
        // A setting only the server has is added.
        XCTAssertEqual(m?["currentVisit"] as? String, "v2")
    }

    func testNestedScopeItemsAndNewerUpdatedAt() {
        let local = plan(["scope": ["gst": 0.1, "items": [["id": "sc1", "desc": "Air mover hire"]]]], updatedAt: "2026-11-16T01:00:00Z")
        let server = plan(["scope": ["gst": 0.1, "items": [["id": "sc2", "desc": "Seal wall"]]]], updatedAt: "2026-11-16T02:00:00Z")
        let r = PlanMerge.merge(local: local, server: server)
        let items = (((r.plan["markup"] as? [String: Any])?["scope"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(items?.compactMap { $0["id"] as? String }, ["sc1", "sc2"])
        XCTAssertEqual(r.plan["updatedAt"] as? String, "2026-11-16T02:00:00Z")
    }

    func testMissingMarkupOnEitherSide() {
        let bare: [String: Any] = ["version": 1, "walls": [[String: Any]]()]
        let withItems = plan(["readings": [["id": "r1", "value": 9]]])
        XCTAssertEqual(PlanMerge.itemIDs(PlanMerge.merge(local: bare, server: withItems).plan), ["readings:r1"])
        XCTAssertEqual(PlanMerge.itemIDs(PlanMerge.merge(local: withItems, server: bare).plan), ["readings:r1"])
    }

    func testIdListDetection() {
        XCTAssertNotNil(PlanMerge.idList([[String: Any]]()))
        XCTAssertNotNil(PlanMerge.idList([["id": "a"]]))
        XCTAssertNil(PlanMerge.idList([["value": 1]]))
        XCTAssertNil(PlanMerge.idList([1, 2]))
        XCTAssertNil(PlanMerge.idList("x"))
    }
}

final class FileMergeTests: XCTestCase {

    private func json(_ any: Any) -> Data { try! JSONSerialization.data(withJSONObject: any) }

    func testRawReadingsUnionById() {
        let local = json(["version": 1, "readings": [["id": "a", "seq": 1], ["id": "b", "seq": 2]]])
        let server = json(["version": 1, "readings": [["id": "b", "seq": 9], ["id": "c", "seq": 3]]])
        let out = FileMerge.merge(path: "readings-raw.json", local: local, server: server)
        let obj = out.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let readings = obj?["readings"] as? [[String: Any]]
        XCTAssertEqual(readings?.compactMap { $0["id"] as? String }, ["a", "b", "c"])
        XCTAssertEqual(readings?[1]["seq"] as? Int, 2)   // this phone's copy of "b"
    }

    func testVoiceIndexUnionByFile() {
        let local = json(["version": 1, "recordings": [["file": "audio/001.m4a", "state": "transcribed"]]])
        let server = json(["version": 1, "recordings": [["file": "audio/001.m4a", "state": "saved"], ["file": "audio/002.m4a", "state": "saved"]]])
        let obj = FileMerge.merge(path: "voice.json", local: local, server: server).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let recs = obj?["recordings"] as? [[String: Any]]
        XCTAssertEqual(recs?.compactMap { $0["file"] as? String }, ["audio/001.m4a", "audio/002.m4a"])
        XCTAssertEqual(recs?.first?["state"] as? String, "transcribed")
    }

    func testArrayLogUnion() {
        let local = json([["id": "s1"], ["at": "x"]])
        let server = json([["id": "s1"], ["id": "s2"], ["at": "x"], ["at": "y"]])
        let arr = FileMerge.merge(path: "revisit-log.json", local: local, server: server).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any]
        XCTAssertEqual(arr?.count, 4)
    }

    func testNotJSONIsNotMerged() {
        XCTAssertNil(FileMerge.merge(path: "readings-raw.json", local: Data("x".utf8), server: json(["readings": [Any]()])))
    }
}

final class SyncSessionTests: XCTestCase {

    private func jwt(_ payload: [String: Any]) -> String {
        let body = try! JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
    }

    func testFromTokenResponse() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = SyncSession.from(json: ["access_token": "a.b.c", "refresh_token": "r1", "expires_in": 3600,
                                        "expires_at": 1_800_003_600, "user": ["id": "U1", "email": "j@example.com"]], now: now)
        XCTAssertEqual(s?.userID, "U1")
        XCTAssertEqual(s?.email, "j@example.com")
        XCTAssertEqual(s?.expiresAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertNil(SyncSession.from(json: ["access_token": "a"], now: now))
        XCTAssertNil(SyncSession.from(json: ["access_token": "", "refresh_token": "r", "user": ["id": "u"]], now: now))
    }

    func testExpiryFallsBackToTheTokenThenExpiresIn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = jwt(["sub": "U2", "exp": 1_800_000_900])
        let s = SyncSession.from(json: ["access_token": token, "refresh_token": "r"], now: now)
        XCTAssertEqual(s?.userID, "U2")
        XCTAssertEqual(s?.expiresAt, Date(timeIntervalSince1970: 1_800_000_900))
        let t = SyncSession.from(json: ["access_token": "opaque", "refresh_token": "r", "expires_in": 600, "user": ["id": "u"]], now: now)
        XCTAssertEqual(t?.expiresAt, now.addingTimeInterval(600))
    }

    func testRefreshKeepsTheUser() {
        let old = SyncSession(accessToken: "a", refreshToken: "r", expiresAt: Date(), userID: "U1", email: "j@example.com")
        let s = SyncSession.from(json: ["access_token": "opaque", "refresh_token": "r2", "expires_in": 3600], previous: old)
        XCTAssertEqual(s?.userID, "U1")
        XCTAssertEqual(s?.email, "j@example.com")
        XCTAssertEqual(s?.refreshToken, "r2")
    }

    func testRefreshTiming() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = SyncSession(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(600), userID: "u", email: "")
        XCTAssertFalse(s.needsRefresh(now: now))
        XCTAssertFalse(s.needsRefresh(now: now.addingTimeInterval(479)))
        XCTAssertTrue(s.needsRefresh(now: now.addingTimeInterval(480)))   // 2 min before
        XCTAssertFalse(s.isExpired(now: now.addingTimeInterval(599)))
        XCTAssertTrue(s.isExpired(now: now.addingTimeInterval(600)))
    }

    func testBackoff() {
        XCTAssertEqual(SyncBackoff.delay(attempt: 0), 0)
        XCTAssertEqual(SyncBackoff.delay(attempt: 1), 15)
        XCTAssertEqual(SyncBackoff.delay(attempt: 2), 30)
        XCTAssertEqual(SyncBackoff.delay(attempt: 4), 120)
        XCTAssertEqual(SyncBackoff.delay(attempt: 20), 900)
        XCTAssertEqual(SyncBackoff.words(30), "in 30 s")
        XCTAssertEqual(SyncBackoff.words(120), "in 2 min")
    }

    func testProfile() {
        let p = SyncProfile.from(row: ["org_id": "O1", "name": "Jordan Lee", "role": "field_tech"], userID: "u", email: "j@example.com")
        XCTAssertEqual(p.orgID, "O1")
        XCTAssertEqual(p.roleTitle, "Field tech")
        XCTAssertEqual(p.initials, "JL")
        let q = SyncProfile.from(row: [:], userID: "u", email: "sam@example.com")
        XCTAssertEqual(q.displayName, "sam@example.com")
        XCTAssertEqual(SyncProfile.from(row: ["full_name": "Ana Ruiz"], userID: "u", email: "").name, "Ana Ruiz")
    }
}

final class SyncRecordTests: XCTestCase {

    func testPostgresTimestamps() {
        let expected = Date(timeIntervalSince1970: 1_794_798_905.123)
        for s in ["2026-11-16T03:15:05.123456+00:00", "2026-11-16T03:15:05.123Z", "2026-11-16 03:15:05.123+00", "2026-11-16T03:15:05.1234+0000"] {
            guard let d = SyncTime.parse(s) else { return XCTFail(s) }
            XCTAssertEqual(d.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, s)
        }
        XCTAssertEqual(SyncTime.parse("2026-11-16T03:15:05Z")?.timeIntervalSince1970, 1_794_798_905)
        XCTAssertEqual(SyncTime.parse("2026-11-16T11:15:05+08:00")?.timeIntervalSince1970, 1_794_798_905)
        XCTAssertNotNil(SyncTime.parse("2026-11-19"))
        XCTAssertNil(SyncTime.parse(""))
        XCTAssertNil(SyncTime.parse(nil))
        XCTAssertNil(SyncTime.parse(42))
    }

    func testScanJobRow() {
        let row = ScanJobRow.from(["id": "6B1F3C2E-0D4A-4C55-9A51-2F7D1E8B9C10", "org_id": "2C9A4F3E-7B61-4D2A-8E0F-5A3B1C9D7E42",
                                   "revision": 7, "job_id": NSNull(), "title": "14 Kingsway", "deleted_at": NSNull(),
                                   "files": [["path": "photos/a.jpg", "kind": "photo", "bytes": 10, "sha256": "aa", "updated_at": "x"]],
                                   "plan": [String: Any](), "updated_at": "2026-11-16T03:15:05.123456+00:00",
                                   "job": ["job_number": 2418, "client_name": "Dana"]])
        XCTAssertEqual(row?.id, "6b1f3c2e-0d4a-4c55-9a51-2f7d1e8b9c10")
        XCTAssertEqual(row?.orgID, "2c9a4f3e-7b61-4d2a-8e0f-5a3b1c9d7e42")
        XCTAssertEqual(row?.revision, 7)
        XCTAssertNil(row?.jobID)
        XCTAssertEqual(row?.deleted, false)
        XCTAssertEqual(row?.files["photos/a.jpg"]?.sha256, "aa")
        XCTAssertEqual(row?.hasPlan, false)
        XCTAssertEqual(row?.jobNumber, "2418")
        XCTAssertNotNil(row?.updatedAt)
        XCTAssertEqual(ScanJobRow.from(["id": "x", "deleted_at": "2026-11-16"])?.deleted, nil)
        XCTAssertEqual(ScanJobRow.from(["id": "6B1F3C2E-0D4A-4C55-9A51-2F7D1E8B9C10", "deleted_at": "2026-11-16T00:00:00Z"])?.deleted, true)
        XCTAssertTrue(ScanJobRow.isRealPlan(["version": 1, "walls": [Any]()]))
        XCTAssertFalse(ScanJobRow.isRealPlan(nil))
    }

    func testSecureSuiteJob() {
        let j = SecureSuiteJob.from(["id": "A1", "job_number": "SW-2418", "status": "in_progress", "client_name": "Dana",
                                     "site_address": "14 Kingsway", "site_suburb": "Wangara", "created_at": "2026-11-16T03:15:05+00:00"])
        XCTAssertEqual(j?.id, "a1")
        XCTAssertEqual(j?.addressLine, "14 Kingsway, Wangara")
        XCTAssertEqual(j?.statusTitle, "In progress")
        XCTAssertEqual(j?.tone, .active)
        var k = j!
        k.siteAddress = "14 Kingsway, Wangara WA"
        XCTAssertEqual(k.addressLine, "14 Kingsway, Wangara WA")
        k.siteAddress = ""
        XCTAssertEqual(k.addressLine, "Wangara")
        XCTAssertEqual(JobStatusTone.of("Completed"), .done)
        XCTAssertEqual(JobStatusTone.of("on hold"), .waiting)
        XCTAssertEqual(JobStatusTone.of("something new"), .neutral)
        XCTAssertEqual(SecureSuiteLink(job: j!).title, "SW-2418 · Dana")
    }

    func testPickerSearch() {
        func job(_ n: String, _ client: String, _ addr: String, _ suburb: String, _ t: TimeInterval?) -> SecureSuiteJob {
            SecureSuiteJob(id: n, jobNumber: n, status: "", type: "", clientName: client, siteAddress: addr, siteSuburb: suburb,
                           createdAt: t.map { Date(timeIntervalSince1970: $0) })
        }
        let recent = [job("SW-1", "Dana Whitfield", "14 Kingsway", "Wangara", 100),
                      job("SW-2", "Raj Natarajan", "118 Wanneroo Rd", "Madeley", 300),
                      job("SW-3", "Strata 41207", "7 Marri Rd", "Madeley", nil)]
        XCTAssertEqual(JobPickerFilter.combine(recent: recent, found: [], query: "").map(\.id), ["SW-2", "SW-1", "SW-3"])
        XCTAssertEqual(JobPickerFilter.combine(recent: recent, found: [], query: "madeley").map(\.id), ["SW-2", "SW-3"])
        XCTAssertEqual(JobPickerFilter.combine(recent: recent, found: [], query: "sw-1").map(\.id), ["SW-1"])
        XCTAssertEqual(JobPickerFilter.combine(recent: recent, found: [], query: "marri madeley").map(\.id), ["SW-3"])
        XCTAssertEqual(JobPickerFilter.combine(recent: recent, found: [], query: "whitfíeld").map(\.id), ["SW-1"])
        // Server results are added once, in date order.
        let older = job("SW-0", "Old client", "1 Old St", "Madeley", 50)
        XCTAssertEqual(JobPickerFilter.combine(recent: recent, found: [older, recent[1]], query: "madeley").map(\.id), ["SW-2", "SW-0", "SW-3"])
    }

    func testServerSearchTermIsSafe() {
        XCTAssertEqual(JobPickerFilter.serverTerm("  Smith, (Unit*4) "), "Smith Unit 4")
        XCTAssertEqual(JobPickerFilter.serverTerm("a%b\"c:d"), "a b c d")
        XCTAssertEqual(JobPickerFilter.orFilter(term: "o'brien st", columns: ["client_name", "site_address"]),
                       "or=(client_name.ilike.*o%27brien%20st*,site_address.ilike.*o%27brien%20st*)")
    }

    func testCloudJobText() {
        let j = CloudScanJob(id: UUID(), title: "t", siteAddress: "", revision: 1, updatedAt: nil, jobNumber: "SW-1", clientName: nil)
        XCTAssertEqual(j.displayAddress, "t")
        XCTAssertEqual(j.linkLine, "SW-1")
        XCTAssertTrue(j.matches("sw-1"))
        XCTAssertFalse(j.matches("kingsway"))
    }
}

final class SyncWordsTests: XCTestCase {

    func testSignInLines() {
        XCTAssertEqual(SyncWords.signIn(.http(400, "Invalid login credentials")), "Wrong email or password.")
        XCTAssertEqual(SyncWords.signIn(.http(400, "Email not confirmed")), "This account isn't confirmed yet.")
        XCTAssertEqual(SyncWords.signIn(.http(429, "")), "Too many tries. Wait a minute and try again.")
        XCTAssertEqual(SyncWords.signIn(.http(503, "")), "SecureSuite isn't answering. Try again soon.")
        XCTAssertEqual(SyncWords.signIn(.offline), "No internet connection. Try again when online.")
        XCTAssertEqual(SyncWords.validateSignIn(email: "", password: "x"), SyncWords.enterBoth)
        XCTAssertEqual(SyncWords.validateSignIn(email: "jordan", password: "x"), SyncWords.badEmail)
        XCTAssertNil(SyncWords.validateSignIn(email: " jordan@example.com ", password: "x"))
    }

    func testStorageErrorsAreRead() {
        // Storage answers 400 with its own statusCode.
        XCTAssertEqual(SyncError.fromReply(status: 400, json: ["statusCode": "403", "error": "Unauthorized",
                                                               "message": "new row violates row-level security policy"]),
                       .http(403, "new row violates row-level security policy"))
        XCTAssertEqual(SyncError.fromReply(status: 400, json: ["statusCode": "400", "error": "InvalidJWT", "message": "\"exp\" claim timestamp check failed"]),
                       .http(401, "\"exp\" claim timestamp check failed"))
        XCTAssertEqual(SyncError.fromReply(status: 409, json: ["code": "23505", "message": "duplicate key"]), .http(409, "duplicate key"))
        XCTAssertEqual(SyncWords.sync(.http(403, "new row violates row-level security policy")), "SecureSuite refused access")
        XCTAssertEqual(SyncWords.sync(.http(413, "Payload too large")), "A file is too big to upload")
        XCTAssertEqual(SyncError.from(urlError: .notConnectedToInternet), .offline)
        XCTAssertEqual(SyncError.wrap(CancellationError()), .cancelled)
    }

    func testStatusLines() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Perth")!
        let now = Date(timeIntervalSince1970: 1_794_798_905)   // 11:15 am in Perth
        XCTAssertEqual(SyncStatus.synced(now.addingTimeInterval(-3600)).detail(now: now, calendar: cal), "Last synced 10:15 am")
        XCTAssertEqual(SyncStatus.synced(now.addingTimeInterval(-86_400)).detail(now: now, calendar: cal), "Last synced yesterday 11:15 am")
        XCTAssertEqual(SyncStatus.synced(nil).detail(now: now, calendar: cal), nil)
        XCTAssertEqual(SyncStatus.offline.title, "Waiting for network")
        XCTAssertEqual(SyncStatus.syncing("Uploading 3 of 12").detail(), "Uploading 3 of 12")
        XCTAssertEqual(SyncStatus.error("No connection").tone, .warning)
        XCTAssertEqual(SyncStatus.signedOut.symbol, "lock.icloud")
        XCTAssertEqual(SyncText.title("in_progress"), "In progress")
    }
}
