import AppKit
import SnapKit

// Small, flat controls for the Annotate chrome. No bezels, no big round buttons.

extension RGBA {
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        self.init(s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
}

enum Chrome {
    static let barColor = NSColor(white: 0.135, alpha: 1)
    static let subBarColor = NSColor(white: 0.115, alpha: 1)
    static let canvasColor = NSColor(white: 0.075, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.07)
    static let icon = NSColor(white: 1, alpha: 0.78)
    static let iconDim = NSColor(white: 1, alpha: 0.45)
    static var accent: NSColor { .controlAccentColor }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    static func separator(height: CGFloat = 16) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
}

/// Bar that lets the window be dragged by its empty areas.
final class DragBar: NSView {
    var fill: NSColor = Chrome.barColor
    var bottomLine = true
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        if bottomLine { Chrome.hairline.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
    }
}

/// 26×24 icon button with hover + selected states.
final class IconButton: NSButton {
    var isOn = false { didSet { refresh() } }
    var onClick: (() -> Void)?
    private var hover = false { didSet { refresh() } }
    private var area: NSTrackingArea?

    init(symbol: String, tip: String, size: CGFloat = 13, width: CGFloat = 28, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        isBordered = false
        title = ""
        if let img = Chrome.symbol(symbol, size: size) { image = img; imagePosition = .imageOnly } else { title = String(tip.prefix(2)) }
        toolTip = tip
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        target = self
        action = #selector(fire)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override var isEnabled: Bool { didSet { refresh() } }

    private func refresh() {
        contentTintColor = !isEnabled ? NSColor(white: 1, alpha: 0.25) : isOn ? Chrome.accent : (hover ? .white : Chrome.icon)
        layer?.backgroundColor = isOn ? NSColor(white: 1, alpha: 0.13).cgColor
            : (hover && isEnabled ? NSColor(white: 1, alpha: 0.07).cgColor : NSColor.clear.cgColor)
    }
}

/// A row of mutually-exclusive tiny buttons drawn by a closure (stroke widths, text sizes…).
final class Segmented: NSView {
    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    let count: Int
    let cell: CGSize
    let drawItem: (Int, NSRect, NSColor) -> Void
    var tips: [String] = []

    init(count: Int, cell: CGSize = CGSize(width: 26, height: 22), draw: @escaping (Int, NSRect, NSColor) -> Void) {
        self.count = count; self.cell = cell; self.drawItem = draw
        super.init(frame: NSRect(x: 0, y: 0, width: cell.width * CGFloat(count), height: cell.height))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: cell.width * CGFloat(count)).isActive = true
        heightAnchor.constraint(equalToConstant: cell.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTips(_ t: [String]) {
        tips = t
        removeAllToolTips()
        for i in 0..<count where i < t.count { addToolTip(rect(i), owner: t[i] as NSString, userData: nil) }
    }

    private func rect(_ i: Int) -> NSRect { NSRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height) }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<count {
            let r = rect(i)
            if i == selected {
                NSColor(white: 1, alpha: 0.13).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            drawItem(i, r, i == selected ? .white : Chrome.iconDim)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.x / cell.width)
        guard i >= 0, i < count else { return }
        selected = i
        onChange?(i)
    }
}

/// Small colour dot. Ring when selected.
final class Swatch: NSView {
    let color: RGBA
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    init(_ c: RGBA) {
        color = c
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let c = NSRect(x: bounds.midX - 6.5, y: bounds.midY - 6.5, width: 13, height: 13)
        if isOn {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: -2.5, dy: -2.5)); ring.lineWidth = 1.5; ring.stroke()
        }
        color.ns.setFill()
        NSBezierPath(ovalIn: c).fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        let edge = NSBezierPath(ovalIn: c.insetBy(dx: 0.25, dy: 0.25)); edge.lineWidth = 0.5; edge.stroke()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Small rounded gradient chip for the Background presets.
final class GradientChip: NSView {
    let preset: Int
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    init(_ i: Int) {
        preset = i
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 3, y: 4, width: 18, height: 14)
        let p = AnnotationBackground.presets[preset]
        NSGradient(starting: p.0.ns, ending: p.1.ns)?.draw(in: NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4), angle: -35)
        if isOn {
            NSColor.white.setStroke()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 5, yRadius: 5); b.lineWidth = 1.5; b.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Drag this to drop the flattened PNG into Finder / any app.
final class DragOutButton: NSView, NSDraggingSource {
    var provide: (() -> (URL, NSImage)?)?
    private var down: NSPoint?
    private var hover = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?
    private let icon = Chrome.symbol("hand.point.up.left", size: 13)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        toolTip = "Drag the annotated image to Finder or another app"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func draw(_ dirtyRect: NSRect) {
        if hover {
            NSColor(white: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        guard let icon else { return }
        let tinted = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r)
            (self.hover ? NSColor.white : Chrome.icon).set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (bounds.width - icon.size.width) / 2, y: (bounds.height - icon.size.height) / 2,
                               width: icon.size.width, height: icon.size.height))
    }

    override func mouseDown(with event: NSEvent) { down = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let d = down, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) > 3,
              let (url, preview) = provide?() else { return }
        down = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let s = preview.size
        let k = min(1, 160 / max(s.width, s.height, 1))
        let size = NSSize(width: s.width * k, height: s.height * k)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// Keeps the document centred when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }
}
