import AppKit
import SnapKit

/// Window that routes ⌘-shortcuts and stray keys to the editor (the app has no main menu).
final class AnnotateWindow: NSWindow {
    weak var editor: AnnotateEditor?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleCommand(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if editor?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { editor?.escape() }
}

/// Current tool settings applied to new annotations.
struct ToolStyle {
    static let widths: [CGFloat] = [3, 5, 8]
    static let fontSizes: [CGFloat] = [16, 22, 32, 44]
    var color: RGBA = .red
    var widthIndex = 1
    var filled = false
    var fontIndex = 1
    var textBackground = false
    var blurStyle: BlurStyle = .blur
    var lineWidth: CGFloat { Self.widths[widthIndex] }
    var fontSize: CGFloat { Self.fontSizes[fontIndex] }
}

final class AnnotateEditor: NSObject, NSWindowDelegate {
    let renderer: AnnotationRenderer
    let item: CaptureItem?
    let sourceURL: URL?
    private(set) var window: AnnotateWindow!
    private(set) var canvas: AnnotateCanvas!
    private var scroll: NSScrollView!

    var doc = AnnotationDocument() {
        didSet { docChanged(from: oldValue) }
    }
    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []
    private(set) var selectedID: UUID?
    private(set) var tool: AnnotationTool = .arrow
    private var toolBeforeCrop: AnnotationTool = .arrow
    var style = ToolStyle()
    private var showBackgroundPanel = false
    private var sliderBefore: AnnotationDocument?

    // Chrome
    private var toolButtons: [AnnotationTool: IconButton] = [:]
    private var bgButton: IconButton!
    private var undoButton: IconButton!
    private var redoButton: IconButton!
    private var zoomLabel: NSButton!
    private var propsStack: NSStackView!
    private var statusLabel: NSTextField!
    private var swatches: [Swatch] = []
    private var colorWell: NSColorWell?

    init(image: CGImage, pointSize: CGSize, item: CaptureItem?, sourceURL: URL?) {
        renderer = AnnotationRenderer(image: image, pointSize: pointSize)
        self.item = item
        self.sourceURL = sourceURL
        super.init()
        buildWindow()
    }

    // MARK: window

