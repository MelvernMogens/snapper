import XCTest
@testable import SnapKit

final class PauseTimelineTests: XCTestCase {
    func testNoPausePassesThrough() {
        let t = PauseTimeline()
        XCTAssertEqual(t.outputTime(for: 100), 100)
        XCTAssertEqual(t.endOutputTime(at: 105), 105)
    }

    func testFramesDuringPauseAreDroppedAndLaterOnesShifted() {
        var t = PauseTimeline()
        t.pause(at: 10)
        XCTAssertTrue(t.isPaused)
        XCTAssertNil(t.outputTime(for: 10))
        XCTAssertNil(t.outputTime(for: 12))
        // A frame captured before the pause but delivered late is kept.
        XCTAssertEqual(t.outputTime(for: 9.9), 9.9)
        t.resume(at: 13)
        XCTAssertFalse(t.isPaused)
        XCTAssertEqual(t.totalPaused, 3, accuracy: 1e-9)
        XCTAssertNil(t.outputTime(for: 12.5))           // late delivery from inside the pause
        XCTAssertEqual(t.outputTime(for: 13)!, 10, accuracy: 1e-9)
        XCTAssertEqual(t.outputTime(for: 15)!, 12, accuracy: 1e-9)
    }

    func testMultiplePausesAccumulate() {
        var t = PauseTimeline()
        t.pause(at: 2); t.resume(at: 4)        // 2s
        t.pause(at: 6); t.resume(at: 6.5)      // 0.5s
        XCTAssertEqual(t.outputTime(for: 5)!, 3, accuracy: 1e-9)
        XCTAssertEqual(t.outputTime(for: 7)!, 4.5, accuracy: 1e-9)
        XCTAssertEqual(t.totalPaused, 2.5, accuracy: 1e-9)
    }

    func testDoublePauseAndStrayResumeAreIgnored() {
        var t = PauseTimeline()
        t.resume(at: 1)                          // not paused: no-op
        XCTAssertEqual(t.intervals.count, 0)
        t.pause(at: 2); t.pause(at: 3)           // second pause ignored, pause still starts at 2
        t.resume(at: 5)
        XCTAssertEqual(t.intervals, [2...5])
        t.pause(at: 6); t.resume(at: 6)          // zero-length pause leaves no interval
        XCTAssertEqual(t.intervals.count, 1)
    }

    func testEndTimeClampsToOpenPause() {
        var t = PauseTimeline()
        t.pause(at: 2); t.resume(at: 4)
        t.pause(at: 7)
        // Stopped while paused at 9: output ends where the pause began (7 - 2 = 5).
        XCTAssertEqual(t.endOutputTime(at: 9), 5, accuracy: 1e-9)
        XCTAssertEqual(t.endOutputTime(at: 3), 2, accuracy: 1e-9)   // inside a closed pause
        XCTAssertEqual(t.endOutputTime(at: 6), 4, accuracy: 1e-9)
    }

    func testRelativeTimeAgainstFirstFrame() {
        var t = PauseTimeline()
        // Paused before any frame arrived; the first frame (after resume) must land at 0.
        t.pause(at: 100); t.resume(at: 105)
        XCTAssertEqual(t.relativeTime(for: 106, start: 106)!, 0, accuracy: 1e-9)
        XCTAssertEqual(t.relativeTime(for: 107.5, start: 106)!, 1.5, accuracy: 1e-9)
        // A pause after the first frame shifts later frames back.
        t.pause(at: 108); t.resume(at: 110)
        XCTAssertNil(t.relativeTime(for: 109, start: 106))
        XCTAssertEqual(t.relativeTime(for: 111, start: 106)!, 3, accuracy: 1e-9)
    }

    func testElapsedExcludesPauses() {
        var t = PauseTimeline()
        XCTAssertEqual(t.elapsed(start: 0, now: 3), 3, accuracy: 1e-9)
        t.pause(at: 3)
        XCTAssertEqual(t.elapsed(start: 0, now: 10), 3, accuracy: 1e-9)   // frozen while paused
        t.resume(at: 10)
        XCTAssertEqual(t.elapsed(start: 0, now: 12), 5, accuracy: 1e-9)
        // Pauses before the start don't count.
        XCTAssertEqual(t.elapsed(start: 11, now: 12), 1, accuracy: 1e-9)
    }
}

