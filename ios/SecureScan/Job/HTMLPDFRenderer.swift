//
//  HTMLPDFRenderer.swift
//  SecureScan
//
//  Turns the editor's print-view HTML into a paginated A4 PDF:
//  load it into an off-screen WKWebView, wait for the load AND for every
//  <img> (photos are data URLs that decode asynchronously), then lay it out
//  with UIPrintPageRenderer + the web view's viewPrintFormatter() and draw
//  each page into a UIGraphicsPDFRenderer context.
//
//  Why this approach: WKWebView.createPDF produces one tall page; the print
//  formatter path honours CSS page breaks and gives real A4 pages.
//

import UIKit
import WebKit

final class A4PageRenderer: UIPrintPageRenderer {
    static let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)   // A4 in points
    override var paperRect: CGRect { Self.paper }
    override var printableRect: CGRect { Self.paper.insetBy(dx: 28, dy: 28) }
}

enum HTMLPDFError: LocalizedError {
    case loadFailed(String)
    case empty
    var errorDescription: String? {
        switch self {
        case .loadFailed(let s): return "The page could not be loaded (\(s))."
        case .empty: return "The page produced no PDF pages."
        }
    }
}

@MainActor
final class HTMLPDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((Result<Data, Error>) -> Void)?

    /// `host` is any on-screen view; the web view is attached to it off-screen
    /// because WebKit may not lay out pages for a view outside a window.
    func render(html: String, host: UIView, completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        let wv = WKWebView(frame: CGRect(x: -2000, y: 0, width: A4PageRenderer.paper.width, height: A4PageRenderer.paper.height))
        wv.navigationDelegate = self
        wv.isUserInteractionEnabled = false
        host.addSubview(wv)
        webView = wv
        wv.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let waitForImages = """
        await Promise.all(Array.from(document.images).map(function (img) {
            return img.complete ? null : new Promise(function (r) { img.onload = r; img.onerror = r; });
        }));
        await new Promise(function (r) { setTimeout(r, 150); });
        return true;
        """
        webView.callAsyncJavaScript(waitForImages, arguments: [:], in: nil, in: .page,
                                    completionHandler: { [weak self] _ in self?.makePDF() })
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(HTMLPDFError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(HTMLPDFError.loadFailed(error.localizedDescription)))
    }

    private func makePDF() {
        guard let wv = webView else { return }
        let renderer = A4PageRenderer()
        renderer.addPrintFormatter(wv.viewPrintFormatter(), startingAtPageAt: 0)
        let pages = renderer.numberOfPages
        guard pages > 0 else { finish(.failure(HTMLPDFError.empty)); return }
        let data = UIGraphicsPDFRenderer(bounds: A4PageRenderer.paper).pdfData { ctx in
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
            for i in 0..<pages {
                ctx.beginPage()
                renderer.drawPage(at: i, in: ctx.pdfContextBounds)
            }
        }
        finish(.success(data))
    }

    private func finish(_ result: Result<Data, Error>) {
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView = nil
        let c = completion
        completion = nil
        c?(result)
    }
}
