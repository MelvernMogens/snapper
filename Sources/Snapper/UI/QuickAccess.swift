import AppKit
import SnapKit

/// Floating thumbnail cards stacked in the bottom-left corner after each capture (CleanShot's "Quick Access Overlay").
/// Hover shows a compact icon row; drag the card out to drop the file anywhere; double-click opens Annotate.
final class QuickAccess {
    static let shared = QuickAccess()
    private(set) var cards: [QuickAccessCard] = []
    let cardWidth: CGFloat = 196
    let margin: CGFloat = 14
    let gap: CGFloat = 10

    func present(_ item: CaptureItem) {
        let card = QuickAccessCard(item: item, owner: self)
        cards.insert(card, at: 0)
        while cards.count > 5 { cards.removeLast().close(animated: false) }
        layout(animated: true, newCard: card)
        let secs = Prefs.shared.quickAccessAutoClose
        if secs > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs)) { [weak card] in
            guard let card, !card.isHovered else { return }
            self.dismiss(card)
        } }
    }

    func dismiss(_ card: QuickAccessCard) {
        cards.removeAll { $0 === card }
        card.close(animated: true)
        layout(animated: true, newCard: nil)
    }

    func dismissAll() { for c in cards { c.close(animated: false) }; cards.removeAll() }

    private func layout(animated: Bool, newCard: QuickAccessCard?) {
        let screen = NSScreen.underMouse
        var y = screen.visibleFrame.minY + margin
        for c in cards {
            let size = c.frame.size
            let target = CGRect(x: screen.visibleFrame.minX + margin, y: y, width: size.width, height: size.height)
            if c === newCard {
                c.setFrame(target.offsetBy(dx: -size.width - margin, dy: 0), display: false)
                c.alphaValue = 0
                c.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    c.animator().setFrame(target, display: true)
                    c.animator().alphaValue = 1
                }
            } else if animated {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; c.animator().setFrame(target, display: true) }
            } else { c.setFrame(target, display: true) }
            y += size.height + gap
        }
    }
}

final class QuickAccessCard: NSPanel {
    let item: CaptureItem
    unowned let owner: QuickAccess
    var isHovered = false

    init(item: CaptureItem, owner: QuickAccess) {
        self.item = item
        self.owner = owner
        let img = item.nsImage ?? NSImage()
        var ratio = img.size.width > 0 ? img.size.height / img.size.width : 0.6
        ratio = min(max(ratio, 0.35), 1.3)
        let w = owner.cardWidth
        let size = CGSize(width: w, height: (w * ratio).rounded())
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = QuickAccessView(card: self, image: img, frame: CGRect(origin: .zero, size: size))
    }

    override var canBecomeKey: Bool { true }

    func close(animated: Bool) {
        guard animated else { orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: -frame.width / 2, dy: 0), display: true)
        }, completionHandler: { self.orderOut(nil) })
    }

    // MARK: actions
    func copyItem() {
        if let img = item.image { Output.copyToClipboard(img, pointSize: item.pointSize) } else { Output.copyFile(item.savedURL ?? item.fileURL) }
        flash("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.owner.dismiss(self) }
    }

    func save() {
        if let s = item.savedURL { NSWorkspace.shared.activateFileViewerSelecting([s]); owner.dismiss(self); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Naming.filename(item.kind, date: Date(), ext: item.fileURL.pathExtension)
        panel.directoryURL = Prefs.shared.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.copyItem(at: item.fileURL, to: url)
            item.savedURL = url
            if let id = item.historyID { HistoryStore.shared.setSavedPath(id: id, url.path) }
            owner.dismiss(self)
        }
    }

    func annotate() {
        guard item.kind == .screenshot else { NSWorkspace.shared.open(item.savedURL ?? item.fileURL); return }
        Annotator.open(item: item)
        owner.dismiss(self)
    }

    func pin() {
        guard item.kind == .screenshot else { return }
        Pinner.pin(item)
        owner.dismiss(self)
    }

    func delete() {
        if let s = item.savedURL { try? FileManager.default.trashItem(at: s, resultingItemURL: nil) }
        if let id = item.historyID { HistoryStore.shared.remove(id: id) }
        owner.dismiss(self)
    }

    private func flash(_ text: String) { (contentView as? QuickAccessView)?.flash(text) }
}

final class QuickAccessView: NSView, NSDraggingSource {
    unowned let card: QuickAccessCard
    let image: NSImage
    private var bar: NSStackView!
    private var closeBtn: NSButton!
    private var flashLabel: NSTextField?
    private var downPoint: CGPoint?

    init(card: QuickAccessCard, image: NSImage, frame: CGRect) {
        self.card = card
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        let iv = NSImageView(frame: bounds)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.unregisterDraggedTypes()
        addSubview(iv)

        if card.item.kind != .screenshot {
            let badge = NSTextField(labelWithString: card.item.kind == .gif ? "GIF" : "VIDEO")
            badge.font = .systemFont(ofSize: 9, weight: .bold)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.drawsBackground = true
            badge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
            badge.sizeToFit()
            badge.frame.origin = CGPoint(x: 6, y: bounds.height - badge.frame.height - 6)
            addSubview(badge)
        }

        let isShot = card.item.kind == .screenshot
        var buttons: [NSButton] = [icon("doc.on.doc", "Copy", #selector(copyAction)), icon("square.and.arrow.down", "Save", #selector(saveAction))]
        if isShot {
            buttons.append(icon("pencil.tip", "Annotate", #selector(annotateAction)))
            buttons.append(icon("pin", "Pin to screen", #selector(pinAction)))
        } else {
            buttons.append(icon("play", "Open", #selector(annotateAction)))
        }
        buttons.append(icon("trash", "Delete", #selector(deleteAction)))
        bar = NSStackView(views: buttons)
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        bar.layer?.cornerRadius = 7
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([bar.centerXAnchor.constraint(equalTo: centerXAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])

        closeBtn = icon("xmark", "Close", #selector(closeAction))
        closeBtn.frame = CGRect(x: bounds.width - 24, y: bounds.height - 24, width: 18, height: 18)
        closeBtn.wantsLayer = true
        closeBtn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        closeBtn.layer?.cornerRadius = 9
        addSubview(closeBtn)
        setHover(false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func icon(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!.withSymbolConfiguration(cfg)!, target: self, action: sel)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    private func setHover(_ on: Bool) {
        card.isHovered = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            bar.animator().alphaValue = on ? 1 : 0
            closeBtn.animator().alphaValue = on ? 1 : 0
        }
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    func flash(_ text: String) {
        flashLabel?.removeFromSuperview()
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.wantsLayer = true
        l.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        l.layer?.cornerRadius = 6
        l.frame = CGRect(x: (bounds.width - 80) / 2, y: (bounds.height - 22) / 2, width: 80, height: 22)
        addSubview(l)
        flashLabel = l
    }

    @objc func copyAction() { card.copyItem() }
    @objc func saveAction() { card.save() }
    @objc func annotateAction() { card.annotate() }
    @objc func pinAction() { card.pin() }
    @objc func deleteAction() { card.delete() }
    @objc func closeAction() { card.owner.dismiss(card) }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        if event.clickCount == 2 { card.annotate() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downPoint, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 4 else { return }
        downPoint = nil
        let url = card.item.savedURL ?? card.item.fileURL
        let di = NSDraggingItem(pasteboardWriter: url as NSURL)
        di.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { card.owner.dismiss(card) }
    }
}
