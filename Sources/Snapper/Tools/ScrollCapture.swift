import AppKit
import ApplicationServices
import ScreenCaptureKit
import SnapKit

/// Scrolling capture: pick an area on the live screen, scroll it (by hand, or auto-scroll when Accessibility is
/// granted), and Snapper stitches the frames into one tall image. Done → Quick Access like any screenshot.
enum ScrollCapture {
    private(set) static var session: ScrollSession?

    static func start() {
        guard session == nil, OverlayController.current == nil, Permissions.ensureScreenRecording() else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        OverlayController.begin(allowWindowMode: false, hint: "Select the area to scroll-capture, then scroll") { r in
            guard let r, r.rect.width >= 40, r.rect.height >= 40 else { return }
            if previous?.processIdentifier != getpid() { previous?.activate() }
            begin(rect: r.rect.integral, screen: r.screen)
        }
    }

    static func begin(rect: CGRect, screen: NSScreen) {
        let s = ScrollSession(rect: rect, screen: screen)
        session = s
        s.run()
    }

    fileprivate static func ended() { session = nil }

    /// Stitch already-captured frames (same size, top-to-bottom order). Frames that didn't move or can't be matched are skipped.
    static func stitch(_ frames: [CGImage]) -> (image: CGImage, offsets: [Int], bands: (top: Int, bottom: Int))? {
        guard let first = frames.first else { return nil }
        var kept = [first]
        var offsets: [Int] = []
        var bands: (top: Int, bottom: Int) = (0, 0)
        var prevGray = ToolsImage.gray(first)
        for f in frames.dropFirst() where f.width == first.width && f.height == first.height {
            let g = ToolsImage.gray(f)
            guard let off = Stitcher.findOffset(prev: prevGray, next: g), off > 0 else { continue }
            if offsets.isEmpty { bands = Stitcher.fixedBands(prev: prevGray, next: g, offset: off) }
            offsets.append(off); kept.append(f); prevGray = g
        }
        let slices = Stitcher.plan(frameHeight: first.height, offsets: offsets, top: bands.top, bottom: bands.bottom)
        let parts = slices.compactMap { ToolsImage.copyRows(kept[$0.frame], $0.rows) }
        guard let img = ToolsImage.stack(parts) else { return nil }
        return (img, offsets, bands)
    }

    @MainActor
    static func registerCLI() {
        CLI.extra["--stitch-test"] = { _ in
            // Synthetic "document": text-like blocks on white, 1200 rows; two 500-row frames 137 rows apart.
            let w = 320, h = 1200
            var px = [UInt8](repeating: 250, count: w * h)
            var seed: UInt32 = 12345
            func rnd() -> UInt32 { seed = seed &* 1664525 &+ 1013904223; return seed >> 8 }
            var y = 8
            while y < h - 20 {
                let lineH = 10 + Int(rnd() % 8)
                var x = 10
                while x < w - 30 {
                    let wordW = 8 + Int(rnd() % 40)
                    let shade = UInt8(20 + rnd() % 90)
                    for yy in y..<min(h, y + lineH) where rnd() % 5 != 0 {
                        for xx in x..<min(w, x + wordW) where rnd() % 3 != 0 { px[yy * w + xx] = shade }
                    }
                    x += wordW + 6
                }
                y += lineH + 6 + Int(rnd() % 14)
            }
            let full = GrayImage(width: w, height: h, pixels: px)
            func crop(_ top: Int, _ rows: Int) -> GrayImage {
                GrayImage(width: w, height: rows, pixels: Array(full.pixels[(top * w)..<((top + rows) * w)]))
            }
            let a = crop(300, 500), b = crop(437, 500)
            let t0 = Date()
            let off = Stitcher.findOffset(prev: a, next: b)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            ToolsCLI.out("expected=137 found=\(off.map(String.init) ?? "nil") (\(ms) ms)")
            ToolsCLI.out("identical=\(Stitcher.findOffset(prev: a, next: a).map(String.init) ?? "nil") tooFar=\(Stitcher.findOffset(prev: crop(0, 500), next: crop(650, 500)).map(String.init) ?? "nil")")
            return off == 137 ? 0 : 1
        }
        CLI.extra["--scroll-stitch"] = { args in
            guard args.count >= 3 else { ToolsCLI.err("usage: --scroll-stitch A.png B.png [C.png …] OUT.png"); return 2 }
            do {
                let frames = try args.dropLast().map { try ToolsImage.load(path: $0) }
                guard let r = stitch(frames) else { ToolsCLI.err("stitch failed"); return 1 }
                try ToolsImage.write(r.image, to: args.last!)
                ToolsCLI.out("offsets=\(r.offsets) header=\(r.bands.top) footer=\(r.bands.bottom) out=\(r.image.width)x\(r.image.height)")
                return r.offsets.isEmpty ? 1 : 0
            } catch { ToolsCLI.err("error: \(error.localizedDescription)"); return 1 }
        }
        // Start a session on a fixed rect without the picker (UI check / manual testing).
        CLI.extra["--scroll-ui"] = { args in
            let n = (args.first ?? "").split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else { ToolsCLI.err("usage: --scroll-ui x,y,w,h"); return 2 }
            let r = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            let s = NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.screens[0]
            begin(rect: r, screen: s)
            return await ToolsCLI.stayAlive()
        }
    }
}

