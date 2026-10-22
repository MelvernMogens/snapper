import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SnapKit

/// Pixel helpers: images are read back as RGBA8, row 0 = top of the image.
private struct Pixels {
    let w: Int, h: Int, data: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height
        var d = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        data = d
    }
    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    func isRed(_ x: Int, _ y: Int) -> Bool { let p = at(x, y); return p.r > 220 && p.g < 90 && p.b < 90 }
    func isWhite(_ x: Int, _ y: Int) -> Bool { let p = at(x, y); return p.r > 245 && p.g > 245 && p.b > 245 }
    func isBlue(_ x: Int, _ y: Int) -> Bool { let p = at(x, y); return p.b > 220 && p.r < 40 && p.g < 40 }
}

private func colorImage(_ w: Int, _ h: Int, _ c: CGColor, clearInset: Int = 0) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(c)
    let i = CGFloat(clearInset)
    ctx.fill(CGRect(x: i, y: i, width: CGFloat(w) - 2 * i, height: CGFloat(h) - 2 * i))
    return ctx.makeImage()!
}

private func writePNG(_ img: CGImage) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapper-bg-\(UUID().uuidString).png")
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    return url.path
}

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

private func solidImage(_ w: Int, _ h: Int, gray: CGFloat = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// Left half black, right half white (to see blur smear across the edge).
private func splitImage(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    return ctx.makeImage()!
}

final class AnnotateRenderTests: XCTestCase {
    func testFilledRectLandsAtTopLeftOriginPoints() {
        let r = AnnotationRenderer(image: solidImage(200, 100))
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .rect, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 60, y: 40), color: .red, filled: true),
        ])
        let out = Pixels(r.flatten(doc)!)
        XCTAssertEqual(out.w, 200); XCTAssertEqual(out.h, 100)
        XCTAssertTrue(out.isRed(40, 25), "centre of the rect is red")
        XCTAssertTrue(out.isRed(22, 12))
        XCTAssertTrue(out.isWhite(100, 25), "right of the rect stays white")
        XCTAssertTrue(out.isWhite(40, 80), "below the rect stays white (y is top-down)")
    }

    func testRetinaFlattenScalesAnnotationsToPixels() {
        // 400x200 px image that covered 200x100 pt.
        let r = AnnotationRenderer(image: solidImage(400, 200), pointSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(r.scale, 2)
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .rect, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 60, y: 40), color: .red, filled: true),
        ])
        let out = Pixels(r.flatten(doc)!)
        XCTAssertEqual(out.w, 400); XCTAssertEqual(out.h, 200)
        XCTAssertTrue(out.isRed(80, 50))
        XCTAssertTrue(out.isRed(44, 24))
        XCTAssertTrue(out.isRed(116, 76))
        XCTAssertTrue(out.isWhite(132, 50), "x beyond 60pt = 120px is white")
        XCTAssertTrue(out.isWhite(80, 96), "well below 40pt = 80px is white (soft shadow aside)")
        XCTAssertTrue(out.isWhite(36, 50))
    }

    func testCropChangesOutputSizeAndShiftsAnnotations() {
        let r = AnnotationRenderer(image: solidImage(400, 200), pointSize: CGSize(width: 200, height: 100))
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .rect, start: CGPoint(x: 50, y: 30), end: CGPoint(x: 70, y: 50), color: .red, filled: true),
        ], crop: CGRect(x: 40, y: 20, width: 100, height: 50))
        let img = r.flatten(doc)!
        XCTAssertEqual(img.width, 200); XCTAssertEqual(img.height, 100)
        let out = Pixels(img)
        // rect now at (10,10)-(30,30) pt = (20,20)-(60,60) px
        XCTAssertTrue(out.isRed(40, 40))
        XCTAssertTrue(out.isWhite(80, 40))
    }

    func testBackgroundAddsPadding() {
        let r = AnnotationRenderer(image: solidImage(200, 100), pointSize: CGSize(width: 100, height: 50))
        let doc = AnnotationDocument(background: AnnotationBackground(preset: 1, padding: 20, cornerRadius: 0, shadow: false))
        let img = r.flatten(doc)!
        XCTAssertEqual(img.width, (100 + 40) * 2); XCTAssertEqual(img.height, (50 + 40) * 2)
        let out = Pixels(img)
        XCTAssertFalse(out.isWhite(5, 5), "padding shows the gradient")
        XCTAssertTrue(out.isWhite(140, 90), "image sits in the middle")
    }

    func testBlurObscuresOnlyInsideRegion() {
        let r = AnnotationRenderer(image: splitImage(200, 100))
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .blur, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 120, y: 50)),
        ])
        let out = Pixels(r.flatten(doc)!)
        let inside = out.at(98, 25).r     // just left of the black/white edge, inside the blur
        XCTAssertGreaterThan(inside, 30, "edge got smeared inside the blur")
        XCTAssertLessThan(out.at(98, 80).r, 10, "same column below the region is untouched")
    }

    func testPixelateChangesPixels() {
        let r = AnnotationRenderer(image: splitImage(200, 100))
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .blur, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100), blurStyle: .pixelate),
        ])
        XCTAssertNotNil(r.flatten(doc))
        XCTAssertNotNil(r.effectImage(.pixelate))
    }

    func testSpotlightDimsOutside() {
        let r = AnnotationRenderer(image: solidImage(200, 100))
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .spotlight, start: CGPoint(x: 50, y: 20), end: CGPoint(x: 150, y: 80)),
        ])
        let out = Pixels(r.flatten(doc)!)
        XCTAssertTrue(out.isWhite(100, 50))
        XCTAssertLessThan(out.at(10, 10).r, 150)
    }

    func testTextAndCounterRender() {
        let r = AnnotationRenderer(image: solidImage(300, 120))
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .text, start: CGPoint(x: 10, y: 10), color: .red, text: "Hello", fontSize: 30, textBackground: true),
            Annotation(kind: .counter, start: CGPoint(x: 250, y: 60), color: .red, number: 1),
        ])
        let out = Pixels(r.flatten(doc)!)
        let box = AnnotationText.boxSize(doc.annotations[0])
        XCTAssertGreaterThan(box.width, 60)
        XCTAssertTrue(out.isRed(13, Int(10 + box.height / 2)), "pill background at left edge")
        XCTAssertTrue(out.isRed(250 - 9, 60 + 9) || out.isRed(250 - 10, 60), "counter disc is filled")
    }
}

