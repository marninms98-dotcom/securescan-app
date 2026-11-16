//
//  FakeCloud.swift
//  SecureScan
//
//  Debug builds only: SECURESCAN_FAKE_CLOUD shows the sync screens in the
//  simulator without a backend (CI screenshots). Nothing here touches the
//  network or the Keychain.
//
//    SECURESCAN_FAKE_CLOUD=1             signed in; job cards show every sync
//                                        state; "On SecureSuite" lists 3 jobs
//    SECURESCAN_FAKE_CLOUD=signin        the first-launch sign-in screen
//    SECURESCAN_FAKE_CLOUD=signin-error  the same, after a wrong password
//    SECURESCAN_FAKE_PICKER=1 | search | linked   (with SECURESCAN_PREVIEW=newjob)
//                                        opens the job picker / with a search
//                                        typed / with a job already picked
//

import Foundation

/// Kept in Release builds only as a type (always nil there).
enum FakeCloudMode: String {
    case signedIn = "1"
    case signIn = "signin"
    case signInError = "signin-error"
}

#if DEBUG
@MainActor
enum FakeCloud {
    static var mode: FakeCloudMode? {
        ProcessInfo.processInfo.environment["SECURESCAN_FAKE_CLOUD"].flatMap(FakeCloudMode.init(rawValue:))
    }

    static var picker: String? { ProcessInfo.processInfo.environment["SECURESCAN_FAKE_PICKER"] }

    static let profile = SyncProfile(userID: "6b1f3c2e-0d4a-4c55-9a51-2f7d1e8b9c10", email: "jordan.lee@example.com",
                                     name: "Jordan Lee", role: "admin", orgID: "2c9a4f3e-7b61-4d2a-8e0f-5a3b1c9d7e42")

    static func apply(_ mode: FakeCloudMode, to center: SyncCenter) {
        switch mode {
        case .signedIn:
            center.setFake(signedIn: true, profile: profile, cloudJobs: cloudOnly, showSignIn: false)
        case .signIn, .signInError:
            center.setFake(signedIn: false, profile: nil, cloudJobs: [], showSignIn: true)
        }
    }

    static func signIn(_ mode: FakeCloudMode, center: SyncCenter) -> String? {
        if mode == .signInError { return SyncWords.signIn(.http(400, "Invalid login credentials")) }
        center.setFake(signedIn: true, profile: profile, cloudJobs: cloudOnly, showSignIn: false)
        return nil
    }

    /// Every state once, by the seeded jobs' refs (SECURESCAN_SEED=jobs).
    static func status(for id: UUID) -> SyncStatus {
        guard SyncCenter.shared.signedIn else { return .signedOut }
        let ref = JobStore.shared.jobs.first(where: { $0.id == id })?.jobRef ?? ""
        let hour: TimeInterval = 3600
        switch ref {
        case "DEMO": return .synced(Date().addingTimeInterval(-0.4 * hour))
        case "CLM-20417": return .syncing("Uploading 3 of 12")
        case "AAMI-55821": return .signedOut
        case "QBE-7731902": return .error("A file is too big to upload")
        case "HOL-88213": return .pending
        case "SUN-55120": return .offline
        default: return .synced(Date().addingTimeInterval(-2 * hour))
        }
    }

    private static var links: [UUID: SecureSuiteLink] = [:]

    static func link(for id: UUID) -> SecureSuiteLink? {
        if let l = links[id] { return l }
        let ref = JobStore.shared.jobs.first(where: { $0.id == id })?.jobRef ?? ""
        if ref == "DEMO" || ref == "CLM-20417" { return SecureSuiteLink(job: secureSuiteJobs[0]) }
        return nil
    }

    static func setLink(_ job: SecureSuiteJob?, for id: UUID) {
        links[id] = job.map { SecureSuiteLink(job: $0) }
    }

    private static func days(_ n: Double) -> Date { Date().addingTimeInterval(-n * 86_400) }

    static let secureSuiteJobs: [SecureSuiteJob] = [
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002418", jobNumber: "SW-2418", status: "in_progress", type: "Water damage",
                       clientName: "Dana Whitfield", siteAddress: "14 Kingsway", siteSuburb: "Wangara", createdAt: days(0.2)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002417", jobNumber: "SW-2417", status: "scheduled", type: "Water damage",
                       clientName: "Raj & Priya Natarajan", siteAddress: "Unit 4/118 Wanneroo Road", siteSuburb: "Madeley", createdAt: days(0.9)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002415", jobNumber: "SW-2415", status: "quoted", type: "Mould",
                       clientName: "Strata Plan 41207", siteAddress: "7 Marri Road", siteSuburb: "Madeley", createdAt: days(1.6)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002412", jobNumber: "SW-2412", status: "lead", type: "Water damage",
                       clientName: "Tom Ferreira", siteAddress: "3 Ocean Reef Road", siteSuburb: "Ocean Reef", createdAt: days(2.3)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002409", jobNumber: "SW-2409", status: "on_hold", type: "Make safe",
                       clientName: "Kingsway Medical Centre", siteAddress: "61 Kingsway", siteSuburb: "Madeley", createdAt: days(3.1)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002401", jobNumber: "SW-2401", status: "complete", type: "Water damage",
                       clientName: "Helen O'Brien", siteAddress: "22 Hepburn Avenue", siteSuburb: "Hillarys", createdAt: days(6.0)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002396", jobNumber: "SW-2396", status: "invoiced", type: "Water damage",
                       clientName: "Mark & Leanne Doyle", siteAddress: "5 Banksia Terrace", siteSuburb: "Kensington", createdAt: days(9.0)),
        SecureSuiteJob(id: "a1000000-0000-4000-8000-000000002390", jobNumber: "SW-2390", status: "cancelled", type: "Mould",
                       clientName: "Sam Kowalski", siteAddress: "40 Alexander Drive", siteSuburb: "Landsdale", createdAt: days(12.0)),
    ]

    static let cloudOnly: [CloudScanJob] = [
        CloudScanJob(id: UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001")!, title: "22 Moreing Rd, Attadale, WA",
                     siteAddress: "22 Moreing Rd, Attadale, WA", revision: 7, updatedAt: Date().addingTimeInterval(-2 * 3600),
                     jobNumber: "SW-2413", clientName: "Alicia Romano"),
        CloudScanJob(id: UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000002")!, title: "5 Banksia Tce, Kensington, WA",
                     siteAddress: "5 Banksia Tce, Kensington, WA", revision: 12, updatedAt: Date().addingTimeInterval(-26 * 3600),
                     jobNumber: "SW-2396", clientName: "Mark & Leanne Doyle"),
        CloudScanJob(id: UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000003")!, title: "Unit 9/31 Cedric St, Stirling, WA",
                     siteAddress: "Unit 9/31 Cedric St, Stirling, WA", revision: 3, updatedAt: Date().addingTimeInterval(-4 * 86_400),
                     jobNumber: nil, clientName: nil),
    ]
}
#endif
