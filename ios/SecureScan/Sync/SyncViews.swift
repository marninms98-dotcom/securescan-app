//
//  SyncViews.swift
//  SecureScan
//
//  The small pieces of sync UI the existing screens host with one line each:
//    SyncGlyph           the tiny cloud on a job card
//    SyncStatusSection   Files tab: the status line and the linked job
//    SyncSettingsSection Settings: the account
//    SyncMenuItems       the job's "…" menu: Link SecureSuite job
//    CloudJobsSection    Jobs list: "On SecureSuite" (jobs not on this phone)
//    LinkJobSection      New job: the optional "Link SecureSuite job" row
//  No banners, no alerts. Nothing shows when sync is not configured.
//

import SwiftUI

extension SyncStatus {
    var color: Color {
        switch tone {
        case .quiet: return Color(.secondaryLabel)
        case .active: return DS.Color.accent
        case .good: return DS.Color.dry
        case .warning: return DS.Color.damp
        }
    }
}

// MARK: - Job card glyph

struct SyncGlyph: View {
    let jobID: UUID
    @ObservedObject private var center = SyncCenter.shared

    var body: some View {
        let s = center.status(jobID)
        if s != .off {
            Image(systemName: s.symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(s.color)
                .frame(minWidth: 18)
                .accessibilityLabel(s.title)
        }
    }
}

// MARK: - Files tab

struct SyncStatusSection: View {
    let jobID: UUID
    @ObservedObject private var center = SyncCenter.shared
    @State private var signingIn = false

    var body: some View {
        if center.isConfigured {
            Section {
                statusRow
                if let link = center.link(for: jobID) {
                    Button { center.linkingJob = jobID } label: {
                        LabeledContent {
                            Text(link.title).foregroundStyle(.secondary).lineLimit(1)
                        } label: {
                            Text("SecureSuite job").foregroundStyle(.primary)
                        }
                        .font(DS.Font.body)
                    }
                    .disabled(!center.canLink)
                } else if center.canLink {
                    Button { center.linkingJob = jobID } label: {
                        Label {
                            Text("Link SecureSuite job").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "link").foregroundStyle(DS.Color.accent)
                        }
                        .font(DS.Font.body)
                    }
                }
            } header: {
                Text("SecureSuite")
            }
            .sheet(isPresented: $signingIn) {
                SignInView(onDone: { signingIn = false }, fromSettings: true)
            }
        }
    }

