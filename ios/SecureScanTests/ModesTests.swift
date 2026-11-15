//
//  ModesTests.swift
//  SecureScanTests
//
//  Inspect / Quote / Monitor, the documents the job screen offers, and the
//  Quote mode tally.
//

import XCTest

final class ModesTests: XCTestCase {

    func testModesAndTheirTools() {
        XCTAssertEqual(WorkMode.offered(laterVisit: false), [.inspect, .quote])
        XCTAssertEqual(WorkMode.offered(laterVisit: true), [.inspect, .quote, .monitor])
        XCTAssertEqual(WorkMode.defaultMode(laterVisit: false), .inspect)
        XCTAssertEqual(WorkMode.defaultMode(laterVisit: true), .monitor)
        XCTAssertEqual(WorkMode.inspect.tools, [.reading, .moisture, .photo, .source])
        XCTAssertEqual(WorkMode.quote.tools, [.equipment, .wallRemoval, .floorRemoval, .photo])
        XCTAssertEqual(WorkMode.monitor.tools, [.remeasure, .moisture, .photo, .markDone])
        // The scan screen's last type picks the mode it lives in.
        XCTAssertEqual(WorkMode.containing(MarkupMode(kind: "removal"), laterVisit: false), .quote)
        XCTAssertEqual(WorkMode.containing(MarkupMode(kind: "equipment"), laterVisit: false), .quote)
        XCTAssertEqual(WorkMode.containing(MarkupMode(kind: "boundary"), laterVisit: false), .inspect)
        XCTAssertEqual(WorkMode.containing(MarkupMode(kind: "boundary"), laterVisit: true), .monitor)
        XCTAssertEqual(MarkupMode.wallRemoval.kind, "removal")
        XCTAssertEqual(MarkupMode.moisture.kind, "boundary")
    }

    func testDocumentsOffered() {
        XCTAssertEqual(DocumentKind.offered(visitCount: 1, lastVisitType: nil), [.initial, .quote])
        XCTAssertEqual(DocumentKind.offered(visitCount: 2, lastVisitType: "monitoring"), [.initial, .quote, .monitoring])
        XCTAssertEqual(DocumentKind.offered(visitCount: 3, lastVisitType: "final"), [.initial, .quote, .final])
    }

    func testDocumentFileNames() {
        XCTAssertEqual(DocumentKind.quote.fileName(address: "18 Example Dr, Testvale, WA"), "18 Example Dr, Testvale, WA-quote.pdf")
        XCTAssertEqual(DocumentKind.initial.fileName(address: ""), "SecureScan-inspection-report.pdf")
        XCTAssertEqual(DocumentKind.cleanFileName("Q-1042 Example Dr.pdf"), "Q-1042 Example Dr.pdf")
        XCTAssertEqual(DocumentKind.cleanFileName("../../etc/quote"), "quote.pdf")
        XCTAssertEqual(DocumentKind.cleanFileName("a:b?.PDF"), "a-b.pdf")
        XCTAssertNil(DocumentKind.cleanFileName("  .pdf"))
        XCTAssertNil(DocumentKind.cleanFileName(nil))
    }

    func testQuoteTally() {
        let walls: [[String: Any]] = [["id": "w1", "a": [0.0, 0.0], "b": [4.0, 0.0], "height": 2.4]]
        let equipment: [[String: Any]] = [
            ["id": "e1", "type": "airMover", "removed": NSNull()],
            ["id": "e2", "type": "airMover"],
            ["id": "e3", "type": "dehumidifier"],
            ["id": "e4", "type": "airMover", "removed": "v2"],
        ]
        let removals: [[String: Any]] = [
            ["id": "x1", "item": "plasterboard", "wallId": "w1", "t0": 0.0, "t1": 0.5, "heightMm": 600],   // 2 m x 0.6
            ["id": "x2", "item": "skirting", "wallId": "w1", "t0": 0.25, "t1": 0.75, "heightMm": 100],    // 2 lm
            ["id": "x3", "item": "flooring", "area": [[0.0, 0.0], [2.0, 0.0], [2.0, 1.6], [0.0, 1.6]]],  // 3.2 m²
        ]
        let markup: [String: Any] = ["equipment": equipment, "removals": removals]
        let t = QuoteTally.from(plan: ["walls": walls, "markup": markup])
        XCTAssertEqual(t.equipment["airMover"], 2)
        XCTAssertEqual(t.equipment["dehumidifier"], 1)
        XCTAssertEqual(t.liningM2, 1.2, accuracy: 1e-9)
        XCTAssertEqual(t.skirtingLm, 2, accuracy: 1e-9)
        XCTAssertEqual(t.flooringM2, 3.2, accuracy: 1e-9)
        XCTAssertEqual(t.text, "2 AM · 1 DH · 1.2 m² lining · 2.0 lm skirting · 3.2 m² flooring")
        XCTAssertEqual(QuoteTally.from(plan: [:]).text, "Nothing yet")
    }
}
