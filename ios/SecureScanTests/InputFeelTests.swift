//
//  InputFeelTests.swift
//  SecureScanTests
//

import XCTest
import simd

final class InputFeelTests: XCTestCase {

    func testReticleSaysWhatItIsOn() {
        XCTAssertEqual(Reticle.surface(normalY: 0.0, height: 1.2, distanceToWall: 0.02), .wall)
        XCTAssertEqual(Reticle.surface(normalY: 0.0, height: 0.8, distanceToWall: 0.6), .cabinet)
        XCTAssertEqual(Reticle.surface(normalY: 0.0, height: 1.0, distanceToWall: nil), .wall)     // no walls yet
        XCTAssertEqual(Reticle.surface(normalY: 0.99, height: 0.0, distanceToWall: nil), .floor)
        XCTAssertEqual(Reticle.surface(normalY: 0.99, height: 0.9, distanceToWall: nil), .benchtop)
        XCTAssertEqual(Reticle.surface(normalY: -0.98, height: 2.4, distanceToWall: nil), .ceiling)
        XCTAssertEqual(Reticle.describe(.wall, height: 1.2, room: "Kitchen"), "Wall · 1.20 m · Kitchen")
        XCTAssertEqual(Reticle.describe(.floor, height: 0.0, room: nil), "Floor")
        XCTAssertEqual(Reticle.describe(.ceiling, height: 2.41, room: "Room 2"), "Ceiling · 2.41 m · Room 2")
        XCTAssertEqual(Reticle.material(.cabinet), "cabinetry")
        XCTAssertNil(Reticle.material(.wall))
        XCTAssertEqual(Reticle.blocked(trackingNormal: false, hasHit: true, needsWall: true), "Move slowly — finding the room")
        XCTAssertEqual(Reticle.blocked(trackingNormal: true, hasHit: false, needsWall: true), "Point at a wall")
        XCTAssertEqual(Reticle.blocked(trackingNormal: true, hasHit: false, needsWall: false), "Move closer to a surface")
        XCTAssertNil(Reticle.blocked(trackingNormal: true, hasHit: true, needsWall: true))
    }

    func testRemovalHeightsSnap() {
        XCTAssertEqual(HeightSnap.snap(560), 600)
        XCTAssertEqual(HeightSnap.snap(140), 100)
        XCTAssertEqual(HeightSnap.snap(1150), 1200)
        XCTAssertEqual(HeightSnap.snap(900), 900)              // between targets: rounded to 10 mm
        XCTAssertEqual(HeightSnap.snap(904), 900)
        XCTAssertEqual(HeightSnap.snap(2350, wallHeightMm: 2400), 2400)
        XCTAssertEqual(HeightSnap.snap(5000, wallHeightMm: 2400), 2400)
        XCTAssertEqual(HeightSnap.label(2400), "Full height")
        XCTAssertEqual(HeightSnap.label(600), "600 mm")
    }

    func testWallEndsSnap() {
        XCTAssertEqual(WallEndSnap.snap(0.03, length: 4), 0)       // 12 cm from the end
        XCTAssertEqual(WallEndSnap.snap(0.98, length: 4), 1)
        XCTAssertEqual(WallEndSnap.snap(0.5, length: 4), 0.5)
        XCTAssertEqual(WallEndSnap.snap(0.1, length: 4), 0.1)      // 40 cm: kept
        XCTAssertEqual(WallEndSnap.snap(-0.2, length: 4), 0)
    }

    func testReadingColours() {
        XCTAssertEqual(ReadingColour.status(12), "dry")
        XCTAssertEqual(ReadingColour.status(15), "elevated")
        XCTAssertEqual(ReadingColour.status(22.5), "wet")
        XCTAssertEqual(ReadingColour.status(30, reference: true), "reference")
        XCTAssertEqual(ReadingColour.status(nil), "none")
    }

    func testUndoChipIsShownForSixSeconds() {
        var u = UndoWindow()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(u.visible(at: t0))
        u.saved(at: t0)
        XCTAssertTrue(u.visible(at: t0.addingTimeInterval(5.9)))
        XCTAssertFalse(u.visible(at: t0.addingTimeInterval(6.0)))
        u.saved(at: t0.addingTimeInterval(10))
        u.used()
        XCTAssertFalse(u.visible(at: t0.addingTimeInterval(10.5)))
    }

    func testReadouts() {
        let pts = [WorldVec(0, 1, 0), WorldVec(3, 0.5, 0), WorldVec(3, 0.5, 4)]
        XCTAssertEqual(Readout.length(pts), 7, accuracy: 1e-9)     // horizontal only
        XCTAssertEqual(Readout.lengthText(2.345), "2.35 m")
        XCTAssertEqual(Readout.areaText(pts), "6.0 m²")
        XCTAssertEqual(Readout.areaText(Array(pts.prefix(2))), "0.0 m²")
        XCTAssertEqual(Readout.elapsed(65), "1:05")
        XCTAssertEqual(Readout.elapsed(3723), "1:02:03")
    }

    func testRecoveryAfterBeingKilledMidRoom() throws {
        let raw: [(roomIndex: Int, photoExpected: Bool, photoOnDisk: Bool)] = [
            (0, true, true), (0, false, false), (1, true, true), (1, true, false),
        ]
        let s = Recovery.summary(raw, roomsSaved: 1)
        XCTAssertEqual(s, Recovery.Summary(items: 4, inUnfinishedRoom: 2, photosMissing: 1))
        let text = try XCTUnwrap(Recovery.message(s))
        XCTAssertTrue(text.contains("All 4 logged items are kept"))
        XCTAssertTrue(text.contains("1 photo didn't finish saving"))
        XCTAssertNil(Recovery.message(Recovery.summary(raw, roomsSaved: 2)))
    }
}