    private var statusRow: some View {
        let s = center.status(jobID)
        return HStack(spacing: 12) {
            Image(systemName: s.symbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(s.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(DS.Font.body)
                if let d = center.detail(jobID) {
                    Text(d)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            switch s {
            case .signedOut:
                rowAction("Sign in") { signingIn = true }
            case .error:
                rowAction("Retry") { center.retryNow(jobID) }
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func rowAction(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(DS.Font.calloutBold)
            .foregroundStyle(DS.Color.accent)
            .buttonStyle(.borderless)
            .frame(minHeight: DS.Size.minTarget)
    }
}

// MARK: - Settings

struct SyncSettingsSection: View {
    @ObservedObject private var center = SyncCenter.shared
    @State private var signingIn = false
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            if !center.isConfigured {
                LabeledContent("Cloud sync", value: "Not configured")
                    .font(DS.Font.body)
            } else if center.signedIn {
                account
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Text("Sign out").font(DS.Font.body).foregroundStyle(DS.Color.remove)
                }
            } else {
                Button { signingIn = true } label: {
                    Label {
                        Text("Sign in to SecureSuite").foregroundStyle(DS.Color.accent)
                    } icon: {
                        Image(systemName: "person.crop.circle").foregroundStyle(DS.Color.accent)
                    }
                    .font(DS.Font.body)
                }
            }
        } header: {
            Text("SecureSuite")
        } footer: {
            Text(footer)
        }
        .sheet(isPresented: $signingIn) {
            SignInView(onDone: { signingIn = false }, fromSettings: true)
        }
        .confirmationDialog("Sign out of SecureSuite?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { center.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jobs stay on this iPhone. New changes upload when you sign in again.")
        }
    }

    private var footer: String {
        if !center.isConfigured { return "Jobs stay on this iPhone." }
        if center.signedIn { return "Every job is saved to SecureSuite. Deleting a job here doesn't delete it there." }
        return "Save jobs to SecureSuite and open them on other phones."
    }

    private var account: some View {
        let p = center.profile
        return HStack(spacing: 12) {
            Text(p?.initials ?? "?")
                .font(DS.Font.calloutBold)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 40, height: 40)
                .background(DS.Color.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(p?.displayName ?? "Signed in")
                    .font(DS.Font.bodyBold)
                    .lineLimit(1)
                Text(subtitle(p))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ p: SyncProfile?) -> String {
        guard let p else { return "SecureSuite" }
        let parts = [p.roleTitle, p.name.isEmpty ? "" : p.email].filter { !$0.isEmpty }
        return parts.isEmpty ? "SecureSuite" : parts.joined(separator: " · ")
    }
}

// MARK: - Job "…" menu

struct SyncMenuItems: View {
    let jobID: UUID
    @ObservedObject private var center = SyncCenter.shared

    var body: some View {
        if center.canLink {
            Button { center.linkingJob = jobID } label: {
                Label(center.link(for: jobID) == nil ? "Link SecureSuite job" : "Change SecureSuite job", systemImage: "link")
            }
        }
    }
}

// MARK: - Jobs list: On SecureSuite

struct CloudJobsSection: View {
    let localIDs: Set<UUID>
    var search: String = ""
    let onOpen: (UUID) -> Void
    @ObservedObject private var center = SyncCenter.shared

    var body: some View {
        let rows = center.remoteOnly(localIDs: localIDs, search: search)
        if center.isConfigured && !rows.isEmpty {
            Section {
                ForEach(rows) { job in
                    Button { open(job.id) } label: {
                        CloudJobRow(job: job, progress: center.downloading[job.id], problem: center.downloadProblem[job.id])
                    }
                    .buttonStyle(.plain)
                    .disabled(center.downloading[job.id] != nil)
                }
            } header: {
                Text("On SecureSuite")
                    .font(DS.Font.captionBold)
            } footer: {
                Text("Saved from other phones. Tap one to download it.")
            }
            .onAppear { center.refreshCloudJobsIfStale() }
        }
    }

    private func open(_ id: UUID) {
        Task { if await center.openCloudJob(id) { onOpen(id) } }
    }
}

struct CloudJobRow: View {
    let job: CloudScanJob
    let progress: String?
    let problem: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 44, height: 44)
                .background(DS.Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayAddress)
                    .font(DS.Font.bodyBold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let line = job.linkLine {
                    Text(line)
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(third)
                    .font(DS.Font.caption)
                    .foregroundStyle(problem != nil ? DS.Color.damp : .secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if progress != nil { ProgressView() }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Downloads the job to this iPhone")
    }

    private var third: String {
        if let progress { return progress }
        if let problem { return problem }
        guard let d = job.updatedAt else { return "On SecureSuite" }
        return "Updated " + Self.day(d)
    }

    /// "today", "yesterday", "14 Nov".
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInYesterday(d) { return "yesterday" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A small tinted capsule (the same look as the jobs list's status badge).
struct SyncPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(DS.Font.captionBold)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - New job

struct LinkJobSection: View {
    @Binding var link: SecureSuiteLink?
    @Binding var address: String
    @ObservedObject private var center = SyncCenter.shared
    @State private var picking = false

    var body: some View {
        if center.canLink {
            Section {
                Button { picking = true } label: { row }
            } header: {
                Text("SecureSuite job")
            }
            .sheet(isPresented: $picking) {
                SecureSuiteJobPicker(current: link,
                                     onPick: { job in
                                         link = SecureSuiteLink(job: job)
                                         if !job.addressLine.isEmpty { address = job.addressLine }
                                         picking = false
                                     },
                                     onUnlink: { link = nil; picking = false },
                                     onCancel: { picking = false })
            }
            .onAppear(perform: previewForScreenshots)
        }
    }

    @ViewBuilder private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(DS.Color.accent)
            if let link {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.jobNumber.isEmpty ? "Linked job" : link.jobNumber)
                        .font(DS.Font.bodyBold)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    if !link.clientName.isEmpty {
                        Text(link.clientName).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("Change").foregroundStyle(DS.Color.accent)
            } else {
                Text("Link SecureSuite job").foregroundStyle(DS.Color.accent)
                Spacer(minLength: 8)
                Text("Optional").foregroundStyle(.secondary)
            }
        }
        .font(DS.Font.body)
        .contentShape(Rectangle())
    }

    private func previewForScreenshots() {
        #if DEBUG
        switch FakeCloud.picker {
        case "1", "search":
            Task { try? await Task.sleep(nanoseconds: 700_000_000); picking = true }
        case "linked":
            if link == nil, let job = FakeCloud.secureSuiteJobs.first {
                link = SecureSuiteLink(job: job)
                address = job.addressLine
            }
        default:
            break
        }
        #endif
    }
}