/// One running scrolling capture: border + control pill + capture loop.
final class ScrollSession {
    let rect: CGRect               // AppKit global points
    let screen: NSScreen
    let maxHeightPx = 32_000

    private var border: NSPanel?
    private var pill: ScrollPill?
    private var loop: Task<Void, Never>?
    private var content: SCShareableContent?

    // Stitch state
    private var first: CGImage?                 // first frame, until the header/footer bands are known
    private var parts: [CGImage] = []           // finished strips, top-to-bottom
    private var lastFrame: CGImage?
    private var lastGray: GrayImage?
    private var bands: (top: Int, bottom: Int)?
    private var totalHeight = 0
    private var mismatches = 0
    private var stillFrames = 0
    private(set) var autoScrolling = false
    private var finished = false

    init(rect: CGRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
    }

    func run() {
        showBorder()
        let p = ScrollPill(session: self, canAutoScroll: AXIsProcessTrusted())
        pill = p
        p.place(near: rect, on: screen)
        p.orderFrontRegardless()
        loop = Task { @MainActor [weak self] in
            // Fetch shareable content after our panels exist so they're excluded from the frames.
            try? await Task.sleep(nanoseconds: 80_000_000)
            while let self, !self.finished {
                await self.tick()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    @MainActor
    private func tick() async {
        do {
            if content == nil { content = try await ScreenGrabber.content() }
            let shot = try await ScreenGrabber.captureDisplay(screen.displayID, content: content)
            guard !finished else { return }
            let crop = try Capture.crop(shot, global: rect, screen: screen)
            ingest(crop)
            if autoScrolling { postScroll() }
        } catch {
            finished = true
            teardown()
            Permissions.showError("Scrolling capture failed", error)
        }
    }

    private func ingest(_ frame: CGImage) {
        let g = ToolsImage.gray(frame)
        guard let prev = lastGray, let prevFrame = lastFrame else {
            first = ToolsImage.copyRows(frame, 0..<frame.height)
            lastFrame = first; lastGray = g; totalHeight = frame.height
            pill?.update(frames: 1, height: totalHeight, warning: nil)
            return
        }
        guard frame.width == prevFrame.width, frame.height == prevFrame.height else { return }
        switch Stitcher.findOffset(prev: prev, next: g) {
        case .none:
            mismatches += 1
            pill?.update(frames: parts.count + 1, height: totalHeight, warning: mismatches > 2 ? "Scroll slower" : nil)
            return
        case .some(let off) where off <= 0:
            stillFrames += 1
            // Auto-scroll reached the end of the page.
            if autoScrolling && stillFrames >= 4 { done() }
            return
        case .some(let off):
            mismatches = 0; stillFrames = 0
            let h = frame.height
            if bands == nil, let f = first {
                let b = Stitcher.fixedBands(prev: prev, next: g, offset: off)
                bands = b
                if let head = ToolsImage.copyRows(f, 0..<(h - b.bottom)) { parts.append(head) }
                first = nil
            }
            let b = bands ?? (0, 0)
            let lo = max(b.top, h - b.bottom - off), hi = h - b.bottom
            if hi > lo, let strip = ToolsImage.copyRows(frame, lo..<hi) { parts.append(strip); totalHeight += hi - lo }
            lastFrame = ToolsImage.copyRows(frame, 0..<h)   // own memory, so the display shot is released
            lastGray = g
            pill?.update(frames: parts.count, height: totalHeight, warning: nil)
            if totalHeight >= maxHeightPx { done() }
        }
    }

    // MARK: auto-scroll (Accessibility needed to post events)
    func toggleAutoScroll() {
        guard AXIsProcessTrusted() else {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            return
        }
        autoScrolling.toggle()
        stillFrames = 0
        if autoScrolling {
            // Scroll events go to the window under the pointer: park it in the middle of the area.
            let ph = NSScreen.primaryHeight
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: ph - rect.midY))
        }
        pill?.setAutoScrolling(autoScrolling)
    }

    private func postScroll() {
        let px = Int32(max(40, rect.height * 0.35))
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -px, wheel2: 0, wheel3: 0) else { return }
        let ph = NSScreen.primaryHeight
        e.location = CGPoint(x: rect.midX, y: ph - rect.midY)
        e.post(tap: .cghidEventTap)
    }

