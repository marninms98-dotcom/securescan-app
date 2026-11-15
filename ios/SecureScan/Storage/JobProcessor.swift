//
//  JobProcessor.swift
//  SecureScan
//
//  Disk-level jobs: save rooms, export the USDZ, (re)build plan.json, create
//  the demo job. Everything here can run off the main thread.
//

import Foundation
import RoomPlan
import UIKit

enum JobProcessorError: LocalizedError {
    case nothingCaptured
    var errorDescription: String? { "Nothing was captured for this job yet." }
}

enum JobProcessor {

    // MARK: Rooms

    static func saveRoom(_ room: CapturedRoom, index: Int, folder: JobFolder) throws {
        try FileManager.default.createDirectory(at: folder.roomsDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(room)
        try data.write(to: folder.roomURL(index), options: .atomic)
    }

    /// Decodes rooms/<n>.json in order. Files that fail to decode are skipped.
    static func loadRooms(_ folder: JobFolder) -> [CapturedRoom] {
        folder.roomFiles().compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(CapturedRoom.self, from: data)
        }
    }

    // MARK: 3D model

    /// Merges the rooms with StructureBuilder and exports model.usdz (mesh).
    /// Returns nil on success, otherwise a short note for the user. If the merge
    /// fails, falls back to exporting the first room on its own.
    static func exportModel(rooms: [CapturedRoom], folder: JobFolder) async -> String? {
        guard !rooms.isEmpty else { return "No rooms were captured, so there is no 3D model." }
        let url = folder.modelURL   // file name must not start with a digit before iOS 17.4
        try? FileManager.default.removeItem(at: url)
        do {
            let builder = StructureBuilder(options: [.beautifyObjects])
            let structure = try await builder.capturedStructure(from: rooms)
            try structure.export(to: url, exportOptions: .mesh)
            return nil
        } catch {
            let mergeError = error.localizedDescription
            do {
                try rooms[0].export(to: url, exportOptions: .mesh)
                return rooms.count > 1
                    ? "The rooms could not be merged into one 3D model (\(mergeError)). The 3D tab shows room 1 only; the floor plan has all rooms."
                    : nil
            } catch {
                try? FileManager.default.removeItem(at: url)   // never leave a half-written model behind
                return "The 3D model could not be built (\(error.localizedDescription)). The floor plan is not affected."
            }
        }
    }

    static func exportModelFromSavedRooms(folder: JobFolder) async -> String? {
        let rooms = loadRooms(folder)
        guard !rooms.isEmpty else { return nil }
        return await exportModel(rooms: rooms, folder: folder)
    }

    // MARK: Plan

