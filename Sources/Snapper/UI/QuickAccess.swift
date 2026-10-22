import AppKit
import AVFoundation
import SnapKit

/// Floating thumbnail cards stacked in the bottom-left corner after each capture (CleanShot's "Quick Access Overlay").
/// Hover dims the thumbnail and shows Copy / Save plus four corner buttons. Two-finger swipe (or mouse-drag) the card
/// toward the screen edge to dismiss it; drag it anywhere else to drop the file; double-click opens Annotate.
final class QuickAccess {
    static let shared = QuickAccess()
    private(set) var cards: [QuickAccessCard] = []   // [0] = newest = bottom of the stack
    let cardWidth: CGFloat = 220
    let margin: CGFloat = 16
    let gap: CGFloat = 12
    let maxCards = 5
    private var screen: NSScreen = .underMouse

    func present(_ item: CaptureItem) {
        if cards.isEmpty { screen = .underMouse }
        let card = QuickAccessCard(item: item, owner: self)
        cards.insert(card, at: 0)
        // Drop the oldest cards if there are too many or the stack would run off the top of the screen.
        let limit = screen.visibleFrame.height - margin * 2
        while cards.count > 1, cards.count > maxCards || stackHeight > limit {
            let old = cards.removeLast()
            old.slideOut(velocity: 0)
        }
        observeEditor()
        layout(newCard: card)
        card.scheduleAutoClose()
    }

    /// Removes the card (sliding it off toward the left edge) and re-stacks the rest.
    func dismiss(_ card: QuickAccessCard, velocity: CGFloat = 0) {
        guard cards.contains(where: { $0 === card }) else { return }
        cards.removeAll { $0 === card }
        card.slideOut(velocity: velocity)
        layout(newCard: nil)
    }

    private var editorObserver: Any?
    /// Annotate posts "SnapperAnnotateDidClose" with the CaptureItem when its window closes.
    func observeEditor() {
        guard editorObserver == nil else { return }
        editorObserver = NotificationCenter.default.addObserver(forName: Notification.Name("SnapperAnnotateDidClose"), object: nil, queue: .main) { [weak self] n in
            guard let item = n.object as? CaptureItem else { return }
            MainActor.assumeIsolated { self?.cards.first { $0.item === item }?.editorClosed() }
        }
    }

    func dismissAll() { for c in cards { c.close(animated: false) }; cards.removeAll() }

    private var stackHeight: CGFloat { cards.reduce(0) { $0 + $1.restFrame.height } + gap * CGFloat(max(0, cards.count - 1)) }

    /// Left edge (global coordinates) of the screen the stack lives on — swipes past it leave the screen.
    var stackEdgeX: CGFloat { screen.visibleFrame.minX }

