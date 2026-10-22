import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Text layout shared by the renderer and the app's inline editor, so both agree on box sizes.
public enum AnnotationText {
    /// Bold system font (SF) at `size` points. Toll-free bridged to NSFont in the app.
    public static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    public static func padding(_ a: Annotation) -> CGSize {
        a.textBackground ? CGSize(width: (a.fontSize * 0.45).rounded(), height: (a.fontSize * 0.22).rounded()) : CGSize(width: 2, height: 1)
    }

    public static func lineHeight(_ f: CTFont) -> CGFloat {
        (CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)).rounded(.up)
    }

    static func lines(_ a: Annotation) -> [CTLine] {
        let f = font(size: a.fontSize)
        let text = a.text.isEmpty ? " " : a.text
        return text.components(separatedBy: "\n").map { s in
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: f])
            return CTLineCreateWithAttributedString(attr)
        }
    }

    /// Size of the text content (without padding).
    public static func contentSize(_ a: Annotation) -> CGSize {
        let f = font(size: a.fontSize)
        let ls = lines(a)
        let w = ls.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return CGSize(width: max(w, a.fontSize * 0.5).rounded(.up), height: lineHeight(f) * CGFloat(ls.count))
    }

    public static func boxSize(_ a: Annotation) -> CGSize {
        let c = contentSize(a), p = padding(a)
        return CGSize(width: c.width + 2 * p.width, height: c.height + 2 * p.height)
    }
}

/// Draws a document onto its image. One renderer per source image (it caches the blurred copies).
/// Coordinates: "image space" = image points, origin top-left, y down. "Canvas space" = the output
/// (cropped image plus background padding), also points / y-down.
public final class AnnotationRenderer {
    public let image: CGImage
    public let pointSize: CGSize
    public var scale: CGFloat { CGFloat(image.width) / max(pointSize.width, 1) }
    public var imageBounds: CGRect { CGRect(origin: .zero, size: pointSize) }

    private lazy var ci = CIContext(options: [.useSoftwareRenderer: false])
    private var effectCache: [BlurStyle: CGImage] = [:]

    public init(image: CGImage, pointSize: CGSize? = nil) {
        self.image = image
        self.pointSize = pointSize ?? CGSize(width: image.width, height: image.height)
    }

    // MARK: layout

    public func cropRect(_ doc: AnnotationDocument) -> CGRect {
        guard let c = doc.crop?.intersection(imageBounds), c.width >= 1, c.height >= 1 else { return imageBounds }
        return c
    }

    /// Output size in points.
    public func canvasSize(_ doc: AnnotationDocument, cropping: Bool = false) -> CGSize {
        if cropping { return pointSize }
        let c = cropRect(doc)
        let p = doc.background?.padding ?? 0
        return CGSize(width: c.width + 2 * p, height: c.height + 2 * p)
    }

    /// Where image-space (0,0) lands in canvas space.
    public func imageOrigin(_ doc: AnnotationDocument, cropping: Bool = false) -> CGPoint {
        if cropping { return .zero }
        let c = cropRect(doc)
        let p = doc.background?.padding ?? 0
        return CGPoint(x: p - c.minX, y: p - c.minY)
    }

    // MARK: flatten

    /// Full-resolution output (pixel size = canvas points × image scale).
    public func flatten(_ doc: AnnotationDocument) -> CGImage? {
        let size = canvasSize(doc)
        let s = scale
        let w = Int((size.width * s).rounded()), h = Int((size.height * s).rounded())
        guard w > 0, h > 0 else { return nil }
        let cs = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        // y-down point space
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        drawCanvas(doc, in: ctx)
        return ctx.makeImage()
    }

    // MARK: drawing

