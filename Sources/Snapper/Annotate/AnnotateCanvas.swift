import AppKit
import SnapKit

/// The drawing surface. Lives inside a magnifying NSScrollView, so its own coordinates are canvas
/// points (+ `margin`), y-down. Image space = canvas space shifted by the renderer's image origin.
final class AnnotateCanvas: NSView, NSTextViewDelegate {
    unowned let editor: AnnotateEditor
    let margin: CGFloat = 28

    private enum Handle: Equatable { case box(Int), start, end }
    private enum Drag {
        case draw(Annotation)
        case move(UUID, Annotation, CGPoint)
        case handle(UUID, Annotation, Handle, CGPoint)
        case cropNew(CGPoint)
        case cropMove(CGRect, CGPoint)
        case cropHandle(CGRect, Int, CGPoint)
    }
    private var drag: Drag?
    private var dragBefore: AnnotationDocument?

    /// Pending crop rect (image space) while the crop tool is active.
    var pendingCrop: CGRect?

    // Inline text editing.
    private(set) var textView: NSTextView?
    private(set) var editingID: UUID?
    private var editBefore: AnnotationDocument?

    init(editor: AnnotateEditor) {
        self.editor = editor
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var renderer: AnnotationRenderer { editor.renderer }
    var doc: AnnotationDocument { editor.doc }
    var cropMode: Bool { editor.tool == .crop }
    var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: coordinates

    var imageOrigin: CGPoint { renderer.imageOrigin(doc, cropping: cropMode) }
    func toImage(_ v: CGPoint) -> CGPoint { CGPoint(x: v.x - margin - imageOrigin.x, y: v.y - margin - imageOrigin.y) }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + margin + imageOrigin.x, y: p.y + margin + imageOrigin.y) }
    func toView(_ r: CGRect) -> CGRect { CGRect(origin: toView(r.origin), size: r.size) }

    func updateSize() {
        let s = renderer.canvasSize(doc, cropping: cropMode)
        setFrameSize(NSSize(width: s.width + 2 * margin, height: s.height + 2 * margin))
        needsDisplay = true
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var shown = doc
        if case .draw(let a)? = drag { shown.annotations.append(a) }
        var skip: Set<UUID> = []
        if let id = editingID { skip.insert(id) }

        ctx.saveGState()
        ctx.translateBy(x: margin, y: margin)
        let size = renderer.canvasSize(doc, cropping: cropMode)
        if doc.background == nil || cropMode {
            // Soft drop shadow so the image floats on the dark canvas.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: CGColor(gray: 0, alpha: 0.6))
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        renderer.drawCanvas(shown, in: ctx, skip: skip, cropping: cropMode)
        ctx.restoreGState()

        ctx.saveGState()
        let o = toView(CGPoint.zero)
        ctx.translateBy(x: o.x, y: o.y)
        if let id = editingID, let a = doc.annotations.first(where: { $0.id == id }), a.textBackground {
            // Pill behind the live NSTextView.
            let box = CGRect(origin: a.start, size: AnnotationText.boxSize(a))
            let rad = min(box.height / 2, a.fontSize * 0.5)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setFillColor(a.color.cgColor); ctx.fillPath()
        }
        if cropMode { drawCropOverlay(ctx) } else { drawSelection(ctx) }
        ctx.restoreGState()
    }

    private var handleSize: CGFloat { 8 / zoom }

    private func drawSelection(_ ctx: CGContext) {
        guard let id = editor.selectedID, let a = doc.annotations.first(where: { $0.id == id }) else { return }
        let px = 1 / zoom
        let accent = NSColor.controlAccentColor.cgColor
        if a.isSegment {
            ctx.setStrokeColor(accent); ctx.setLineWidth(px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            ctx.move(to: a.start); ctx.addLine(to: a.end); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            let b = a.bounds.insetBy(dx: -3 * px, dy: -3 * px)
            ctx.setStrokeColor(accent); ctx.setLineWidth(px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            ctx.stroke(b)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (_, p) in handles(of: a) { drawHandle(ctx, p) }
    }

    private func drawHandle(_ ctx: CGContext, _ p: CGPoint) {
        let s = handleSize
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.setFillColor(.white)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.2 / zoom)
        ctx.addEllipse(in: r); ctx.drawPath(using: .fillStroke)
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        let img = renderer.imageBounds
        let c = pendingCrop ?? img
        let px = 1 / zoom
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        let p = CGMutablePath(); p.addRect(img); p.addRect(c)
        ctx.addPath(p); ctx.fillPath(using: .evenOdd)
        // thirds
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); ctx.setLineWidth(px)
        for i in 1...2 {
            let fx = c.minX + c.width * CGFloat(i) / 3, fy = c.minY + c.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: fx, y: c.minY)); ctx.addLine(to: CGPoint(x: fx, y: c.maxY))
            ctx.move(to: CGPoint(x: c.minX, y: fy)); ctx.addLine(to: CGPoint(x: c.maxX, y: fy))
        }
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); ctx.setLineWidth(px)
        ctx.stroke(c)
        // L-shaped corners + edge bars
        let L = min(18 * px, c.width / 3, c.height / 3), t = 3 * px
        ctx.setFillColor(.white)
        for h in AnnotationGeometry.boxHandles {
            let pt = AnnotationGeometry.handlePoint(c, h)
            if h.x != 0 && h.y != 0 {
                let sx = CGFloat(-h.x), sy = CGFloat(-h.y)
                ctx.fill(CGRect(x: min(pt.x, pt.x + sx * L), y: pt.y - (sy > 0 ? 0 : t) , width: L, height: t).standardized)
                ctx.fill(CGRect(x: pt.x - (sx > 0 ? 0 : t), y: min(pt.y, pt.y + sy * L), width: t, height: L).standardized)
            } else if h.x == 0 {
                ctx.fill(CGRect(x: pt.x - L / 2, y: pt.y - t / 2, width: L, height: t))
            } else {
                ctx.fill(CGRect(x: pt.x - t / 2, y: pt.y - L / 2, width: t, height: L))
            }
        }
        // size label
        let s = renderer.scale
        let label = "\(Int((c.width * s).rounded())) × \(Int((c.height * s).rounded()))" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11 * px, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        var lr = CGRect(x: c.midX - sz.width / 2 - 6 * px, y: c.maxY + 6 * px, width: sz.width + 12 * px, height: sz.height + 4 * px)
        if lr.maxY > img.maxY { lr.origin.y = c.maxY - lr.height - 6 * px }
        NSGraphicsContext.saveGraphicsState()
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: lr, xRadius: 4 * px, yRadius: 4 * px).fill()
        label.draw(at: CGPoint(x: lr.minX + 6 * px, y: lr.minY + 2 * px), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func handles(of a: Annotation) -> [(Handle, CGPoint)] {
        if a.isSegment { return [(.start, a.start), (.end, a.end)] }
        if a.isBoxed {
            return AnnotationGeometry.boxHandles.enumerated().map { (.box($0.offset), AnnotationGeometry.handlePoint(a.rect, $0.element)) }
        }
        return []
    }

    // MARK: mouse

    override func resetCursorRects() {
        let c: NSCursor
        switch editor.tool {
        case .select: c = .arrow
        case .text: c = .iBeam
        default: c = .crosshair
        }
        addCursorRect(visibleRect, cursor: c)
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        let p = toImage(v)
        if textView != nil {
            // Clicking outside the text box commits it.
            endTextEditing()
            if editor.tool == .text { return }
        }
        window?.makeFirstResponder(self)
        let tol = 4 / zoom
        dragBefore = doc

        if cropMode {
            let c = pendingCrop ?? renderer.imageBounds
            for (i, h) in AnnotationGeometry.boxHandles.enumerated() {
                let hp = AnnotationGeometry.handlePoint(c, h)
                if hypot(hp.x - p.x, hp.y - p.y) <= 10 / zoom { drag = .cropHandle(c, i, p); return }
            }
            drag = c.contains(p) ? .cropMove(c, p) : .cropNew(p)
            return
        }

        // Handles of the current selection win.
        if let id = editor.selectedID, let a = doc.annotations.first(where: { $0.id == id }) {
            for (h, hp) in handles(of: a) where hypot(hp.x - p.x, hp.y - p.y) <= handleSize * 0.9 + 2 / zoom {
                drag = .handle(id, a, h, p); return
            }
            if a.hitTest(p, tolerance: tol) && editor.tool != .counter {
                if event.clickCount == 2, a.kind == .text { beginTextEditing(id); return }
                drag = .move(id, a, p); return
            }
        }

        switch editor.tool {
        case .select:
            if let hit = doc.hit(p, tolerance: tol) {
                editor.select(hit.id)
                if event.clickCount == 2, hit.kind == .text { beginTextEditing(hit.id); return }
                drag = .move(hit.id, hit, p)
            } else {
                editor.select(nil)
            }
        case .text:
            if let hit = doc.hit(p, tolerance: tol), hit.kind == .text {
                editor.select(hit.id); beginTextEditing(hit.id); return
            }
            var a = editor.newAnnotation(.text, at: p)
            let h = AnnotationText.boxSize(a).height
            a.start = CGPoint(x: p.x - AnnotationText.padding(a).width, y: p.y - h / 2)
            let before = doc
            editor.insertLive(a)
            editor.select(a.id)
            beginTextEditing(a.id, before: before)
        case .counter:
            var a = editor.newAnnotation(.counter, at: p)
            a.number = doc.nextCounter
            editor.insertLive(a)       // dragBefore (set above) makes place+move one undo step
            editor.select(a.id)
            drag = .move(a.id, a, p)
        default:
            guard let kind = editor.tool.kind else { return }
            editor.select(nil)
            var a = editor.newAnnotation(kind, at: p)
            if kind == .pencil || kind == .highlighter { a.points = [p] }
            drag = .draw(a)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        autoscroll(with: event)
        switch d {
        case .draw(var a):
            switch a.kind {
            case .pencil, .highlighter:
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) < 1.2 / zoom { return }
                if shift, let first = a.points.first {
                    a.points = [first, AnnotationGeometry.snap45(from: first, to: p)]   // straight stroke
                } else { a.points.append(p) }
                a.end = p
            case .arrow, .line:
                a.end = shift ? AnnotationGeometry.snap45(from: a.start, to: p) : p
            default:
                a.end = shift ? AnnotationGeometry.square(from: a.start, to: p) : p
            }
            drag = .draw(a)
        case .move(let id, let orig, let p0):
            let moved = orig.translated(by: CGVector(dx: p.x - p0.x, dy: p.y - p0.y))
            editor.replaceLive(id, moved)
        case .handle(let id, let orig, let h, let p0):
            var a = orig
            let dv = CGVector(dx: p.x - p0.x, dy: p.y - p0.y)
            switch h {
            case .start: a.start = shift ? AnnotationGeometry.snap45(from: orig.end, to: p) : CGPoint(x: orig.start.x + dv.dx, y: orig.start.y + dv.dy)
            case .end: a.end = shift ? AnnotationGeometry.snap45(from: orig.start, to: p) : CGPoint(x: orig.end.x + dv.dx, y: orig.end.y + dv.dy)
            case .box(let i): a.rect = AnnotationGeometry.resize(orig.rect, handle: AnnotationGeometry.boxHandles[i], by: dv, minSize: 2)
            }
            editor.replaceLive(id, a)
        case .cropNew(let p0):
            pendingCrop = clampCrop(CGRect(x: min(p0.x, p.x), y: min(p0.y, p.y), width: abs(p.x - p0.x), height: abs(p.y - p0.y)))
            editor.cropChanged()
        case .cropMove(let r, let p0):
            pendingCrop = Geo.clampMove(r.offsetBy(dx: p.x - p0.x, dy: p.y - p0.y), into: renderer.imageBounds)
            editor.cropChanged()
        case .cropHandle(let r, let i, let p0):
            pendingCrop = clampCrop(AnnotationGeometry.resize(r, handle: AnnotationGeometry.boxHandles[i],
                                                              by: CGVector(dx: p.x - p0.x, dy: p.y - p0.y), minSize: 8))
            editor.cropChanged()
        }
        needsDisplay = true
    }

    private func clampCrop(_ r: CGRect) -> CGRect {
        let c = r.intersection(renderer.imageBounds)
        return c.isNull ? .zero : c
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; dragBefore = nil; needsDisplay = true }
        guard let d = drag else { return }
        switch d {
        case .draw(let a):
            let big: Bool
            switch a.kind {
            case .pencil, .highlighter: big = a.points.count > 1 || event.clickCount > 0
            case .arrow, .line: big = a.length >= 4
            default: big = a.rect.width >= 3 && a.rect.height >= 3
            }
            guard big else { return }
            editor.commit { $0.annotations.append(a) }
            if a.kind != .pencil && a.kind != .highlighter { editor.select(a.id) }
        case .move, .handle:
            if let before = dragBefore { editor.finishLive(before: before) }
        case .cropNew, .cropMove, .cropHandle:
            if let c = pendingCrop, c.width < 4 || c.height < 4 { pendingCrop = nil }
            editor.cropChanged()
        }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if !editor.handleKey(event) { super.keyDown(with: event) }
    }

    // MARK: text editing

    func beginTextEditing(_ id: UUID, before: AnnotationDocument? = nil) {
        guard let a = doc.annotations.first(where: { $0.id == id }) else { return }
        endTextEditing()
        editingID = id
        editBefore = before ?? doc
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: 100_000, height: 100_000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.focusRingType = .none
        tv.delegate = self
        tv.string = a.text
        styleTextView(tv, a)
        addSubview(tv)
        textView = tv
        layoutTextView()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func styleTextView(_ tv: NSTextView, _ a: Annotation) {
        let ct = AnnotationText.font(size: a.fontSize)
        let font = unsafeBitCast(ct, to: NSFont.self)
        let lh = AnnotationText.lineHeight(ct)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lh; para.maximumLineHeight = lh
        let color: NSColor = a.textBackground ? (a.color.isLight ? NSColor(white: 0.08, alpha: 1) : .white) : a.color.ns
        tv.font = font
        tv.textColor = color
        tv.insertionPointColor = a.textBackground ? color : a.color.ns
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        tv.textStorage?.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para],
                                      range: NSRange(location: 0, length: tv.textStorage?.length ?? 0))
        let pad = AnnotationText.padding(a)
        tv.textContainerInset = NSSize(width: pad.width, height: pad.height)
    }

    /// Restyle the live editor after the user changed colour / size / pill.
    func restyleEditing() {
        guard let tv = textView, let id = editingID, let a = doc.annotations.first(where: { $0.id == id }) else { return }
        styleTextView(tv, a)
        layoutTextView()
    }

    func layoutTextView() {
        guard let tv = textView, let id = editingID, let a = doc.annotations.first(where: { $0.id == id }) else { return }
        let box = AnnotationText.boxSize(a)
        tv.frame = CGRect(origin: toView(a.start), size: CGSize(width: box.width + a.fontSize, height: box.height))
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID, var a = doc.annotations.first(where: { $0.id == id }) else { return }
        a.text = tv.string
        editor.replaceLive(id, a)
        layoutTextView()
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) || mods.contains(.option) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            endTextEditing(); return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endTextEditing(); return true }
        return false
    }

    func endTextEditing() {
        guard let tv = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        tv.removeFromSuperview()
        let text = tv.string
        let before = editBefore
        editBefore = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.replaceLive(id, nil)
            if editor.selectedID == id { editor.select(nil) }
        }
        if let before { editor.finishLive(before: before) }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
