import AppKit
import ImageIO
import SnapKit
import UniformTypeIdentifiers

/// Where background pictures come from: the current desktop picture, the user's own picks (copied
/// into Application Support so they survive), and the full-res wallpapers macOS ships.
enum BackgroundStore {
    private static let recentsKey = "annotateBackgroundRecents"
    private static let lastKey = "annotateLastBackground"
    static let maxRecents = 6

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Snapper/Backgrounds", isDirectory: true)
    }

    /// The main screen's desktop picture, if it is a plain image file.
    static var currentDesktopPicture: URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let u = NSWorkspace.shared.desktopImageURL(for: screen), u.isFileURL else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue,
              BackgroundLibrary.isImageFile(u) else { return nil }
        return u
    }

    static var wallpapers: [URL] { BackgroundLibrary.systemWallpapers() }

    /// Recently chosen pictures (most recent first), only those still on disk.
    static var recents: [URL] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func remember(_ url: URL) {
        var list = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxRecents)), forKey: recentsKey)
    }

    /// Copy a user-picked picture into Snapper's Backgrounds folder (dedup by name + size) and remember it.
    static func importPicture(_ src: URL) -> URL? {
        guard BackgroundLibrary.isImageFile(src) || UTType(filenameExtension: src.pathExtension)?.conforms(to: .image) == true
        else { return nil }
        let fm = FileManager.default
        if src.path.hasPrefix(directory.path + "/") { remember(src); return src }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var dst = directory.appendingPathComponent(src.lastPathComponent)
            let srcSize = (try? fm.attributesOfItem(atPath: src.path)[.size] as? Int) ?? -1
            if fm.fileExists(atPath: dst.path) {
                let dstSize = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? -2
                if dstSize != srcSize {
                    let stem = src.deletingPathExtension().lastPathComponent
                    dst = directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(6)).\(src.pathExtension)")
                    try fm.copyItem(at: src, to: dst)
                }
            } else {
                try fm.copyItem(at: src, to: dst)
            }
            guard BackgroundImageCache.decode(dst, maxPixel: 64) != nil else { try? fm.removeItem(at: dst); return nil }
            BackgroundImageCache.shared.forget(dst.path)
            remember(dst)
            return dst
        } catch {
            return nil
        }
    }

    /// The background from Settings › Background. Tweaks made inside one Annotate window stay in that
    /// window only; the Settings choice is the default everywhere.
    static var lastUsed: AnnotationBackground? {
        get { Prefs.shared.background }
        set { }
    }

    /// A sensible first background: the last used one, else the first wallpaper, else a gradient.
    static var defaultForWindowShots: AnnotationBackground {
        if let b = lastUsed { return b }
        if let w = wallpapers.first { return AnnotationBackground(kind: .image(w.path)) }
        return AnnotationBackground()
    }
}

/// Small downscaled previews for the chip strip, decoded off the main thread and cached.
@MainActor final class BackgroundThumbs {
    static let shared = BackgroundThumbs()
    private var cache: [String: NSImage] = [:]
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    func thumb(_ url: URL, _ done: @escaping (NSImage) -> Void) {
        let key = url.path
        if let img = cache[key] { done(img); return }
        if waiting[key] != nil { waiting[key]!.append(done); return }
        waiting[key] = [done]
        // macOS ships small previews for its wallpapers; decoding those is far cheaper.
        let small = url.deletingLastPathComponent().appendingPathComponent(".thumbnails").appendingPathComponent(url.lastPathComponent)
        let src = FileManager.default.fileExists(atPath: small.path) ? small : url
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = BackgroundImageCache.decode(src, maxPixel: 120)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } ?? NSImage()
                    self.cache[key] = img
                    for f in self.waiting.removeValue(forKey: key) ?? [] { f(img) }
                }
            }
        }
    }
}

