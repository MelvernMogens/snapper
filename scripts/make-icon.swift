// Renders Resources/AppIcon.icns: dark rounded square, teal→blue viewfinder brackets framing a lit
// selection region with a crosshair cursor at its dragging corner.
// Run from the repo root: swift scripts/make-icon.swift [repoRoot]
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    gctx.imageInterpolation = .high
    let ctx = gctx.cgContext
    let s = size / 1024
    let small = size <= 32

    // Body: macOS icon grid (824pt square inside 1024, ~185 radius), with a soft drop shadow.
    let inset = 100 * s
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = 185 * s
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        color(0.08, 0.09, 0.11).setFill()
        bodyPath.fill()
        ctx.restoreGState()
    }
    NSGradient(colors: [color(0.165, 0.18, 0.21), color(0.07, 0.078, 0.094)])!.draw(in: bodyPath, angle: -90)

    // Subtle top sheen + hairline rim.
    ctx.saveGState()
    bodyPath.addClip()
    let glow = NSGradient(colors: [color(0.45, 0.75, 1.0, 0.10), color(0.2, 0.5, 1.0, 0.0)])!
    if !small { glow.draw(fromCenter: NSPoint(x: size * 0.5, y: size * 0.78), radius: 0,
              toCenter: NSPoint(x: size * 0.5, y: size * 0.6), radius: 520 * s, options: []) }
    ctx.restoreGState()
    if !small {
        let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: radius - 1.5 * s, yRadius: radius - 1.5 * s)
        rim.lineWidth = 3 * s
        color(1, 1, 1, 0.09).setStroke()
        rim.stroke()
    }

    // Accent gradient used for strokes (teal top-left → blue bottom-right).
    let accent = NSGradient(colors: [color(0.18, 0.92, 0.82), color(0.16, 0.62, 1.0), color(0.30, 0.38, 1.0)],
                            atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!

    // Viewfinder corner brackets.
    let frameRect = body.insetBy(dx: 168 * s, dy: 168 * s)
    let arm = 140 * s
    let lw = (small ? 64 : 46) * s
    let cr = 46 * s
    let brackets = NSBezierPath()
    brackets.lineWidth = lw
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round
    func corner(_ p: NSPoint, _ dx: CGFloat, _ dy: CGFloat) {
        brackets.move(to: NSPoint(x: p.x, y: p.y + dy * arm))
        brackets.line(to: NSPoint(x: p.x, y: p.y + dy * cr))
        brackets.curve(to: NSPoint(x: p.x + dx * cr, y: p.y),
                       controlPoint1: NSPoint(x: p.x, y: p.y + dy * cr * 0.45),
                       controlPoint2: NSPoint(x: p.x + dx * cr * 0.45, y: p.y))
        brackets.line(to: NSPoint(x: p.x + dx * arm, y: p.y))
    }
    corner(NSPoint(x: frameRect.minX, y: frameRect.maxY), 1, -1)
    corner(NSPoint(x: frameRect.maxX, y: frameRect.maxY), -1, -1)
    corner(NSPoint(x: frameRect.minX, y: frameRect.minY), 1, 1)
    corner(NSPoint(x: frameRect.maxX, y: frameRect.minY), -1, 1)

    // Glow under the brackets, then the gradient stroke itself (stroke → path → clip → gradient fill).
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22 * s, color: color(0.15, 0.75, 1.0, 0.32).cgColor)
        color(0.15, 0.7, 1.0, 0.9).setStroke()
        brackets.stroke()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(brackets.cgPathCompat)
    ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    accent.draw(in: frameRect.insetBy(dx: -lw, dy: -lw), angle: -45)
    ctx.restoreGState()

    // Hero: a lit selection region being dragged out, with a crosshair cursor at its lower-right corner.
    let sel = frameRect.insetBy(dx: 98 * s, dy: 98 * s).offsetBy(dx: -12 * s, dy: 12 * s)
    let selPath = NSBezierPath(roundedRect: sel, xRadius: 18 * s, yRadius: 18 * s)
    ctx.saveGState()
    if !small { ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.5).cgColor) }
    NSGradient(colors: [color(0.32, 0.93, 0.88, 0.95), color(0.22, 0.62, 1.0, 0.95), color(0.36, 0.42, 1.0, 0.95)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!.draw(in: selPath, angle: -45)
    ctx.restoreGState()
    if !small {
        // Top-light sheen and crisp white edge.
        ctx.saveGState()
        selPath.addClip()
        NSGradient(colors: [color(1, 1, 1, 0.28), color(1, 1, 1, 0)])!.draw(in: NSRect(x: sel.minX, y: sel.midY, width: sel.width, height: sel.height / 2), angle: -90)
        ctx.restoreGState()
        selPath.lineWidth = 10 * s
        color(1, 1, 1, 0.95).setStroke()
        selPath.stroke()
        // Corner handles.
        let hs = 34 * s
        for c in [NSPoint(x: sel.minX, y: sel.maxY), NSPoint(x: sel.maxX, y: sel.maxY), NSPoint(x: sel.minX, y: sel.minY)] {
            let h = NSBezierPath(ovalIn: NSRect(x: c.x - hs / 2, y: c.y - hs / 2, width: hs, height: hs))
            color(1, 1, 1).setFill(); h.fill()
        }
    }
    // Crosshair cursor at the dragging corner (too fine to read at 16/32 px, so skipped there).
    if !small {
    let cx = sel.maxX, cy = sel.minY
    let armLen = (small ? 110 : 54) * s, gap = (small ? 0 : 14) * s
    let cross = NSBezierPath()
    cross.lineWidth = (small ? 44 : 18) * s
    cross.lineCapStyle = .round
    cross.move(to: NSPoint(x: cx - armLen, y: cy)); cross.line(to: NSPoint(x: cx - gap, y: cy))
    cross.move(to: NSPoint(x: cx + gap, y: cy)); cross.line(to: NSPoint(x: cx + armLen, y: cy))
    cross.move(to: NSPoint(x: cx, y: cy - armLen)); cross.line(to: NSPoint(x: cx, y: cy - gap))
    cross.move(to: NSPoint(x: cx, y: cy + gap)); cross.line(to: NSPoint(x: cx, y: cy + armLen))
    ctx.saveGState()
    if !small {
        // Dark halo so the white crosshair reads over both the selection and the background.
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * s), blur: 10 * s, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    }
    color(1, 1, 1).setStroke()
    cross.stroke()
    ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    /// CGPath for macOS 13- (NSBezierPath.cgPath is 14+, keep the script runnable anywhere).
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: path.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = fm.temporaryDirectory.appendingPathComponent("SnapperAppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
exit(p.terminationStatus)
