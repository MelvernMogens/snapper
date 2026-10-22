import AppKit
import SnapKit

/// What the user picked in the overlay. `rect` is in AppKit global points.
struct OverlayResult {
    let screen: NSScreen
    let rect: CGRect
    let windowID: CGWindowID?
    var displayID: CGDirectDisplayID { screen.displayID }
}

/// Full-screen selection overlay on every display: drag an area, or (Space) pick a window.
/// - Freeze-frame: when `shots` are given the frozen screen image is shown under the dim layer
///   (screenshots). Without shots the live screen shows through (recording, scrolling).
/// - Keys: Esc / right-click cancel · Space toggles window mode, or moves the selection while dragging
///   · Shift while dragging = square · Return = whole screen under the mouse.
/// - A click without a drag selects the whole screen it was on.
final class OverlayController {
    static var current: OverlayController?

    let shots: [CGDirectDisplayID: CGImage]
    let allowWindowMode: Bool
    let hint: String?
    var windowMode: Bool
    private(set) var windows: [OverlayWindow] = []
    private var monitor: Any?
    private let completion: (OverlayResult?) -> Void
    private let previousApp = NSWorkspace.shared.frontmostApplication
    let windowList = ScreenGrabber.windowList()

    @discardableResult
    static func begin(shots: [CGDirectDisplayID: CGImage] = [:], windowMode: Bool = false, allowWindowMode: Bool = true,
                      hint: String? = nil, completion: @escaping (OverlayResult?) -> Void) -> OverlayController? {
        guard current == nil else { return nil }
        let c = OverlayController(shots: shots, windowMode: windowMode, allowWindowMode: allowWindowMode, hint: hint, completion: completion)
        current = c
        c.show()
        return c
    }

    private init(shots: [CGDirectDisplayID: CGImage], windowMode: Bool, allowWindowMode: Bool, hint: String?, completion: @escaping (OverlayResult?) -> Void) {
        self.shots = shots
        self.windowMode = windowMode && allowWindowMode
        self.allowWindowMode = allowWindowMode
        self.hint = hint
        self.completion = completion
    }