final class AnnotateBackgroundTests: XCTestCase {
    func testImageBackgroundFillsPadding() {
        let path = writePNG(colorImage(30, 30, blue))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = AnnotationRenderer(image: colorImage(100, 50, red))
        let doc = AnnotationDocument(background: AnnotationBackground(kind: .image(path), padding: 20, cornerRadius: 0, shadow: false))
        let img = r.flatten(doc)!
        XCTAssertEqual(img.width, 140); XCTAssertEqual(img.height, 90)
        let out = Pixels(img)
        XCTAssertTrue(out.isBlue(5, 5), "padding shows the picture: \(out.at(5, 5))")
        XCTAssertTrue(out.isBlue(135, 85))
        XCTAssertTrue(out.isRed(70, 45), "image in the centre")
    }

    func testTransparentSourcePixelsShowBackgroundNotBlack() {
        let path = writePNG(colorImage(10, 10, blue))
        defer { try? FileManager.default.removeItem(atPath: path) }
        // 100x50 with a 10px fully transparent margin (like a window capture's shadow area).
        let src = colorImage(100, 50, red, clearInset: 10)
        let r = AnnotationRenderer(image: src)
        XCTAssertTrue(r.hasTransparentEdges)
        XCTAssertEqual(r.opaqueBounds, CGRect(x: 10, y: 10, width: 80, height: 30))
        for shadow in [false, true] {
            let doc = AnnotationDocument(background: AnnotationBackground(kind: .image(path), padding: 20, cornerRadius: 0, shadow: shadow))
            let img = r.flatten(doc)!
            // Padding is measured from the opaque body, so the body is centred.
            XCTAssertEqual(img.width, 80 + 40); XCTAssertEqual(img.height, 30 + 40)
            let out = Pixels(img)
            // Image (2,2) is transparent and lands at canvas (12,12).
            if shadow {
                let p = out.at(12, 12)
                XCTAssertTrue(p.b > 120 && p.r < 40 && p.g < 40, "shadowed but still the picture, not black: \(p)")
            } else {
                XCTAssertTrue(out.isBlue(12, 12), "transparent source pixel shows the picture: \(out.at(12, 12))")
            }
            XCTAssertTrue(out.isBlue(2, 2))
            XCTAssertTrue(out.isRed(60, 35))
            XCTAssertTrue(out.isRed(21, 21), "body starts at the padding")
        }
    }

