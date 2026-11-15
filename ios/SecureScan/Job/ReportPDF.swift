//
//  ReportPDF.swift
//  SecureScan
//
//  The assessment report PDF (docs/SPEC.md addendum v1.5): the editor's
//  self-contained report HTML (page boxes of exactly 595 x 842 px) becomes one
//  A4 PDF page per box, with internal links added from `reportLinks`.
//
//  Route (checked against Apple's documentation):
//   * The HTML is loaded into an off-screen WKWebView 595 px wide whose frame
//     is as tall as the whole document. WKPDFConfiguration.rect is "a rectangle
//     in the view's coordinate system" that "must lie within the bounds
//     rectangle" of the web view - with the frame as tall as the document, a
//     page box at document y is the same rect in view coordinates.
//   * After load, fonts and every <img> are awaited (img.decode()), then each
//     page box's position is measured in the page (not assumed), and
//     WKWebView.createPDF(configuration:) is called once per box with that
//     rect. createPDF draws the page through WebKit's PDF context, so text and
//     vector art stay vector (verified on the simulator by extracting the page
//     text with PDFKit - see report-check.txt).
//   * The single-page PDFs are merged with PDFKit on a background thread.
//     Links WebKit may have written itself are removed (an anchor to another
//     page cannot resolve inside a one-page PDF) and replaced by link
//     annotations with GoTo actions built from `reportLinks` (PDF space has a
//     bottom-left origin: y' = boxTop - y - h).
//

import UIKit
import WebKit
import PDFKit

enum ReportPDFError: LocalizedError {
    case load(String)
    case noPages
    case pdf(String)
    var errorDescription: String? {
        switch self {
        case .load(let s): return "The report could not be laid out (\(s))."
        case .noPages: return "The report has no pages."
        case .pdf(let s): return "The PDF could not be made (\(s))."
        }
    }
}

/// Facts about a finished report PDF (written to report-check.txt in the
/// automated check, and useful in logs).
struct ReportCheck {
    var pages = 0
    var pageSizes: [CGSize] = []
    var linkAnnotations = 0
    var linksResolving = 0
    var webkitLinksRemoved = 0
    var textCharacters = 0
    var bytes = 0
    var seconds = 0.0
    var expectedPages = 0
    var expectedLinks = 0

    var text: String {
        var lines: [String] = []
        lines.append("pages: \(pages) (editor said \(expectedPages))")
        let sizes = pageSizes.map { String(format: "%.1fx%.1f", $0.width, $0.height) }
        let distinct = Array(Set(sizes)).sorted()
        lines.append("page sizes (pt): \(distinct.joined(separator: ", "))\(distinct == ["595.0x842.0"] ? " - all exact A4 page boxes" : "")")
        for (i, s) in sizes.enumerated() { lines.append("  page \(i + 1): \(s)") }
        lines.append("link annotations: \(linkAnnotations) (editor sent \(expectedLinks))")
        lines.append("links resolving to a valid page: \(linksResolving) of \(linkAnnotations)")
        lines.append("links WebKit wrote itself (removed): \(webkitLinksRemoved)")
        lines.append("text extractable via PDFKit: \(textCharacters > 0 ? "yes" : "NO") (\(textCharacters) characters)")
        lines.append("file size: \(bytes) bytes (\(String(format: "%.2f", Double(bytes) / 1_048_576)) MB)")
        lines.append("elapsed: \(String(format: "%.1f", seconds)) s")
        return lines.joined(separator: "\n") + "\n"
    }

    static func of(_ data: Data) -> ReportCheck {
        var c = ReportCheck()
        c.bytes = data.count
        guard let doc = PDFDocument(data: data) else { return c }
        c.pages = doc.pageCount
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            c.pageSizes.append(page.bounds(for: .mediaBox).size)
            for a in page.annotations where a.type == "Link" {
                c.linkAnnotations += 1
                if let goTo = a.action as? PDFActionGoTo, let p = goTo.destination.page, doc.index(for: p) < doc.pageCount {
                    c.linksResolving += 1
                }
            }
        }
        c.textCharacters = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
        return c
    }
}

/// Hands PDF page data to the background merge.
final class PageDataBox: @unchecked Sendable {
    let pages: [Data]
    let links: ReportLinks?
    init(_ pages: [Data], _ links: ReportLinks?) { self.pages = pages; self.links = links }
}

