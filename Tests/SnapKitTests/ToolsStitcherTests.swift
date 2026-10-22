import XCTest
@testable import SnapKit

// MARK: - Deterministic fixtures

/// Seeded linear congruential generator — same pixels on every machine and every run.
private struct LCG {
    var state: UInt64
    mutating func next() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(truncatingIfNeeded: state >> 33)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt32(n)) }
}

/// Tall "document": bands of blocky text-like runs, blank gaps between paragraphs,
/// plus a few long flat regions with no texture at all.
private func tallImage(width: Int, height: Int, seed: UInt64 = 0x5EED) -> GrayImage {
    var rng = LCG(state: seed)
    var px = [UInt8](repeating: 235, count: width * height)
    var y = 0
    while y < height {
        if rng.int(20) == 0 {                        // long blank region
            y += 40 + rng.int(40)
            continue
        }
        let bandH = 10 + rng.int(8)
        let blank = rng.int(10) < 2                  // ordinary line gap
        if !blank {
            for row in y ..< min(height, y + bandH) {
                var x = rng.int(6)
                while x < width {
                    let run = 1 + rng.int(5)
                    let ink = UInt8(20 + rng.int(120))
                    for xx in x ..< min(width, x + run) { px[row * width + xx] = ink }
                    x += run + 1 + rng.int(4)
                }
            }
        }
        y += bandH
    }
    return GrayImage(width: width, height: height, pixels: px)
}

private func crop(_ img: GrayImage, y: Int, height: Int) -> GrayImage {
    let start = y * img.width
    return GrayImage(width: img.width, height: height,
                     pixels: Array(img.pixels[start ..< start + height * img.width]))
}

/// Overwrite the top and bottom rows with a fixed pattern — a sticky header / footer.
private func addStickyBands(_ img: GrayImage, top: Int, bottom: Int) -> GrayImage {
    var out = img
    let w = img.width
    for y in 0 ..< top {
        for x in 0 ..< w { out.pixels[y * w + x] = UInt8(40 + (x % 7) * 20) }
    }
    for y in (img.height - bottom) ..< img.height {
        for x in 0 ..< w { out.pixels[y * w + x] = UInt8(90 + (x % 5) * 12) }
    }
    return out
}

private func addNoise(_ img: GrayImage, amplitude: Int, seed: UInt64 = 7) -> GrayImage {
    var rng = LCG(state: seed)
    var out = img
    for i in 0 ..< out.pixels.count {
        let delta = rng.int(2 * amplitude + 1) - amplitude
        out.pixels[i] = UInt8(clamping: Int(out.pixels[i]) + delta)
    }
    return out
}

// MARK: - findOffset

final class StitcherOffsetTests: XCTestCase {
    private let tall = tallImage(width: 200, height: 3000)

    func testFindsExactOffsetBetweenTwoCrops() {
        let prev = crop(tall, y: 500, height: 900)
        let next = crop(tall, y: 637, height: 900)
        XCTAssertEqual(Stitcher.findOffset(prev: prev, next: next), 137)
    }

    func testIdenticalFramesReturnZero() {
        let f = crop(tall, y: 500, height: 900)
        XCTAssertEqual(Stitcher.findOffset(prev: f, next: f), 0)
    }

    func testStickyHeaderAndFooterDoNotBreakTheOffset() {
        let prev = addStickyBands(crop(tall, y: 500, height: 900), top: 60, bottom: 40)
        let next = addStickyBands(crop(tall, y: 637, height: 900), top: 60, bottom: 40)
        let offset = Stitcher.findOffset(prev: prev, next: next)
        XCTAssertEqual(offset, 137)

        let bands = Stitcher.fixedBands(prev: prev, next: next, offset: offset ?? 0)
        // Blank background rows next to a band are identical either way, so a band can read wide.
        XCTAssertGreaterThanOrEqual(bands.top, 60)
        XCTAssertLessThan(bands.top, 100)
        XCTAssertGreaterThanOrEqual(bands.bottom, 40)
        XCTAssertLessThan(bands.bottom, 100)
    }

    /// Rows just outside the sticky bands can be blank page background, which is identical in
    /// both frames whether it scrolled or not — so the bands may legitimately read a little wide.
    func testStickyBandSizeWithTexturedNeighbours() {
        let tallImg = tall
        var prev = crop(tallImg, y: 500, height: 900)
        var next = crop(tallImg, y: 637, height: 900)
        // Ink the content rows adjacent to the bands so the boundary is unambiguous.
        for (i, img) in [prev, next].enumerated() {
            var m = img
            for y in [60, 61, 858, 859] {
                for x in 0 ..< m.width { m.pixels[y * m.width + x] = UInt8((x * 7 + y * 13 + i * 90) % 200) }
            }
            if i == 0 { prev = m } else { next = m }
        }
        prev = addStickyBands(prev, top: 60, bottom: 40)
        next = addStickyBands(next, top: 60, bottom: 40)
        XCTAssertEqual(Stitcher.findOffset(prev: prev, next: next), 137)
        let bands = Stitcher.fixedBands(prev: prev, next: next, offset: 137)
        XCTAssertEqual(bands.top, 60)
        XCTAssertEqual(bands.bottom, 40)
    }

    func testSurvivesSmallNoise() {
        let prev = crop(tall, y: 500, height: 900)
        let next = addNoise(crop(tall, y: 637, height: 900), amplitude: 2)
        XCTAssertEqual(Stitcher.findOffset(prev: prev, next: next), 137)
    }

