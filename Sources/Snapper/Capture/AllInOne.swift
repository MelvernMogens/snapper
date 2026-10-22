import AppKit
import SnapKit

/// ⇧⌘5 All-In-One (CleanShot X style): an adjustable selection over the live screen that remembers the last area,
/// with a compact toolbar underneath to pick what to do with it — screenshot, window, fullscreen, scrolling, OCR,
/// pin, record video or GIF — plus exact W×H fields.
/// Drag outside the selection = new selection · drag inside = move · handles = resize · arrows nudge (⇧ = 10pt)
/// Return = screenshot · Esc = cancel.
final class AllInOne {
    static var current: AllInOne?

    enum Mode: String, CaseIterable {
        case screenshot, window, fullscreen, scrolling, ocr, pin, video, gif
        var symbol: String {
            switch self {
            case .screenshot: return "camera.viewfinder"
            case .window: return "macwindow"
            case .fullscreen: return "display"
            case .scrolling: return "arrow.up.and.down.text.horizontal"
            case .ocr: return "text.viewfinder"
            case .pin: return "pin"
            case .video: return "record.circle"
            case .gif: return "photo.stack"
            }
        }
        var title: String {
            switch self {
            case .screenshot: return "Capture Area (↩)"
            case .window: return "Capture Window"
            case .fullscreen: return "Capture Fullscreen"
            case .scrolling: return "Scrolling Capture"
            case .ocr: return "Capture Text (OCR)"
            case .pin: return "Capture & Pin"
            case .video: return "Record Video"
            case .gif: return "Record GIF"
            }
        }
    }

    let screen: NSScreen
    var rect: CGRect             // global AppKit points
    private var windows: [AllInOneWindow] = []
    private var toolbar: AllInOneToolbar?
    private var monitor: Any?
    private let previousApp = NSWorkspace.shared.frontmostApplication

    static var lastRect: CGRect? {
        get {
            guard let a = UserDefaults.standard.array(forKey: "allInOneRect") as? [Double], a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        set {
            guard let r = newValue else { return }
            UserDefaults.standard.set([r.minX, r.minY, r.width, r.height], forKey: "allInOneRect")
        }
    }

    static func start() {
        if let c = current { c.close(); return }       // ⇧⌘5 again toggles it off
        guard OverlayController.current == nil, Permissions.ensureScreenRecording() else { return }
        let s = NSScreen.underMouse
        var r = lastRect ?? .zero
        if !s.frame.contains(r) || r.width < 8 || r.height < 8 {
            let w = (s.frame.width * 0.5).rounded(), h = (s.frame.height * 0.5).rounded()
            r = CGRect(x: s.frame.midX - w / 2, y: s.frame.midY - h / 2, width: w, height: h).integral
        }
        let c = AllInOne(screen: s, rect: r)
        current = c
        c.show()
    }

    private init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        self.rect = rect
    }

    private func show() {
        for s in NSScreen.screens {
            let w = AllInOneWindow(screen: s)
            w.contentView = AllInOneView(frame: CGRect(origin: .zero, size: s.frame.size), screen: s, owner: self)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        windows.first { $0.screen == screen }?.makeKey()
        let tb = AllInOneToolbar(owner: self)
        toolbar = tb
        tb.orderFrontRegardless()
        rectChanged()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            // Let the W/H fields have their keys.
            if let fr = NSApp.keyWindow?.firstResponder as? NSTextView, fr.isFieldEditor, Int(e.keyCode) != 53 { return e }
            return self.key(e) ? nil : e
        }
    }

    private func key(_ e: NSEvent) -> Bool {
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(e.keyCode) {
        case 53: close(); return true
        case 36, 76: run(.screenshot); return true
        case 123: nudge(-step, 0); return true
        case 124: nudge(step, 0); return true
        case 125: nudge(0, -step); return true
        case 126: nudge(0, step); return true
        default: return false
        }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        rect = Geo.clampMove(rect.offsetBy(dx: dx, dy: dy), into: screenFrame(for: rect))
        rectChanged()
    }