final class RecordMathTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testPlanFlipsToTopLeftAndScales() {
        // 800x500 at the bottom-left of a 2x display.
        let p = RecordMath.plan(global: CGRect(x: 0, y: 0, width: 800, height: 500), screenFrame: screen, scale: 2)!
        XCTAssertEqual(p.pixelWidth, 1600)
        XCTAssertEqual(p.pixelHeight, 1000)
        XCTAssertEqual(p.sourceRect, CGRect(x: 0, y: 482, width: 800, height: 500))
        XCTAssertEqual(p.globalRect, CGRect(x: 0, y: 0, width: 800, height: 500))
    }

    func testOddPixelSizesBecomeEven() {
        let p = RecordMath.plan(global: CGRect(x: 10, y: 10, width: 301, height: 201), screenFrame: screen, scale: 1)!
        XCTAssertEqual(p.pixelWidth % 2, 0)
        XCTAssertEqual(p.pixelHeight % 2, 0)
        XCTAssertEqual(p.pixelWidth, 300)
        XCTAssertEqual(p.pixelHeight, 200)
        // Fractional points on a 2x screen snap to whole pixels.
        let q = RecordMath.plan(global: CGRect(x: 10.3, y: 10.7, width: 100.6, height: 50.2), screenFrame: screen, scale: 2)!
        XCTAssertEqual(q.pixelWidth % 2, 0)
        XCTAssertEqual(q.pixelHeight % 2, 0)
        XCTAssertEqual(q.sourceRect.minX * 2, (q.sourceRect.minX * 2).rounded())
    }

    func testTinySelectionStillRecordsTwoPixels() {
        let p = RecordMath.plan(global: CGRect(x: 100, y: 100, width: 0.4, height: 1), screenFrame: screen, scale: 1)!
        XCTAssertEqual(p.pixelWidth, 2)
        XCTAssertEqual(p.pixelHeight, 2)
    }

    func testFullOddSizedScreenStaysInside() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 601)
        let p = RecordMath.plan(global: odd, screenFrame: odd, scale: 1)!
        XCTAssertEqual(p.pixelWidth, 1000)
        XCTAssertEqual(p.pixelHeight, 600)
        XCTAssertTrue(odd.contains(p.globalRect))
    }

    func testSecondaryDisplayCoordinates() {
        // Secondary display to the left of and above the primary (negative x, positive y).
        let sec = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let p = RecordMath.plan(global: CGRect(x: -1900, y: 2000, width: 400, height: 40), screenFrame: sec, scale: 1)!
        XCTAssertEqual(p.sourceRect, CGRect(x: 20, y: 22, width: 400, height: 40))
        XCTAssertEqual(p.globalRect, CGRect(x: -1900, y: 2000, width: 400, height: 40))
    }

    func testSelectionClippedToDisplay() {
        let p = RecordMath.plan(global: CGRect(x: 1400, y: -50, width: 300, height: 200), screenFrame: screen, scale: 2)!
        XCTAssertEqual(p.globalRect, CGRect(x: 1400, y: 0, width: 112, height: 150))
        XCTAssertNil(RecordMath.plan(global: CGRect(x: 5000, y: 0, width: 10, height: 10), screenFrame: screen, scale: 2))
    }

    func testGifSize() {
        XCTAssertTrue(RecordMath.gifSize(pixelWidth: 1200, pixelHeight: 800) == (960, 640))
        XCTAssertTrue(RecordMath.gifSize(pixelWidth: 600, pixelHeight: 400) == (600, 400))
        XCTAssertTrue(RecordMath.gifSize(pixelWidth: 3000, pixelHeight: 2, maxWidth: 960) == (960, 1))
    }

    func testGifFramesSumToDuration() {
        let f = RecordMath.gifFrames(duration: 3, fps: 15)
        XCTAssertEqual(f.count, 45)
        XCTAssertEqual(f.reduce(0) { $0 + $1.delayCS }, 300)
        XCTAssertEqual(f.first?.time, 0)
        XCTAssertTrue(f.allSatisfy { $0.delayCS >= 6 && $0.delayCS <= 7 })
        XCTAssertTrue(RecordMath.gifFrames(duration: 0, fps: 15).isEmpty)
        XCTAssertEqual(RecordMath.gifFrames(duration: 0.03, fps: 15).count, 1)
    }

    func testFormatElapsedAndParse() {
        XCTAssertEqual(RecordMath.formatElapsed(7.9), "0:07")
        XCTAssertEqual(RecordMath.formatElapsed(754), "12:34")
        XCTAssertEqual(RecordMath.formatElapsed(3723), "1:02:03")
        XCTAssertEqual(RecordMath.formatElapsed(-1), "0:00")
        XCTAssertEqual(RecordMath.parseRect("0,0,800,500"), CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(RecordMath.parseRect("-10, 5, 3, 4"), CGRect(x: -10, y: 5, width: 3, height: 4))
        XCTAssertNil(RecordMath.parseRect("1,2,3"))
        XCTAssertNil(RecordMath.parseRect("1,2,0,4"))
        XCTAssertNil(RecordMath.parseRect("a,b,c,d"))
    }
}