    private func show() {
        for s in NSScreen.screens {
            let w = OverlayWindow(screen: s)
            let v = SelectionView(frame: CGRect(origin: .zero, size: s.frame.size), screen: s, frozen: shots[s.displayID], controller: self)
            w.contentView = v
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let under = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        under?.makeKey()
        NSCursor.crosshair.set()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e) ? nil : e
        }
        for v in views { v.refreshMouse() }
    }

    var views: [SelectionView] { windows.compactMap { $0.contentView as? SelectionView } }

    private func handleKey(_ e: NSEvent) -> Bool {
        switch e.type {
        case .keyDown:
            switch Int(e.keyCode) {
            case 53: finish(nil); return true                       // Esc
            case 49:                                                // Space
                if e.isARepeat { return true }
                if let v = views.first(where: { $0.dragging }) { v.moving = true }
                else if allowWindowMode { windowMode.toggle(); views.forEach { $0.refreshMouse() } }
                return true
            case 36, 76:                                            // Return
                let s = NSScreen.underMouse
                finish(OverlayResult(screen: s, rect: s.frame, windowID: nil)); return true
            default: return true
            }
        case .keyUp:
            if Int(e.keyCode) == 49 { views.forEach { $0.moving = false } }
            return true
        case .flagsChanged:
            views.forEach { $0.square = e.modifierFlags.contains(.shift); $0.needsDisplay = true }
            return true
        default: return false
        }
    }

    /// Topmost window under a global point.
    func window(at p: CGPoint) -> (id: CGWindowID, rect: CGRect)? {
        windowList.first { $0.rect.contains(p) }.map { ($0.id, $0.rect) }
    }

    func finish(_ r: OverlayResult?) {
        guard OverlayController.current === self else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        OverlayController.current = nil
        NSCursor.arrow.set()
        if r == nil { previousApp?.activate() }
        completion(r)
    }

    /// Hand focus back to whatever app was frontmost before the overlay (after a capture that opens no window).
    func restoreFocus() { previousApp?.activate() }
}

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    let screen: NSScreen
    let frozen: CGImage?
    unowned let controller: OverlayController

    var mouse: CGPoint?
    var anchor: CGPoint?
    var current: CGPoint?
    var dragging = false
    var moving = false
    var square = false
    private var lastDrag: CGPoint?
    private var hover: (id: CGWindowID, rect: CGRect)?

    init(frame: CGRect, screen: NSScreen, frozen: CGImage?, controller: OverlayController) {
        self.screen = screen
        self.frozen = frozen
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        if let frozen {
            let bg = CALayer()
            bg.frame = bounds
            bg.contents = frozen
            bg.contentsGravity = .resize
            bg.zPosition = -1
            layer?.addSublayer(bg)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func toGlobal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY) }
    func toLocal(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    func refreshMouse() {
        let g = NSEvent.mouseLocation
        mouse = NSMouseInRect(g, screen.frame, false) ? CGPoint(x: g.x - screen.frame.minX, y: g.y - screen.frame.minY) : nil
        updateHover()
        needsDisplay = true
    }

    private func updateHover() {
        hover = nil
        guard controller.windowMode, let m = mouse, let w = controller.window(at: toGlobal(m)) else { return }
        hover = (w.id, toLocal(w.rect).intersection(bounds))
    }

    var selection: CGRect? {
        guard let a = anchor, let c = current else { return nil }
        var r = Geo.rect(from: a, to: c)
        if square {
            let s = max(r.width, r.height)
            r = CGRect(x: c.x < a.x ? a.x - s : a.x, y: c.y < a.y ? a.y - s : a.y, width: s, height: s)
        }
        return r.intersection(bounds)
    }

    override func mouseEntered(with event: NSEvent) { window?.makeKey(); refreshMouse() }
    override func mouseExited(with event: NSEvent) { mouse = nil; hover = nil; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if controller.windowMode {
            if let h = hover, let full = controller.windowList.first(where: { $0.id == h.id }) {
                controller.finish(OverlayResult(screen: screen, rect: full.rect, windowID: h.id))
            }
            return
        }
        anchor = p; current = p; lastDrag = p; dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if moving, let a = anchor, let l = lastDrag {
            anchor = CGPoint(x: a.x + p.x - l.x, y: a.y + p.y - l.y)
        }
        current = p; lastDrag = p; mouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let sel = selection
        if let sel, sel.width >= 4, sel.height >= 4 {
            controller.finish(OverlayResult(screen: screen, rect: sel.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), windowID: nil))
        } else {
            controller.finish(OverlayResult(screen: screen, rect: screen.frame, windowID: nil))   // click = whole screen
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller.finish(nil) }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hole: CGRect? = dragging ? selection : (controller.windowMode ? hover?.rect : nil)

        let p = CGMutablePath()
        p.addRect(bounds)
        if let hole { p.addRect(hole) }
        ctx.addPath(p)
        ctx.setFillColor(NSColor.black.withAlphaComponent(controller.windowMode ? 0.25 : 0.38).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let hole {
            if controller.windowMode {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                ctx.fill(hole)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(hole.insetBy(dx: 1.5, dy: 1.5))
            } else {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(hole.insetBy(dx: -0.5, dy: -0.5))
                drawSizeLabel(for: hole)
            }
        }

        if let m = mouse, !controller.windowMode {
            if Prefs.shared.showCrosshair && !dragging { drawCrosshair(ctx, m) }
            if Prefs.shared.showMagnifier, frozen != nil { drawLoupe(ctx, at: m) }
        }
        if let hint = controller.hint, NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) { drawHint(hint) }
    }

    private func pill(_ text: String, at origin: CGPoint, font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)) -> CGRect {
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = s.size()
        let r = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3))
        return r
    }

    private func drawSizeLabel(for r: CGRect) {
        let text = "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
        let w = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).size().width + 12
        var o = CGPoint(x: r.minX, y: r.minY - 24)
        if o.y < 4 { o.y = r.minY + 6; o.x = r.minX + 6 }
        o.x = min(max(4, o.x), bounds.width - w - 4)
        _ = pill(text, at: o)
    }

    private func drawCrosshair(_ ctx: CGContext, _ m: CGPoint) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        for (color, off) in [(NSColor.black.withAlphaComponent(0.35), 1.0), (NSColor.white.withAlphaComponent(0.75), 0.0)] {
            ctx.setStrokeColor(color.cgColor)
            let x = m.x.rounded() + 0.5 + off, y = m.y.rounded() + 0.5 - off
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Pixel loupe: 15×15 source pixels at 8× next to the cursor, with coordinates and hex colour.
    private func drawLoupe(_ ctx: CGContext, at m: CGPoint) {
        guard let img = frozen else { return }
        let n = 15, zoom: CGFloat = 8
        let side = CGFloat(n) * zoom
        let scale = CGFloat(img.width) / bounds.width
        let px = Int(m.x * scale), cgY = Int(m.y * scale)          // bottom-left pixel coords
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let tmp = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        tmp.setFillColor(NSColor.black.cgColor)
        tmp.fill(CGRect(x: 0, y: 0, width: n, height: n))
        tmp.interpolationQuality = .none
        tmp.draw(img, in: CGRect(x: n / 2 - px, y: n / 2 - cgY, width: img.width, height: img.height))
        guard let zoomed = tmp.makeImage() else { return }
        var hex = ""
        if let data = tmp.data {
            let b = data.assumingMemoryBound(to: UInt8.self)
            let i = (n / 2) * n * 4 + (n / 2) * 4
            hex = String(format: "#%02X%02X%02X", b[i], b[i + 1], b[i + 2])
        }

        var o = CGPoint(x: m.x + 22, y: m.y - 22 - side)
        if o.x + side > bounds.width - 4 { o.x = m.x - 22 - side }
        if o.y < 34 { o.y = m.y + 22 }
        let frame = CGRect(x: o.x, y: o.y, width: side, height: side)

        ctx.saveGState()
        let clip = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(clip); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(clip); ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(zoomed, in: frame)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1)
        for i in 1..<n {
            let d = CGFloat(i) * zoom
            ctx.move(to: CGPoint(x: frame.minX + d, y: frame.minY)); ctx.addLine(to: CGPoint(x: frame.minX + d, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: frame.minY + d)); ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + d))
        }
        ctx.strokePath()
        let c = CGRect(x: frame.minX + CGFloat(n / 2) * zoom, y: frame.minY + CGFloat(n / 2) * zoom, width: zoom, height: zoom)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.stroke(c)
        ctx.restoreGState()
        ctx.addPath(clip); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(1.5); ctx.strokePath()

        let label = "\(Int(m.x)), \(Int(bounds.height - m.y))  \(hex)"
        _ = pill(label, at: CGPoint(x: frame.minX, y: frame.minY - 24), font: .monospacedSystemFont(ofSize: 10, weight: .medium))
    }

    private func drawHint(_ text: String) {
        let w = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).size().width + 12
        let top = bounds.height - (screen.frame.maxY - screen.visibleFrame.maxY) - 40
        _ = pill(text, at: CGPoint(x: (bounds.width - w) / 2, y: top), font: .systemFont(ofSize: 12, weight: .medium))
    }
}