    func screenFrame(for r: CGRect) -> CGRect {
        (NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } ?? screen).frame
    }

    var selectionScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? screen
    }

    func rectChanged() {
        windows.forEach { $0.contentView?.needsDisplay = true }
        toolbar?.place(below: rect, on: selectionScreen)
        toolbar?.setSize(rect.size)
    }

    func setSize(width: CGFloat?, height: CGFloat?) {
        var r = rect
        if let width, width >= 8 { r.size.width = width.rounded() }
        if let height, height >= 8 { r.size.height = height.rounded() }
        rect = Geo.clampMove(r, into: screenFrame(for: rect))
        rectChanged()
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        toolbar?.orderOut(nil)
        toolbar = nil
        if AllInOne.current === self { AllInOne.current = nil }
    }

    /// Hide the overlay first, then act on the selection once the dim layer is off the screen.
    func run(_ mode: Mode) {
        let r = rect.integral
        let s = selectionScreen
        AllInOne.lastRect = r
        close()
        if previousApp?.processIdentifier != getpid() { previousApp?.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            switch mode {
            case .screenshot: Capture.capture(rect: r, screen: s)
            case .window: Capture.area(windowMode: true)
            case .fullscreen: Capture.fullscreen()
            case .scrolling: ScrollCapture.begin(rect: r, screen: s)
            case .ocr: OCR.captureText(rect: r, screen: s)
            case .pin: Capture.capture(rect: r, screen: s) { Pinner.pin($0) }
            case .video: Recorder.shared.record(rect: r, screen: s, gif: false)
            case .gif: Recorder.shared.record(rect: r, screen: s, gif: true)
            }
        }
    }
}

final class AllInOneWindow: NSWindow {
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
}

final class AllInOneView: NSView {
    let screen: NSScreen
    unowned let owner: AllInOne
    private enum Drag { case none, new(CGPoint), move(CGPoint, CGRect), resize((x: Int, y: Int), CGPoint, CGRect) }
    private var drag: Drag = .none
    private let handleSize: CGFloat = 9

    init(frame: CGRect, screen: NSScreen, owner: AllInOne) {
        self.screen = screen
        self.owner = owner
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    private var local: CGRect { owner.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY) }

    private func handles(_ r: CGRect) -> [((x: Int, y: Int), CGPoint)] {
        var out: [((x: Int, y: Int), CGPoint)] = []
        for hx in [-1, 0, 1] { for hy in [-1, 0, 1] where !(hx == 0 && hy == 0) {
            let x = hx < 0 ? r.minX : hx > 0 ? r.maxX : r.midX
            let y = hy < 0 ? r.minY : hy > 0 ? r.maxY : r.midY
            out.append(((hx, hy), CGPoint(x: x, y: y)))
        } }
        return out
    }

    private func handle(at p: CGPoint) -> (x: Int, y: Int)? {
        for (h, c) in handles(local) where abs(p.x - c.x) <= 8 && abs(p.y - c.y) <= 8 { return h }
        return nil
    }

    override func mouseMoved(with event: NSEvent) { cursor(for: convert(event.locationInWindow, from: nil)).set() }
    override func cursorUpdate(with event: NSEvent) { cursor(for: convert(event.locationInWindow, from: nil)).set() }

    private func cursor(for p: CGPoint) -> NSCursor {
        if let h = handle(at: p) {
            if h.x == 0 { return .resizeUpDown }
            if h.y == 0 { return .resizeLeftRight }
            return .crosshair
        }
        return local.contains(p) ? .openHand : .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        if let h = handle(at: p) { drag = .resize(h, p, owner.rect) }
        else if local.contains(p) { drag = .move(p, owner.rect); NSCursor.closedHand.set() }
        else { drag = .new(p) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none: return
        case .new(let a):
            owner.rect = Geo.rect(from: global(a), to: global(p)).intersection(screen.frame)
        case .move(let a, let start):
            owner.rect = Geo.clampMove(start.offsetBy(dx: p.x - a.x, dy: p.y - a.y), into: screen.frame)
        case .resize(let h, let a, let start):
            owner.rect = Geo.resize(start, handle: h, by: CGVector(dx: p.x - a.x, dy: p.y - a.y), minSize: 8).intersection(screen.frame)
        }
        owner.rect = owner.rect.integral
        owner.rectChanged()
    }

