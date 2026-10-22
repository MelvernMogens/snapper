import AppKit
import ImageIO
import SnapKit

/// Small helpers shared by the Tools features (OCR, pins, scrolling capture, history/settings CLI hooks).
enum ToolsImage {
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func load(path: String) throws -> CGImage {
        guard let img = load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
            throw GrabError(message: "Could not read image at \(path)")
        }
        return img
    }

    /// 8-bit grayscale copy, row 0 = top. Only the width is resampled so vertical offsets stay pixel-exact.
    static func gray(_ img: CGImage, maxWidth: Int = 256) -> GrayImage {
        let w = max(1, min(img.width, maxWidth)), h = img.height
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    /// Rows `rows` (top-origin pixel rows) copied into an image that owns its memory
    /// (a plain `cropping(to:)` keeps the whole parent frame alive).
    static func copyRows(_ img: CGImage, _ rows: Range<Int>) -> CGImage? {
        let lo = max(0, rows.lowerBound), hi = min(img.height, rows.upperBound)
        guard hi > lo, let c = img.cropping(to: CGRect(x: 0, y: lo, width: img.width, height: hi - lo)) else { return nil }
        guard let ctx = CGContext(data: nil, width: c.width, height: c.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
        return ctx.makeImage()
    }

    /// Stack images top-to-bottom (all should share a width; narrower ones are left-aligned).
    static func stack(_ parts: [CGImage]) -> CGImage? {
        guard let first = parts.first else { return nil }
        let w = parts.map(\.width).max() ?? first.width
        let h = parts.reduce(0) { $0 + $1.height }
        guard h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = 0
        for p in parts {
            // CG origin is bottom-left: a part starting `top` rows from the top sits at y = h - top - p.height.
            ctx.draw(p, in: CGRect(x: 0, y: h - top - p.height, width: p.width, height: p.height))
            top += p.height
        }
        return ctx.makeImage()
    }

    static func write(_ img: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fmt: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        guard let d = Output.encode(img, format: fmt) else { throw GrabError(message: "encode failed") }
        try d.write(to: url)
    }

    /// Screen backing scale used to turn pixel sizes into point sizes when nothing better is known.
    static var defaultScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
}

/// Keeps a CLI-launched window alive for screenshots (the process is killed from outside).
enum ToolsCLI {
    @MainActor static func stayAlive() async -> Int32 {
        while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
    static func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

/// Transient dark pill near the bottom of the screen ("Copied 42 characters"). Click-through, fades out.
final class ToolsHUD {
    private static var panel: NSPanel?
    private static var generation = 0

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", on screen: NSScreen = .underMouse, duration: TimeInterval = 1.2) {
        panel?.orderOut(nil)
        generation += 1
        let gen = generation

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = symbol.contains("xmark") || symbol.contains("exclamation") ? .systemOrange : .systemTeal
        icon.frame.size = CGSize(width: 16, height: 16)

        let padX: CGFloat = 14, gap: CGFloat = 7, h: CGFloat = 34
        let w = padX * 2 + 16 + gap + ceil(label.frame.width)
        let vf = screen.visibleFrame
        let frame = CGRect(x: (vf.midX - w / 2).rounded(), y: vf.minY + 72, width: w, height: h)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        bg.material = .hudWindow
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = h / 2
        bg.layer?.masksToBounds = true
        icon.frame.origin = CGPoint(x: padX, y: (h - 16) / 2)
        label.frame.origin = CGPoint(x: padX + 16 + gap, y: ((h - label.frame.height) / 2).rounded())
        bg.addSubview(icon)
        bg.addSubview(label)
        p.contentView = bg
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard gen == generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; p.animator().alphaValue = 0 },
                                                 completionHandler: { if gen == generation { p.orderOut(nil); panel = nil } })
        }
    }
}