    func testOpaqueImageShadowDoesNotDarkenTransparentInterior() {
        // Shadow on, opaque image: padding near the image edge is darkened, but not black.
        let r = AnnotationRenderer(image: colorImage(100, 50, red))
        let doc = AnnotationDocument(background: AnnotationBackground(kind: .solid(RGBA(1, 1, 1)), padding: 40, cornerRadius: 0, shadow: true))
        let out = Pixels(r.flatten(doc)!)
        XCTAssertTrue(out.isWhite(2, 2), "far corner is the solid colour")
        XCTAssertLessThan(out.at(90, 95).r, 250, "shadow below the image")
        XCTAssertTrue(out.isRed(90, 65))
    }

    func testSolidBackground() {
        let r = AnnotationRenderer(image: solidImage(50, 50))
        let doc = AnnotationDocument(background: AnnotationBackground(kind: .solid(RGBA(0, 0, 1)), padding: 10, cornerRadius: 0, shadow: false))
        let out = Pixels(r.flatten(doc)!)
        XCTAssertTrue(out.isBlue(3, 3))
        XCTAssertTrue(out.isWhite(35, 35))
    }

    func testMissingPictureFallsBackWithoutCrashing() {
        let r = AnnotationRenderer(image: solidImage(50, 50))
        let doc = AnnotationDocument(background: AnnotationBackground(kind: .image("/nonexistent/x.png"), padding: 10, shadow: false))
        let out = Pixels(r.flatten(doc)!)
        XCTAssertFalse(out.isWhite(3, 3))
    }

