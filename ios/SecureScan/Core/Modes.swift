//
//  Modes.swift
//  SecureScan
//
//  The owner thinks in three modes, and the AR mark-up screen shows them:
//    Inspect  - readings, the moisture line, photos, the source (-> report)
//    Quote    - equipment, wall and floor removals (-> the quote)
//    Monitor  - later visits: re-measure, the new line, mark done/removed
//  The mode is presentation only: every item goes through the same capture
//  model and the same document fields. Also: the documents the job screen
//  offers, their file names, and the running quote tally.
//  Foundation + simd only - unit tested.
//

import Foundation
import simd

/// One tool on the mark-up screen's bottom strip.
enum MarkupMode: String, CaseIterable, Identifiable {
    case reading, moisture, photo, source
    case equipment, wallRemoval, floorRemoval
    case remeasure, markDone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading: return "Reading"
        case .moisture: return "Moisture"
        case .photo: return "Photo"
        case .source: return "Source"
        case .equipment: return "Equipment"
        case .wallRemoval: return "Wall removal"
        case .floorRemoval: return "Floor removal"
        case .remeasure: return "Re-measure"
        case .markDone: return "Done / removed"
        }
    }

    var icon: String {
        switch self {
        case .reading: return "percent"
        case .moisture: return "square.dashed"
        case .photo: return "camera"
        case .source: return "drop.triangle"
        case .equipment: return "fan"
        case .wallRemoval: return "scissors"
        case .floorRemoval: return "square.grid.3x3"
        case .remeasure: return "arrow.triangle.2.circlepath"
        case .markDone: return "checkmark.circle"
        }
    }

    /// The Log sheet kind this tool preselects.
    var kind: String {
        switch self {
        case .moisture: return "boundary"
        case .wallRemoval, .floorRemoval: return "removal"
        case .remeasure: return "reading"
        case .markDone: return "equipment"
        default: return rawValue
        }
    }

    /// The tool for a Log sheet kind (the last one used on the scan screen).
    init(kind: String) {
        switch kind {
        case "boundary": self = .moisture
        case "removal": self = .wallRemoval
        case "photo": self = .photo
        case "source": self = .source
        case "equipment": self = .equipment
        default: self = .reading
        }
    }
}

enum WorkMode: String, CaseIterable, Identifiable {
    case inspect, quote, monitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspect: return "Inspect"
        case .quote: return "Quote"
        case .monitor: return "Monitor"
        }
    }

    var tools: [MarkupMode] {
        switch self {
        case .inspect: return [.reading, .moisture, .photo, .source]
        case .quote: return [.equipment, .wallRemoval, .floorRemoval, .photo]
        case .monitor: return [.remeasure, .moisture, .photo, .markDone]
        }
    }

    /// "Quote" is "Scope" on a phone that doesn't show prices. (Not named
    /// `title(pricesVisible:)`: a property and a method sharing a base name
    /// invite ambiguous references.)
    func label(pricesVisible: Bool) -> String { self == .quote && !pricesVisible ? "Scope" : self.title }

    func promptText(pricesVisible: Bool) -> String {
        self == .quote && !pricesVisible ? "Place equipment and mark what comes out — the scope of works." : self.prompt
    }

    /// One line under the switch: what this mode is for.
    var prompt: String {
        switch self {
        case .inspect: return "Readings, the moisture line, photos and the source — they make the report."
        case .quote: return "Place equipment and mark what comes out — it adds up the quote."
        case .monitor: return "Re-measure the points, redraw the line, mark gear removed and work done."
        }
    }

    /// Monitor only when the job has a previous visit.
    static func offered(laterVisit: Bool) -> [WorkMode] { laterVisit ? [.inspect, .quote, .monitor] : [.inspect, .quote] }
    static func defaultMode(laterVisit: Bool) -> WorkMode { laterVisit ? .monitor : .inspect }

    /// The mode a tool belongs to first (keeps the scan screen's last type in view).
    static func containing(_ tool: MarkupMode, laterVisit: Bool) -> WorkMode {
        if laterVisit, WorkMode.monitor.tools.contains(tool) { return .monitor }
        return WorkMode.inspect.tools.contains(tool) ? .inspect : (WorkMode.quote.tools.contains(tool) ? .quote : .monitor)
    }
}

/// The documents the job screen makes directly.
enum DocumentKind: String, CaseIterable, Identifiable {
    case initial, quote, scope, monitoring, final

    var id: String { rawValue }

    var title: String {
        switch self {
        case .initial: return "Inspection report"
        case .quote: return "Quote"
        case .scope: return "Scope of works"
        case .monitoring: return "Monitoring report"
        case .final: return "Final report"
        }
    }

    var icon: String {
        switch self {
        case .initial: return "doc.text.magnifyingglass"
        case .quote: return "dollarsign.square"
        case .scope: return "list.bullet.clipboard"
        case .monitoring: return "chart.line.downtrend.xyaxis"
        case .final: return "checkmark.seal"
        }
    }

