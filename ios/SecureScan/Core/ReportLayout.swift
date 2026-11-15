//
//  ReportLayout.swift
//  SecureScan
//
//  Pure maths for the assessment report PDF (docs/SPEC.md addendum v1.5):
//  the editor's `reportLinks()` object, and the conversion of its page-box
//  coordinates (pixels = points, origin top-left) into PDF page space (origin
//  bottom-left). Foundation only - unit tested.
//

import Foundation
import CoreGraphics

struct ReportLinks: Equatable {
    struct Link: Equatable {
        var page: Int            // 1-based
        var rect: CGRect         // page-box coordinates, origin top-left
        var targetPage: Int      // 1-based
        var targetY: Double      // from the top of the target page
    }

    var pages: Int
    var pageSize: CGSize
    var links: [Link]

    static let a4 = CGSize(width: 595, height: 842)

    /// Parses `{ pages, pageSize: [w, h], links: [ { page, rect: [x, y, w, h], targetPage, targetY } ] }`.
    /// Malformed links are skipped; nil if the object itself is unusable.
    static func parse(_ any: Any?) -> ReportLinks? {
        guard let d = any as? [String: Any], let pages = PlanDocument.number(d["pages"]), pages >= 1 else { return nil }
        var size = a4
        if let s = d["pageSize"] as? [Any], s.count == 2,
           let w = PlanDocument.number(s[0]), let h = PlanDocument.number(s[1]), w > 0, h > 0 {
            size = CGSize(width: w, height: h)
        }
        var out: [Link] = []
        for l in d["links"] as? [[String: Any]] ?? [] {
            guard let p = PlanDocument.number(l["page"]), let tp = PlanDocument.number(l["targetPage"]),
                  let r = l["rect"] as? [Any], r.count == 4,
                  let x = PlanDocument.number(r[0]), let y = PlanDocument.number(r[1]),
                  let w = PlanDocument.number(r[2]), let h = PlanDocument.number(r[3]),
                  w > 0, h > 0 else { continue }
            out.append(Link(page: Int(p), rect: CGRect(x: x, y: y, width: w, height: h),
                            targetPage: Int(tp), targetY: PlanDocument.number(l["targetY"]) ?? 0))
        }
        return ReportLinks(pages: Int(pages), pageSize: size, links: out)
    }

    /// A link's rectangle in PDF page space, for a page whose media box is
    /// `box` (page-box units are scaled to the box if it differs from `pageSize`).
    static func pdfRect(_ r: CGRect, pageSize: CGSize, box: CGRect) -> CGRect {
        let sx = box.width / pageSize.width, sy = box.height / pageSize.height
        return CGRect(x: box.minX + r.minX * sx, y: box.maxY - (r.minY + r.height) * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    /// The point a "go to" destination should show at the top-left of the view.
    static func pdfDestination(targetY: Double, pageSize: CGSize, box: CGRect) -> CGPoint {
        let sy = box.height / pageSize.height
        let y = min(max(targetY, 0), Double(pageSize.height))
        return CGPoint(x: box.minX, y: box.maxY - CGFloat(y) * sy)
    }

    /// Links whose source and target pages exist in a document of `pageCount` pages.
    func valid(pageCount: Int) -> [Link] {
        guard pageCount >= 1 else { return [] }
        return links.filter { (1...pageCount).contains($0.page) && (1...pageCount).contains($0.targetPage) }
    }
}
