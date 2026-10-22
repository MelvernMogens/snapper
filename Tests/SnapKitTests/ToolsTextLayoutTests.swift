import XCTest
@testable import SnapKit

final class TextLayoutTests: XCTestCase {
    /// Normalized box with origin bottom-left.
    private func box(_ text: String, x: Double, y: Double, w: Double = 0.2, h: Double = 0.03) -> TextBox {
        TextBox(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    func testEmptyInput() {
        XCTAssertEqual(TextLayout.join([]), "")
    }

    func testBoxesOnOneLineAreOrderedLeftToRight() {
        let out = TextLayout.join([box("right", x: 0.5, y: 0.8), box("left", x: 0.1, y: 0.8)])
        XCTAssertEqual(out, "left right")
    }

    func testLinesAreOrderedTopToBottom() {
        let out = TextLayout.join([
            box("middle", x: 0.1, y: 0.50),
            box("bottom", x: 0.1, y: 0.45),
            box("top", x: 0.1, y: 0.55),
        ])
        XCTAssertEqual(out, "top\nmiddle\nbottom")
    }

    func testTiltedBaselinesStayOnOneLine() {
        // Same visual line, each box nudged up a third of its height.
        let out = TextLayout.join([
            box("c", x: 0.7, y: 0.802),
            box("a", x: 0.1, y: 0.790),
            box("b", x: 0.4, y: 0.796),
        ])
        XCTAssertEqual(out, "a b c")
    }

    func testParagraphGapInsertsBlankLine() {
        let out = TextLayout.join([
            box("one", x: 0.1, y: 0.90),
            box("two", x: 0.1, y: 0.85),
            box("far", x: 0.1, y: 0.60),
            box("near", x: 0.1, y: 0.55),
        ])
        XCTAssertEqual(out, "one\ntwo\n\nfar\nnear")
    }

    func testWhitespaceIsTrimmedAndEmptyBoxesSkipped() {
        let out = TextLayout.join([
            box("  hello \n", x: 0.1, y: 0.8),
            box("   ", x: 0.4, y: 0.8),
            box("world", x: 0.6, y: 0.8),
        ])
        XCTAssertEqual(out, "hello world")
    }

    func testSingleBox() {
        XCTAssertEqual(TextLayout.join([box("solo", x: 0.3, y: 0.3)]), "solo")
    }
}
