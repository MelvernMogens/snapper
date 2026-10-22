import CoreGraphics
import Foundation

/// sRGB colour that survives Codable round-trips.
public struct RGBA: Codable, Hashable {
    public var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    public init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public func alpha(_ v: CGFloat) -> RGBA { RGBA(r, g, b, v) }
    /// Perceived brightness; light colours get dark text on top of them.
    public var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.68 }

    public static let red = RGBA(1, 0.231, 0.188)
    public static let orange = RGBA(1, 0.584, 0)
    public static let yellow = RGBA(1, 0.8, 0)
    public static let green = RGBA(0.204, 0.78, 0.349)
    public static let blue = RGBA(0, 0.478, 1)
    public static let purple = RGBA(0.686, 0.322, 0.871)
    public static let black = RGBA(0.1, 0.1, 0.1)
    public static let white = RGBA(1, 1, 1)
    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

public enum AnnotationTool: String, Codable, CaseIterable {
    case select, arrow, rect, ellipse, line, text, pencil, highlighter, blur, spotlight, counter, crop

    /// Single-key shortcut (when not typing).
    public var key: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rect: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .text: return "t"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .blur: return "b"
        case .spotlight: return "s"
        case .counter: return "n"
        case .crop: return "c"
        }
    }

    public var kind: Annotation.Kind? { Annotation.Kind(rawValue: rawValue) }
}

public enum BlurStyle: String, Codable, CaseIterable { case blur, pixelate }

/// One shape on the image. All geometry is in image *points*, origin top-left, y down.
public struct Annotation: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable {
        case arrow, rect, ellipse, line, text, pencil, highlighter, blur, spotlight, counter
    }

    public var id: UUID
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    /// Freehand path (pencil / highlighter).
    public var points: [CGPoint]
    public var color: RGBA
    public var lineWidth: CGFloat
    public var filled: Bool
    public var text: String
    public var fontSize: CGFloat
    public var textBackground: Bool
    public var number: Int
    public var blurStyle: BlurStyle

    public init(kind: Kind, start: CGPoint, end: CGPoint? = nil, points: [CGPoint] = [], color: RGBA = .red,
                lineWidth: CGFloat = 4, filled: Bool = false, text: String = "", fontSize: CGFloat = 22,
                textBackground: Bool = false, number: Int = 0, blurStyle: BlurStyle = .blur, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.start = start; self.end = end ?? start; self.points = points
        self.color = color; self.lineWidth = lineWidth; self.filled = filled; self.text = text
        self.fontSize = fontSize; self.textBackground = textBackground; self.number = number; self.blurStyle = blurStyle
    }

    public var rect: CGRect {
        get { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y)) }
        set { start = newValue.origin; end = CGPoint(x: newValue.maxX, y: newValue.maxY) }
    }

    /// Kinds whose geometry is a box with 8 resize handles.
    public var isBoxed: Bool { [.rect, .ellipse, .blur, .spotlight].contains(kind) }
    /// Kinds with two endpoint handles.
    public var isSegment: Bool { kind == .arrow || kind == .line }

    public var counterRadius: CGFloat { 8 + lineWidth * 1.5 }

    /// Effective stroke width of the highlighter marker.
    public var highlighterWidth: CGFloat { lineWidth * 4 + 6 }

    /// Bounding box used for selection, in image points.
    public var bounds: CGRect {
        switch kind {
        case .rect, .ellipse, .blur, .spotlight:
            return rect
        case .arrow, .line:
            let pad = kind == .arrow ? AnnotationGeometry.arrowHeadHalfWidth(width: lineWidth, length: length) : lineWidth / 2
            return rect.insetBy(dx: -pad, dy: -pad)
        case .pencil, .highlighter:
            let w = (kind == .highlighter ? highlighterWidth : lineWidth) / 2
            return AnnotationGeometry.boundingBox(points.isEmpty ? [start] : points).insetBy(dx: -w, dy: -w)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: 2 * r, height: 2 * r)
        case .text:
            return CGRect(origin: start, size: AnnotationText.boxSize(self))
        }
    }

    public var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }

    public func translated(by d: CGVector) -> Annotation {
        var a = self
        a.start = CGPoint(x: start.x + d.dx, y: start.y + d.dy)
        a.end = CGPoint(x: end.x + d.dx, y: end.y + d.dy)
        a.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return a
    }

    /// Hit test in image points. `tolerance` should be a few screen pixels converted to points.
    public func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch kind {
        case .blur, .spotlight, .text:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        case .counter:
            return hypot(p.x - start.x, p.y - start.y) <= counterRadius + t
        case .rect:
            let r = rect, w = lineWidth / 2 + t
            if filled { return r.insetBy(dx: -w, dy: -w).contains(p) }
            return r.insetBy(dx: -w, dy: -w).contains(p) && !r.insetBy(dx: w, dy: w).contains(p)
        case .ellipse:
            let r = rect, w = lineWidth / 2 + t
            func inside(_ e: CGRect) -> Bool {
                guard e.width > 0, e.height > 0 else { return false }
                let dx = (p.x - e.midX) / (e.width / 2), dy = (p.y - e.midY) / (e.height / 2)
                return dx * dx + dy * dy <= 1
            }
            let outer = r.insetBy(dx: -w, dy: -w)
            if filled { return inside(outer) }
            let inner = r.insetBy(dx: w, dy: w)
            return inside(outer) && !(inner.width > 0 && inner.height > 0 && inside(inner))
        case .arrow, .line:
            let extra = kind == .arrow ? max(lineWidth / 2, AnnotationGeometry.arrowHeadHalfWidth(width: lineWidth, length: length) * 0.6) : lineWidth / 2
            return AnnotationGeometry.distance(p, segment: start, end) <= extra + t
        case .pencil, .highlighter:
            let w = (kind == .highlighter ? highlighterWidth : lineWidth) / 2 + t
            let pts = points.isEmpty ? [start] : points
            if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) <= w }
            for i in 1..<pts.count where AnnotationGeometry.distance(p, segment: pts[i - 1], pts[i]) <= w { return true }
            return false
        }
    }
}