    func testScrollBeyondOneFrameReturnsNil() {
        let prev = crop(tall, y: 0, height: 900)
        let next = crop(tall, y: 1000, height: 900)
        XCTAssertNil(Stitcher.findOffset(prev: prev, next: next))
    }

    func testUniformFramesThatDifferReturnNil() {
        let a = GrayImage(width: 200, height: 900, pixels: [UInt8](repeating: 100, count: 200 * 900))
        let b = GrayImage(width: 200, height: 900, pixels: [UInt8](repeating: 150, count: 200 * 900))
        XCTAssertNil(Stitcher.findOffset(prev: a, next: b))
    }

    func testUniformIdenticalFramesReturnZero() {
        let a = GrayImage(width: 200, height: 900, pixels: [UInt8](repeating: 100, count: 200 * 900))
        XCTAssertEqual(Stitcher.findOffset(prev: a, next: a), 0)
    }

    func testMismatchedSizesReturnNil() {
        let a = crop(tall, y: 0, height: 900)
        let b = crop(tall, y: 0, height: 800)
        XCTAssertNil(Stitcher.findOffset(prev: a, next: b))
    }

    func testFixedBandsIgnoresFramesThatDidNotScroll() {
        let f = crop(tall, y: 500, height: 900)
        XCTAssertEqual(Stitcher.fixedBands(prev: f, next: f, offset: 0).top, 0)
        XCTAssertEqual(Stitcher.fixedBands(prev: f, next: f, offset: 0).bottom, 0)
    }

    func testPerformanceOnFullSizeFrames() {
        let big = tallImage(width: 256, height: 3000, seed: 0xC0FFEE)
        let prev = crop(big, y: 0, height: 1800)
        let next = crop(big, y: 97, height: 1800)
        let t0 = Date()
        let offset = Stitcher.findOffset(prev: prev, next: next)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(offset, 97)
        XCTAssertLessThan(elapsed, 0.150, "findOffset took \(Int(elapsed * 1000)) ms on 256x1800 frames")
    }
}

// MARK: - plan

final class StitcherPlanTests: XCTestCase {
    func testPlanWithoutStickyBands() {
        XCTAssertEqual(Stitcher.plan(frameHeight: 900, offsets: [137, 263], top: 0, bottom: 0), [
            StitchSlice(frame: 0, rows: 0 ..< 900),
            StitchSlice(frame: 1, rows: 763 ..< 900),
            StitchSlice(frame: 2, rows: 637 ..< 900),
        ])
    }

    func testPlanKeepsHeaderOnceAndFooterFromLastFrame() {
        XCTAssertEqual(Stitcher.plan(frameHeight: 900, offsets: [100, 700], top: 60, bottom: 40), [
            StitchSlice(frame: 0, rows: 0 ..< 860),
            StitchSlice(frame: 1, rows: 760 ..< 860),
            StitchSlice(frame: 2, rows: 160 ..< 860),   // 860-700=160, still clear of the header
            StitchSlice(frame: 2, rows: 860 ..< 900),
        ])
    }

    func testPlanClampsOffsetLargerThanTheScrollableArea() {
        XCTAssertEqual(Stitcher.plan(frameHeight: 100, offsets: [500], top: 10, bottom: 10), [
            StitchSlice(frame: 0, rows: 0 ..< 90),
            StitchSlice(frame: 1, rows: 10 ..< 90),
            StitchSlice(frame: 1, rows: 90 ..< 100),
        ])
    }

    func testPlanWithSingleFrame() {
        XCTAssertEqual(Stitcher.plan(frameHeight: 900, offsets: [], top: 0, bottom: 0),
                       [StitchSlice(frame: 0, rows: 0 ..< 900)])
    }
}

// MARK: - end to end

final class StitcherEndToEndTests: XCTestCase {
    func testFourFramesReassembleTheSourceExactly() {
        let tall = tallImage(width: 200, height: 3000)
        let h = 900
        let starts = [0, 137, 400, 650]
        let frames = starts.map { crop(tall, y: $0, height: h) }

        var offsets: [Int] = []
        for i in 1 ..< frames.count {
            guard let offset = Stitcher.findOffset(prev: frames[i - 1], next: frames[i]) else {
                return XCTFail("no offset between frame \(i - 1) and \(i)")
            }
            offsets.append(offset)
        }
        XCTAssertEqual(offsets, [137, 263, 250])

        let slices = Stitcher.plan(frameHeight: h, offsets: offsets, top: 0, bottom: 0)
        var out: [UInt8] = []
        for slice in slices {
            let img = frames[slice.frame]
            out += img.pixels[(slice.rows.lowerBound * img.width) ..< (slice.rows.upperBound * img.width)]
        }

        let expected = Array(tall.pixels[0 ..< 1550 * tall.width])
        XCTAssertEqual(out.count, expected.count)
        XCTAssertEqual(out, expected)
    }
}

final class StitcherOffsetRangeTests: XCTestCase {
    /// How far a single frame may scroll and still be matched. Beyond this the overlap left
    /// inside the texture band is too small to verify, and nil is the honest answer.
    func testOffsetRangeCeiling() {
        let tall = tallImage(width: 200, height: 3000)
        var found: [Int] = []
        for d in [1, 5, 40, 137, 300, 450, 500] {
            let prev = crop(tall, y: 400, height: 900)
            let next = crop(tall, y: 400 + d, height: 900)
            if Stitcher.findOffset(prev: prev, next: next) == d { found.append(d) }
        }
        XCTAssertEqual(found, [1, 5, 40, 137, 300, 450, 500])
    }
}
