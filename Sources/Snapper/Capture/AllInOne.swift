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
    var toolbarWindow: NSWindow? { toolbar }
    private var monitor: Any?
    private let previousApp = NSWorkspace.shared.frontmostApplication

    // Record mode (after pressing Record Video / Record GIF): pick Area / Window / Fullscreen, then Record.
    enum Target: Int { case area, window, fullscreen }
    private(set) var recordMode: Mode?          // .video or .gif while choosing what to record
    private(set) var target: Target = .area
    private var areaRect: CGRect = .zero
    private(set) var lockedWindow: CGWindowID?
    private var windowList: [(id: CGWindowID, rect: CGRect, owner: String)] = []

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
        let tb = AllInOneToolbar(owner: self, recording: nil)
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
        case 53: if recordMode != nil { leaveRecordMode() } else { close() }; return true
        case 36, 76: recordMode != nil ? startRecording() : run(.screenshot); return true
        case 123: nudge(-step, 0); return true
        case 124: nudge(step, 0); return true
        case 125: nudge(0, -step); return true
        case 126: nudge(0, step); return true
        default: return false
        }
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard recordMode == nil || target == .area else { return }
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

    // MARK: record mode

    func enterRecordMode(_ m: Mode) {
        recordMode = m
        areaRect = rect
        rebuildToolbar()
        setTarget(Target(rawValue: Prefs.shared.recordTarget) ?? .area)
    }

    func leaveRecordMode() {
        if target != .area { rect = areaRect }
        recordMode = nil
        target = .area
        lockedWindow = nil
        rebuildToolbar()
        rectChanged()
    }

    func setTarget(_ t: Target) {
        if target == .area && t != .area { areaRect = rect }
        target = t
        Prefs.shared.recordTarget = t.rawValue
        lockedWindow = nil
        switch t {
        case .area: rect = areaRect
        case .fullscreen: rect = NSScreen.underMouse.frame
        case .window:
            windowList = ScreenGrabber.windowList()
            rect = .zero
            hoverWindow(at: NSEvent.mouseLocation)
        }
        toolbar?.recordTargetChanged(t)
        rectChanged()
    }

    private func windowRect(at p: CGPoint) -> (CGWindowID, CGRect)? {
        guard let w = windowList.first(where: { $0.rect.contains(p) }) else { return nil }
        return (w.id, w.rect.intersection(screenFrame(for: w.rect)).integral)
    }

    /// Window target: highlight the window under the pointer until one is clicked.
    func hoverWindow(at p: CGPoint) {
        guard target == .window, lockedWindow == nil else { return }
        let r = windowRect(at: p)?.1 ?? .zero
        if r != rect { rect = r; rectChanged() }
    }

    func lockWindow(at p: CGPoint) {
        guard target == .window, let (id, r) = windowRect(at: p) else { return }
        lockedWindow = id
        rect = r
        rectChanged()
    }

    func toggleCountdown() {
        Prefs.shared.recordCountdown.toggle()
        toolbar?.recordTargetChanged(target)
    }

    func startRecording() {
        guard let m = recordMode, rect.width >= 8, rect.height >= 8 else { NSSound.beep(); return }
        let r = rect.integral
        let s = selectionScreen
        if target == .area { AllInOne.lastRect = r } else { AllInOne.lastRect = areaRect }
        close()
        if previousApp?.processIdentifier != getpid() { previousApp?.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            Recorder.shared.record(rect: r, screen: s, gif: m == .gif)
        }
    }

    private func rebuildToolbar() {
        toolbar?.orderOut(nil)
        let tb = AllInOneToolbar(owner: self, recording: recordMode)
        toolbar = tb
        tb.orderFrontRegardless()
        rectChanged()
    }

    /// Hide the overlay first, then act on the selection once the dim layer is off the screen.
    func run(_ mode: Mode) {
        if mode == .video || mode == .gif { enterRecordMode(mode); return }
        let r = rect.integral
        let s = selectionScreen
        if r.width >= 8 { AllInOne.lastRect = r }
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
        // The selection is drawn fully transparent; without this macOS sends clicks there to the app behind,
        // so the box could never be grabbed and moved.
        ignoresMouseEvents = false
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

    private var areaEditable: Bool { owner.recordMode == nil || owner.target == .area }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if owner.recordMode != nil && owner.target == .window { owner.hoverWindow(at: global(p)); NSCursor.pointingHand.set(); return }
        cursor(for: p).set()
    }
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
        if owner.recordMode != nil {
            switch owner.target {
            case .window:
                owner.lockWindow(at: global(p))
                if event.clickCount >= 2 { owner.startRecording() }
                drag = .none; return
            case .fullscreen:
                // Dragging out a new rectangle switches back to Area.
                owner.setTarget(.area); drag = .new(p); return
            case .area: break
            }
        }
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
        // Invisible, but non-zero alpha so the window keeps receiving clicks inside the box.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.004).cgColor)
        ctx.fill(r)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.setLineDash(phase: 0, lengths: [])

        if owner.recordMode != nil && owner.target == .window {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(owner.lockedWindow != nil ? 3 : 2)
            ctx.stroke(r.insetBy(dx: 1, dy: 1))
            return
        }
        guard areaEditable else { return }
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

    private var targetButtons: [NSButton] = []
    private var timerButton: NSButton?
    private var sizeViews: [NSView] = []

    init(owner: AllInOne, recording: AllInOne.Mode?) {
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

        let views: [NSView]
        if let recording {
            func icon(_ name: String, _ tip: String, _ action: Selector, size: CGFloat = 13) -> NSButton {
                let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tip)!
                    .withSymbolConfiguration(.init(pointSize: size, weight: .regular))!, target: self, action: action)
                b.isBordered = false
                b.contentTintColor = .white
                b.toolTip = tip
                b.wantsLayer = true
                b.layer?.cornerRadius = 5
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 28).isActive = true
                b.heightAnchor.constraint(equalToConstant: 26).isActive = true
                return b
            }
            let back = icon("chevron.left", "Back (Esc)", #selector(backAction), size: 11)
            back.contentTintColor = .secondaryLabelColor
            let targets: [(String, String)] = [("rectangle.dashed", "Record Area"), ("macwindow", "Record Window — click a window"),
                                               ("display", "Record Fullscreen")]
            targetButtons = targets.enumerated().map { i, t in
                let b = icon(t.0, t.1, #selector(targetAction(_:)))
                b.tag = i
                return b
            }
            let timer = NSButton(title: "", target: self, action: #selector(timerAction))
            timer.isBordered = false
            timer.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Countdown")!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            timer.imagePosition = .imageLeading
            timer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            timer.translatesAutoresizingMaskIntoConstraints = false
            timer.widthAnchor.constraint(equalToConstant: 46).isActive = true
            timer.heightAnchor.constraint(equalToConstant: 26).isActive = true
            timerButton = timer

            let rec = NSButton(title: recording == .gif ? "Record GIF" : "Record", target: self, action: #selector(recordAction))
            rec.isBordered = false
            rec.wantsLayer = true
            rec.layer?.backgroundColor = NSColor.systemRed.cgColor
            rec.layer?.cornerRadius = 6
            rec.attributedTitle = NSAttributedString(string: recording == .gif ? "Record GIF" : "Record",
                                                     attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)])
            rec.toolTip = "Start recording (↩)"
            rec.translatesAutoresizingMaskIntoConstraints = false
            rec.heightAnchor.constraint(equalToConstant: 22).isActive = true
            rec.widthAnchor.constraint(equalToConstant: recording == .gif ? 82 : 60).isActive = true

            let sizeSep = sep()
            sizeViews = [wField, times, hField, sizeSep]
            views = [back, sep()] + targetButtons + [sep(), wField, times, hField, sizeSep, timer, rec, sep(), close]
        } else {
            views = [btn(.screenshot), btn(.window), btn(.fullscreen), sep(),
                     btn(.scrolling), btn(.ocr), btn(.pin), sep(),
                     btn(.video), btn(.gif), sep(),
                     wField, times, hField, sep(), close]
        }
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
    @objc private func backAction() { owner.leaveRecordMode() }
    @objc private func targetAction(_ sender: NSButton) { owner.setTarget(AllInOne.Target(rawValue: sender.tag) ?? .area) }
    @objc private func timerAction() { owner.toggleCountdown() }
    @objc private func recordAction() { owner.startRecording() }

    /// Highlight the chosen target, show W×H only for Area, and the countdown state.
    func recordTargetChanged(_ t: AllInOne.Target) {
        for b in targetButtons {
            let on = b.tag == t.rawValue
            b.layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.2).cgColor : NSColor.clear.cgColor
            b.contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.6)
        }
        sizeViews.forEach { $0.isHidden = t != .area }
        if let timer = timerButton {
            let on = Prefs.shared.recordCountdown
            timer.attributedTitle = NSAttributedString(string: on ? "3s" : "Off", attributes: [
                .foregroundColor: on ? NSColor.white : NSColor.white.withAlphaComponent(0.45),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
            timer.contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.45)
            timer.toolTip = on ? "Countdown 3-2-1 is on — click to start recording instantly" : "No countdown — click to turn the 3-2-1 back on"
        }
        if let stack = contentView?.subviews.first { setContentSize(stack.fittingSize) }
    }
    @objc private func sizeEdited() {
        owner.setSize(width: Double(wField.stringValue).map { CGFloat($0) }, height: Double(hField.stringValue).map { CGFloat($0) })
        makeFirstResponder(nil)
    }
}

