//
//  Timeline.swift
//  SecureScan
//
//  Time ordering of everything that happened on site: spoken/typed notes and
//  the logged items (readings, moisture-line marks, photo notes, sources).
//  Used to keep markup.notes in time order and to show the site timeline.
//  Foundation only - unit tested.
//

import Foundation

enum Timeline {

    struct Event: Equatable {
        var id: String
        /// "note" | "reading" | "boundary" | "photo" | "source" | "equipment" | "removal"
        var kind: String
        var time: Date
        var text: String
    }

    /// Stable sort of JSON items by an ISO time field. Items without a usable
    /// time keep their relative order and go after timed items.
    static func sortedByTime(_ items: [[String: Any]], key: String) -> [[String: Any]] {
        let indexed = items.enumerated().map { (offset: $0.offset, item: $0.element, t: ISOTime.date($0.element[key] as? String)) }
        return indexed.sorted { a, b in
            switch (a.t, b.t) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }.map { $0.item }
    }

    /// The whole site story from a plan document, in time order. At equal
    /// times, logged items come before notes (the note usually talks about the
    /// item just logged); otherwise document order is kept.
    static func events(plan: [String: Any]) -> [Event] {
        let markup = plan["markup"] as? [String: Any] ?? [:]
        var out: [(Event, Int, Int)] = []      // event, rank, order
        var order = 0
        for r in markup["readings"] as? [[String: Any]] ?? [] {
            guard let t = ISOTime.date(r["takenAt"] as? String) else { continue }
            let kind = (r["kind"] as? String) ?? "reading"
            var text = ""
            switch kind {
            case "boundary": text = "Moisture line mark"
            case "photo":
                let n: String = PlanDocument.number(r["n"]).map { String(Int($0)) } ?? ""
                let caption: String = (r["note"] as? String) ?? ""
                text = caption.isEmpty ? "Photo P\(n)" : "Photo P\(n) — \(caption)"
            default:
                let n: String = PlanDocument.number(r["n"]).map { String(Int($0)) } ?? ""
                var v = "–"
                if let x = PlanDocument.number(r["value"]) {
                    v = x.rounded() == x ? String(Int(x)) : String(format: "%.1f", x)
                }
                text = "Reading \(n): \(v)%"
            }
            out.append((Event(id: (r["id"] as? String) ?? "", kind: kind, time: t, text: text), 0, order)); order += 1
        }
        for s in markup["sources"] as? [[String: Any]] ?? [] {
            guard let t = ISOTime.date(s["takenAt"] as? String) else { continue }
            let label = (s["label"] as? String) ?? ""
            out.append((Event(id: (s["id"] as? String) ?? "", kind: "source", time: t,
                              text: label.isEmpty ? "Water source" : "Water source — \(label)"), 0, order)); order += 1
        }
        for e in markup["equipment"] as? [[String: Any]] ?? [] {
            guard let t = ISOTime.date(e["placedAt"] as? String) else { continue }
            let label = (e["label"] as? String) ?? ""
            let name = PlanDocument.equipmentName((e["type"] as? String) ?? "other")
            out.append((Event(id: (e["id"] as? String) ?? "", kind: "equipment", time: t,
                              text: label.isEmpty ? "\(name) placed" : "\(name) placed — \(label)"), 0, order)); order += 1
        }
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            guard let t = ISOTime.date(x["takenAt"] as? String) else { continue }
            let item = ((x["item"] as? String) ?? "other").capitalized
            out.append((Event(id: (x["id"] as? String) ?? "", kind: "removal", time: t,
                              text: "Removal marked — \(item)"), 0, order)); order += 1
        }
        for n in markup["notes"] as? [[String: Any]] ?? [] {
            guard let t = ISOTime.date(n["t"] as? String) else { continue }
            out.append((Event(id: (n["id"] as? String) ?? "", kind: "note", time: t,
                              text: (n["text"] as? String) ?? ""), 1, order)); order += 1
        }
        return out.sorted { a, b in
            if a.0.time != b.0.time { return a.0.time < b.0.time }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }.map { $0.0 }
    }
}
