//
//  JobPickerView.swift
//  SecureScan
//
//  "Link SecureSuite job": the org's jobs, most recent first, searchable by
//  job number, client or address. Each row: job number and status, client,
//  address. Used from New job and from a job's "…" menu.
//

import SwiftUI

struct SecureSuiteJobPicker: View {
    var current: SecureSuiteLink?
    let onPick: (SecureSuiteJob) -> Void
    /// Shown as "Don't link a job" when something is linked.
    var onUnlink: (() -> Void)? = nil
    let onCancel: () -> Void

    @ObservedObject private var center = SyncCenter.shared
    @State private var query = ""
    @State private var recent: [SecureSuiteJob] = []
    @State private var found: [SecureSuiteJob] = []
    @State private var loading = true
    @State private var searching = false
    @State private var problem: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var shown: [SecureSuiteJob] { JobPickerFilter.combine(recent: recent, found: found, query: query) }

    var body: some View {
        NavigationStack {
            List {
                Section { searchField }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                content
                if let current, let onUnlink {
                    Section {
                        Button(role: .destructive, action: onUnlink) {
                            Text("Don't link a job").font(DS.Font.body).foregroundStyle(DS.Color.remove)
                        }
                    } footer: {
                        Text("Linked now: \(current.title)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SecureSuite jobs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
            .task { await loadRecent() }
            .onChange(of: query) { _, q in scheduleSearch(q) }
            .onDisappear { searchTask?.cancel() }
        }
    }

    @ViewBuilder private var content: some View {
        let jobs = shown
        if jobs.isEmpty {
            Section {
                if loading || searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading SecureSuite jobs…").foregroundStyle(.secondary)
                    }
                    .font(DS.Font.callout)
                    .frame(maxWidth: .infinity, minHeight: 44)
                } else if let problem {
                    VStack(spacing: DS.Space.gap) {
                        Text(problem)
                            .font(DS.Font.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        SecondaryButton("Try again", icon: "arrow.clockwise") { Task { await loadRecent() } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    Text(query.isEmpty ? "No SecureSuite jobs yet." : "No job matches “\(query)”.")
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(jobs) { job in
                    Button { onPick(job) } label: {
                        JobPickerRow(job: job, selected: job.id == current?.jobID)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(query.isEmpty ? "Most recent" : "Matches")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Job number, client or address", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if searching && !query.isEmpty {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(DS.Font.body)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadRecent() async {
        loading = true
        problem = nil
        #if DEBUG
        if let p = FakeCloud.picker, p == "search", query.isEmpty { query = "madeley" }
        #endif
        do {
            recent = try await center.recentSecureSuiteJobs()
        } catch {
            problem = Self.words(SyncError.wrap(error))
        }
        loading = false
    }

    /// The server search runs 0.35 s after typing stops (the recent list filters at once).
    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        found = []
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let result = try? await center.searchSecureSuiteJobs(term)
            guard !Task.isCancelled else { return }
            found = result ?? []
            searching = false
        }
    }

    static func words(_ e: SyncError) -> String {
        switch e {
        case .offline: return "No connection. Jobs load when you're online."
        case .notSignedIn: return "Sign in to see SecureSuite jobs."
        default: return "SecureSuite jobs didn't load."
        }
    }
}

struct JobPickerRow: View {
    let job: SecureSuiteJob
    var selected = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.displayNumber)
                        .font(DS.Font.bodyBold)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if !job.status.isEmpty {
                        SyncPill(title: job.statusTitle, color: Self.color(job.tone))
                    }
                }
                if !job.clientName.isEmpty {
                    Text(job.clientName)
                        .font(DS.Font.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if !job.addressLine.isEmpty {
                    Text(job.addressLine)
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Linked")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    static func color(_ tone: JobStatusTone) -> Color {
        switch tone {
        case .active: return DS.Color.accent
        case .quoted: return DS.Color.grey(8)
        case .done: return DS.Color.dry
        case .waiting: return DS.Color.damp
        case .closed: return DS.Color.grey(5)
        case .neutral: return DS.Color.grey(6)
        }
    }
}
