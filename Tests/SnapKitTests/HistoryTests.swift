import XCTest
@testable import SnapKit

final class HistoryTests: XCTestCase {
    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("snapper-hist-\(UUID())")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testAddPersistsAndReloads() throws {
        let dir = tmpDir(), src = tmpDir().appendingPathComponent("a.png")
        try Data([1, 2, 3]).write(to: src)
        let s = HistoryStore(dir: dir)
        let e = try XCTUnwrap(s.add(fileAt: src, kind: .screenshot, savedPath: nil, pixelWidth: 10, pixelHeight: 20))
        XCTAssertEqual(try Data(contentsOf: s.url(of: e)), Data([1, 2, 3]))
        let reloaded = HistoryStore(dir: dir)
        XCTAssertEqual(reloaded.entries, [e])
    }

    func testTrimDeletesOldestFiles() throws {
        let dir = tmpDir(), src = tmpDir().appendingPathComponent("a.png")
        try Data([0]).write(to: src)
        let s = HistoryStore(dir: dir, limit: 2)
        let first = try XCTUnwrap(s.add(fileAt: src, kind: .screenshot, savedPath: nil, pixelWidth: 1, pixelHeight: 1))
        s.add(fileAt: src, kind: .screenshot, savedPath: nil, pixelWidth: 1, pixelHeight: 1)
        s.add(fileAt: src, kind: .screenshot, savedPath: nil, pixelWidth: 1, pixelHeight: 1)
        XCTAssertEqual(s.entries.count, 2)
        XCTAssertFalse(s.entries.contains(first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.url(of: first).path))
    }

    func testRemoveAndClear() throws {
        let dir = tmpDir(), src = tmpDir().appendingPathComponent("a.png")
        try Data([0]).write(to: src)
        let s = HistoryStore(dir: dir)
        let a = try XCTUnwrap(s.add(fileAt: src, kind: .screenshot, savedPath: nil, pixelWidth: 1, pixelHeight: 1))
        s.add(fileAt: src, kind: .gif, savedPath: "/x.gif", pixelWidth: 1, pixelHeight: 1)
        s.remove(id: a.id)
        XCTAssertEqual(s.entries.count, 1)
        s.clear()
        XCTAssertTrue(HistoryStore(dir: dir).entries.isEmpty)
    }
}