    private func layout(newCard: QuickAccessCard?) {
        let vf = screen.visibleFrame
        var y = vf.minY + margin
        for c in cards {
            let size = c.restFrame.size
            let target = CGRect(x: vf.minX + margin, y: y, width: size.width, height: size.height)
            c.restFrame = target
            let wf = c.windowFrame(for: target)
            if c === newCard {
                c.setFrame(wf, display: false)
                c.orderFrontRegardless()
                c.slideIn()
            } else if !c.isInteracting {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    c.animator().setFrame(wf, display: true)
                }
            }
            y += size.height + gap
        }
    }

    // MARK: swipe maths (pure)

    enum SwipeDecision: Equatable { case dismiss, snapBack }

    /// `offset` < 0 means the card has moved toward the left screen edge; `velocity` in pt/s (negative = leftward).
    static func swipeDecision(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> SwipeDecision {
        if velocity > 350 { return .snapBack }                      // flicked back toward the screen
        if offset <= -width * 0.35 { return .dismiss }               // dragged far enough
        if velocity < -650 && offset < -12 { return .dismiss }       // fast flick toward the edge
        return .snapBack
    }

    /// Displayed offset for a raw finger offset: free movement toward the edge, rubber-band resistance away from it.
    static func rubberBand(_ offset: CGFloat, width: CGFloat) -> CGFloat {
        guard offset > 0 else { return offset }
        let limit = max(width, 1) * 0.25, c: CGFloat = 0.5   // initial slope c, never past `limit`
        return limit * (1 - 1 / (offset * c / limit + 1))
    }

    // MARK: CLI

    @MainActor
    static func registerCLI() {
        CLI.extra["--qa-demo"] = { args in
            guard let path = args.first else { ToolsCLI.err("usage: --qa-demo IN.png [hover]"); return 2 }
            do {
                let img = try ToolsImage.load(path: path)
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let item = CaptureItem(kind: .screenshot, image: img, fileURL: url, savedURL: nil, historyID: nil,
                                       pointSize: CGSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2))
                shared.present(item)
                if args.dropFirst().contains("hover"), let card = shared.cards.first { card.forceHover() }
                ToolsCLI.out("quick access card \(img.width)x\(img.height)")
                return await ToolsCLI.stayAlive()
            } catch { ToolsCLI.err("error: \(error.localizedDescription)"); return 1 }
        }
        CLI.extra["--qa-swipe-test"] = { _ in
            let w: CGFloat = 220
            let cases: [(CGFloat, CGFloat, SwipeDecision)] = [
                (0, 0, .snapBack), (-40, 0, .snapBack), (-77, 0, .dismiss), (-150, 0, .dismiss),
                (-20, -900, .dismiss), (-8, -900, .snapBack), (-100, 600, .snapBack), (60, -50, .snapBack), (40, 0, .snapBack),
            ]
            var ok = true
            for (o, v, want) in cases where swipeDecision(offset: o, velocity: v, width: w) != want {
                ToolsCLI.err("FAIL offset=\(o) velocity=\(v) want=\(want)"); ok = false
            }
            let rb = rubberBand(1000, width: w)
            if !(rb > 0 && rb < w * 0.25) || rubberBand(-30, width: w) != -30 { ToolsCLI.err("FAIL rubberBand \(rb)"); ok = false }
            ToolsCLI.out(ok ? "swipe ok" : "swipe FAILED")
            return ok ? 0 : 1
        }
    }
}

final class QuickAccessCard: NSPanel {
    let item: CaptureItem
    unowned let owner: QuickAccess
    var isHovered = false
    /// Where the card rests in the stack; swipes move the window relative to this.
    var restFrame: CGRect
    /// True while a finger/mouse swipe owns the window frame (layout must not fight it).
    var isInteracting = false
    private(set) var isDismissing = false
    private var autoCloseGeneration = 0
    private var demoHover = false

    init(item: CaptureItem, owner: QuickAccess) {
        self.item = item
        self.owner = owner
        let img = item.nsImage
        let src = img?.size ?? item.pointSize
        var ratio = src.width > 0 ? src.height / src.width : 0.6
        ratio = min(max(ratio, 0.4), 1.2)
        let w = owner.cardWidth
        let size = CGSize(width: w, height: (w * ratio).rounded())
        restFrame = CGRect(origin: .zero, size: size)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        let container = NSView(frame: CGRect(x: 0, y: 0, width: size.width + lead, height: size.height))
        container.wantsLayer = true
        let v = QuickAccessView(card: self, image: img, frame: CGRect(x: lead, y: 0, width: size.width, height: size.height))
        container.addSubview(v)
        cardViewRef = v
        contentView = container
        setContentSize(container.frame.size)
    }

    /// The window spans from the screen edge to the card's right side, so the card can slide out to the real edge
    /// while the WINDOW stays still (moving a window toward the edge triggers macOS's half-screen tiling preview).
    let lead: CGFloat = 16
    private var cardViewRef: QuickAccessView!
    func windowFrame(for card: CGRect) -> CGRect {
        CGRect(x: card.minX - lead, y: card.minY, width: card.width + lead, height: card.height)
    }
    private var slideLayer: CALayer? { cardViewRef.layer }

    func slideIn() {
        guard let layer = slideLayer else { return }
        let from = -(restFrame.width + lead)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = from
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        layer.add(move, forKey: "in")
        layer.add(fade, forKey: "inFade")
        CATransaction.commit()
    }

    override var canBecomeKey: Bool { true }
    private var cardView: QuickAccessView? { cardViewRef }

    // MARK: lifecycle