    func testAspectFillCoversAndCentres() {
        let f = AnnotationRenderer.aspectFill(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(f, CGRect(x: -50, y: 0, width: 200, height: 100))
    }

    func testLegacyBackgroundJSONDecodes() throws {
        let old = #"{"annotations":[],"background":{"preset":3,"padding":30,"cornerRadius":6,"shadow":false}}"#
        let doc = try JSONDecoder().decode(AnnotationDocument.self, from: Data(old.utf8))
        XCTAssertEqual(doc.background, AnnotationBackground(preset: 3, padding: 30, cornerRadius: 6, shadow: false))
        XCTAssertEqual(doc.background?.kind, .gradient(3))
        XCTAssertEqual(doc.background?.blur, 0)
    }

    func testBackgroundKindsRoundTrip() throws {
        for k: AnnotationBackground.Kind in [.gradient(2), .solid(RGBA(0.1, 0.2, 0.3)), .image("/tmp/a b.heic")] {
            let b = AnnotationBackground(kind: k, padding: 12, cornerRadius: 4, shadow: false, blur: 30)
            XCTAssertEqual(try JSONDecoder().decode(AnnotationBackground.self, from: JSONEncoder().encode(b)), b)
        }
    }

    func testSystemWallpaperListingSkipsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Solid Colors.heic"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("B.heic"))
        try Data().write(to: dir.appendingPathComponent("A.heic"))
        try Data().write(to: dir.appendingPathComponent("C.madesktop"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(BackgroundLibrary.systemWallpapers(in: dir).map(\.lastPathComponent), ["A.heic", "B.heic"])
    }
}

final class AnnotateModelTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let doc = AnnotationDocument(annotations: [
            Annotation(kind: .arrow, start: CGPoint(x: 1, y: 2), end: CGPoint(x: 30, y: 40), color: .blue, lineWidth: 6),
            Annotation(kind: .pencil, start: .zero, points: [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9)]),
            Annotation(kind: .text, start: CGPoint(x: 3, y: 3), text: "hi\nthere", textBackground: true),
        ], crop: CGRect(x: 1, y: 2, width: 3, height: 4), background: AnnotationBackground(preset: 2))
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationDocument.self, from: data), doc)
    }

    func testNextCounterContinuesAfterMax() {
        var d = AnnotationDocument()
        XCTAssertEqual(d.nextCounter, 1)
        d.annotations.append(Annotation(kind: .counter, start: .zero, number: 1))
        d.annotations.append(Annotation(kind: .counter, start: .zero, number: 4))
        XCTAssertEqual(d.nextCounter, 5)
    }

    func testHitTesting() {
        let rect = Annotation(kind: .rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 60), lineWidth: 4)
        XCTAssertTrue(rect.hitTest(CGPoint(x: 10, y: 30), tolerance: 2), "on the outline")
        XCTAssertFalse(rect.hitTest(CGPoint(x: 60, y: 35), tolerance: 2), "hollow inside")
        var filled = rect; filled.filled = true
        XCTAssertTrue(filled.hitTest(CGPoint(x: 60, y: 35), tolerance: 2))
        let line = Annotation(kind: .line, start: .zero, end: CGPoint(x: 100, y: 100), lineWidth: 4)
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 52), tolerance: 2))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 70), tolerance: 2))
        let doc = AnnotationDocument(annotations: [filled, Annotation(kind: .counter, start: CGPoint(x: 60, y: 35), number: 1)])
        XCTAssertEqual(doc.hit(CGPoint(x: 60, y: 35), tolerance: 1)?.kind, .counter, "topmost wins")
    }

    func testTranslateMovesEveryPoint() {
        let a = Annotation(kind: .pencil, start: .zero, end: CGPoint(x: 1, y: 1), points: [CGPoint(x: 2, y: 2)])
        let b = a.translated(by: CGVector(dx: 5, dy: -1))
        XCTAssertEqual(b.start, CGPoint(x: 5, y: -1)); XCTAssertEqual(b.points, [CGPoint(x: 7, y: 1)])
    }

    func testResizeTopLeftInYDownSpace() {
        let r = AnnotationGeometry.resize(CGRect(x: 0, y: 0, width: 100, height: 100), handle: (-1, -1), by: CGVector(dx: 10, dy: 20))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 90, height: 80))
        let tiny = AnnotationGeometry.resize(CGRect(x: 0, y: 0, width: 100, height: 100), handle: (1, 1), by: CGVector(dx: -500, dy: -500))
        XCTAssertEqual(tiny, CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    func testSnapHelpers() {
        let p = AnnotationGeometry.snap45(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(p.y, 0, accuracy: 0.001)
        XCTAssertEqual(AnnotationGeometry.square(from: .zero, to: CGPoint(x: -30, y: 10)), CGPoint(x: -30, y: 30))
        XCTAssertEqual(AnnotationGeometry.pixelAligned(CGRect(x: 0.3, y: 0.2, width: 10.1, height: 5), scale: 2),
                       CGRect(x: 0.5, y: 0, width: 10, height: 5))
    }

    func testArrowPathCoversTip() {
        let p = AnnotationGeometry.arrowPath(from: .zero, to: CGPoint(x: 100, y: 0), width: 4)
        XCTAssertTrue(p.contains(CGPoint(x: 97, y: 0)))
        XCTAssertTrue(p.contains(CGPoint(x: 50, y: 0)))
        XCTAssertFalse(p.contains(CGPoint(x: 50, y: 10)))
    }
}
