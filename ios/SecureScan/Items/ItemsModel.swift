//
//  ItemsModel.swift
//  SecureScan
//
//  The Items tab's data: everything captured on a job (readings, moisture-line
//  points, photo notes, sources, equipment, removals, wet areas, floor types,
//  voice notes) read from plan.json, grouped by room; plus the raw items that
//  never reached the plan ("Needs a quick fix").
//
//  Writes go through the same paths as the scan screens' edit sheet
//  (MarkupEdit on plan.json + the matching readings-raw.json record).
//

import SwiftUI
import ImageIO

struct CapturedItem: Identifiable, Equatable {
    enum Kind: String { case reading, boundary, photo, source, equipment, removal, affected, floor, note }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", readings = "Readings", photos = "Photos", marks = "Marks", equipment = "Equipment"
        var id: String { rawValue }
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    /// Reading value, for the coloured value tile.
    var value: Double?
    var reference = false
    /// The material (readings) or caption / label being edited.
    var material: String = ""
    var text: String = ""
    /// The data URL (or nil) of its photo.
    var photo: String?
    var roomID: String?
    var order: Int
    /// A moisture line: the ids of its points (the row stands for all of them).
    var memberIDs: [String] = []

    func matches(_ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .readings: return kind == .reading
        case .photos: return photo != nil || kind == .photo
        case .marks: return [.boundary, .removal, .affected, .floor, .source].contains(kind)
        case .equipment: return kind == .equipment
        }
    }

    var editable: Bool { kind != .floor }
    /// Every plan id this row stands for.
    var allIDs: [String] { memberIDs.isEmpty ? [id] : memberIDs }

    static func == (a: CapturedItem, b: CapturedItem) -> Bool {
        a.id == b.id && a.title == b.title && a.detail == b.detail && a.value == b.value && a.text == b.text
            && a.material == b.material && a.roomID == b.roomID && (a.photo?.count ?? 0) == (b.photo?.count ?? 0)
    }
}

/// A raw item that is not on the plan.
struct FixItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
}

struct ItemsSnapshot: Equatable {
    struct Room: Identifiable, Equatable { var id: String; var name: String }
    var rooms: [Room] = []
    var items: [CapturedItem] = []
    var fixes: [FixItem] = []
    /// Why the fix items are off the plan: an interrupted scan (try placing
    /// again) or marks the plan could not draw (draw them on the plan).
    var fixesFromInterruptedScan = false
    var damp = 15.0
    var wet = 20.0
}

enum ItemsModel {

    // MARK: Reading