    // MARK: finish
    func done() {
        guard !finished else { return }
        finished = true
        autoScrolling = false
        loop?.cancel()
        var pieces = parts
        if let f = first { pieces = [f] }                                  // never moved: just the one frame
        else if let b = bands, b.bottom > 0, let last = lastFrame,
                let foot = ToolsImage.copyRows(last, (last.height - b.bottom)..<last.height) { pieces.append(foot) }
        teardown()
        guard let img = ToolsImage.stack(pieces) else { NSSound.beep(); return }
        let scale = screen.backingScaleFactor
        do {
            _ = try Output.finish(img, kind: .screenshot, pointSize: CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
        } catch { Permissions.showError("Scrolling capture failed", error) }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        loop?.cancel()
        teardown()
    }

    private func teardown() {
        border?.orderOut(nil); border = nil
        pill?.orderOut(nil); pill = nil
        parts.removeAll(); first = nil; lastFrame = nil
        ScrollCapture.ended()
    }

    private func showBorder() {
        let pad: CGFloat = 3
        let f = rect.insetBy(dx: -pad, dy: -pad)
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let v = NSView(frame: CGRect(origin: .zero, size: f.size))
        v.wantsLayer = true
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 4
        v.layer?.borderColor = NSColor.systemTeal.cgColor
        p.contentView = v
        p.orderFrontRegardless()
        border = p
    }
}

/// The compact dark control pill shown next to the area: status · Auto-scroll · Cancel · Done.
final class ScrollPill: NSPanel {
    weak var session: ScrollSession?
    private let status = NSTextField(labelWithString: "Scroll down…")
    private let detail = NSTextField(labelWithString: "")
    private var autoBtn: NSButton?

    init(session: ScrollSession, canAutoScroll: Bool) {
        self.session = session
        super.init(contentRect: CGRect(x: 0, y: 0, width: 300, height: 38), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.3; pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = .white
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor.white.withAlphaComponent(0.6)
        detail.stringValue = "0 px"
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 92).isActive = true
        detail.alignment = .right
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(equalToConstant: 62).isActive = true

        var views: [NSView] = [dot, status, detail]
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
        views.append(sep)
        let a = button("Auto-scroll", #selector(autoAction), primary: false)
        a.toolTip = canAutoScroll ? "Scroll automatically until the end of the page" : "Needs Accessibility permission (click to request)"
        a.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        a.imagePosition = .imageLeading
        autoBtn = a
        views += [a, button("Cancel", #selector(cancelAction), primary: false), button("Done", #selector(doneAction), primary: true)]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(6, after: dot)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        contentView = bg
        let fit = stack.fittingSize
        setContentSize(CGSize(width: max(280, fit.width + 4), height: 38))
    }

    override var canBecomeKey: Bool { false }

    private func button(_ title: String, _ sel: Selector, primary: Bool) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11, weight: primary ? .semibold : .regular)
        if primary { b.keyEquivalent = "\r"; b.bezelColor = .systemTeal }
        return b
    }

    func place(near r: CGRect, on screen: NSScreen) {
        let vf = screen.visibleFrame
        let size = frame.size
        var x = (r.midX - size.width / 2).rounded()
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        var y = r.minY - size.height - 12                                     // below
        if y < vf.minY + 8 { y = r.maxY + 12 }                                // above
        if y + size.height > vf.maxY - 8 { y = r.minY + 16 }                  // inside, bottom edge
        setFrameOrigin(CGPoint(x: x, y: y))
    }

    func update(frames: Int, height: Int, warning: String?) {
        status.stringValue = warning ?? (frames <= 1 ? "Scroll down…" : "Capturing")
        status.textColor = warning == nil ? .white : .systemOrange
        let f = NumberFormatter(); f.numberStyle = .decimal
        detail.stringValue = "\(f.string(from: NSNumber(value: height)) ?? "\(height)") px"
    }

    func setAutoScrolling(_ on: Bool) {
        autoBtn?.title = on ? "Stop" : "Auto-scroll"
        autoBtn?.image = NSImage(systemSymbolName: on ? "pause.circle" : "arrow.down.circle", accessibilityDescription: nil)
    }

    @objc private func autoAction() { session?.toggleAutoScroll() }
    @objc private func cancelAction() { session?.cancel() }
    @objc private func doneAction() { session?.done() }
}
