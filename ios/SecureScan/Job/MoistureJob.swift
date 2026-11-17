//
//  MoistureJob.swift
//  SecureScan
//
//  The moisture model for a job (docs/MOISTURE.md): solved from plan.json off the
//  main thread when the job opens and whenever the plan changes (debounced, and
//  cached by the inputs' hash, so reopening a job or re-saving an unchanged plan
//  costs nothing), then written back as markup.moistureModel so sync carries it
//  to the office and other phones. The 3D tab and the Items tab draw from it.
//

import Foundation
import SwiftUI

@MainActor
final class MoistureJob: ObservableObject {
    /// plan.json's one writer queue (the editor's saves use it too).
    nonisolated static let planIO = DispatchQueue(label: "com.secureworkswa.securescan.planio", qos: .userInitiated)

    let folder: JobFolder
    let jobID: UUID
    @Published private(set) var solve: MoistureSolve?
    /// "Solving…" while a solve is running for changed inputs.
    @Published private(set) var busy = false
    private let runner = MoistureRunner(debounce: 0.3)

    /// Solves by inputs hash, shared by every job screen this run (the newest few).
    private static var cache: [(hash: String, solve: MoistureSolve)] = []

    init(folder: JobFolder, jobID: UUID) {
        self.folder = folder
        self.jobID = jobID
    }

    /// Read plan.json and solve if its inputs changed; then keep the result in plan.json.
    func refresh() {
        let url = folder.planURL
        Task {
            let plan = await withCheckedContinuation { (c: CheckedContinuation<[String: Any]?, Never>) in
                MoistureJob.planIO.async {
                    c.resume(returning: (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
                }
            }
            guard let plan, !((plan["walls"] as? [Any]) ?? []).isEmpty else { return }
            let options = MoistureLive.options(live: false)
            let hash = await Task.detached(priority: .utility) { MoisturePlan.inputsHash(MoisturePlan.input(plan: plan, options: options)) }.value
            if let hit = Self.cache.first(where: { $0.hash == hash })?.solve {
                solve = hit
                persist(hit)
                return
            }
            busy = true
            runner.schedule(plan: plan, options: options) { [weak self] s in
                guard let self else { return }
                self.busy = false
                self.solve = s
                Self.cache.removeAll { $0.hash == s.inputsHash }
                Self.cache.append((s.inputsHash, s))
                if Self.cache.count > 4 { Self.cache.removeFirst() }
                MoistureLog.record(s, label: "job")
                self.persist(s)
            }
        }
    }

    /// Writes markup.moistureModel into plan.json, if the plan on disk still has the inputs this
    /// solve was for and doesn't already carry it.
    private func persist(_ s: MoistureSolve) {
        let url = folder.planURL
        let id = jobID
        MoistureJob.planIO.async {
            guard let data = try? Data(contentsOf: url),
                  var plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let input = MoisturePlan.input(plan: plan, options: MoistureLive.options(live: false))
            guard MoisturePlan.inputsHash(input) == s.inputsHash else { return }
            var markup = plan["markup"] as? [String: Any] ?? [:]
            let previous = markup["moistureModel"] as? [String: Any]
            if ((previous?["solved"] as? [String: Any])?["inputsHash"] as? String) == s.inputsHash { return }
            markup["moistureModel"] = MoisturePlan.modelJSON(s.result, report: s.report, previous: previous,
                                                             solvedAt: PlanDocument.iso(Date()))
            plan["markup"] = markup
            guard let out = try? PlanDocument.data(plan) else { return }
            try? out.write(to: url, options: .atomic)
            Task { @MainActor in SyncCenter.shared.jobChanged(id) }  // SecureSuite sync hook
        }
    }
}

/// The solve times, for the log (and CI's perf line).
enum MoistureLog {
    static func record(_ s: MoistureSolve, label: String) {
        print(String(format: "[moisture] %@ solve %.0f ms · %ld cells · %.2f m cells · %@", label, s.millis, s.result.grid.count, s.cellSize,
                     MoistureWords.state(s).text))
    }
}