    static func load(folder: JobFolder, meta: JobMeta?) -> ItemsSnapshot {
        let plan = (try? Data(contentsOf: folder.planURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        var s = parse(plan: plan ?? [:], names: EditorNamesStore.load(folder))
        let raw = JobFiles.loadRawReadings(folder)
        let interrupted = ScanOpenMarker.exists(folder)
        let ids = fixIDs(raw: raw, plan: plan, interrupted: interrupted, note: meta?.note)
        s.fixesFromInterruptedScan = interrupted
        s.fixes = raw.filter { ids.contains($0.id) }.map(fixItem)
        return s
    }

    /// Raw items off the plan that need attention: after an interrupted scan,
    /// every item not on the plan; otherwise the removals the last plan build
    /// could not place (job.json note), never items the user deleted in the editor.
    static func fixIDs(raw: [RawReading], plan: [String: Any]?, interrupted: Bool, note: String?) -> Set<String> {
        guard let plan else { return interrupted ? Set(raw.map(\.id)) : [] }
        let onPlan = Recovery.planIds(plan)
        let off = raw.filter { !onPlan.contains($0.id) }
        if interrupted { return Set(off.map(\.id)) }
        guard let note, note.contains("could not be placed") else { return [] }
        return Set(off.filter { $0.kind == "removal" }.map(\.id))
    }

    static func needsFixCount(folder: JobFolder, plan: [String: Any]?, meta: JobMeta) -> Int {
        let interrupted = ScanOpenMarker.exists(folder)
        guard interrupted || (meta.note ?? "").contains("could not be placed") else { return 0 }
        return fixIDs(raw: JobFiles.loadRawReadings(folder), plan: plan, interrupted: interrupted, note: meta.note).count
    }

    static func fixItem(_ r: RawReading) -> FixItem {
        switch r.kind {
        case "removal":
            let what = r.material == "flooring" ? "Flooring to lift" : "\(removalName(r.material)) to remove"
            return FixItem(id: r.id, title: what, detail: "Not on the plan yet")
        case "reading":
            return FixItem(id: r.id, title: "Reading" + (r.value.map { " · \(fmt($0)) %" } ?? ""), detail: "Not on the plan yet")
        case "photo":
            return FixItem(id: r.id, title: "Photo", detail: r.note.isEmpty ? "Not on the plan yet" : r.note)
        case "equipment":
            return FixItem(id: r.id, title: PlanDocument.equipmentName(r.material), detail: "Not on the plan yet")
        case "source":
            return FixItem(id: r.id, title: "Water source", detail: r.note.isEmpty ? "Not on the plan yet" : r.note)
        default:
            return FixItem(id: r.id, title: kindName(r.kind), detail: "Not on the plan yet")
        }
    }

    /// Pure: plan.json -> rooms and items.
    static func parse(plan: [String: Any], names: EditorNames? = nil) -> ItemsSnapshot {
        var s = ItemsSnapshot()
        let markup = plan["markup"] as? [String: Any] ?? [:]
        if let t = markup["thresholds"] as? [String: Any] {
            s.damp = PlanDocument.number(t["damp"]) ?? 15
            s.wet = PlanDocument.number(t["wet"]) ?? 20
        }
        // Rooms.
        var polys: [(id: String, poly: [PlanVec])] = []
        for (i, r) in (plan["rooms"] as? [[String: Any]] ?? []).enumerated() {
            let id = (r["id"] as? String) ?? "r\(i + 1)"
            let name = ((r["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            s.rooms.append(.init(id: id, name: name.isEmpty ? "Room \(i + 1)" : name))
            polys.append((id, (r["polygon"] as? [Any] ?? []).compactMap(ScopeList.pt)))
        }
        // Walls (removals sit on a wall stretch).
        var walls: [String: (PlanVec, PlanVec)] = [:]
        for w in plan["walls"] as? [[String: Any]] ?? [] {
            if let id = w["id"] as? String, let a = ScopeList.pt(w["a"]), let b = ScopeList.pt(w["b"]) { walls[id] = (a, b) }
        }
        func room(_ item: [String: Any], at p: PlanVec?) -> String? {
            // Where the camera stood says which side of a shared wall it is.
            guard let q = ScopeList.pt(item["cam"]) ?? p else { return nil }
            if let inside = polys.filter({ FloorArea.inside(q, $0.poly) }).min(by: { FloorArea.area($0.poly) < FloorArea.area($1.poly) }) {
                return inside.id
            }
            return polys.min(by: { dist(q, $0.poly) < dist(q, $1.poly) }).flatMap { dist(q, $0.poly) < 0.6 ? $0.id : nil }
        }

        var order = 0
        func next() -> Int { order += 1; return order }

        func wallName(_ id: String?) -> String? {
            guard let id, !id.isEmpty else { return nil }
            if let n = names?.wallNames[id] { return n }
            return nil
        }
        // Moisture lines: one row per wall and visit, however many points.
        struct Line { var ids: [String] = []; var top = 0.0; var first: [String: Any] = [:]; var photo: String?; var order = 0; var visit = "v1"; var wall: String? }
        var lines: [String: Line] = [:]
        var lineKeys: [String] = []

        var readingN = 0, photoN = 0
        for r in markup["readings"] as? [[String: Any]] ?? [] {
            guard let id = r["id"] as? String else { continue }
            let kind = (r["kind"] as? String) ?? "reading"
            let pos = ScopeList.pt(r["pos"])
            let note = (r["note"] as? String) ?? ""
            let material = (r["material"] as? String) ?? ""
            let photo = (r["photo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let where_ = place(material: kind == "reading" ? material : nil, height: PlanDocument.number(r["height"]))
            switch kind {
            case "boundary":
                let wall = r["wallId"] as? String
                let visit = (r["visit"] as? String) ?? "v1"
                let key = "\(wall ?? "-")|\(visit)"
                if lines[key] == nil { lineKeys.append(key); lines[key] = Line(first: r, order: next(), visit: visit, wall: wall) }
                lines[key]!.ids.append(id)
                lines[key]!.top = max(lines[key]!.top, PlanDocument.number(r["height"]) ?? 0)
                if lines[key]!.photo == nil { lines[key]!.photo = photo }
            case "photo":
                photoN += 1
                s.items.append(CapturedItem(id: id, kind: .photo, title: "Photo P\(photoN)", detail: note.isEmpty ? "No caption" : note,
                                            text: note, photo: photo, roomID: room(r, at: pos), order: next()))
            default:
                readingN += 1
                let n = PlanDocument.number(r["n"]).map { Int($0) } ?? readingN
                let value = PlanDocument.number(r["value"])
                let ref = (r["reference"] as? Bool) == true
                var detail = where_
                if ref { detail = detail.isEmpty ? "Dry reference" : "Dry reference · " + detail }
                if !note.isEmpty { detail += (detail.isEmpty ? "" : " · ") + note }
                s.items.append(CapturedItem(id: id, kind: .reading, title: "Reading R\(n)", detail: detail.isEmpty ? "Reading" : detail,
                                            value: value, reference: ref, material: material, text: note, photo: photo,
                                            roomID: room(r, at: pos), order: next()))
            }
        }
        for key in lineKeys {
            guard let l = lines[key] else { continue }
            var parts: [String] = []
            if let w = wallName(l.wall) { parts.append(w) }
            if l.top > 0.005 { parts.append("up to \(fmt(l.top)) m") }
            if l.visit != "v1", let n = Int(l.visit.dropFirst()) { parts.append("visit \(n)") }
            let n = l.ids.count
            s.items.append(CapturedItem(id: "line:" + key, kind: .boundary, title: n == 1 ? "Moisture line · 1 point" : "Moisture line · \(n) points",
                                        detail: parts.isEmpty ? "On the wall" : parts.joined(separator: " · "), photo: l.photo,
                                        roomID: room(l.first, at: ScopeList.pt(l.first["pos"])), order: l.order, memberIDs: l.ids))
        }
        for x in markup["sources"] as? [[String: Any]] ?? [] {
            guard let id = x["id"] as? String else { continue }
            let label = ((x["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            s.items.append(CapturedItem(id: id, kind: .source, title: "Water source", detail: label.isEmpty ? "Cause not set" : label,
                                        text: label, photo: (x["photo"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                        roomID: room(x, at: ScopeList.pt(x["pos"])), order: next()))
        }
        for e in markup["equipment"] as? [[String: Any]] ?? [] {
            guard let id = e["id"] as? String else { continue }
            let name = PlanDocument.equipmentName((e["type"] as? String) ?? "other")
            let label = ((e["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let removed = e["removed"].map { !($0 is NSNull) && ($0 as? String)?.isEmpty != true } ?? false
            s.items.append(CapturedItem(id: id, kind: .equipment, title: label.isEmpty ? name : "\(name) · \(label)",
                                        detail: removed ? "Removed" : "Running", text: label,
                                        roomID: room(e, at: ScopeList.pt(e["pos"])), order: next()))
        }
        for x in markup["removals"] as? [[String: Any]] ?? [] {
            guard let id = x["id"] as? String else { continue }
            let item = (x["item"] as? String) ?? "other"
            let done = (x["status"] as? String) == "done"
            let note = (x["note"] as? String) ?? ""
            let photo = ((x["photos"] as? [[String: Any]])?.first?["photo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let area = (x["area"] as? [Any])?.compactMap(ScopeList.pt), area.count >= 3 {
                let type = (x["floorType"] as? String).map { $0.capitalized } ?? "Flooring"
                s.items.append(CapturedItem(id: id, kind: .removal, title: "Lift \(type.lowercased()) · \(area2(FloorArea.area(area))) m²",
                                            detail: (names?.removalRefs[id].map { $0 + " · " } ?? "") + (done ? "Done" : "To do"), text: note, photo: photo,
                                            roomID: room(x, at: PlanBuilder.centroid(area)), order: next()))
            } else {
                var mid: PlanVec?
                var len: Double?
                if let wid = x["wallId"] as? String, let w = walls[wid] {
                    let t0 = PlanDocument.number(x["t0"]) ?? 0, t1 = PlanDocument.number(x["t1"]) ?? 1
                    let a = w.0 + (w.1 - w.0) * t0, b = w.0 + (w.1 - w.0) * t1
                    mid = (a + b) / 2
                    len = ((b - a) * (b - a)).sum().squareRoot()
                }
                let what = removalName(item).lowercased()
                var title = "Remove \(what)"
                if let len { title += " · \(fmt(len)) m" }
                var detail = done ? "Done" : "To do"
                if let tag = names?.removalRefs[id] { detail = tag + " · " + detail }
                if let w = wallName(x["wallId"] as? String) { detail += " · " + w }
                if item != "skirting", let h = PlanDocument.number(x["heightMm"]), h > 0 { detail += " · to \(Int(h)) mm" }
                if !note.isEmpty { detail += " · " + note }
                s.items.append(CapturedItem(id: id, kind: .removal, title: title, detail: detail, text: note, photo: photo,
                                            roomID: room(x, at: mid), order: next()))
            }
        }
        for a in markup["affected"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? String else { continue }
            let poly = (a["polygon"] as? [Any] ?? []).compactMap(ScopeList.pt)
            let label = (a["label"] as? String) ?? ""
            s.items.append(CapturedItem(id: id, kind: .affected, title: "Wet floor · \(area2(FloorArea.area(poly))) m²",
                                        detail: label.isEmpty ? "Wet area" : label, text: label,
                                        roomID: poly.count >= 3 ? room(a, at: PlanBuilder.centroid(poly)) : nil, order: next()))
        }
        for z in markup["floors"] as? [[String: Any]] ?? [] {
            guard let id = z["id"] as? String else { continue }
            let poly = (z["polygon"] as? [Any] ?? []).compactMap(ScopeList.pt)
            let type = ((z["type"] as? String) ?? "other").capitalized
            s.items.append(CapturedItem(id: id, kind: .floor, title: "Floor · \(type)", detail: "\(area2(FloorArea.area(poly))) m²",
                                        roomID: poly.count >= 3 ? room(z, at: PlanBuilder.centroid(poly)) : nil, order: next()))
        }
        for n in markup["notes"] as? [[String: Any]] ?? [] {
            guard let id = n["id"] as? String else { continue }
            let text = ((n["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var detail = (n["source"] as? String) == "typed" ? "Typed note" : "Voice note"
            if let t = ISOTime.date(n["t"] as? String) { detail += " · " + t.formatted(date: .omitted, time: .shortened) }
            s.items.append(CapturedItem(id: id, kind: .note, title: text.isEmpty ? "(empty note)" : text, detail: detail,
                                        text: text, roomID: nil, order: next()))
        }
        return s
    }

    static func place(material: String?, height: Double?) -> String {
        var parts: [String] = []
        if let m = material, !m.isEmpty { parts.append(m == "cabinetry" ? "Cabinet" : m.capitalized) }
        if let h = height, h > 0.005 { parts.append("\(fmt(h)) m up") }
        return parts.joined(separator: " · ")
    }

    static func fmt(_ x: Double) -> String {
        let r = (x * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : (abs(r * 10 - (r * 10).rounded()) < 0.001 ? String(format: "%.1f", r) : String(format: "%.2f", r))
    }

    static func removalName(_ key: String) -> String {
        ["plasterboard": "Plasterboard", "skirting": "Skirting", "cabinetry": "Cabinetry", "flooring": "Flooring"][key] ?? "Wall lining"
    }

    static func kindName(_ kind: String) -> String {
        ["boundary": "Moisture line point", "floorType": "Floor type", "affected": "Wet floor area"][kind] ?? "Item"
    }

    static func area2(_ a: Double) -> String { String(format: "%.1f", a) }

    private static func dist(_ p: PlanVec, _ poly: [PlanVec]) -> Double {
        guard poly.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ab = b - a
            let l2 = (ab * ab).sum()
            let t = l2 > 0 ? min(1, max(0, ((p - a) * ab).sum() / l2)) : 0
            let q = a + ab * t
            best = min(best, ((p - q) * (p - q)).sum().squareRoot())
        }
        return best
    }

    // MARK: Writing (same paths as RawItemEditSheet / ScanModel.delete)

    static func readPlan(_ folder: JobFolder) -> [String: Any]? {
        (try? Data(contentsOf: folder.planURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func writePlan(_ doc: [String: Any], _ folder: JobFolder) {
        if let clean = PlanDocument.sanitised(doc) as? [String: Any], let bytes = try? PlanDocument.data(clean) {
            try? bytes.write(to: folder.planURL, options: .atomic)
        }
    }

    /// Value / material / caption-or-label (text) of one item.
    static func edit(folder: JobFolder, item: CapturedItem, value: Double?, material: String?, text: String) {
        var raw = JobFiles.loadRawReadings(folder)
        if let i = raw.firstIndex(where: { $0.id == item.id }) {
            raw[i].note = text
            if raw[i].kind == "reading" { raw[i].value = value; if let material { raw[i].material = material } }
            try? JobFiles.saveRawReadings(raw, folder)
        }
        guard let doc = readPlan(folder) else { return }
        if item.kind == .note {
            if let out = updateNote(doc, id: item.id, text: text) { writePlan(out, folder) }
            return
        }
        guard let f = MarkupEdit.find(doc, id: item.id) else { return }
        var set: [String: Any] = [["sources", "equipment", "affected"].contains(f.list) ? "label" : "note": text]
        if f.list == "readings", (f.item["kind"] as? String ?? "reading") == "reading" {
            set["value"] = value.map { $0 as Any } ?? NSNull()
            if let material { set["material"] = material }
            // A reading with a visit history: the latest entry mirrors the top-level value.
            if var h = f.item["history"] as? [[String: Any]], !h.isEmpty {
                h[h.count - 1]["value"] = value.map { $0 as Any } ?? NSNull()
                set["history"] = h
            }
        }
        if let out = MarkupEdit.update(doc, id: item.id, set: set) { writePlan(out, folder) }
    }

    static func delete(folder: JobFolder, ids: [String], kind: CapturedItem.Kind?) {
        for id in ids { delete(folder: folder, id: id, kind: kind) }
    }

    static func delete(folder: JobFolder, id: String, kind: CapturedItem.Kind?) {
        var raw = JobFiles.loadRawReadings(folder)
        if let i = raw.firstIndex(where: { $0.id == id }) {
            let r = raw.remove(at: i)
            if let f = r.photoFile { try? FileManager.default.removeItem(at: folder.url.appendingPathComponent(f)) }
            try? JobFiles.saveRawReadings(raw, folder)
        }
        guard let doc = readPlan(folder) else { return }
        if kind == .note {
            if let out = deleteNote(doc, id: id) { writePlan(out, folder) }
        } else if let out = MarkupEdit.delete(doc, id: id) {
            writePlan(out, folder)
        }
    }

    static func updateNote(_ doc: [String: Any], id: String, text: String) -> [String: Any]? {
        var d = doc
        var markup = d["markup"] as? [String: Any] ?? [:]
        var notes = markup["notes"] as? [[String: Any]] ?? []
        guard let i = notes.firstIndex(where: { ($0["id"] as? String) == id }) else { return nil }
        notes[i]["text"] = text
        notes[i]["edited"] = true
        markup["notes"] = notes
        d["markup"] = markup
        return d
    }

    static func deleteNote(_ doc: [String: Any], id: String) -> [String: Any]? {
        var d = doc
        var markup = d["markup"] as? [String: Any] ?? [:]
        var notes = markup["notes"] as? [[String: Any]] ?? []
        guard let i = notes.firstIndex(where: { ($0["id"] as? String) == id }) else { return nil }
        notes.remove(at: i)
        markup["notes"] = notes
        d["markup"] = markup
        return d
    }

    // MARK: Thumbnails

    /// A small image from a "data:image/jpeg;base64,..." URL (or a path in the job folder).
    static func thumbnail(_ photo: String, folder: JobFolder, side: CGFloat = 160) -> UIImage? {
        let data: Data?
        if photo.hasPrefix("data:"), let comma = photo.firstIndex(of: ",") {
            data = Data(base64Encoded: String(photo[photo.index(after: comma)...]), options: .ignoreUnknownCharacters)
        } else {
            data = try? Data(contentsOf: folder.url.appendingPathComponent(photo))
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