    /// Draw the whole output (background + cropped image + annotations) into a y-down context in canvas space.
    public func drawCanvas(_ doc: AnnotationDocument, in ctx: CGContext, skip: Set<UUID> = [], cropping: Bool = false) {
        let origin = imageOrigin(doc, cropping: cropping)
        let crop = cropping ? imageBounds : cropRect(doc)
        let size = canvasSize(doc, cropping: cropping)
        let k = deviceScale(ctx)
        ctx.saveGState()
        var imgRadius: CGFloat = 0
        if let bg = doc.background, !cropping {
            drawGradient(bg, size: size, in: ctx)
            imgRadius = min(bg.cornerRadius, crop.width / 4, crop.height / 4)
            let r = CGRect(x: bg.padding, y: bg.padding, width: crop.width, height: crop.height)
            if bg.shadow {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 36 * k, color: CGColor(gray: 0, alpha: 0.45))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: imgRadius, cornerHeight: imgRadius, transform: nil))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
        // Clip to the visible image area.
        let visible = CGRect(x: crop.minX + origin.x, y: crop.minY + origin.y, width: crop.width, height: crop.height)
        ctx.addPath(CGPath(roundedRect: visible, cornerWidth: imgRadius, cornerHeight: imgRadius, transform: nil))
        ctx.clip()
        ctx.translateBy(x: origin.x, y: origin.y)
        drawImageSpace(doc, in: ctx, skip: skip)
        ctx.restoreGState()
    }

    /// Image + annotations, context already in image space (y-down points).
    public func drawImageSpace(_ doc: AnnotationDocument, in ctx: CGContext, skip: Set<UUID> = []) {
        drawFlipped(image, in: imageBounds, ctx: ctx)
        let visible = doc.annotations.filter { !skip.contains($0.id) }
        // 1. effects that alter the pixels themselves
        for a in visible where a.kind == .blur { drawBlur(a, in: ctx) }
        // 2. one combined spotlight dim layer (several spotlights all stay lit)
        let spots = visible.filter { $0.kind == .spotlight && $0.rect.width > 1 && $0.rect.height > 1 }
        if !spots.isEmpty {
            ctx.saveGState()
            let p = CGMutablePath()
            p.addRect(imageBounds.insetBy(dx: -2, dy: -2))
            for s in spots {
                let r = s.rect, rad = min(8, r.width / 2, r.height / 2)
                p.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            }
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        // 3. vector annotations
        for a in visible where a.kind != .blur && a.kind != .spotlight { draw(a, in: ctx) }
    }

    /// Draw one vector annotation (no blur / spotlight) in image space.
    public func draw(_ a: Annotation, in ctx: CGContext) {
        let k = deviceScale(ctx)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let color = a.color.cgColor
        func softShadow() {
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * k), blur: 3 * k, color: CGColor(gray: 0, alpha: 0.3))
        }
        switch a.kind {
        case .arrow:
            softShadow()
            ctx.addPath(AnnotationGeometry.arrowPath(from: a.start, to: a.end, width: a.lineWidth))
            ctx.setFillColor(color)
            ctx.fillPath()
        case .line:
            softShadow()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.move(to: a.start); ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rect:
            softShadow()
            let r = a.rect
            let rad = min(a.lineWidth * 0.75 + 1, r.width / 2, r.height / 2)
            if a.filled {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
                ctx.setFillColor(color); ctx.fillPath()
            } else {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
                ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokePath()
            }
        case .ellipse:
            softShadow()
            ctx.addEllipse(in: a.rect)
            if a.filled { ctx.setFillColor(color); ctx.fillPath() } else { ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokePath() }
        case .pencil:
            softShadow()
            ctx.addPath(Self.smoothPath(a.points.isEmpty ? [a.start] : a.points))
            ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.square)
            ctx.addPath(Self.smoothPath(a.points.isEmpty ? [a.start] : a.points))
            ctx.setStrokeColor(a.color.alpha(0.45).cgColor)
            ctx.setLineWidth(a.highlighterWidth)
            ctx.strokePath()
        case .counter:
            let r = a.counterRadius
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * k), blur: 4 * k, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(color); ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); ctx.setLineWidth(max(1.5, r * 0.12))
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
            let label = "\(a.number)"
            let f = AnnotationText.font(size: r * (label.count > 1 ? 0.95 : 1.15))
            drawCentered(label, font: f, color: a.color.isLight ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1), center: a.start, in: ctx)
        case .text:
            drawText(a, in: ctx, k: k)
        case .blur:
            drawBlur(a, in: ctx)
        case .spotlight:
            break
        }
    }

    public func drawText(_ a: Annotation, in ctx: CGContext, k: CGFloat? = nil) {
        let k = k ?? deviceScale(ctx)
        let box = CGRect(origin: a.start, size: AnnotationText.boxSize(a))
        let pad = AnnotationText.padding(a)
        let f = AnnotationText.font(size: a.fontSize)
        let textColor: CGColor
        ctx.saveGState()
        if a.textBackground {
            let rad = min(box.height / 2, a.fontSize * 0.5)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * k), blur: 4 * k, color: CGColor(gray: 0, alpha: 0.3))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setFillColor(a.color.cgColor); ctx.fillPath()
            ctx.restoreGState()
            textColor = a.color.isLight ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
        } else {
            textColor = a.color.cgColor
            // Thin contrasting halo keeps plain text readable on busy screenshots.
            ctx.setShadow(offset: .zero, blur: 2.5 * k, color: a.color.isLight ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.5))
        }
        let lh = AnnotationText.lineHeight(f)
        let ascent = CTFontGetAscent(f)
        for (i, s) in a.text.components(separatedBy: "\n").enumerated() {
            let attr = NSAttributedString(string: s, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: f,
                kCTForegroundColorAttributeName as NSAttributedString.Key: textColor,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let baseline = CGPoint(x: box.minX + pad.width, y: box.minY + pad.height + CGFloat(i) * lh + ascent)
            ctx.saveGState()
            ctx.translateBy(x: baseline.x, y: baseline.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawCentered(_ s: String, font f: CTFont, color: CGColor, center: CGPoint, in ctx: CGContext) {
        let attr = NSAttributedString(string: s, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: f,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let g = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -g.midX, y: -g.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    public func drawBlur(_ a: Annotation, in ctx: CGContext) {
        let r = a.rect.intersection(imageBounds)
        guard r.width > 0.5, r.height > 0.5, let fx = effectImage(a.blurStyle) else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        drawFlipped(fx, in: imageBounds, ctx: ctx)
        ctx.restoreGState()
    }

    /// Whole-image blurred / pixelated copy at full pixel resolution (cached).
    public func effectImage(_ style: BlurStyle) -> CGImage? {
        if let c = effectCache[style] { return c }
        let src = CIImage(cgImage: image)
        let ext = src.extent
        let out: CIImage?
        switch style {
        case .blur:
            let f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
            f?.setValue(max(6, 9 * scale), forKey: kCIInputRadiusKey)
            out = f?.outputImage?.cropped(to: ext)
        case .pixelate:
            let f = CIFilter(name: "CIPixellate")
            f?.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
            f?.setValue(max(8, 9 * scale), forKey: kCIInputScaleKey)
            f?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            out = f?.outputImage?.cropped(to: ext)
        }
        guard let out, let cg = ci.createCGImage(out, from: ext) else { return nil }
        effectCache[style] = cg
        return cg
    }

    private func drawGradient(_ bg: AnnotationBackground, size: CGSize, in ctx: CGContext) {
        let p = AnnotationBackground.presets[max(0, min(bg.preset, AnnotationBackground.presets.count - 1))]
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let g = CGGradient(colorsSpace: cs, colors: [p.0.cgColor, p.1.cgColor] as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // MARK: helpers

    /// Draw a CGImage upright into `r` of a y-down context.
    public func drawFlipped(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// Points → device pixels for the current CTM (shadow offsets/blur ignore the CTM).
    func deviceScale(_ ctx: CGContext) -> CGFloat {
        let m = ctx.ctm
        return max(0.01, sqrt(abs(m.a * m.d - m.b * m.c)))
    }

    /// Catmull-Rom-ish smoothing via midpoint quad curves.
    public static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 { p.addLine(to: first); return p }
        if pts.count == 2 { p.addLine(to: pts[1]); return p }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}
