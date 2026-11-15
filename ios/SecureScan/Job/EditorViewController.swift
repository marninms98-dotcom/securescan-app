//
//  EditorViewController.swift
//  SecureScan
//
//  Hosts the bundled web/editor.html in a WKWebView and implements the host
//  bridge exactly as docs/SPEC.md "Contract 2":
//    editor -> host  window.webkit.messageHandlers.host.postMessage(msg)
//      ready  -> host calls window.SecureScan.load(plan)
//      save   -> write plan.json atomically
//      export -> decode base64, share; text/html is turned into an A4 PDF first
//      exportPack -> write the files + plan.json, audio, model.usdz and the
//                    report PDF, zip, share "<address>-job-pack.zip" (v1.4/v1.5)
//      exportReport -> html + links -> A4 PDF with internal links, share
//                    "<address>-assessment-report.pdf" (addendum v1.5)
//  The app-wide brand (markup.brand) is remembered on save and injected into
//  plans without one before load (AppSettings).
//      close  -> dismiss
//    host -> editor  window.SecureScan.load(planObject) / getPlan()
//
//  The plan is passed with callAsyncJavaScript(arguments:), so WebKit itself
//  serialises the (possibly multi-MB) JSON text: no string escaping in Swift.
//

import UIKit
import WebKit