/// 30×22 picture chip (aspect-fill thumbnail, ring when selected).
final class ImageChip: NSView {
    let url: URL
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var thumb: NSImage?
    private var hover = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    init(_ url: URL, tip: String? = nil) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        toolTip = tip ?? url.deletingPathExtension().lastPathComponent
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        MainActor.assumeIsolated {
            BackgroundThumbs.shared.thumb(url) { [weak self] img in self?.thumb = img; self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 3, y: 4, width: 26, height: 14)
        let clip = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor(white: 0.25, alpha: 1).setFill(); r.fill()
        if let t = thumb, t.size.width > 0 {
            let f = AnnotationRenderer.aspectFill(t.size, in: r)
            t.draw(in: f, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        if isOn || hover {
            (isOn ? NSColor.white : NSColor(white: 1, alpha: 0.35)).setStroke()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 4.5, yRadius: 4.5); b.lineWidth = 1.5; b.stroke()
        } else {
            NSColor(white: 1, alpha: 0.15).setStroke()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 3.5, yRadius: 3.5); b.lineWidth = 0.5; b.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// "No background" chip: a struck-through outline.
final class NoneChip: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        toolTip = "No background"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 3, y: 4, width: 18, height: 14)
        NSColor(white: 1, alpha: 0.45).setStroke()
        let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); b.lineWidth = 1; b.stroke()
        let l = NSBezierPath(); l.move(to: NSPoint(x: r.minX + 2, y: r.minY + 2)); l.line(to: NSPoint(x: r.maxX - 2, y: r.maxY - 2))
        NSColor(srgbRed: 1, green: 0.35, blue: 0.3, alpha: 0.9).setStroke(); l.lineWidth = 1.2; l.stroke()
        if isOn {
            NSColor.white.setStroke()
            let o = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 5, yRadius: 5); o.lineWidth = 1.5; o.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Horizontally scrolling strip of chips (vertical wheel scrolls it sideways too).
final class ChipStrip: NSScrollView {
    let stack = NSStackView()
    private var widthPref: NSLayoutConstraint!

    init(_ views: [NSView]) {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = false; hasVerticalScroller = false
        horizontalScrollElasticity = .allowed; verticalScrollElasticity = .none
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal; stack.spacing = 0; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        views.forEach { stack.addArrangedSubview($0) }
        let doc = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc
        let contentW = CGFloat(views.count) * 32
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: contentView.heightAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            // Never narrower than 3½ chips, so a cut-off chip hints that the strip scrolls.
            widthAnchor.constraint(greaterThanOrEqualToConstant: min(contentW, 32 * 3.5)),
            widthAnchor.constraint(lessThanOrEqualToConstant: max(contentW, 1)),
        ])
        widthPref = widthAnchor.constraint(equalToConstant: contentW)
        widthPref.priority = .defaultLow
        widthPref.isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let doc = documentView {
            let clip = contentView
            var o = clip.bounds.origin
            o.x = max(0, min(doc.frame.width - clip.bounds.width, o.x - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)))
            clip.scroll(to: o)
            reflectScrolledClipView(clip)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func layout() {
        super.layout()
        updateFade()
    }
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        updateFade()
    }

    /// Fade the edges that have more chips beyond them.
    private func updateFade() {
        guard let doc = documentView else { return }
        wantsLayer = true
        let x = contentView.bounds.minX, visW = contentView.bounds.width
        let moreLeft = x > 1, moreRight = x + visW < doc.frame.width - 1
        guard moreLeft || moreRight, bounds.width > 0 else { layer?.mask = nil; return }
        let g = (layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        g.frame = bounds
        g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
        let f = Double(min(0.25, 18 / bounds.width))
        g.colors = [moreLeft ? NSColor.clear.cgColor : NSColor.black.cgColor, NSColor.black.cgColor,
                    NSColor.black.cgColor, moreRight ? NSColor.clear.cgColor : NSColor.black.cgColor]
        g.locations = [0, NSNumber(value: f), NSNumber(value: 1 - f), 1]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.mask = g
        CATransaction.commit()
    }

    func scrollToShow(_ v: NSView) {
        guard let doc = documentView else { return }
        layoutSubtreeIfNeeded()
        doc.scrollToVisible(v.convert(v.bounds, to: doc).insetBy(dx: -8, dy: 0))
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Window content view that accepts dropped image files (used to set a background picture).
final class DropRootView: NSView {
    /// Return true if the drop was used. When nil, drops are refused.
    var onDropImage: ((URL) -> Bool)?
    var acceptsDrops: () -> Bool = { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func imageURL(_ info: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                          .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?.first
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrops() && imageURL(sender) != nil ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrops(), let u = imageURL(sender) else { return false }
        return onDropImage?(u) ?? false
    }
}
