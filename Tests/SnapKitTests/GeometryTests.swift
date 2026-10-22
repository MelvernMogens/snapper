import XCTest
@testable import SnapKit

final class GeometryTests: XCTestCase {
    func testRectFromAnyDragDirection() {
        XCTAssertEqual(Geo.rect(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 0, y: 20)), CGRect(x: 0, y: 20, width: 10, height: 30))
    }

    func testPixelRectFlipsAndScalesForRetina() {
        // 1000x600 pt view, 2000x1200 px image. Selection at bottom-left 100x50 pt.
        let r = Geo.pixelRect(viewRect: CGRect(x: 0, y: 0, width: 100, height: 50),
                              viewSize: CGSize(width: 1000, height: 600), imageSize: CGSize(width: 2000, height: 1200))
        XCTAssertEqual(r, CGRect(x: 0, y: 1100, width: 200, height: 100))
    }

    func testPixelRectClampsToImage() {
        let r = Geo.pixelRect(viewRect: CGRect(x: 950, y: -20, width: 100, height: 50),
                              viewSize: CGSize(width: 1000, height: 600), imageSize: CGSize(width: 1000, height: 600))
        XCTAssertEqual(r, CGRect(x: 950, y: 570, width: 50, height: 30))
    }

    func testQuartzToAppKit() {
        let r = Geo.quartzToAppKit(CGRect(x: 10, y: 0, width: 100, height: 40), primaryHeight: 900)
        XCTAssertEqual(r, CGRect(x: 10, y: 860, width: 100, height: 40))
    }

    func testClampMoveKeepsSize() {
        let r = Geo.clampMove(CGRect(x: 950, y: -10, width: 100, height: 50), into: CGRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(r, CGRect(x: 900, y: 0, width: 100, height: 50))
    }

    func testResizeFromTopLeftHandle() {
        let r = Geo.resize(CGRect(x: 0, y: 0, width: 100, height: 100), handle: (-1, 1), by: CGVector(dx: 10, dy: 20))
        XCTAssertEqual(r, CGRect(x: 10, y: 0, width: 90, height: 120))
    }

    func testResizeNeverInverts() {
        let r = Geo.resize(CGRect(x: 0, y: 0, width: 100, height: 100), handle: (1, 0), by: CGVector(dx: -500, dy: 0))
        XCTAssertEqual(r.width, 4)
        XCTAssertEqual(r.minX, 0)
    }
}

final class NamingTests: XCTestCase {
    func testFilename() {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 22; c.hour = 23; c.minute = 5; c.second = 9
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(Naming.filename(.screenshot, date: d, ext: "png"), "Snapper 2026-10-22 at 23.05.09.png")
        XCTAssertEqual(Naming.filename(.recording, date: d, ext: "mp4"), "Snapper Recording 2026-10-22 at 23.05.09.mp4")
    }

    func testOrganizedFolders() {
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 2
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(Naming.folder(.screenshot, date: d), "Screenshots/2026-03")
        XCTAssertEqual(Naming.folder(.recording, date: d), "Recordings/2026-03")
        XCTAssertEqual(Naming.folder(.gif, date: d), "GIFs/2026-03")
        let p = Prefs(defaults: UserDefaults(suiteName: "snapper-test-\(UUID())")!)
        XCTAssertTrue(p.saveDirectory.path.hasSuffix("/Movies/Snapper"))
        XCTAssertTrue(p.directory(for: .gif, date: d).path.hasSuffix("/Movies/Snapper/GIFs/2026-03"))
        p.organizeFolders = false
        XCTAssertEqual(p.directory(for: .gif, date: d), p.saveDirectory)
        XCTAssertTrue(p.useCommandShiftKeys)
    }

    func testUniqueAppendsCounter() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a 2.png"]
        XCTAssertEqual(Naming.unique(in: dir, name: "a.png", exists: { taken.contains($0.path) }).lastPathComponent, "a 3.png")
    }

    func testPrefsDefaults() {
        let p = Prefs(defaults: UserDefaults(suiteName: "snapper-test-\(UUID())")!)
        XCTAssertTrue(p.autoSave); XCTAssertTrue(p.autoCopy); XCTAssertEqual(p.imageFormat, .png)
        p.autoSave = false; XCTAssertFalse(p.autoSave)
    }
}