final class EditorViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    static var editorURL: URL? { Bundle.main.url(forResource: "editor", withExtension: "html") }

    let folder: JobFolder
    private let fallbackMeta: JobMeta?
    var onClose: (() -> Void)?
    var onSaved: ((String?, String?) -> Void)?
    /// The editor has loaded the plan: which documents it makes, and whether
    /// it can hide prices (SecureScan.setPricesVisible).
    var onReady: ((Set<String>, Bool) -> Void)?
    /// nil until the first load; then whether the editor has setPricesVisible.
    private(set) var hidesPrices: Bool?
    private var pricesObserver: NSObjectProtocol?
    var loadedVersion = 0

    private var webView: WKWebView?
    private var isReady = false
    /// Serial queue: plan.json reads and writes never overlap and stay in order.
    private let ioQueue = DispatchQueue(label: "com.secureworkswa.securescan.planio", qos: .userInitiated)
    private var pdfRenderer: HTMLPDFRenderer?

    init(folder: JobFolder, fallbackMeta: JobMeta?) {
        self.folder = folder
        self.fallbackMeta = fallbackMeta
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pricesObserver = NotificationCenter.default.addObserver(forName: .pricesVisibleChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPricesVisible() }
        }
        guard let url = Self.editorURL else { return }   // PlanTab shows the error view

        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "host")
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: view.bounds, configuration: config)
        wv.navigationDelegate = self
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        wv.isInspectable = true
        #endif
        view.addSubview(wv)
        webView = wv
        // Read access to the editor's folder (the app bundle) only.
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Leaving the Plan tab or the job (back button / swipe): the editor's
    /// autosave is debounced ~800 ms, so ask it to flush now. The page's own
    /// `pagehide` handler posts `save` only if a save is pending. The Task keeps
    /// this controller (and its web view) alive until the message has arrived.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isReady, let webView else { return }
        Task { @MainActor in
            _ = try? await webView.evaluateJavaScript("window.dispatchEvent(new Event('pagehide')); true")
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = self
        }
    }

    // MARK: Bridge: editor -> host

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            sendPlan()
        case "save":
            if let plan = body["plan"] as? [String: Any] { save(plan: plan) }
        case "export":
            let name = ((body["filename"] as? String) ?? "").lowercased()
            if exportWouldShowPrices && (name.contains("scope") || name.contains("quote") || name.contains("report")) {
                refusePricedExport()
            } else {
                handleExport(body)
            }
        case "exportPack":
            handleExportPack(body)
        case "exportReport":
            handleExportReport(body)
        case "close":
            onClose?()
        default:
            break
        }
    }

    // MARK: Host -> editor

    /// Reads plan.json off the main thread and calls SecureScan.load(plan).
    func sendPlan() {
        guard isReady, webView != nil else { return }
        let planURL = folder.planURL
        let fallback = fallbackMeta
        ioQueue.async { [weak self] in
            var text = (try? Data(contentsOf: planURL)).flatMap { String(data: $0, encoding: .utf8) }
            if text == nil, let m = fallback {
                // No plan yet: hand the editor an empty document for this job.
                let doc = PlanDocument.newDocument(id: m.id.uuidString, address: m.address, jobRef: m.jobRef,
                                                   createdAt: m.createdAt, now: Date(), geometry: PlanGeometry())
                text = (try? PlanDocument.data(doc)).flatMap { String(data: $0, encoding: .utf8) }
            }
            // A plan without a brand gets the one remembered app-wide.
            if let t = text, let data = t.data(using: .utf8),
               let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let withBrand = AppSettings.injected(plan: doc, stored: AppSettings.load()),
               let out = try? PlanDocument.data(withBrand) {
                text = String(data: out, encoding: .utf8)
            }
            guard let planText = text else { return }
            Task { @MainActor [weak self] in
                // After every load: tell the editor whether to show prices (when it can).
                self?.webView?.callAsyncJavaScript(
                    "window.SecureScan.load(JSON.parse(planText)); " + Self.pricesJS,
                    arguments: ["planText": planText, "prices": PriceLock.pricesVisible], in: nil, in: .page,
                    completionHandler: { [weak self] result in
                        switch result {
                        case .failure(let error):
                            print("SecureScan.load failed: \(error)")
                        case .success(let v):
                            guard let self else { return }
                            self.hidesPrices = (v as? Bool) ?? false
                            self.runAutomationIfRequested()
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                await self.cacheEditorNames()
                                guard let kinds = await self.documentKinds() else { return }
                                self.onReady?(kinds, self.hidesPrices ?? false)
                            }
                        }
                    })
            }
        }
    }

    /// Calls SecureScan.setPricesVisible(prices) when the editor has it; returns whether it does.
    private static let pricesJS = "var s = window.SecureScan; var hook = !!(s && typeof s.setPricesVisible === 'function'); if (hook) { s.setPricesVisible(prices); } return hook;"

    /// The "Show prices" setting changed: tell the loaded editor.
    func applyPricesVisible() {
        guard isReady, let webView else { return }
        webView.callAsyncJavaScript(Self.pricesJS, arguments: ["prices": PriceLock.pricesVisible], in: nil, in: .page) { [weak self] result in
            if case .success(let v) = result { self?.hidesPrices = (v as? Bool) ?? false }
        }
    }

    /// With prices hidden, an editor that cannot hide them must not export
    /// anything that could carry them (report, job pack) from this phone.
    private var exportWouldShowPrices: Bool { !PriceLock.pricesVisible && hidesPrices != true }

    private func refusePricedExport() {
        showMessage("Prices are hidden on this phone",
                    "This export could include prices, and this version of the plan editor can't hide them. It will be available after the plan editor update, or ask the office.")
    }

    /// Asks the editor for its current document and writes it to plan.json,
    /// so a regenerate starts from the latest markup.
    func flushLatestPlan() async {
        guard isReady, let webView else { return }
        let json: String? = await withCheckedContinuation { cont in
            webView.callAsyncJavaScript(
                "return JSON.stringify(window.SecureScan.getPlan());",
                arguments: [:], in: nil, in: .page,
                completionHandler: { result in
                    if case .success(let value) = result { cont.resume(returning: value as? String) }
                    else { cont.resume(returning: nil) }
                })
        }
        guard let json, let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return }
        let url = folder.planURL
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                try? data.write(to: url, options: .atomic)
                cont.resume()
            }
        }
    }

    // MARK: Save

    private func save(plan: [String: Any]) {
        let url = folder.planURL
        let address = plan["address"] as? String
        let jobRef = plan["jobRef"] as? String
        ioQueue.async { [weak self] in
            guard let clean = PlanDocument.sanitised(plan) as? [String: Any],
                  JSONSerialization.isValidJSONObject(clean),
                  let data = try? PlanDocument.data(clean) else {
                print("plan.json save skipped: the editor sent a document that is not valid JSON")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("plan.json save failed: \(error)")
                return
            }
            AppSettings.remember(from: clean)
            Task { @MainActor [weak self] in self?.onSaved?(address, jobRef) }
        }
    }

    // MARK: Export

    private func handleExport(_ body: [String: Any]) {
        let filename = Self.safeFilename((body["filename"] as? String) ?? "SecureScan-export")
        let mime = (body["mime"] as? String) ?? "application/octet-stream"
        var b64 = (body["base64"] as? String) ?? ""
        if b64.hasPrefix("data:"), let comma = b64.firstIndex(of: ",") {
            b64 = String(b64[b64.index(after: comma)...])     // tolerate a data URL
        }
        let payload = b64
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
                Task { @MainActor [weak self] in self?.showError("The export could not be read.") }
                return
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("exports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(filename)
            try? data.write(to: fileURL, options: .atomic)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if mime.lowercased().hasPrefix("text/html") {
                    let html = String(data: data, encoding: .utf8) ?? ""
                    let pdfURL = dir.appendingPathComponent((filename as NSString).deletingPathExtension + ".pdf")
                    self.makePDF(html: html, to: pdfURL)
                } else {
                    self.share([fileURL])
                }
            }
        }
    }

    // MARK: Progress

    private var exportBusy = false
    private var progressOverlay: ProgressOverlay?
    private var reportMaker: ReportPDFMaker?

    private func showProgress(_ text: String) {
        let overlay = ProgressOverlay(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        progressOverlay = overlay
        overlay.update(0, text)
    }

    private func hideProgress() {
        progressOverlay?.removeFromSuperview()
        progressOverlay = nil
    }

    // MARK: Assessment report (PDF)

    private func handleExportReport(_ body: [String: Any]) {
        guard !exportBusy, let html = body["html"] as? String else { return }
        if exportWouldShowPrices { refusePricedExport(); return }
        let links = ReportLinks.parse(body["links"])
        // Optional from editor v1.9: kind and filename.
        let address = Self.address(in: folder) ?? fallbackMeta?.address ?? ""
        let fileName = DocumentKind.cleanFileName(body["filename"] as? String)
            ?? (body["kind"] as? String).flatMap { DocumentKind(rawValue: $0 == "inspection" ? "initial" : $0) }?.fileName(address: address)
        exportBusy = true
        showProgress("Making the report PDF…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.exportBusy = false; self.hideProgress() }
            do {
                let (url, check) = try await self.makeReportPDF(html: html, links: links, progressFrom: 0, to: 1, fileName: fileName)
                print("Report PDF: \(check.text)")
                self.share([url])
            } catch {
                self.showError(error.localizedDescription)
            }
        }
    }

    /// The report straight from the editor (used by the job pack and the
    /// automated check; the Export sheet sends the same two values in its message).
    func editorReport() async -> (html: String, links: ReportLinks?)? {
        guard isReady, let webView else { return nil }
        let value: Any? = await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(
                "return { html: window.SecureScan.reportHTML(), links: window.SecureScan.reportLinks() };",
                arguments: [:], in: nil, in: .page,
                completionHandler: { result in
                    if case .success(let v) = result { c.resume(returning: v) } else { c.resume(returning: nil) }
                })
        }
        guard let d = value as? [String: Any], let html = d["html"] as? String, !html.isEmpty else { return nil }
        return (html, ReportLinks.parse(d["links"]))
    }

    // MARK: Documents straight from the job screen

    var ready: Bool { isReady }

    /// Feature test, shared by the two calls below: which kinds the editor's
    /// SecureScan.reportHTML(kind) understands ([] = only the no-argument form).
    private static let kindsJS = """
    var s = window.SecureScan;
    if (!s || !s.reportHTML) { return null; }
    var kinds = Array.isArray(s.reportKinds) ? s.reportKinds
              : (/^[^(]*\\(\\s*[A-Za-z_$]/.test(String(s.reportHTML)) ? ['initial', 'quote', 'monitoring', 'final'] : []);
    """

    /// Caches SecureScan.wallNames() / removalRefs() (editor v1.9+) for the AR screens.
    func cacheEditorNames() async {
        guard isReady, let webView else { return }
        let value: Any? = await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(
                "var s = window.SecureScan; if (!s || typeof s.wallNames !== 'function') { return null; } return { walls: s.wallNames(), refs: typeof s.removalRefs === 'function' ? s.removalRefs() : [] };",
                arguments: [:], in: nil, in: .page) { result in
                if case .success(let v) = result { c.resume(returning: v) } else { c.resume(returning: nil) }
            }
        }
        guard let d = value as? [String: Any] else { return }
        EditorNamesStore.save(EditorNames.parse(wallNames: d["walls"], removalRefs: d["refs"]), folder)
    }

    /// The document kinds the loaded editor makes; nil if it isn't loaded.
    func documentKinds() async -> Set<String>? {
        guard isReady, let webView else { return nil }
        let value: Any? = await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(Self.kindsJS + "return kinds;", arguments: [:], in: nil, in: .page) { result in
                if case .success(let v) = result { c.resume(returning: v) } else { c.resume(returning: nil) }
            }
        }
        guard let list = value as? [Any] else { return nil }
        return Set(list.compactMap { $0 as? String })
    }

    enum DocumentSource {
        case report(html: String, links: ReportLinks?, legacy: Bool)
        case unsupported
        case failed
    }

    /// SecureScan.reportHTML(kind) / reportLinks(kind). An editor without the
    /// argument form gives its one report for inspection / monitoring / final
    /// (legacy) and nothing for the quote - never a stand-in quote.
    func documentSource(_ kind: DocumentKind) async -> DocumentSource {
        guard isReady, let webView else { return .failed }
        let js = Self.kindsJS + """
        if (kinds.indexOf(kind) < 0) {
          if (kind === 'quote' || kind === 'scope' || kinds.length) { return { unsupported: true }; }
          return { html: s.reportHTML(), links: s.reportLinks(), legacy: true };
        }
        return { html: s.reportHTML(kind), links: s.reportLinks(kind) };
        """
        let value: Any? = await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(js, arguments: ["kind": kind.rawValue], in: nil, in: .page) { result in
                if case .success(let v) = result { c.resume(returning: v) } else { c.resume(returning: nil) }
            }
        }
        guard let d = value as? [String: Any] else { return .failed }
        if (d["unsupported"] as? Bool) == true { return .unsupported }
        guard let html = d["html"] as? String, !html.isEmpty else { return .failed }
        return .report(html: html, links: ReportLinks.parse(d["links"]), legacy: (d["legacy"] as? Bool) == true)
    }

    /// Job screen: make the document as a PDF and open the share sheet.
    /// `checkDir` (automated check only): write the PDF and report-check.txt there instead.
    func exportDocument(_ kind: DocumentKind, checkDir: URL? = nil) async {
        guard !exportBusy else { return }
        if !DocumentKind.available(kind, editorKinds: nil, editorHidesPrices: hidesPrices, pricesVisible: PriceLock.pricesVisible) {
            try? "UNSUPPORTED: prices are hidden and this editor can't hide them (or the quote was asked for)\n"
                .write(to: (checkDir ?? FileManager.default.temporaryDirectory).appendingPathComponent("report-check.txt"), atomically: true, encoding: .utf8)
            showMessage(kind.title, kind == .quote && !PriceLock.pricesVisible
                        ? "Prices are hidden on this phone. The office can turn them on in Settings."
                        : "The \(kind.title.lowercased()) is available after the plan editor update.")
            return
        }
        exportBusy = true
        showProgress("Making the \(kind.title.lowercased())…")
        defer { exportBusy = false; hideProgress() }
        let checkURL = checkDir?.appendingPathComponent("report-check.txt")
        switch await documentSource(kind) {
        case .unsupported:
            try? "UNSUPPORTED: this editor has no SecureScan.reportHTML('\(kind.rawValue)') yet\n".write(to: checkURL ?? URL(fileURLWithPath: "/dev/null"), atomically: false, encoding: .utf8)
            showMessage(kind.title, "The \(kind.title.lowercased()) is available after the plan editor update. Everything you've marked up is saved and will be in it.")
        case .failed:
            try? "FAILED: the editor returned no \(kind.rawValue) document\n".write(to: checkURL ?? URL(fileURLWithPath: "/dev/null"), atomically: false, encoding: .utf8)
            showError("The plan editor didn't return the \(kind.title.lowercased()).")
        case .report(let html, let links, let legacy):
            let address = Self.address(in: folder) ?? fallbackMeta?.address ?? ""
            do {
                let (url, check) = try await makeReportPDF(html: html, links: links, progressFrom: 0, to: 1,
                                                           fileName: legacy ? nil : kind.fileName(address: address))
                if let checkDir, let checkURL {
                    let out = checkDir.appendingPathComponent(kind == .quote ? "quote.pdf" : kind == .scope ? "scope-of-works.pdf" : "\(kind.rawValue)-report.pdf")
                    try? FileManager.default.removeItem(at: out)
                    try FileManager.default.copyItem(at: url, to: out)
                    let text = "file: \(url.lastPathComponent)\nkind: \(kind.rawValue)\(legacy ? " (editor without kinds: its one report)" : "")\nhtml: \(html.utf8.count) bytes\n" + check.text
                    try text.write(to: checkURL, atomically: true, encoding: .utf8)
                } else {
                    share([url])
                }
            } catch {
                try? "FAILED: \(error.localizedDescription)\n".write(to: checkURL ?? URL(fileURLWithPath: "/dev/null"), atomically: false, encoding: .utf8)
                showError(error.localizedDescription)
            }
        }
    }

    /// Lays out the report, makes the PDF, writes "<address>-assessment-report.pdf"
    /// to a temporary folder. Progress goes to the overlay between `from` and `to`.
    func makeReportPDF(html: String, links: ReportLinks?, progressFrom from: Double, to: Double,
                       fileName: String? = nil) async throws -> (URL, ReportCheck) {
        let maker = ReportPDFMaker()
        reportMaker = maker
        defer { reportMaker = nil }
        let (data, check) = try await maker.make(html: html, links: links, host: view) { [weak self] f, text in
            self?.progressOverlay?.update(from + (to - from) * f, text)
        }
        let address = Self.address(in: folder) ?? fallbackMeta?.address ?? ""
        let name = fileName ?? PackNames.reportFileName(address: address)
        let url: URL = try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("exports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }.value
        return (url, check)
    }

    // MARK: Job pack

    private func handleExportPack(_ body: [String: Any]) {
        guard !exportBusy else { return }
        if exportWouldShowPrices { refusePricedExport(); return }
        let files = (body["files"] as? [[String: Any]]) ?? []
        exportBusy = true
        showProgress("Preparing the job pack…")
        let payload = PackPayload(files)
        let folder = self.folder
        let fallbackAddress = fallbackMeta?.address ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The pack's plan.json should hold the very latest edits.
            await self.flushLatestPlan()
            let address = Self.address(in: folder) ?? fallbackAddress
            // The report PDF goes in the pack too (the editor adds the HTML).
            var extra: [(String, URL)] = []
            if let report = await self.editorReport() {
                do {
                    let (url, _) = try await self.makeReportPDF(html: report.html, links: report.links, progressFrom: 0, to: 0.5)
                    extra.append((url.lastPathComponent, url))
                } catch {
                    print("Job pack: report PDF skipped: \(error)")
                }
            }
            let extraFiles = PackExtras(extra)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: Swift.Result<JobPack.Output, Error>
                do {
                    result = .success(try JobPack.build(payload: payload, folder: folder, address: address,
                                                        extra: extraFiles.files) { fraction, text in
                        Task { @MainActor [weak self] in self?.progressOverlay?.update(0.5 + 0.5 * fraction, text) }
                    })
                } catch {
                    result = .failure(error)
                }
                let outcome = PackOutcome(result)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = outcome.value
                    self.exportBusy = false
                    self.hideProgress()
                    switch result {
                    case .success(let out):
                        if !out.skipped.isEmpty {
                            print("Job pack: skipped \(out.skipped)")
                        }
                        self.share([out.zip])
                    case .failure(let error):
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Opens the editor's re-measure flow through its public hook
    /// (window.SecureScan.startRemeasure(), editor v1.8). Returns false when
    /// the editor says there is nothing to re-measure.
    @discardableResult
    func startRemeasure() async -> Bool {
        guard isReady, let webView else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            webView.callAsyncJavaScript("return !!(window.SecureScan && window.SecureScan.startRemeasure && window.SecureScan.startRemeasure());",
                                        arguments: [:], in: nil, in: .page) { result in
                if case .success(let v) = result { c.resume(returning: (v as? Bool) ?? false) } else { c.resume(returning: false) }
            }
        }
    }

    // MARK: Automation (CI screenshots and the report check only)

    private var automationDone = false

    /// SECURESCAN_EDITOR_VIEW=walls|notes|report switches the editor's view
    /// (window.SecureScan.setView); SECURESCAN_EXPORT_REPORT=1 makes
    /// the report PDF through the same code as Export and writes it, with
    /// report-check.txt, to Documents/report-check/.
    private func runAutomationIfRequested() {
        guard !automationDone else { return }
        let env = ProcessInfo.processInfo.environment
        let viewName = env["SECURESCAN_EDITOR_VIEW"]
        let exportValue = env["SECURESCAN_EXPORT_REPORT"]
        let export = exportValue == "1"
        let docKind = exportValue.flatMap(DocumentKind.init(rawValue:))
        guard viewName != nil || export || docKind != nil else { return }
        automationDone = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            if let v = viewName { await self.switchEditorView(v) }
            if export { await self.writeReportCheck() }
            if let k = docKind {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dir = docs.appendingPathComponent("report-check-\(k.rawValue)", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                await self.exportDocument(k, checkDir: dir)
            }
        }
    }

    /// Switches the editor's view through its public hook
    /// window.SecureScan.setView(name): plan | walls | notes | 3d | report.
    private func switchEditorView(_ name: String) async {
        guard let webView else { return }
        let view = name == "elev" ? "walls" : name
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            webView.callAsyncJavaScript("return window.SecureScan && window.SecureScan.setView ? window.SecureScan.setView(name) : null;",
                                        arguments: ["name": view], in: nil, in: .page) { result in
                if case .failure(let e) = result { print("Editor view switch failed: \(e)") }
                c.resume()
            }
        }
    }

    private func writeReportCheck() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stress = ProcessInfo.processInfo.environment["SECURESCAN_DEMO_VARIANT"] == "stress"
        let dir = docs.appendingPathComponent(stress ? "report-check-stress" : "report-check", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let checkURL = dir.appendingPathComponent("report-check.txt")
        exportBusy = true
        showProgress("Making the report PDF…")
        defer { exportBusy = false; hideProgress() }
        guard let report = await editorReport() else {
            try? "FAILED: SecureScan.reportHTML() returned nothing\n".write(to: checkURL, atomically: true, encoding: .utf8)
            return
        }
        do {
            let (url, check) = try await makeReportPDF(html: report.html, links: report.links, progressFrom: 0, to: 1)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("assessment-report.pdf"))
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("assessment-report.pdf"))
            let text = "file: \(url.lastPathComponent)\nhtml: \(report.html.utf8.count) bytes\n" + check.text
            try text.write(to: checkURL, atomically: true, encoding: .utf8)
            showMessage("Report check", "\(check.pages) pages, \(check.linkAnnotations) links, \(String(format: "%.1f", check.seconds)) s")
        } catch {
            try? "FAILED: \(error.localizedDescription)\n".write(to: checkURL, atomically: true, encoding: .utf8)
            showMessage("Report check failed", error.localizedDescription)
        }
    }

    private func showMessage(_ title: String, _ text: String) {
        let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    nonisolated static func address(in folder: JobFolder) -> String? {
        guard let data = try? Data(contentsOf: folder.planURL),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return doc["address"] as? String
    }

    private func makePDF(html: String, to url: URL) {
        let renderer = HTMLPDFRenderer()
        pdfRenderer = renderer
        renderer.render(html: html, host: view) { [weak self] result in
            guard let self else { return }
            self.pdfRenderer = nil
            switch result {
            case .success(let data):
                do {
                    try data.write(to: url, options: .atomic)
                    self.share([url])
                } catch {
                    self.showError("The PDF could not be saved: \(error.localizedDescription)")
                }
            case .failure(let error):
                self.showError("The PDF could not be made: \(error.localizedDescription)")
            }
        }
    }

    private func share(_ items: [Any]) {
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = view
        ac.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(ac, animated: true)
    }

    private func showError(_ text: String) {
        let a = UIAlertController(title: "Export", message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    // MARK: WKNavigationDelegate

    /// iOS kills the web content process under memory pressure (large plans with
    /// photos, camera use). Reload; the page posts `ready` again and gets the
    /// last saved plan.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.reload()
    }

    static func safeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "SecureScan-export" : cleaned
    }
}

/// Hands the extra pack files (the report PDF) to the background queue.
final class PackExtras: @unchecked Sendable {
    let files: [(String, URL)]
    init(_ files: [(String, URL)]) { self.files = files }
}

/// Carries the pack result back to the main actor.
final class PackOutcome: @unchecked Sendable {
    let value: Swift.Result<JobPack.Output, Error>
    init(_ value: Swift.Result<JobPack.Output, Error>) { self.value = value }
}

/// Dimmed panel with a progress bar, shown while a job pack is built.
final class ProgressOverlay: UIView {
    private let label = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        let panel = UIView()
        panel.backgroundColor = .systemBackground
        panel.layer.cornerRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 2
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [label, bar])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 280),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ fraction: Double, _ text: String) {
        bar.setProgress(Float(min(max(fraction, 0), 1)), animated: true)
        label.text = text
    }
}

/// WKUserContentController retains its handlers strongly; this proxy avoids a
/// retain cycle with the view controller.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
