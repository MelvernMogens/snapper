import AppKit
import SnapKit

/// Pin to screen: borderless floating windows showing a capture at 1:1. Drag to move, scroll/pinch/⌘± to zoom,
/// double-click or Esc to close, right-click for Copy / Save / Opacity / Lock (click-through) / Close.
enum Pinner {
    private(set) static var pins: [PinWindow] = []

    static func pin(_ item: CaptureItem) {
        guard item.kind == .screenshot, let img = item.image ?? ToolsImage.load(item.fileURL) else { NSSound.beep(); return }
        var size = item.pointSize
        if size.width < 1 || size.height < 1 {
            let s = ToolsImage.defaultScale
            size = CGSize(width: CGFloat(img.width) / s, height: CGFloat(img.height) / s)
        }
        // Put it back where it was captured when the last area selection matches this capture.
        var frame: CGRect
        if let last = Capture.lastArea, abs(last.rect.width - size.width) < 1, abs(last.rect.height - size.height) < 1,
           NSScreen.screens.contains(where: { $0.frame.intersects(last.rect) }) {
            frame = last.rect
        } else {
            let vf = NSScreen.underMouse.visibleFrame
            var s = size
            let fit = min(1, (vf.width * 0.9) / s.width, (vf.height * 0.9) / s.height)
            s = CGSize(width: (s.width * fit).rounded(), height: (s.height * fit).rounded())
            frame = CGRect(x: (vf.midX - s.width / 2).rounded(), y: (vf.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        }
        // Cascade if another pin already sits exactly there.
        while pins.contains(where: { $0.frame.origin == frame.origin }) { frame = frame.offsetBy(dx: 18, dy: -18) }
        let w = PinWindow(image: img, naturalSize: size, frame: frame, item: item)
        pins.append(w)
        w.alphaValue = 0
        w.orderFrontRegardless()
        w.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
    }

    static func remove(_ w: PinWindow) {
        pins.removeAll { $0 === w }
    }

    static func closeAll() { for p in pins { p.orderOut(nil) }; pins.removeAll() }
    static func unlockAll() { for p in pins where p.locked { p.setLocked(false) } }
    static var anyLocked: Bool { pins.contains { $0.locked } }

    @MainActor
    static func registerCLI() {
        CLI.extra["--pin-file"] = { args in
            guard let path = args.first else { ToolsCLI.err("usage: --pin-file IN.png"); return 2 }
            do {
                let img = try ToolsImage.load(path: path)
                let s = ToolsImage.defaultScale
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                pin(CaptureItem(kind: .screenshot, image: img, fileURL: url, savedURL: nil, historyID: nil,
                                pointSize: CGSize(width: CGFloat(img.width) / s, height: CGFloat(img.height) / s)))
                ToolsCLI.out("pinned \(img.width)x\(img.height)")
                return await ToolsCLI.stayAlive()
            } catch { ToolsCLI.err("error: \(error.localizedDescription)"); return 1 }
        }
    }
}

final class PinWindow: NSPanel {
    let image: CGImage
    let naturalSize: CGSize
    let item: CaptureItem
    private(set) var scale: CGFloat
    private(set) var locked = false
    private var pinView: PinView { contentView as! PinView }

    init(image: CGImage, naturalSize: CGSize, frame: CGRect, item: CaptureItem) {
        self.image = image
        self.naturalSize = naturalSize
        self.item = item
        self.scale = naturalSize.width > 0 ? frame.width / naturalSize.width : 1
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(frame: CGRect(origin: .zero, size: frame.size), image: image, owner: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: zoom
    func setScale(_ s: CGFloat, anchor: CGPoint? = nil) {
        let ns = min(max(s, 0.1), 8)
        guard abs(ns - scale) > 0.0001 else { return }
        let old = frame
        let size = CGSize(width: max(24, (naturalSize.width * ns).rounded()), height: max(16, (naturalSize.height * ns).rounded()))
        // Keep the point under the cursor (or the centre) fixed.
        let a = anchor ?? CGPoint(x: old.midX, y: old.midY)
        let fx = old.width > 0 ? (a.x - old.minX) / old.width : 0.5
        let fy = old.height > 0 ? (a.y - old.minY) / old.height : 0.5
        let nf = CGRect(x: (a.x - fx * size.width).rounded(), y: (a.y - fy * size.height).rounded(), width: size.width, height: size.height)
        scale = ns
        setFrame(nf, display: true)
        pinView.showBadge("\(Int((ns * 100).rounded()))%")
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) { setScale(scale * factor, anchor: anchor) }

    // MARK: actions
    @objc func copyImage() {
        Output.copyToClipboard(image, pointSize: naturalSize)
        pinView.showBadge("Copied")
    }

    @objc func saveImage() {
        let panel = NSSavePanel()
        let ext = Prefs.shared.imageFormat == .png ? "png" : "jpg"
        panel.nameFieldStringValue = Naming.filename(.screenshot, date: Date(), ext: ext)
        panel.directoryURL = Prefs.shared.saveDirectory
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fmt: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        do {
            guard let d = Output.encode(image, format: fmt) else { throw GrabError(message: "Could not encode image") }
            try d.write(to: url)
        } catch { Permissions.showError("Save failed", error) }
    }

    @objc func setOpacityFromMenu(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc func actualSize() { setScale(1) }
    @objc func toggleLock() { setLocked(!locked) }
    @objc func closePin() {
        Pinner.remove(self)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 }, completionHandler: { self.orderOut(nil) })
    }
    @objc func closeAllPins() { Pinner.closeAll() }
    @objc func unlockAllPins() { Pinner.unlockAll() }

    func setLocked(_ on: Bool) {
        locked = on
        ignoresMouseEvents = on
        pinView.needsDisplay = true
        if on { pinView.showBadge("Locked — click-through") }
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "", _ symbol: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            m.addItem(i)
            return i
        }
        _ = add("Copy", #selector(copyImage), "c", "doc.on.doc")
        _ = add("Save…", #selector(saveImage), "s", "square.and.arrow.down")
        m.addItem(.separator())
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        op.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let sub = NSMenu()
        for v in [100, 75, 50, 25] {
            let i = NSMenuItem(title: "\(v)%", action: #selector(setOpacityFromMenu(_:)), keyEquivalent: "")
            i.target = self; i.tag = v
            i.state = abs(alphaValue * 100 - CGFloat(v)) < 1 ? .on : .off
            sub.addItem(i)
        }
        op.submenu = sub
        m.addItem(op)
        let zoomItem = add("Actual Size (\(Int((scale * 100).rounded()))%)", #selector(actualSize), "0", "1.magnifyingglass")
        zoomItem.isEnabled = abs(scale - 1) > 0.001
        _ = add("Lock (Click-Through)", #selector(toggleLock), "", "lock")
        m.addItem(.separator())
        _ = add("Close", #selector(closePin), "w", "xmark")
        if Pinner.pins.count > 1 { _ = add("Close All Pins (\(Pinner.pins.count))", #selector(closeAllPins), "", "xmark.square") }
        if Pinner.anyLocked { _ = add("Unlock All Pins", #selector(unlockAllPins), "", "lock.open") }
        return m
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        let ch = e.charactersIgnoringModifiers ?? ""
        if e.keyCode == 53 { closePin(); return }                       // Esc
        if cmd {
            switch ch {
            case "=", "+": zoom(by: 1.25); return
            case "-", "_": zoom(by: 0.8); return
            case "0": actualSize(); return
            case "c": copyImage(); return
            case "s": saveImage(); return
            case "w": closePin(); return
            default: break
            }
        }
        super.keyDown(with: e)
    }
}

final class PinView: NSView {
    let image: CGImage
    unowned let owner: PinWindow
    private var badge: NSTextField?
    private var badgeGen = 0

    init(frame: CGRect, image: CGImage, owner: PinWindow) {
        self.image = image
        self.owner = owner
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.borderColor = (owner.locked ? NSColor.systemOrange.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.22)).cgColor
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { owner.closePin(); return }
        owner.makeKey()
        owner.performDrag(with: e)
    }

    override func rightMouseDown(with e: NSEvent) {
        owner.makeKey()
        NSMenu.popUpContextMenu(owner.buildMenu(), with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        guard dy != 0 else { return }
        owner.zoom(by: exp(dy * 0.006), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with e: NSEvent) {
        owner.zoom(by: 1 + e.magnification, anchor: NSEvent.mouseLocation)
    }

    func showBadge(_ text: String) {
        badge?.removeFromSuperview()
        let l = NSTextField(labelWithString: text)
        l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.wantsLayer = true
        l.drawsBackground = false
        l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        l.layer?.cornerRadius = 5
        l.sizeToFit()
        let w = l.frame.width + 14, h: CGFloat = 20
        l.frame = CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
        l.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(l)
        badge = l
        badgeGen += 1
        let g = badgeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, g == self.badgeGen else { return }
            self.badge?.removeFromSuperview(); self.badge = nil
        }
    }
}