    /// Inspection report and Quote (Scope of works when prices are hidden)
    /// always; with more than one visit, the Final report once the last
    /// visit is a final one, else Monitoring.
    static func offered(visitCount: Int, lastVisitType: String?, pricesVisible: Bool = true) -> [DocumentKind] {
        let first: [DocumentKind] = [.initial, pricesVisible ? .quote : .scope]
        guard visitCount > 1 else { return first }
        return first + [lastVisitType == "final" ? .final : .monitoring]
    }

    /// Whether this phone may make `k` now.
    ///  * editorKinds: the kinds SecureScan.reportHTML(kind) takes (nil = editor not
    ///    loaded yet, [] = only the old no-argument report);
    ///  * editorHidesPrices: the editor has SecureScan.setPricesVisible (nil = unknown).
    /// With prices hidden, nothing that could carry prices is made by an editor
    /// that cannot hide them, and the Quote is never made.
    static func available(_ k: DocumentKind, editorKinds: Set<String>?, editorHidesPrices: Bool?, pricesVisible: Bool) -> Bool {
        if !pricesVisible && (k == .quote || editorHidesPrices == false) { return false }
        guard let kinds = editorKinds else { return true }
        if kinds.isEmpty { return k == .initial || k == .monitoring || k == .final }
        return kinds.contains(k.rawValue)
    }

    /// "<address>-inspection-report.pdf" etc.
    func fileName(address: String) -> String {
        let suffix: String
        switch self {
        case .initial: suffix = "inspection-report"
        case .quote: suffix = "quote"
        case .scope: suffix = "scope-of-works"
        case .monitoring: suffix = "monitoring-report"
        case .final: suffix = "final-report"
        }
        return PackNames.fileBase(address: address) + "-" + suffix + ".pdf"
    }

    /// A file name from the editor's message: kept to one safe path
    /// component, ".pdf" added when missing; nil if nothing usable is left.
    static func cleanFileName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let last = (raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let stem = last.lowercased().hasSuffix(".pdf") ? String(last.dropLast(4)) : last
        guard !stem.trimmingCharacters(in: CharacterSet(charactersIn: " .-")).isEmpty else { return nil }
        return PackNames.fileBase(address: stem) + ".pdf"
    }
}

/// The running tally on the Quote mode chip, from plan.json.
struct QuoteTally: Equatable {
    var equipment: [String: Int] = [:]     // type -> count (not yet removed)
    var liningM2 = 0.0                     // plasterboard, cabinetry, other: length x height
    var skirtingLm = 0.0
    var flooringM2 = 0.0

    static func from(plan: [String: Any]) -> QuoteTally {
        var t = QuoteTally()
        let markup = plan["markup"] as? [String: Any] ?? [:]
        for e in markup["equipment"] as? [[String: Any]] ?? [] {
            if let r = e["removed"], !(r is NSNull) { continue }
            t.equipment[(e["type"] as? String) ?? "other", default: 0] += 1
        }
        let walls = Dictionary(Revisit.walls(plan).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            let item = (x["item"] as? String) ?? "other"
            if item == "flooring" {
                let poly = (x["area"] as? [Any] ?? []).compactMap { Revisit.point($0) }
                if poly.count >= 3 { t.flooringM2 += FloorArea.area(poly) }
                continue
            }
            guard let wid = x["wallId"] as? String, let w = walls[wid] else { continue }
            let t0 = PlanDocument.number(x["t0"]) ?? 0, t1 = PlanDocument.number(x["t1"]) ?? 1
            let len = abs(t1 - t0) * w.length
            if item == "skirting" { t.skirtingLm += len; continue }
            let h = min((PlanDocument.number(x["heightMm"]) ?? 600) / 1000, w.height)
            t.liningM2 += len * max(0, h)
        }
        return t
    }

    static let short: [String: String] = ["airMover": "AM", "dehumidifier": "DH", "airScrubber": "AS", "heater": "HT", "other": "EQ"]

    /// "2 AM · 1 DH · 2.6 m² lining · 1.8 lm skirting · 3.2 m² flooring", or "Nothing yet".
    var text: String {
        var parts: [String] = []
        for key in ["airMover", "dehumidifier", "airScrubber", "heater", "other"] {
            if let n = equipment[key], n > 0 { parts.append("\(n) \(Self.short[key] ?? "EQ")") }
        }
        func one(_ v: Double) -> String { String(format: "%.1f", v) }
        if liningM2 >= 0.05 { parts.append("\(one(liningM2)) m² lining") }
        if skirtingLm >= 0.05 { parts.append("\(one(skirtingLm)) lm skirting") }
        if flooringM2 >= 0.05 { parts.append("\(one(flooringM2)) m² flooring") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }
}

/// The office PIN that turns "Show prices" on: 4 to 8 digits.
enum PinRule {
    static func valid(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