    static func photoDataURL(_ folder: JobFolder, _ file: String?) -> String? {
        guard let file, let data = try? Data(contentsOf: folder.url.appendingPathComponent(file)) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    static func pbReading(_ r: RawReading, folder: JobFolder) -> PBReading {
        func v(_ a: [Double]?) -> WorldVec? {
            guard let a, a.count == 3 else { return nil }
            return WorldVec(a[0], a[1], a[2])
        }
        var pb = PBReading(id: r.id, seq: r.seq, kind: r.kind, value: r.value, material: r.material,
                           note: r.note, reference: r.reference, takenAt: r.takenAt,
                           photo: photoDataURL(folder, r.photoFile),
                           cameraPosition: v(r.cameraPosition) ?? .zero,
                           cameraForward: v(r.cameraForward) ?? WorldVec(0, 0, -1),
                           hit: v(r.hit))
        if let ec = v(r.endCameraPosition), let ef = v(r.endCameraForward) {
            pb.end = PBPose(cameraPosition: ec, cameraForward: ef, hit: v(r.endHit))
        }
        pb.heightMm = r.heightMm
        pb.corners = (r.corners ?? []).compactMap { c -> PBPose? in
            guard c.count >= 6 else { return nil }
            return PBPose(cameraPosition: WorldVec(c[0], c[1], c[2]), cameraForward: WorldVec(c[3], c[4], c[5]),
                          hit: c.count >= 9 ? WorldVec(c[6], c[7], c[8]) : nil)
        }
        pb.wholeRoom = r.wholeRoom ?? false
        pb.floorType = r.floorType
        pb.underlay = r.underlay ?? false
        return pb
    }

    /// Builds plan.json from rooms/*.json (or the simulated house for a demo
    /// job) plus readings-raw.json. If plan.json already exists it is MERGED:
    /// markup, room names, address, jobRef and edits to AR readings survive.
    /// `modelNote`: nil = leave meta.note alone, "" = clear it.
    @discardableResult
    static func buildPlan(folder: JobFolder, modelNote: String?) throws -> JobMeta {
        var meta = JobFiles.readMeta(folder)
            ?? JobMeta(id: UUID(uuidString: folder.url.lastPathComponent) ?? UUID(), address: "", jobRef: "",
                       createdAt: Date(), roomCount: 0, totalArea: 0, readingCount: 0, note: nil, demo: nil)

        let pbRooms: [PBRoom] = meta.demo == true
            ? SimulatedScan.rooms()
            : loadRooms(folder).map(RoomPlanAdapter.room)
        var raw = JobFiles.loadRawReadings(folder)
        // A job with only voice notes still gets a (geometry-free) plan to hold them.
        guard !pbRooms.isEmpty || !raw.isEmpty || JobFiles.hasAudio(folder) else { throw JobProcessorError.nothingCaptured }

        let g = PlanBuilder.build(rooms: pbRooms, readings: raw.map { pbReading($0, folder: folder) })

        var doc: [String: Any]
        if let data = try? Data(contentsOf: folder.planURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            doc = PlanDocument.merged(existing: existing, geometry: g)
        } else {
            doc = PlanDocument.newDocument(id: meta.id.uuidString, address: meta.address, jobRef: meta.jobRef,
                                           createdAt: meta.createdAt, now: Date(), geometry: g)
        }
        try PlanDocument.data(doc).write(to: folder.planURL, options: .atomic)

        // Cache the resolved world points for the 3D markers.
        var resolved: [String: WorldVec] = [:]
        for r in g.readings + g.sources { if let w = r.worldPoint { resolved[r.id] = w } }
        for i in raw.indices {
            if let w = resolved[raw[i].id] { raw[i].resolved = [w.x, w.y, w.z] }
        }
        if !raw.isEmpty { try? JobFiles.saveRawReadings(raw, folder) }
        let frame = PlanFrame(angle: g.transform.angle, offset: [g.transform.offset.x, g.transform.offset.y], floorY: g.floorY)
        if let data = try? JobFiles.encoder().encode(frame) { try? data.write(to: folder.frameURL, options: .atomic) }

        if let png = Thumbnailer.png(for: g) { try? png.write(to: folder.thumbURL, options: .atomic) }

        if let a = doc["address"] as? String { meta.address = a }
        if let j = doc["jobRef"] as? String { meta.jobRef = j }
        meta.roomCount = g.rooms.count
        meta.totalArea = g.totalArea
        meta.readingCount = raw.filter { $0.kind == "reading" }.count
        if let modelNote { meta.note = modelNote.isEmpty ? nil : modelNote }
        if !g.rejectedRemovals.isEmpty {
            let why = g.rejectedRemovals.map { $0.reason }.joined(separator: " ")
            let text = "\(g.rejectedRemovals.count) removal\(g.rejectedRemovals.count == 1 ? "" : "s") could not be placed and are not on the plan (\(why)) Mark them on the Plan tab."
            meta.note = [meta.note, text].compactMap { $0 }.joined(separator: " ")
        }
        try JobFiles.writeMeta(meta, folder)
        return meta
    }

    // MARK: Demo job

    /// Runs the simulated house through the real PlanBuilder and saves a normal
    /// job (no model.usdz, no rooms/*.json).
    /// `stress`: a CI-only variant with ~20 extra photo notes, to prove a long
    /// report (about 30 pages, 25+ photos) goes through the PDF path.
    static func createDemoJob(stress: Bool = false) throws -> JobMeta {
        var meta = try JobFiles.create(address: stress ? "2 Stress Test St, Wangara, WA" : "1 Demo St, Wangara, WA",
                                       jobRef: stress ? "STRESS" : "DEMO", demo: true)
        meta.note = "Demo job made from a simulated scan (no camera). There is no 3D model; the 3D tab shows simple walls."
        let folder = JobFiles.folder(for: meta.id)
        try JobFiles.writeMeta(meta, folder)
        // A few items get a small photo drawn in code, so the report's evidence
        // cards (photo + locator map + view cone) can be tried without a camera.
        try? FileManager.default.createDirectory(at: folder.photosDir, withIntermediateDirectories: true)
        var photoFiles: [String: String] = [:]
        for (i, p) in SimulatedScan.demoPhotos.enumerated() {
            let file = "photos/\(p.id).jpg"
            if let data = DemoPhoto.jpeg(title: p.title, subtitle: p.subtitle, variant: i),
               (try? data.write(to: folder.url.appendingPathComponent(file), options: .atomic)) != nil {
                photoFiles[p.id] = file
            }
        }
        var pbs = SimulatedScan.readings()
        if stress {
            let extra = SimulatedScan.stressPhotos(count: 20)
            pbs += extra
            for (i, r) in extra.enumerated() {
                let file = "photos/\(r.id).jpg"
                if let data = DemoPhoto.jpeg(title: "Photo \(i + 7)", subtitle: r.note, variant: i),
                   (try? data.write(to: folder.url.appendingPathComponent(file), options: .atomic)) != nil {
                    photoFiles[r.id] = file
                }
            }
        }
        let raw: [RawReading] = pbs.map { r in
            RawReading(id: r.id, seq: r.seq, kind: r.kind, value: r.value, material: r.material,
                       reference: r.reference, note: r.note, takenAt: r.takenAt, roomIndex: 0,
                       cameraPosition: [r.cameraPosition.x, r.cameraPosition.y, r.cameraPosition.z],
                       cameraForward: [r.cameraForward.x, r.cameraForward.y, r.cameraForward.z],
                       hit: r.hit.map { [$0.x, $0.y, $0.z] }, hitKind: "simulated",
                       photoFile: photoFiles[r.id], resolved: nil,
                       endCameraPosition: r.end.map { [$0.cameraPosition.x, $0.cameraPosition.y, $0.cameraPosition.z] },
                       endCameraForward: r.end.map { [$0.cameraForward.x, $0.cameraForward.y, $0.cameraForward.z] },
                       endHit: r.end?.hit.map { [$0.x, $0.y, $0.z] },
                       heightMm: r.heightMm, wholeRoom: r.wholeRoom ? true : nil, floorType: r.floorType)
        }
        try JobFiles.saveRawReadings(raw, folder)
        let built = try buildPlan(folder: folder, modelNote: nil)
        // Spoken notes, as if transcribed (the demo has no audio files).
        if let data = try? Data(contentsOf: folder.planURL),
           var doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var markup = doc["markup"] as? [String: Any] ?? [:]
            markup["notes"] = SimulatedScan.notes()
            doc["markup"] = markup
            try PlanDocument.data(doc).write(to: folder.planURL, options: .atomic)
        }
        return built
    }
}