    func scheduleAutoClose() {
        autoCloseGeneration += 1
        let secs = Prefs.shared.quickAccessAutoClose
        guard secs > 0, !demoHover else { return }
        let gen = autoCloseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs)) { [weak self] in
            guard let self, gen == self.autoCloseGeneration, !self.isHovered, !self.isInteracting, !self.isEditing else { return }
            self.owner.dismiss(self)
        }
    }
    func cancelAutoClose() { autoCloseGeneration += 1 }

    func forceHover() { demoHover = true; cancelAutoClose(); cardView?.setHover(true, animated: false) }
    var hoverLocked: Bool { demoHover }

    func close(animated: Bool) {
        guard animated else { isDismissing = true; orderOut(nil); return }
        slideOut(velocity: 0)
    }

    /// Slides the card's CONTENT off to the left and fades it out. The window itself never moves: moving a window
    /// toward the screen edge makes macOS show its half-screen tiling preview.
    func slideOut(velocity: CGFloat) {
        isDismissing = true
        isInteracting = false
        cancelAutoClose()
        guard let layer = slideLayer else { orderOut(nil); return }
        let fromX = layer.affineTransform().tx
        let toX = -(restFrame.maxX - owner.stackEdgeX) - 10
        let speed = max(abs(min(velocity, 0)), 1100)
        let duration = min(max(Double(abs(toX - fromX) / speed), 0.14), 0.3)
        hasShadow = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: velocity < -300 ? .linear : .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            self?.orderOut(nil)
            self?.slideLayer?.setAffineTransform(.identity)
            self?.slideLayer?.opacity = 1
        }
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = fromX
        move.toValue = toX
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.opacity
        fade.toValue = 0
        layer.add(move, forKey: "slide")
        layer.add(fade, forKey: "fade")
        layer.setAffineTransform(CGAffineTransform(translationX: toX, y: 0))
        layer.opacity = 0
        CATransaction.commit()
    }

    // MARK: swipe support (offset relative to the resting position; only the content layer moves)

    func applySwipe(offset: CGFloat) {
        guard let layer = slideLayer else { return }
        let shown = QuickAccess.rubberBand(offset, width: restFrame.width)
        if hasShadow { hasShadow = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(translationX: shown, y: 0))
        layer.opacity = Float(shown < 0 ? max(0.25, 1 - (-shown / restFrame.width) * 0.75) : 1)
        CATransaction.commit()
    }

    func endSwipe(offset: CGFloat, velocity: CGFloat) {
        switch QuickAccess.swipeDecision(offset: offset, velocity: velocity, width: restFrame.width) {
        case .dismiss:
            // Swiping a card away throws the capture out (file to Trash + gone from History), unless turned off in Settings.
            if Prefs.shared.swipeDeletes { discardFiles() }
            owner.dismiss(self, velocity: min(velocity, -1100))
        case .snapBack:
            isInteracting = false
            guard let layer = slideLayer else { return }
            let fromX = layer.affineTransform().tx
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.32)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 1.35, 0.4, 1))  // slight overshoot
            CATransaction.setCompletionBlock { [weak self] in self?.hasShadow = true }
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = fromX
            move.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 1
            layer.add(move, forKey: "snap")
            layer.add(fade, forKey: "snapFade")
            layer.setAffineTransform(.identity)
            layer.opacity = 1
            CATransaction.commit()
            if !isHovered { scheduleAutoClose() }
        }
    }

    /// Saved file → Trash (recoverable), private history copy removed.
    func discardFiles() {
        if let s = item.savedURL { try? FileManager.default.trashItem(at: s, resultingItemURL: nil) }
        if let id = item.historyID { HistoryStore.shared.remove(id: id) }
    }

    // MARK: actions

    func copyItem() {
        if let img = item.image { Output.copyToClipboard(img, pointSize: item.pointSize) } else { Output.copyFile(item.savedURL ?? item.fileURL) }
        cardView?.flash("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.owner.dismiss(self) }
    }

    func save() {
        if let s = item.savedURL { NSWorkspace.shared.activateFileViewerSelecting([s]); owner.dismiss(self); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Naming.filename(item.kind, date: Date(), ext: item.fileURL.pathExtension)
        panel.directoryURL = Prefs.shared.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: item.fileURL, to: url)
            item.savedURL = url
            if let id = item.historyID { HistoryStore.shared.setSavedPath(id: id, url.path) }
            owner.dismiss(self)
        }
    }

    /// CleanShot behaviour: the card stays while the editor is open and shows the edited image after it closes.
    func annotate() {
        guard item.kind == .screenshot else { NSWorkspace.shared.open(item.savedURL ?? item.fileURL); return }
        cancelAutoClose()
        isEditing = true
        Annotator.open(item: item)
    }

    /// Open Annotate with the Background panel ready (CleanShot "Background" flow).
    func annotateWithBackground() {
        guard item.kind == .screenshot else { return }
        cancelAutoClose()
        isEditing = true
        Annotator.openWithBackground(item: item)
    }

    var isEditing = false
    func editorClosed() {
        isEditing = false
        cardView?.refreshImage()
        if !isHovered { scheduleAutoClose() }
    }

    func pin() {
        guard item.kind == .screenshot else { return }
        Pinner.pin(item)
        owner.dismiss(self)
    }

    func delete() {
        discardFiles()
        owner.dismiss(self)
    }
}