    private func buildWindow() {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let img = renderer.pointSize
        let chromeH: CGFloat = 38 + 34
        let w = min(max(img.width + 56, 860), vf.width * 0.9)
        let h = min(max(img.height + 56 + chromeH, 520), vf.height * 0.9)
        let win = AnnotateWindow(contentRect: NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        win.editor = self
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "Annotate — " + (sourceURL?.lastPathComponent ?? "Screenshot")
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = Chrome.canvasColor
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 360)
        win.delegate = self
        win.collectionBehavior = [.fullScreenPrimary]
        window = win

        let root = DropRootView()
        root.acceptsDrops = { [weak self] in self?.showBackgroundPanel == true && self?.tool != .crop }
        root.onDropImage = { [weak self] url in self?.useBackgroundPicture(url) ?? false }
        win.contentView = root

        let top = DragBar()
        let props = DragBar(); props.fill = Chrome.subBarColor
        let sv = NSScrollView()
        sv.contentView = CenteringClipView()
        sv.hasHorizontalScroller = true; sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.allowsMagnification = true
        sv.minMagnification = 0.05; sv.maxMagnification = 8
        sv.drawsBackground = true
        sv.backgroundColor = Chrome.canvasColor
        canvas = AnnotateCanvas(editor: self)
        sv.documentView = canvas
        scroll = sv
        for v in [sv, props, top] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor), top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor), top.heightAnchor.constraint(equalToConstant: 38),
            props.topAnchor.constraint(equalTo: top.bottomAnchor), props.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            props.trailingAnchor.constraint(equalTo: root.trailingAnchor), props.heightAnchor.constraint(equalToConstant: 34),
            sv.topAnchor.constraint(equalTo: props.bottomAnchor), sv.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: root.trailingAnchor), sv.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        buildToolbar(in: top)
        buildPropsBar(in: props)
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: sv)
        canvas.updateSize()
        rebuildProps()
        refreshChrome()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        zoomToFit()
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        canvas.endTextEditing()
        NotificationCenter.default.removeObserver(self)
        Annotator.closed(self)
        if let item { NotificationCenter.default.post(name: Annotator.didClose, object: item) }
    }

    func windowDidResize(_ notification: Notification) { updateZoomLabel() }

    private func buildToolbar(in bar: NSView) {
        let tools: [(AnnotationTool, String, String)] = [
            (.select, "cursorarrow", "Select & Move (V)"),
            (.crop, "crop", "Crop (C)"),
            (.arrow, "arrow.up.right", "Arrow (A)"),
            (.rect, "rectangle", "Rectangle (R)"),
            (.ellipse, "circle", "Ellipse (O)"),
            (.line, "line.diagonal", "Line (L)"),
            (.text, "textformat", "Text (T)"),
            (.pencil, "scribble", "Pencil (P)"),
            (.highlighter, "highlighter", "Highlighter (H)"),
            (.blur, "drop.halffull", "Blur / Pixelate (B)"),
            (.spotlight, "flashlight.on.fill", "Spotlight (S)"),
            (.counter, "1.circle", "Counter (N)"),
        ]
        let left = NSStackView(); left.orientation = .horizontal; left.spacing = 1
        for (i, (t, sym, tip)) in tools.enumerated() {
            if i == 2 { left.addArrangedSubview(gap(6)); left.addArrangedSubview(Chrome.separator()); left.addArrangedSubview(gap(6)) }
            let b = IconButton(symbol: sym, tip: tip) { [weak self] in self?.setTool(t) }
            toolButtons[t] = b
            left.addArrangedSubview(b)
        }
        left.addArrangedSubview(gap(6)); left.addArrangedSubview(Chrome.separator()); left.addArrangedSubview(gap(6))
        bgButton = IconButton(symbol: "photo.artframe", tip: "Background") { [weak self] in self?.toggleBackgroundPanel() }
        left.addArrangedSubview(bgButton)

        let right = NSStackView(); right.orientation = .horizontal; right.spacing = 1
        undoButton = IconButton(symbol: "arrow.uturn.backward", tip: "Undo (⌘Z)") { [weak self] in self?.undo() }
        redoButton = IconButton(symbol: "arrow.uturn.forward", tip: "Redo (⇧⌘Z)") { [weak self] in self?.redo() }
        zoomLabel = NSButton(title: "100%", target: self, action: #selector(zoomLabelClicked))
        zoomLabel.isBordered = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.contentTintColor = Chrome.iconDim
        zoomLabel.toolTip = "Zoom — click to fit (⌘0), ⌘+ / ⌘−, pinch"
        zoomLabel.refusesFirstResponder = true
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let drag = DragOutButton()
        drag.provide = { [weak self] in self?.dragPayload() }
        let copy = IconButton(symbol: "doc.on.doc", tip: "Copy & Close (⌘C)") { [weak self] in self?.copyAndClose() }
        let save = IconButton(symbol: "square.and.arrow.down", tip: "Save (⌘S)") { [weak self] in self?.save() }
        for v in [undoButton!, redoButton!] { right.addArrangedSubview(v) }
        right.addArrangedSubview(gap(4)); right.addArrangedSubview(zoomLabel); right.addArrangedSubview(gap(4))
        right.addArrangedSubview(Chrome.separator()); right.addArrangedSubview(gap(6))
        for v in [drag, copy, save] as [NSView] { right.addArrangedSubview(v) }

        for s in [left, right] { s.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(s) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 80),   // clear the traffic lights
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
    }

    private func gap(_ w: CGFloat) -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    private func buildPropsBar(in bar: NSView) {
        let s = NSStackView(); s.orientation = .horizontal; s.spacing = 2; s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(s)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = Chrome.iconDim
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            s.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: s.trailingAnchor, constant: 12),
        ])
        propsStack = s
    }

    /// Label for groups in the properties row.
    private func caption(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = Chrome.iconDim
        return l
    }

    private func smallTextButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> NSView {
        let b = IconButton(symbol: "", tip: title, width: primary ? 64 : 56, onClick: action)
        b.image = nil
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: primary ? .semibold : .medium),
            .foregroundColor: primary ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.8),
        ])
        return b
    }

    /// The properties row adapts to the active tool / selection.
    private func rebuildProps() {
        propsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        swatches = []; colorWell = nil
        let s = propsStack!

        if tool == .crop {
            s.addArrangedSubview(caption("Drag to choose the area · handles resize · ⏎ apply · esc cancel"))
            s.addArrangedSubview(gap(12))
            s.addArrangedSubview(smallTextButton("Reset") { [weak self] in self?.canvas.pendingCrop = nil; self?.cropChanged() })
            s.addArrangedSubview(smallTextButton("Cancel") { [weak self] in self?.cancelCrop() })
            s.addArrangedSubview(smallTextButton("Apply", primary: true) { [weak self] in self?.applyCrop() })
            return
        }
        if showBackgroundPanel {
            buildBackgroundProps(into: s)
            return
        }

        let sel = selected
        let kind = sel?.kind ?? tool.kind
        if kind == .blur {
            let seg = Segmented(count: 2, cell: CGSize(width: 72, height: 22)) { i, r, c in
                let t = (i == 0 ? "Blur" : "Pixelate") as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: c]
                let sz = t.size(withAttributes: a)
                t.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
            }
            seg.selected = (sel?.blurStyle ?? style.blurStyle) == .blur ? 0 : 1
            seg.onChange = { [weak self] i in
                let b: BlurStyle = i == 0 ? .blur : .pixelate
                self?.style.blurStyle = b
                self?.applyToSelection { $0.blurStyle = b }
            }
            s.addArrangedSubview(seg)
            return
        }
        if kind == .spotlight {
            s.addArrangedSubview(caption("Drag to highlight an area — everything else is dimmed"))
            return
        }
        if tool == .select && sel == nil {
            s.addArrangedSubview(caption("Click an annotation to select · drag to move · ⌫ delete · arrows nudge"))
            return
        }

        // Colours
        let current = sel?.color ?? style.color
        for c in RGBA.palette {
            let sw = Swatch(c)
            sw.isOn = c == current
            sw.onClick = { [weak self] in self?.setColor(c) }
            swatches.append(sw)
            s.addArrangedSubview(sw)
        }
        let well = NSColorWell(style: .minimal)
        well.color = current.ns
        well.target = self; well.action = #selector(wellChanged(_:))
        well.toolTip = "Custom colour"
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 26).isActive = true
        well.heightAnchor.constraint(equalToConstant: 18).isActive = true
        colorWell = well
        s.addArrangedSubview(gap(2)); s.addArrangedSubview(well)

        if kind == .text {
            s.addArrangedSubview(gap(8)); s.addArrangedSubview(Chrome.separator()); s.addArrangedSubview(gap(8))
            let seg = Segmented(count: ToolStyle.fontSizes.count, cell: CGSize(width: 26, height: 22)) { i, r, c in
                let t = "A" as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: [9.5, 11.5, 13.5, 15.5][i], weight: .semibold), .foregroundColor: c]
                let sz = t.size(withAttributes: a)
                t.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
            }
            seg.setTips(["Small", "Medium", "Large", "Extra large"])
            seg.selected = ToolStyle.fontSizes.firstIndex(of: sel?.fontSize ?? -1) ?? style.fontIndex
            seg.onChange = { [weak self] i in
                self?.style.fontIndex = i
                self?.applyToSelection { $0.fontSize = ToolStyle.fontSizes[i] }
            }
            s.addArrangedSubview(seg)
            s.addArrangedSubview(gap(6))
            let pill = IconButton(symbol: "capsule.fill", tip: "Background pill") { [weak self] in
                guard let self else { return }
                let v = !(self.selected?.textBackground ?? self.style.textBackground)
                self.style.textBackground = v
                self.applyToSelection { $0.textBackground = v }
                self.rebuildProps()
            }
            pill.isOn = sel?.textBackground ?? style.textBackground
            s.addArrangedSubview(pill)
            return
        }

        // Stroke width
        s.addArrangedSubview(gap(8)); s.addArrangedSubview(Chrome.separator()); s.addArrangedSubview(gap(8))
        let seg = Segmented(count: 3) { i, r, c in
            c.setFill()
            let h: CGFloat = [1.5, 3, 5][i]
            NSBezierPath(roundedRect: NSRect(x: r.midX - 7, y: r.midY - h / 2, width: 14, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        }
        seg.setTips(["Thin", "Medium", "Thick"])
        seg.selected = ToolStyle.widths.firstIndex(of: sel?.lineWidth ?? -1) ?? style.widthIndex
        seg.onChange = { [weak self] i in
            self?.style.widthIndex = i
            self?.applyToSelection { $0.lineWidth = ToolStyle.widths[i] }
        }
        s.addArrangedSubview(seg)

        if kind == .rect || kind == .ellipse {
            s.addArrangedSubview(gap(6))
            let filled = sel?.filled ?? style.filled
            let sym = kind == .rect ? (filled ? "rectangle.fill" : "rectangle") : (filled ? "circle.fill" : "circle")
            let b = IconButton(symbol: sym, tip: "Filled shape (F)") { [weak self] in self?.toggleFill() }
            b.isOn = filled
            s.addArrangedSubview(b)
        }
    }

    private func slider(value: CGFloat, max: CGFloat, width: CGFloat = 96, tip: String? = nil, action: Selector) -> NSSlider {
        let sl = NSSlider(value: Double(value), minValue: 0, maxValue: Double(max), target: self, action: action)
        sl.controlSize = .mini
        sl.isContinuous = true
        sl.refusesFirstResponder = true
        sl.toolTip = tip
        sl.translatesAutoresizingMaskIntoConstraints = false
        sl.widthAnchor.constraint(equalToConstant: width).isActive = true
        return sl
    }

    /// Background row: [none] [gradients] [colour] | [pictures… scroll] [+] | padding · corners · (blur) · shadow
    private func buildBackgroundProps(into s: NSStackView) {
        let bg = doc.background
        let none = NoneChip()
        none.isOn = bg == nil
        none.onClick = { [weak self] in
            guard let self, self.doc.background != nil else { return }
            self.commit { $0.background = nil }
            self.rebuildProps(); self.refreshChrome()
        }
        s.addArrangedSubview(none)
        for i in 0..<AnnotationBackground.presets.count {
            let c = GradientChip(i)
            c.isOn = bg?.preset == i
            c.onClick = { [weak self] in self?.setBackground { $0.kind = .gradient(i) } }
            s.addArrangedSubview(c)
        }
        let well = NSColorWell(style: .minimal)
        if case .solid(let c)? = bg?.kind { well.color = c.ns } else { well.color = .white }
        well.target = self; well.action = #selector(bgWellChanged(_:))
        well.toolTip = "Solid colour"
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 20).isActive = true
        well.heightAnchor.constraint(equalToConstant: 14).isActive = true
        if case .solid? = bg?.kind {
            well.wantsLayer = true
            well.layer?.borderColor = NSColor.white.cgColor; well.layer?.borderWidth = 1.5; well.layer?.cornerRadius = 4
        }
        s.addArrangedSubview(gap(3)); s.addArrangedSubview(well)
        s.addArrangedSubview(gap(7)); s.addArrangedSubview(Chrome.separator()); s.addArrangedSubview(gap(5))

        // Pictures: current desktop, recent picks, built-in wallpapers (deduped, in that order).
        var urls: [(URL, String?)] = []
        var seen = Set<String>()
        func add(_ u: URL, _ tip: String?) { if seen.insert(u.standardizedFileURL.path).inserted { urls.append((u, tip)) } }
        if let d = BackgroundStore.currentDesktopPicture { add(d, "Current desktop picture") }
        // A picture in use that isn't otherwise listed (e.g. dropped from Finder before import).
        for u in BackgroundStore.recents { add(u, u.lastPathComponent) }
        for u in BackgroundStore.wallpapers { add(u, nil) }
        if let p = bg?.imagePath, !seen.contains(URL(fileURLWithPath: p).standardizedFileURL.path) {
            urls.insert((URL(fileURLWithPath: p), URL(fileURLWithPath: p).lastPathComponent), at: 0)
        }
        var chips: [ImageChip] = []
        var selectedChip: ImageChip?
        for (u, tip) in urls {
            let c = ImageChip(u, tip: tip)
            c.isOn = bg?.imagePath.map { URL(fileURLWithPath: $0).standardizedFileURL == u.standardizedFileURL } ?? false
            if c.isOn { selectedChip = c }
            c.onClick = { [weak self] in self?.setBackground { $0.kind = .image(u.path) } }
            chips.append(c)
        }
        let strip = ChipStrip(chips)
        s.addArrangedSubview(strip)
        let plus = IconButton(symbol: "plus", tip: "Choose Picture… (or drop an image here)", size: 11, width: 24) { [weak self] in
            self?.chooseBackgroundPicture()
        }
        s.addArrangedSubview(plus)
        if let sel = selectedChip { DispatchQueue.main.async { strip.scrollToShow(sel) } }

        s.addArrangedSubview(gap(5)); s.addArrangedSubview(Chrome.separator()); s.addArrangedSubview(gap(8))
        s.addArrangedSubview(caption("Padding")); s.addArrangedSubview(gap(3))
        s.addArrangedSubview(slider(value: bg?.padding ?? 48, max: 200, width: 64, tip: "Padding", action: #selector(paddingSlid(_:))))
        s.addArrangedSubview(gap(8)); s.addArrangedSubview(caption("Corners")); s.addArrangedSubview(gap(3))
        s.addArrangedSubview(slider(value: bg?.cornerRadius ?? 10, max: 32, width: 56, tip: "Corner radius", action: #selector(radiusSlid(_:))))
        if bg?.imagePath != nil {
            s.addArrangedSubview(gap(8)); s.addArrangedSubview(caption("Blur")); s.addArrangedSubview(gap(3))
            s.addArrangedSubview(slider(value: bg?.blur ?? 0, max: 100, width: 52, tip: "Blur the picture", action: #selector(blurSlid(_:))))
        }
        s.addArrangedSubview(gap(6))
        let shadow = IconButton(symbol: "shadow", tip: "Shadow") { [weak self] in self?.setBackground { $0.shadow.toggle() } }
        shadow.isOn = bg?.shadow ?? true
        s.addArrangedSubview(shadow)
    }

    // MARK: state

    var selected: Annotation? { selectedID.flatMap { id in doc.annotations.first { $0.id == id } } }

    private func docChanged(from old: AnnotationDocument) {
        let oldSize = renderer.canvasSize(old, cropping: tool == .crop)
        canvas?.updateSize()
        if let id = selectedID, doc.index(of: id) == nil { selectedID = nil }
        refreshChrome()
        if renderer.canvasSize(doc, cropping: tool == .crop) != oldSize, old.crop != doc.crop { zoomToFit() }
    }

    private func refreshChrome() {
        guard undoButton != nil else { return }
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        for (t, b) in toolButtons { b.isOn = t == tool && !showBackgroundPanel }
        bgButton.isOn = showBackgroundPanel || doc.background != nil
        updateStatus()
    }

    private func updateStatus() {
        let size = renderer.canvasSize(doc, cropping: tool == .crop)
        let s = renderer.scale
        statusLabel?.stringValue = "\(Int((size.width * s).rounded())) × \(Int((size.height * s).rounded())) px"
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
        rebuildProps()
        canvas.needsDisplay = true
    }

    func setTool(_ t: AnnotationTool) {
        canvas.endTextEditing()
        if t == .crop { beginCrop(); return }
        if tool == .crop { canvas.pendingCrop = nil }
        let wasCrop = tool == .crop
        tool = t
        showBackgroundPanel = false
        if t != .select { selectedID = nil }
        if wasCrop { canvas.updateSize(); zoomToFit() }
        window.invalidateCursorRects(for: canvas)
        rebuildProps()
        refreshChrome()
        canvas.needsDisplay = true
        window.makeFirstResponder(canvas)
    }

    func newAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> Annotation {
        Annotation(kind: kind, start: p, end: p, color: style.color, lineWidth: style.lineWidth,
                   filled: (kind == .rect || kind == .ellipse) && style.filled,
                   fontSize: style.fontSize, textBackground: style.textBackground, blurStyle: style.blurStyle)
    }

    // MARK: undo

    /// One undoable change.
    func commit(_ change: (inout AnnotationDocument) -> Void) {
        var d = doc
        change(&d)
        guard d != doc else { return }
        undoStack.append(doc)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        doc = d
    }

    /// Live update during a gesture (no undo entry). Pass nil to delete.
    func replaceLive(_ id: UUID, _ a: Annotation?) {
        guard let i = doc.index(of: id) else { return }
        if let a { doc.annotations[i] = a } else { doc.annotations.remove(at: i) }
        canvas.needsDisplay = true
    }

    func insertLive(_ a: Annotation) { doc.annotations.append(a) }

    /// Close a gesture: record `before` as one undo step if anything changed.
    func finishLive(before: AnnotationDocument) {
        guard before != doc else { return }
        undoStack.append(before)
        redoStack.removeAll()
        refreshChrome()
    }

    func undo() {
        canvas.endTextEditing()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = prev
        rebuildProps()
        canvas.needsDisplay = true
    }

    func redo() {
        canvas.endTextEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = next
        rebuildProps()
        canvas.needsDisplay = true
    }

    // MARK: properties

    func applyToSelection(_ f: (inout Annotation) -> Void) {
        if let id = canvas.editingID, var a = doc.annotations.first(where: { $0.id == id }) {
            f(&a)
            replaceLive(id, a)
            canvas.restyleEditing()
        } else if let id = selectedID, let i = doc.index(of: id) {
            commit { f(&$0.annotations[i]) }
        }
        canvas.needsDisplay = true
        if canvas.editingID != nil { window.makeFirstResponder(canvas.textView) }
    }

    private func setColor(_ c: RGBA) {
        style.color = c
        for s in swatches { s.isOn = s.color == c }
        colorWell?.color = c.ns
        applyToSelection { $0.color = c }
    }

    @objc private func wellChanged(_ w: NSColorWell) {
        let c = RGBA(w.color)
        style.color = c
        for s in swatches { s.isOn = s.color == c }
        applyToSelection { $0.color = c }
    }

    private func toggleFill() {
        let v = !(selected?.filled ?? style.filled)
        style.filled = v
        applyToSelection { if $0.kind == .rect || $0.kind == .ellipse { $0.filled = v } }
        rebuildProps()
    }

    // MARK: background

    private func toggleBackgroundPanel() {
        canvas.endTextEditing()
        if tool == .crop { cancelCrop() }
        showBackgroundPanel.toggle()
        if showBackgroundPanel && doc.background == nil {
            commit { $0.background = BackgroundStore.lastUsed ?? AnnotationBackground() }
        }
        if showBackgroundPanel { selectedID = nil }
        rebuildProps(); refreshChrome()
        zoomToFit()
    }

    /// Open the Background panel with `bg` applied (Quick Access "Background", `--background`).
    func showBackground(_ bg: AnnotationBackground) {
        canvas.endTextEditing()
        if tool == .crop { cancelCrop() }
        if doc.background == nil { commit { $0.background = bg } }
        showBackgroundPanel = true
        selectedID = nil
        rebuildProps(); refreshChrome()
        zoomToFit()
    }

    private func setBackground(_ f: (inout AnnotationBackground) -> Void) {
        commit { var b = $0.background ?? AnnotationBackground(); f(&b); $0.background = b }
        BackgroundStore.lastUsed = doc.background
        rebuildProps(); refreshChrome()
    }

    @objc private func bgWellChanged(_ w: NSColorWell) {
        let c = RGBA(w.color)
        slide { $0.kind = .solid(c) }
        // Don't rebuild the row (that would detach the live colour panel from this well) — just
        // clear the other chips' selection and fold the burst of changes into one undo step.
        for v in propsStack.arrangedSubviews {
            (v as? GradientChip)?.isOn = false
            (v as? NoneChip)?.isOn = false
            (v as? ChipStrip)?.stack.arrangedSubviews.forEach { ($0 as? ImageChip)?.isOn = false }
        }
        w.wantsLayer = true
        w.layer?.borderColor = NSColor.white.cgColor; w.layer?.borderWidth = 1.5; w.layer?.cornerRadius = 4
        guard !wellCommitPending else { return }
        wellCommitPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.wellCommitPending = false
            if let before = self.sliderBefore { self.sliderBefore = nil; self.finishLive(before: before) }
            BackgroundStore.lastUsed = self.doc.background
        }
    }
    private var wellCommitPending = false

    private func chooseBackgroundPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a background picture"
        panel.prompt = "Use Picture"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = panel.url else { return }
            _ = self?.useBackgroundPicture(u)
        }
    }

    /// Import (copy into Application Support) and apply a picture as the background.
    @discardableResult
    func useBackgroundPicture(_ url: URL) -> Bool {
        guard let local = BackgroundStore.importPicture(url) else { NSSound.beep(); return false }
        if !showBackgroundPanel { showBackground(BackgroundStore.lastUsed ?? AnnotationBackground()) }
        setBackground { $0.kind = .image(local.path) }
        return true
    }

    private func slide(_ f: (inout AnnotationBackground) -> Void) {
        if sliderBefore == nil { sliderBefore = doc }
        var b = doc.background ?? AnnotationBackground()
        f(&b)
        doc.background = b
        canvas.needsDisplay = true
        if NSApp.currentEvent?.type == .leftMouseUp, let before = sliderBefore {
            sliderBefore = nil
            finishLive(before: before)
            BackgroundStore.lastUsed = doc.background
        }
    }
    @objc private func paddingSlid(_ s: NSSlider) { slide { $0.padding = CGFloat(s.doubleValue).rounded() } }
    @objc private func radiusSlid(_ s: NSSlider) { slide { $0.cornerRadius = CGFloat(s.doubleValue).rounded() } }
    @objc private func blurSlid(_ s: NSSlider) { slide { $0.blur = CGFloat(s.doubleValue).rounded() } }

    // MARK: crop

    private func beginCrop() {
        guard tool != .crop else { return }
        toolBeforeCrop = tool
        tool = .crop
        showBackgroundPanel = false
        selectedID = nil
        canvas.pendingCrop = doc.crop
        canvas.updateSize()
        window.invalidateCursorRects(for: canvas)
        rebuildProps(); refreshChrome()
        zoomToFit()
    }

    func cropChanged() {
        canvas.needsDisplay = true
        updateStatus()
    }

    func applyCrop() {
        guard tool == .crop else { return }
        var c = canvas.pendingCrop.map { AnnotationGeometry.pixelAligned($0, scale: renderer.scale) }
        if let r = c, r.width < 2 || r.height < 2 || r.integral == renderer.imageBounds.integral { c = nil }
        commit { $0.crop = c }
        setTool(toolBeforeCrop == .crop ? .select : toolBeforeCrop)
    }

    func cancelCrop() {
        guard tool == .crop else { return }
        setTool(toolBeforeCrop == .crop ? .select : toolBeforeCrop)
    }

    // MARK: zoom

    func zoomToFit() {
        guard let clip = scroll?.contentView else { return }
        let avail = clip.frame.size
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, avail.width > 0 else { return }
        let m = min(1, avail.width / size.width, avail.height / size.height)
        scroll.magnification = max(scroll.minMagnification, m)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        updateZoomLabel()
        canvas.needsDisplay = true
    }

    private func zoom(by f: CGFloat) {
        let clip = scroll.contentView
        let c = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scroll.setMagnification(min(scroll.maxMagnification, max(scroll.minMagnification, scroll.magnification * f)), centeredAt: c)
        updateZoomLabel()
        canvas.needsDisplay = true
    }

    @objc private func magnified() { updateZoomLabel(); canvas.needsDisplay = true }
    @objc private func zoomLabelClicked() { zoomToFit() }
    private func updateZoomLabel() { zoomLabel?.title = "\(Int((scroll.magnification * 100).rounded()))%" }

    // MARK: keys

    /// ⌘-shortcuts. Returns true if handled.
    func handleCommand(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        // While typing, standard editing commands go to the text view.
        if let tv = canvas.textView, window.firstResponder === tv {
            switch ch {
            case "a": tv.selectAll(nil); return true
            case "c": tv.copy(nil); return true
            case "x": tv.cut(nil); return true
            case "v": tv.pasteAsPlainText(nil); return true
            case "z": if mods.contains(.shift) { tv.undoManager?.redo() } else { tv.undoManager?.undo() }; return true
            default: break
            }
        }
        switch ch {
        case "z": mods.contains(.shift) ? redo() : undo(); return true
        case "c": copyAndClose(); return true
        case "s": save(); return true
        case "w": window.performClose(nil); return true
        case "=", "+": zoom(by: 1.25); return true
        case "-": zoom(by: 0.8); return true
        case "0": zoomToFit(); return true
        case "1": scroll.magnification = 1; updateZoomLabel(); canvas.needsDisplay = true; return true
        default: return false
        }
    }

    /// Plain keys (tool shortcuts, delete, arrows, esc, return).
    func handleKey(_ e: NSEvent) -> Bool {
        if canvas.textView != nil { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        switch e.keyCode {
        case 53: escape(); return true
        case 36, 76:
            if tool == .crop { applyCrop(); return true }
            if let s = selected, s.kind == .text { canvas.beginTextEditing(s.id); return true }
            return false
        case 51, 117:
            if let id = selectedID, let i = doc.index(of: id) { commit { $0.annotations.remove(at: i) }; select(nil) }
            return true
        case 123, 124, 125, 126:
            guard let id = selectedID, let a = selected else { return false }
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            let d: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                               125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][e.keyCode]!
            let i = doc.index(of: id)!
            commit { $0.annotations[i] = a.translated(by: d) }
            return true
        default: break
        }
        guard let c = e.charactersIgnoringModifiers?.lowercased().first else { return false }
        if c == "f" { toggleFill(); return true }
        if let t = AnnotationTool.allCases.first(where: { $0.key == c }) { setTool(t); return true }
        return false
    }

    func escape() {
        if canvas.textView != nil { canvas.endTextEditing(); return }
        if tool == .crop { cancelCrop(); return }
        if showBackgroundPanel { showBackgroundPanel = false; rebuildProps(); refreshChrome(); return }
        if selectedID != nil { select(nil); return }
        window.performClose(nil)
    }

    // MARK: output

    func flattened() -> CGImage? {
        canvas.endTextEditing()
        return renderer.flatten(doc)
    }

    var outputPointSize: CGSize { renderer.canvasSize(doc) }

    func copyAndClose() {
        guard let img = flattened() else { NSSound.beep(); return }
        Output.copyToClipboard(img, pointSize: outputPointSize)
        if let item {
            item.image = img
            item.pointSize = outputPointSize
        }
        window.close()
    }

    func save() {
        guard let img = flattened() else { NSSound.beep(); return }
        let fmt: ImageFormat
        var target: URL?
        if let s = item?.savedURL {
            target = s
        } else {
            let panel = NSSavePanel()
            let ext = Prefs.shared.imageFormat == .png ? "png" : "jpg"
            if let src = sourceURL, item == nil {
                panel.directoryURL = src.deletingLastPathComponent()
                panel.nameFieldStringValue = src.lastPathComponent
            } else {
                panel.directoryURL = Prefs.shared.saveDirectory
                panel.nameFieldStringValue = Naming.filename(.screenshot, date: Date(), ext: ext)
            }
            panel.allowedContentTypes = [.png, .jpeg]
            panel.isExtensionHidden = false
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let u = panel.url else { return }
            target = u
        }
        guard let url = target else { return }
        let ext = url.pathExtension.lowercased()
        fmt = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
        guard let data = Annotator.encode(img, format: fmt, scale: renderer.scale) else { NSSound.beep(); return }
        do { try data.write(to: url, options: .atomic) } catch {
            let a = NSAlert(); a.messageText = "Could not save"; a.informativeText = error.localizedDescription
            a.beginSheetModal(for: window); return
        }
        if let item {
            item.savedURL = url
            item.image = img
            item.pointSize = outputPointSize
            if let id = item.historyID {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                if let png = Output.encode(img, format: .png), (try? png.write(to: tmp)) != nil {
                    HistoryStore.shared.replaceFile(id: id, with: tmp)
                    try? FileManager.default.removeItem(at: tmp)
                }
                HistoryStore.shared.setSavedPath(id: id, url.path)
            }
        }
        flashStatus("Saved to \(url.lastPathComponent)")
    }

    private func flashStatus(_ s: String) {
        statusLabel.stringValue = s
        statusLabel.textColor = .white
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.statusLabel.textColor = Chrome.iconDim
            self?.updateStatus()
        }
    }

    private func dragPayload() -> (URL, NSImage)? {
        guard let img = flattened(), let png = Annotator.encode(img, format: .png, scale: renderer.scale) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapper Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = item?.savedURL?.deletingPathExtension().lastPathComponent
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? Naming.filename(.screenshot, date: Date(), ext: "png").replacingOccurrences(of: ".png", with: "")
        let url = dir.appendingPathComponent(name + ".png")
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        return (url, NSImage(cgImage: img, size: outputPointSize))
    }

    // MARK: demo

    func loadDemo() {
        commit { $0 = Annotator.demoDocument(size: renderer.pointSize) }
        if let t = doc.annotations.first(where: { $0.kind == .rect }) { select(t.id); setTool(.select); select(t.id) }
    }
}