/// A believable stand-in for a site photo, drawn in code (no bundled images):
/// a wall with skirting, a damp stain, a moisture meter and a caption bar.
/// Deterministic for a given `variant`.
enum DemoPhoto {
    static func jpeg(title: String, subtitle: String, variant: Int) -> Data? {
        let size = CGSize(width: 640, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let hues: [CGFloat] = [0.10, 0.08, 0.12, 0.58, 0.09, 0.06]
        let hue = hues[variant % hues.count]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Wall: soft vertical gradient.
            let top = UIColor(hue: hue, saturation: 0.10, brightness: 0.93, alpha: 1).cgColor
            let bottom = UIColor(hue: hue, saturation: 0.16, brightness: 0.78, alpha: 1).cgColor
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Damp stain rising from the floor.
            let stain = UIBezierPath()
            stain.move(to: CGPoint(x: 0, y: 380))
            for k in 0...8 {
                let x = CGFloat(k) * 80
                let y = 300 - 40 * sin(CGFloat(k + variant) * 0.9) - CGFloat(variant * 6)
                stain.addLine(to: CGPoint(x: x, y: y))
            }
            stain.addLine(to: CGPoint(x: 640, y: 380))
            stain.close()
            UIColor(hue: 0.08, saturation: 0.35, brightness: 0.55, alpha: 0.35).setFill()
            stain.fill()
            // Skirting board and floor.
            UIColor(white: 0.97, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 380, width: 640, height: 34))
            UIColor(white: 0.70, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 412, width: 640, height: 2))
            UIColor(hue: 0.07, saturation: 0.30, brightness: 0.45, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 414, width: 640, height: 66))
            // Moisture meter held against the wall.
            let meter = UIBezierPath(roundedRect: CGRect(x: 250 + CGFloat(variant * 25), y: 200, width: 110, height: 170), cornerRadius: 14)
            UIColor(red: 0.95, green: 0.62, blue: 0.10, alpha: 1).setFill()
            meter.fill()
            UIColor(white: 0.12, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 265 + CGFloat(variant * 25), y: 218, width: 80, height: 46), cornerRadius: 4).fill()
            // Caption bar.
            UIColor(white: 0, alpha: 0.55).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: 640, height: 74))
            let t: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.white]
            let st: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20, weight: .regular), .foregroundColor: UIColor(white: 0.9, alpha: 1)]
            (title as NSString).draw(at: CGPoint(x: 20, y: 6), withAttributes: t)
            (subtitle as NSString).draw(at: CGPoint(x: 20, y: 42), withAttributes: st)
            ("DEMO" as NSString).draw(at: CGPoint(x: 560, y: 444), withAttributes: st)
        }
        return image.jpegData(compressionQuality: 0.6)
    }
}

/// Small plan picture for the jobs list, drawn straight from the geometry.
enum Thumbnailer {
    static func png(for g: PlanGeometry, size: CGFloat = 240) -> Data? {
        let pts = g.walls.flatMap { [$0.a, $0.b] } + g.rooms.flatMap(\.polygon)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        let pad: CGFloat = 14
        let span = max(maxX - minX, maxY - minY, 0.5)
        let s = (size - 2 * pad) / CGFloat(span)
        func p(_ v: PlanVec) -> CGPoint {
            CGPoint(x: pad + CGFloat(v.x - minX) * s, y: pad + CGFloat(v.y - minY) * s)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            for room in g.rooms where room.polygon.count >= 3 {
                let path = UIBezierPath()
                path.move(to: p(room.polygon[0]))
                for v in room.polygon.dropFirst() { path.addLine(to: p(v)) }
                path.close()
                UIColor(red: 0.90, green: 0.93, blue: 0.98, alpha: 1).setFill()
                path.fill()
            }
            UIColor(red: 0.36, green: 0.37, blue: 0.48, alpha: 1).setStroke()
            for w in g.walls {
                let path = UIBezierPath()
                path.move(to: p(w.a))
                path.addLine(to: p(w.b))
                path.lineWidth = 3
                path.lineCapStyle = .square
                path.stroke()
            }
        }
        return image.pngData()
    }
}