/// Backdrop placed behind the screenshot (CleanShot "Background"): a gradient preset, a solid
/// colour, or any picture (built-in wallpaper / user-chosen file), drawn aspect-fill.
public struct AnnotationBackground: Codable, Equatable {
    public enum Kind: Codable, Equatable, Hashable {
        case gradient(Int)
        case solid(RGBA)
        /// Absolute file path of a picture.
        case image(String)
    }

    public var kind: Kind
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var shadow: Bool
    /// Blur strength for picture backgrounds, 0 (sharp) … 100.
    public var blur: CGFloat

    public init(preset: Int = 0, padding: CGFloat = 48, cornerRadius: CGFloat = 10, shadow: Bool = true) {
        self.init(kind: .gradient(preset), padding: padding, cornerRadius: cornerRadius, shadow: shadow)
    }

    public init(kind: Kind, padding: CGFloat = 48, cornerRadius: CGFloat = 10, shadow: Bool = true, blur: CGFloat = 0) {
        self.kind = kind; self.padding = padding; self.cornerRadius = cornerRadius; self.shadow = shadow; self.blur = blur
    }

    /// Gradient preset index (nil-safe accessor kept for older call sites). Setting it switches to a gradient.
    public var preset: Int? {
        get { if case .gradient(let i) = kind { return i }; return nil }
        set { if let newValue { kind = .gradient(newValue) } }
    }

    public var imagePath: String? { if case .image(let p) = kind { return p }; return nil }

    // Flat JSON: {kind:"gradient|solid|image", preset, color, imagePath, padding, cornerRadius, shadow, blur}.
    // Old documents only carry {preset, padding, cornerRadius, shadow} and decode as gradients.
    private enum CodingKeys: String, CodingKey { case kind, preset, color, imagePath, padding, cornerRadius, shadow, blur }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 48
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 10
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        blur = try c.decodeIfPresent(CGFloat.self, forKey: .blur) ?? 0
        let preset = try c.decodeIfPresent(Int.self, forKey: .preset) ?? 0
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "gradient" {
        case "solid": kind = .solid(try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .white)
        case "image":
            if let p = try c.decodeIfPresent(String.self, forKey: .imagePath) { kind = .image(p) } else { kind = .gradient(preset) }
        default: kind = .gradient(preset)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(padding, forKey: .padding)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(blur, forKey: .blur)
        switch kind {
        case .gradient(let i): try c.encode("gradient", forKey: .kind); try c.encode(i, forKey: .preset)
        case .solid(let col): try c.encode("solid", forKey: .kind); try c.encode(col, forKey: .color)
        case .image(let p): try c.encode("image", forKey: .kind); try c.encode(p, forKey: .imagePath)
        }
    }

