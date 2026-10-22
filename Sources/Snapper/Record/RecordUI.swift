import AppKit
import QuartzCore
import SnapKit

/// Borderless, click-through overlay panel that never steals focus.
class RecordPanel: NSPanel {
    init(frame: CGRect, captured: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Our chrome never shows up in recordings or other apps' captures; the click rings must.
        sharingType = captured ? .readOnly : .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Border + countdown

/// Thin dashed frame just outside the recorded rect, plus the 3-2-1 countdown in its centre.
final class RecordBorder {
    static let margin: CGFloat = 6
    let window: RecordPanel
    private let view: BorderView

    init(rect: CGRect) {
        let f = rect.insetBy(dx: -Self.margin, dy: -Self.margin)
        window = RecordPanel(frame: f, captured: false)
        view = BorderView(frame: CGRect(origin: .zero, size: f.size))
        window.contentView = view
    }

    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil); window.close() }
    func setCountdown(_ n: Int?) { view.countdown = n; view.needsDisplay = true }
    func setPaused(_ p: Bool) { view.paused = p; view.needsDisplay = true }

    final class BorderView: NSView {
        var countdown: Int?
        var paused = false

        override func draw(_ dirty: NSRect) {
            let inner = bounds.insetBy(dx: RecordBorder.margin, dy: RecordBorder.margin)
            if countdown != nil {
                NSColor.black.withAlphaComponent(0.25).setFill()
                inner.fill()
            }
            let r = inner.insetBy(dx: -1.5, dy: -1.5)       // stroke sits entirely outside the recorded pixels
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1.5
            p.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let under = NSBezierPath(rect: r); under.lineWidth = 1.5; under.stroke()
            (paused ? NSColor.systemYellow : NSColor.white).setStroke()
            p.stroke()

            if let n = countdown {
                let side = min(120, min(inner.width, inner.height) * 0.8)
                guard side > 24 else { return }
                let c = CGRect(x: inner.midX - side / 2, y: inner.midY - side / 2, width: side, height: side)
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: c, xRadius: side * 0.22, yRadius: side * 0.22).fill()
                let s = "\(n)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: side * 0.55, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let sz = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2), withAttributes: attrs)
            }
        }
    }
}

// MARK: - Click rings (captured on purpose)

/// Transparent window over the recorded area that draws an expanding ring at every mouse click.
/// Its sharingType is .readOnly and the recorder keeps it in the capture filter, so rings land in the video.
final class ClickRings {
    let window: RecordPanel
    private var monitor: Any?

    init(rect: CGRect) {
        window = RecordPanel(frame: rect, captured: true)
        let v = NSView(frame: CGRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        window.contentView = v
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    func show() {
        window.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            self?.ring(at: NSEvent.mouseLocation, right: e.type == .rightMouseDown)
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window.orderOut(nil)
        window.close()
    }

    func ring(at global: CGPoint, right: Bool = false) {
        guard window.frame.insetBy(dx: -30, dy: -30).contains(global), let host = window.contentView?.layer else { return }
        let p = CGPoint(x: global.x - window.frame.minX, y: global.y - window.frame.minY)
        let r: CGFloat = 22
        let l = CAShapeLayer()
        l.frame = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        l.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: r * 2 - 4, height: r * 2 - 4), transform: nil)
        let color = right ? NSColor.systemOrange : NSColor.systemBlue
        l.fillColor = color.withAlphaComponent(0.25).cgColor
        l.strokeColor = color.withAlphaComponent(0.9).cgColor
        l.lineWidth = 3
        l.opacity = 0
        host.addSublayer(l)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35; scale.toValue = 1.15
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.9, 0]; fade.keyTimes = [0, 0.55, 1]
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 0.55
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "ring")
        CATransaction.commit()
    }
}

// MARK: - Control pill

/// Compact floating pill: ● timer | stop · pause · restart · cancel.
final class RecordControls {
    enum Cmd { case stop, pause, restart, cancel }
    let window: NSPanel
    private let timer = NSTextField(labelWithString: "0:00")
    private let dot = NSView()
    private var pauseButton: NSButton!
    private let onCmd: (Cmd) -> Void

    init(near rect: CGRect, screen: NSScreen, onCmd: @escaping (Cmd) -> Void) {
        self.onCmd = onCmd
        let size = CGSize(width: 178, height: 30)
        let f = Self.place(size, near: rect, in: screen.visibleFrame)
        window = ControlsPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .screenSaver
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none

        let bg = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        bg.appearance = NSAppearance(named: .vibrantDark)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.frame = CGRect(x: 11, y: (size.height - 7) / 2, width: 7, height: 7)
        bg.addSubview(dot)

        timer.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timer.textColor = .white
        timer.frame = CGRect(x: 23, y: (size.height - 16) / 2, width: 52, height: 16)
        bg.addSubview(timer)

        var x: CGFloat = 78
        func add(_ symbol: String, _ tip: String, _ tint: NSColor, _ sel: Selector) -> NSButton {
            let b = NSButton(frame: CGRect(x: x, y: 3, width: 24, height: 24))
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            b.contentTintColor = tint
            b.toolTip = tip
            b.target = self
            b.action = sel
            bg.addSubview(b)
            x += 24
            return b
        }
        _ = add("stop.fill", "Stop and save", .systemRed, #selector(stop))
        pauseButton = add("pause.fill", "Pause", .white, #selector(pause))
        _ = add("arrow.counterclockwise", "Restart", .white, #selector(restart))
        _ = add("xmark", "Cancel", .white, #selector(cancel))
        window.contentView = bg
    }

    /// Below the selection when there's room, else above, else tucked inside its bottom edge.
    static func place(_ size: CGSize, near r: CGRect, in vis: CGRect) -> CGRect {
        let gap: CGFloat = 12
        var y = r.minY - gap - size.height
        if y < vis.minY { y = r.maxY + gap }
        if y + size.height > vis.maxY { y = max(vis.minY, r.minY) + gap }
        var x = r.midX - size.width / 2
        x = max(vis.minX + 4, min(x, vis.maxX - size.width - 4))
        y = max(vis.minY + 4, min(y, vis.maxY - size.height - 4))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil); window.close() }

    func update(elapsed: Double, paused: Bool, counting: Int?) {
        if let n = counting {
            timer.stringValue = "in \(n)…"
        } else {
            timer.stringValue = RecordMath.formatElapsed(elapsed)
        }
        dot.layer?.backgroundColor = (paused ? NSColor.systemYellow : NSColor.systemRed).cgColor
        let sym = paused ? "play.fill" : "pause.fill"
        if pauseButton.toolTip != (paused ? "Resume" : "Pause") {
            pauseButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            pauseButton.toolTip = paused ? "Resume" : "Pause"
        }
        pauseButton.isEnabled = counting == nil
    }

    @objc private func stop() { onCmd(.stop) }
    @objc private func pause() { onCmd(.pause) }
    @objc private func restart() { onCmd(.restart) }
    @objc private func cancel() { onCmd(.cancel) }

    private final class ControlsPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