@MainActor
final class ReportPDFMaker: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    static let pageSize = ReportLinks.a4

    /// html + links -> PDF data. `host` is any on-screen view; the web view is
    /// attached to it, off-screen, so WebKit lays it out.
    func make(html: String, links: ReportLinks?, host: UIView,
              progress: @escaping (Double, String) -> Void) async throws -> (Data, ReportCheck) {
        let started = Date()
        let expectedPages = max(1, links?.pages ?? 1)
        let w = Self.pageSize.width, h = Self.pageSize.height
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: -20_000, y: 0, width: w, height: h * CGFloat(expectedPages)), configuration: config)
        wv.navigationDelegate = self
        wv.isUserInteractionEnabled = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.isScrollEnabled = false
        wv.isOpaque = true
        wv.backgroundColor = .white
        host.addSubview(wv)
        webView = wv
        defer {
            wv.removeFromSuperview()
            webView = nil
        }

        progress(0.02, "Laying out the report…")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            wv.loadHTMLString(html, baseURL: nil)
        }

        var boxes = try await measure(wv)
        guard !boxes.isEmpty else { throw ReportPDFError.noPages }
        // Make the view exactly as tall as the document so every box is inside its bounds.
        let docHeight = boxes.map(\.maxY).max() ?? h
        if abs(wv.frame.height - docHeight) > 0.5 {
            wv.frame = CGRect(x: wv.frame.minX, y: 0, width: w, height: docHeight)
            boxes = try await measure(wv)
        }

        var pages: [Data] = []
        for (i, box) in boxes.enumerated() {
            progress(0.05 + 0.85 * Double(i) / Double(boxes.count), "Making page \(i + 1) of \(boxes.count)…")
            let pc = WKPDFConfiguration()
            pc.rect = box
            let data: Data = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                wv.createPDF(configuration: pc) { result in
                    switch result {
                    case .success(let d): c.resume(returning: d)
                    case .failure(let e): c.resume(throwing: ReportPDFError.pdf(e.localizedDescription))
                    }
                }
            }
            pages.append(data)
        }

        progress(0.92, "Adding links…")
        let box = PageDataBox(pages, links)
        let merged = try await Task.detached(priority: .userInitiated) { () throws -> (Data, Int) in
            try ReportPDFMaker.merge(box)
        }.value
        var check = ReportCheck.of(merged.0)
        check.webkitLinksRemoved = merged.1
        check.expectedPages = links?.pages ?? boxes.count
        check.expectedLinks = links?.links.count ?? 0
        check.seconds = Date().timeIntervalSince(started)
        progress(1, "Done")
        return (merged.0, check)
    }

    /// Positions of the page boxes in document coordinates, after fonts and
    /// images are ready.
    private func measure(_ wv: WKWebView) async throws -> [CGRect] {
        let js = """
        if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
        await Promise.all(Array.from(document.images).map(function (img) {
            if (img.decode) { return img.decode().catch(function () {}); }
            return img.complete ? null : new Promise(function (r) { img.onload = r; img.onerror = r; });
        }));
        await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); });
        var boxes = Array.from(document.querySelectorAll('.rp-page'));
        if (boxes.length === 0) { boxes = [document.body]; }
        return boxes.map(function (s) {
            var r = s.getBoundingClientRect();
            return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
        });
        """
        let value: Any? = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
            wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): c.resume(returning: v)
                case .failure(let e): c.resume(throwing: ReportPDFError.load(e.localizedDescription))
                }
            }
        }
        let list = value as? [[Any]] ?? []
        return list.compactMap { a in
            guard a.count == 4, let x = PlanDocument.number(a[0]), let y = PlanDocument.number(a[1]),
                  let w = PlanDocument.number(a[2]), let h = PlanDocument.number(a[3]), w > 1, h > 1 else { return nil }
            // Page boxes are whole points; snap away sub-pixel layout noise.
            return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
        }
    }

    /// Background: one document, our link annotations. Returns the PDF data and
    /// the number of links WebKit had written itself (removed).
    nonisolated static func merge(_ box: PageDataBox) throws -> (Data, Int) {
        let out = PDFDocument()
        var sources: [PDFDocument] = []          // kept alive until written
        var removed = 0
        for d in box.pages {
            guard let src = PDFDocument(data: d), let page = src.page(at: 0) else {
                throw ReportPDFError.pdf("a page could not be read")
            }
            sources.append(src)
            for a in page.annotations where a.type == "Link" {
                page.removeAnnotation(a)
                removed += 1
            }
            out.insert(page, at: out.pageCount)
        }
        if let links = box.links {
            for l in links.valid(pageCount: out.pageCount) {
                guard let page = out.page(at: l.page - 1), let target = out.page(at: l.targetPage - 1) else { continue }
                let pb = page.bounds(for: .mediaBox), tb = target.bounds(for: .mediaBox)
                let rect = ReportLinks.pdfRect(l.rect, pageSize: links.pageSize, box: pb)
                let a = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
                let border = PDFBorder()
                border.lineWidth = 0
                a.border = border
                let point = ReportLinks.pdfDestination(targetY: l.targetY, pageSize: links.pageSize, box: tb)
                a.action = PDFActionGoTo(destination: PDFDestination(page: target, at: point))
                page.addAnnotation(a)
            }
        }
        guard let data = out.dataRepresentation() else { throw ReportPDFError.pdf("PDFKit could not write the file") }
        _ = sources.count
        return (data, removed)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: ReportPDFError.load(error.localizedDescription))
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: ReportPDFError.load(error.localizedDescription))
        loadContinuation = nil
    }
}