    /// Two-stop diagonal gradients.
    public static let presets: [(RGBA, RGBA)] = [
        (RGBA(0.42, 0.36, 0.98), RGBA(0.93, 0.36, 0.71)),   // violet → pink
        (RGBA(0.13, 0.69, 0.98), RGBA(0.16, 0.36, 0.89)),   // sky → blue
        (RGBA(1.0, 0.62, 0.29), RGBA(0.96, 0.29, 0.42)),    // peach → coral
        (RGBA(0.20, 0.83, 0.60), RGBA(0.05, 0.55, 0.62)),   // mint → teal
        (RGBA(0.98, 0.84, 0.36), RGBA(0.98, 0.52, 0.27)),   // sun
        (RGBA(0.22, 0.24, 0.30), RGBA(0.08, 0.09, 0.12)),   // graphite
    ]
}

/// Everything the user did to one image. A value type, so undo is just a stack of snapshots.
public struct AnnotationDocument: Codable, Equatable {
    public var annotations: [Annotation]
    /// Crop in image points (nil = whole image).
    public var crop: CGRect?
    public var background: AnnotationBackground?
    public init(annotations: [Annotation] = [], crop: CGRect? = nil, background: AnnotationBackground? = nil) {
        self.annotations = annotations; self.crop = crop; self.background = background
    }

    public func index(of id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }

    /// Next counter number (continues after the highest one present).
    public var nextCounter: Int { (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1 }

    /// Topmost annotation under the point.
    public func hit(_ p: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first { $0.hitTest(p, tolerance: tolerance) }
    }
}

public enum AnnotationGeometry {
    public static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    public static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .zero }
        var r = CGRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Snap the drag vector to 45° steps (Shift while drawing lines / arrows).
    public static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
    }

    /// Square / circle constraint (Shift while drawing boxes).
    public static func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let s = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x >= a.x ? s : -s), y: a.y + (b.y >= a.y ? s : -s))
    }

    public static func arrowHeadLength(width w: CGFloat, length: CGFloat) -> CGFloat {
        min(max(w * 3.8 + 6, 12), length * 0.6)
    }

    public static func arrowHeadHalfWidth(width w: CGFloat, length: CGFloat) -> CGFloat {
        arrowHeadLength(width: w, length: length) * 0.58
    }

    /// Tapered arrow outline: a thin tail that widens to the neck, then a swept-back head.
    public static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return path }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let head = arrowHeadLength(width: w, length: len)
        let half = arrowHeadHalfWidth(width: w, length: len)
        let tail = max(w * 0.18, 0.6)
        let neckHalf = w * 0.55
        func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: s.x + ux * along + nx * side, y: s.y + uy * along + ny * side)
        }
        let neck = len - head * 0.72      // where the shaft enters the head
        let wing = len - head             // back corners of the head
        path.move(to: pt(0, -tail))
        path.addLine(to: pt(neck, -neckHalf))
        path.addLine(to: pt(wing, -half))
        path.addQuadCurve(to: e, control: pt(len - head * 0.45, -half * 0.55))
        path.addQuadCurve(to: pt(wing, half), control: pt(len - head * 0.45, half * 0.55))
        path.addLine(to: pt(neck, neckHalf))
        path.addLine(to: pt(0, tail))
        path.addArc(center: s, radius: tail, startAngle: atan2(ny, nx), endAngle: atan2(-ny, -nx), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Resize handles of a box: (x, y) in -1...1 per axis (y = -1 is the top edge, since y points down).
    public static let boxHandles: [(x: Int, y: Int)] = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]

    public static func handlePoint(_ r: CGRect, _ h: (x: Int, y: Int)) -> CGPoint {
        CGPoint(x: r.midX + CGFloat(h.x) * r.width / 2, y: r.midY + CGFloat(h.y) * r.height / 2)
    }

    /// Resize in a y-down space. Never inverts; keeps at least `minSize`.
    public static func resize(_ r: CGRect, handle h: (x: Int, y: Int), by d: CGVector, minSize: CGFloat = 4) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if h.x < 0 { minX = min(minX + d.dx, maxX - minSize) } else if h.x > 0 { maxX = max(maxX + d.dx, minX + minSize) }
        if h.y < 0 { minY = min(minY + d.dy, maxY - minSize) } else if h.y > 0 { maxY = max(maxY + d.dy, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Snap a rect (in points) to the pixel grid of an image with `scale` pixels per point.
    public static func pixelAligned(_ r: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return r }
        let x0 = (r.minX * scale).rounded(), y0 = (r.minY * scale).rounded()
        let x1 = (r.maxX * scale).rounded(), y1 = (r.maxY * scale).rounded()
        return CGRect(x: x0 / scale, y: y0 / scale, width: (x1 - x0) / scale, height: (y1 - y0) / scale)
    }
}