/// Small layer-backed button used on the card: a white "pill" with a title, or a dark round icon.
final class QAButton: NSView {
    enum Style { case pill(String), round(String) }
    private let style: Style
    private let action: () -> Void
    private var hovering = false { didSet { refresh() } }
    private var pressed = false { didSet { refresh() } }

    init(_ style: Style, tip: String, action: @escaping () -> Void) {
        self.style = style
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
        switch style {
        case .pill(let title):
            layer?.cornerRadius = 6
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 13, weight: .medium)
            l.textColor = NSColor(white: 0.08, alpha: 1)
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 84), heightAnchor.constraint(equalToConstant: 26),
                l.centerXAnchor.constraint(equalTo: centerXAnchor), l.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        case .round(let symbol):
            layer?.cornerRadius = 11
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg) ?? NSImage())
            iv.contentTintColor = .white
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 22),
                iv.centerXAnchor.constraint(equalTo: centerXAnchor), iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        refresh()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        switch style {
        case .pill:
            let a: CGFloat = pressed ? 0.75 : hovering ? 1 : 0.9
            layer?.backgroundColor = NSColor(white: 1, alpha: a).cgColor
        case .round:
            let a: CGFloat = pressed ? 0.9 : hovering ? 0.8 : 0.62
            layer?.backgroundColor = NSColor(white: 0, alpha: a).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// Dim layer + buttons shown on hover. Transparent to clicks unless the card is hovered.
private final class QAHoverOverlay: NSView {
    var active = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active, !isHidden else { return nil }
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

final class QuickAccessView: NSView, NSDraggingSource {
    unowned let card: QuickAccessCard
    private(set) var image: NSImage?
    private var thumbView: NSImageView?
    private let overlay = QAHoverOverlay()
    private let centerStack = NSStackView()
    private var badge: NSView?
    private var flashView: NSView?

    // Swipe / drag state
    private enum Gesture { case idle, undecided, horizontal, ignored }
    private var scrollGesture: Gesture = .idle
    private var scrollAccum = CGSize.zero
    private var swipeOffset: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastSampleTime: TimeInterval = 0
    private var mouseDownScreen: CGPoint?
    private var mouseSwiping = false

    init(card: QuickAccessCard, image: NSImage?, frame: CGRect) {
        self.card = card
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        let iv = NSImageView(frame: bounds)
        thumbView = iv
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.animates = card.item.kind == .gif
        iv.autoresizingMask = [.width, .height]
        iv.unregisterDraggedTypes()
        addSubview(iv)
        if image == nil, card.item.kind == .recording { loadVideoThumbnail(into: iv) }

        let isShot = card.item.kind == .screenshot
        if !isShot {
            let b = NSTextField(labelWithString: card.item.kind == .gif ? "GIF" : "VIDEO")
            b.font = .systemFont(ofSize: 9, weight: .bold)
            b.textColor = .white
            b.alignment = .center
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            b.layer?.cornerRadius = 4
            b.sizeToFit()
            b.frame = CGRect(x: 7, y: bounds.height - b.frame.height - 9, width: b.frame.width + 10, height: b.frame.height + 2)
            addSubview(b)
            badge = b
        }

        // Hover overlay: dim + centred Copy / Save + four corner buttons.
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        addSubview(overlay)

        centerStack.orientation = .vertical
        centerStack.spacing = bounds.height < 100 ? 5 : 7
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.addArrangedSubview(QAButton(.pill("Copy"), tip: "Copy to clipboard") { [unowned self] in self.card.copyItem() })
        centerStack.addArrangedSubview(QAButton(.pill("Save"), tip: "Save") { [unowned self] in self.card.save() })
        overlay.addSubview(centerStack)
        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        let inset: CGFloat = 6
        func corner(_ b: QAButton, top: Bool, left: Bool, offset: CGFloat = 0) {
            overlay.addSubview(b)
            NSLayoutConstraint.activate([
                top ? b.topAnchor.constraint(equalTo: overlay.topAnchor, constant: inset)
                    : b.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -inset),
                left ? b.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: inset + offset)
                     : b.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -(inset + offset)),
            ])
        }
        corner(QAButton(.round("xmark"), tip: "Close") { [unowned self] in self.card.owner.dismiss(self.card) }, top: true, left: true)
        if isShot {
            corner(QAButton(.round("pin.fill"), tip: "Pin to screen") { [unowned self] in self.card.pin() }, top: true, left: false)
            corner(QAButton(.round("photo.artframe"), tip: "Annotate with background") { [unowned self] in self.card.annotateWithBackground() }, top: true, left: true, offset: 28)
            corner(QAButton(.round("pencil"), tip: "Annotate") { [unowned self] in self.card.annotate() }, top: false, left: true)
        } else {
            corner(QAButton(.round("play.fill"), tip: "Open") { [unowned self] in self.card.annotate() }, top: false, left: true)
        }
        corner(QAButton(.round("trash"), tip: "Delete") { [unowned self] in self.card.delete() }, top: false, left: false)

        setHover(false, animated: false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func loadVideoThumbnail(into iv: NSImageView) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: card.item.savedURL ?? card.item.fileURL))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.generateCGImageAsynchronously(for: .zero) { [weak iv] cg, _, _ in
            guard let cg else { return }
            DispatchQueue.main.async { iv?.image = NSImage(cgImage: cg, size: .zero) }
        }
    }

    // MARK: hover

    /// Show the edited image after Annotate saved/copied.
    func refreshImage() {
        guard let img = card.item.nsImage else { return }
        image = img
        thumbView?.image = img
    }

    func setHover(_ on: Bool, animated: Bool = true) {
        let on = on || card.hoverLocked
        card.isHovered = on
        overlay.active = on
        if on { overlay.isHidden = false }
        let apply = { [self] in
            (animated ? overlay.animator() : overlay).alphaValue = on ? 1 : 0
            if let badge { (animated ? badge.animator() : badge).alphaValue = on ? 0 : 1 }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.14; apply() },
                                                 completionHandler: { [weak self] in if let self, !self.card.isHovered { self.overlay.isHidden = true } })
        } else {
            apply()
            overlay.isHidden = !on
        }
    }
    override func mouseEntered(with event: NSEvent) {
        guard !card.isDismissing else { return }
        card.cancelAutoClose()
        setHover(true)
    }
    override func mouseExited(with event: NSEvent) {
        guard !card.isDismissing, !card.hoverLocked else { return }
        setHover(false)
        if !card.isInteracting { card.scheduleAutoClose() }
    }

    func flash(_ text: String) {
        flashView?.removeFromSuperview()
        centerStack.isHidden = true
        let l = NSTextField(labelWithString: "✓ " + text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.sizeToFit()
        l.frame = CGRect(x: (bounds.width - l.frame.width) / 2, y: (bounds.height - l.frame.height) / 2, width: l.frame.width, height: l.frame.height)
        overlay.addSubview(l)
        flashView = l
        if !card.isHovered { overlay.isHidden = false; overlay.alphaValue = 1 }
    }

    // MARK: two-finger trackpad swipe

    /// Finger movement in points, positive = right, regardless of the "natural scrolling" setting.
    private func fingerDelta(_ e: NSEvent) -> CGSize {
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        return CGSize(width: e.scrollingDeltaX * sign, height: e.scrollingDeltaY * sign)
    }

    private func sampleVelocity(dx: CGFloat, time: TimeInterval) {
        let dt = time - lastSampleTime
        if lastSampleTime > 0, dt > 0.001 {
            let v = dx / CGFloat(dt)
            velocity = velocity * 0.35 + v * 0.65
        }
        lastSampleTime = time
    }

    override func scrollWheel(with event: NSEvent) {
        // Plain mouse wheel (no gesture phases): not a swipe.
        if event.phase.isEmpty && event.momentumPhase.isEmpty { super.scrollWheel(with: event); return }
        // Momentum after the fingers lift: the decision was already made on .ended — swallow it.
        if !event.momentumPhase.isEmpty { return }
        if card.isDismissing || mouseSwiping { return }

        if event.phase.contains(.began) {
            scrollGesture = .undecided
            scrollAccum = .zero
            swipeOffset = 0
            velocity = 0
            lastSampleTime = 0
        }
        guard scrollGesture != .idle else { return }

        if event.phase.contains(.began) || event.phase.contains(.changed) {
            guard event.hasPreciseScrollingDeltas else { return }
            let d = fingerDelta(event)
            switch scrollGesture {
            case .undecided:
                scrollAccum.width += d.width
                scrollAccum.height += d.height
                guard hypot(scrollAccum.width, scrollAccum.height) > 4 else { return }
                if abs(scrollAccum.width) >= abs(scrollAccum.height) * 1.2 {
                    scrollGesture = .horizontal
                    card.isInteracting = true
                    card.cancelAutoClose()
                    swipeOffset = scrollAccum.width
                    sampleVelocity(dx: scrollAccum.width, time: event.timestamp)
                    card.applySwipe(offset: swipeOffset)
                } else {
                    scrollGesture = .ignored            // vertical-dominant: leave it alone
                }
            case .horizontal:
                swipeOffset += d.width
                sampleVelocity(dx: d.width, time: event.timestamp)
                card.applySwipe(offset: swipeOffset)
            case .ignored, .idle:
                break
            }
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let wasHorizontal = scrollGesture == .horizontal
            scrollGesture = .idle
            guard wasHorizontal else { return }
            // Stale velocity (fingers rested before lifting) shouldn't fling the card.
            let v = event.timestamp - lastSampleTime > 0.08 ? 0 : velocity
            if event.phase.contains(.cancelled) { card.endSwipe(offset: 0, velocity: 0) }
            else { card.endSwipe(offset: swipeOffset, velocity: v) }
        }
    }

    // MARK: mouse: click, double-click annotate, drag left = dismiss, drag elsewhere = drop the file

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreen = NSEvent.mouseLocation
        mouseSwiping = false
        if event.clickCount == 2 { mouseDownScreen = nil; card.annotate() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !card.isDismissing else { return }
        let p = NSEvent.mouseLocation
        if mouseSwiping, let d = mouseDownScreen {
            swipeOffset = p.x - d.x
            sampleVelocity(dx: event.deltaX, time: event.timestamp)
            card.applySwipe(offset: swipeOffset)
            return
        }
        guard let d = mouseDownScreen else { return }
        let dx = p.x - d.x, dy = p.y - d.y
        guard hypot(dx, dy) > 5 else { return }
        if dx < 0 && abs(dx) > abs(dy) * 1.2 {
            // Toward the screen edge: the card follows the mouse like a swipe.
            mouseSwiping = true
            card.isInteracting = true
            card.cancelAutoClose()
            swipeOffset = dx
            velocity = 0
            lastSampleTime = event.timestamp
            card.applySwipe(offset: swipeOffset)
            return
        }
        mouseDownScreen = nil
        let url = card.item.savedURL ?? card.item.fileURL
        let di = NSDraggingItem(pasteboardWriter: url as NSURL)
        di.setDraggingFrame(bounds, contents: image ?? NSImage(size: bounds.size))
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownScreen = nil; mouseSwiping = false }
        guard mouseSwiping else { return }
        let v = event.timestamp - lastSampleTime > 0.08 ? 0 : velocity
        card.endSwipe(offset: swipeOffset, velocity: v)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        card.cancelAutoClose()
        card.animator().alphaValue = 0.4
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { card.owner.dismiss(card) }
        else { card.animator().alphaValue = 1; if !card.isHovered { card.scheduleAutoClose() } }
    }
}