    override func mouseUp(with event: NSEvent) {
        if case .new = drag, owner.rect.width < 8 || owner.rect.height < 8 {
            owner.rect = screen.frame      // a click = whole screen
            owner.rectChanged()
        }
        drag = .none
    }

    override func rightMouseDown(with event: NSEvent) { owner.close() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = local.intersection(bounds)
        let path = CGMutablePath()
        path.addRect(bounds)
        if !r.isEmpty { path.addRect(r) }
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.fillPath(using: .evenOdd)
        guard !r.isEmpty else { return }

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.setLineDash(phase: 0, lengths: [])

        for (_, c) in handles(r) {
            let hr = CGRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2, width: handleSize, height: handleSize)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: hr)
            ctx.setShadow(offset: .zero, blur: 0)
        }
    }
}

/// The compact dark toolbar under the selection.
final class AllInOneToolbar: NSPanel, NSTextFieldDelegate {
    unowned let owner: AllInOne
    private let wField = NSTextField()
    private let hField = NSTextField()

    init(owner: AllInOne) {
        self.owner = owner
        super.init(contentRect: CGRect(x: 0, y: 0, width: 100, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 9
        bg.layer?.masksToBounds = true

        func btn(_ m: AllInOne.Mode) -> NSButton {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let b = NSButton(image: NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title)!.withSymbolConfiguration(cfg)!,
                             target: self, action: #selector(modeAction(_:)))
            b.isBordered = false
            b.contentTintColor = m == .video || m == .gif ? NSColor.systemRed.blended(withFraction: 0.25, of: .white) : .white
            b.toolTip = m.title
            b.identifier = NSUserInterfaceItemIdentifier(m.rawValue)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        func sep() -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            v.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return v
        }
        for f in [wField, hField] {
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.alignment = .center
            f.isBordered = false
            f.drawsBackground = true
            f.backgroundColor = NSColor.white.withAlphaComponent(0.1)
            f.textColor = .white
            f.focusRingType = .none
            f.delegate = self
            f.wantsLayer = true
            f.layer?.cornerRadius = 4
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 46).isActive = true
            f.target = self
            f.action = #selector(sizeEdited)
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        times.font = .systemFont(ofSize: 11)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")!
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))!, target: self, action: #selector(closeAction))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Cancel (Esc)"

        let views: [NSView] = [btn(.screenshot), btn(.window), btn(.fullscreen), sep(),
                               btn(.scrolling), btn(.ocr), btn(.pin), sep(),
                               btn(.video), btn(.gif), sep(),
                               wField, times, hField, sep(), close]
        let stack = NSStackView(views: views)
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        contentView = bg
        setContentSize(stack.fittingSize)
        initialFirstResponder = nil
        makeFirstResponder(nil)
    }

    override var canBecomeKey: Bool { true }

    func setSize(_ s: CGSize) {
        let editing = isKeyWindow
        if !editing || wField.currentEditor() == nil { wField.stringValue = "\(Int(s.width))" }
        if !editing || hField.currentEditor() == nil { hField.stringValue = "\(Int(s.height))" }
    }

    /// Under the selection, or inside its bottom edge when there is no room, always on-screen.
    func place(below r: CGRect, on screen: NSScreen) {
        let vf = screen.frame
        let size = frame.size
        var x = r.midX - size.width / 2
        var y = r.minY - size.height - 12
        if y < vf.minY + 8 { y = r.minY + 12 }
        if y < vf.minY + 8 { y = vf.minY + 8 }
        x = min(max(vf.minX + 8, x), vf.maxX - size.width - 8)
        setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
    }

    @objc private func modeAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let m = AllInOne.Mode(rawValue: raw) else { return }
        owner.run(m)
    }
    @objc private func closeAction() { owner.close() }
    @objc private func sizeEdited() {
        owner.setSize(width: Double(wField.stringValue).map { CGFloat($0) }, height: Double(hField.stringValue).map { CGFloat($0) })
        makeFirstResponder(nil)
    }
}
