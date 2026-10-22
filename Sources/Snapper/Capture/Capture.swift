import AppKit
import SnapKit
import UniformTypeIdentifiers

/// One finished capture, as passed to Quick Access, Annotate, Pin and History.
final class CaptureItem {
    let kind: CaptureKind
    var image: CGImage?            // nil for videos
    /// The working file (history copy). Always exists.
    var fileURL: URL
    /// The user-visible saved file, if auto-save or "Save" put one somewhere.
    var savedURL: URL?
    var historyID: UUID?
    /// Points size the image covered on screen (for pinning at 1:1).
    var pointSize: CGSize

    init(kind: CaptureKind, image: CGImage?, fileURL: URL, savedURL: URL?, historyID: UUID?, pointSize: CGSize) {
        self.kind = kind; self.image = image; self.fileURL = fileURL; self.savedURL = savedURL
        self.historyID = historyID; self.pointSize = pointSize
    }

    var nsImage: NSImage? {
        if let image { return NSImage(cgImage: image, size: pointSize) }
        return NSImage(contentsOf: fileURL)
    }
}

enum Capture {
    static var lastArea: (rect: CGRect, display: CGDirectDisplayID)? {
        get {
            guard let a = UserDefaults.standard.array(forKey: "lastArea") as? [Double], a.count == 5 else { return nil }
            return (CGRect(x: a[0], y: a[1], width: a[2], height: a[3]), CGDirectDisplayID(a[4]))
        }
        set {
            guard let n = newValue else { UserDefaults.standard.removeObject(forKey: "lastArea"); return }
            UserDefaults.standard.set([n.rect.minX, n.rect.minY, n.rect.width, n.rect.height, Double(n.display)], forKey: "lastArea")
        }
    }

    /// Area / window selection over a frozen screen. `then` overrides the default output (Quick Access).
    static func area(windowMode: Bool = false, then: ((CaptureItem) -> Void)? = nil) {
        guard OverlayController.current == nil, Permissions.ensureScreenRecording() else { return }
        Task { @MainActor in
            let shots: [CGDirectDisplayID: CGImage]
            do { shots = try await ScreenGrabber.captureAllDisplays() } catch { Permissions.showError("Capture failed", error); return }
            OverlayController.begin(shots: shots, windowMode: windowMode) { r in
                guard let r else { return }
                Task { @MainActor in
                    do {
                        let (img, pts) = try await image(for: r, shots: shots)
                        if r.windowID == nil { lastArea = (r.rect, r.displayID) }
                        let item = try Output.finish(img, kind: .screenshot, pointSize: pts, presentQuickAccess: then == nil, isWindow: r.windowID != nil)
                        then?(item)
                    } catch { Permissions.showError("Capture failed", error) }
                }
            }
        }
    }

    /// Crop a frozen display image to the selection, or grab the picked window on its own.
    @MainActor
    static func image(for r: OverlayResult, shots: [CGDirectDisplayID: CGImage]) async throws -> (CGImage, CGSize) {
        if let wid = r.windowID {
            let img = try await ScreenGrabber.captureWindow(wid)
            let scale = r.screen.backingScaleFactor
            return (img, CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
        }
        guard let shot = shots[r.displayID] else { throw GrabError(message: "No frozen image for the display") }
        return (try crop(shot, global: r.rect, screen: r.screen), r.rect.size)
    }

    static func crop(_ shot: CGImage, global: CGRect, screen: NSScreen) throws -> CGImage {
        let local = global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let px = Geo.pixelRect(viewRect: local, viewSize: screen.frame.size, imageSize: CGSize(width: shot.width, height: shot.height))
        guard px.width >= 1, px.height >= 1, let c = shot.cropping(to: px) else { throw GrabError(message: "Selection is empty") }
        return c
    }

    static func fullscreen(then: ((CaptureItem) -> Void)? = nil) {
        guard Permissions.ensureScreenRecording() else { return }
        let s = NSScreen.underMouse
        Task { @MainActor in
            do {
                let img = try await ScreenGrabber.captureDisplay(s.displayID)
                let item = try Output.finish(img, kind: .screenshot, pointSize: s.frame.size, presentQuickAccess: then == nil)
                then?(item)
            } catch { Permissions.showError("Capture failed", error) }
        }
    }

    static func previousArea() {
        guard let last = lastArea, let s = NSScreen.withDisplayID(last.display) else { area(); return }
        guard Permissions.ensureScreenRecording() else { return }
        Task { @MainActor in
            do {
                let shot = try await ScreenGrabber.captureDisplay(s.displayID)
                let img = try crop(shot, global: last.rect, screen: s)
                _ = try Output.finish(img, kind: .screenshot, pointSize: last.rect.size)
            } catch { Permissions.showError("Capture failed", error) }
        }
    }

    /// Capture a known global rect on the live screen (All-In-One, previous area).
    static func capture(rect: CGRect, screen: NSScreen, then: ((CaptureItem) -> Void)? = nil) {
        Task { @MainActor in
            do {
                let shot = try await ScreenGrabber.captureDisplay(screen.displayID)
                let img = try crop(shot, global: rect, screen: screen)
                lastArea = (rect, screen.displayID)
                let item = try Output.finish(img, kind: .screenshot, pointSize: rect.size, presentQuickAccess: then == nil)
                then?(item)
            } catch { Permissions.showError("Capture failed", error) }
        }
    }

    /// Pick an area on the live screen, count down, then capture it (menus/hover states stay open).
    static func selfTimer(seconds: Int) {
        guard OverlayController.current == nil, Permissions.ensureScreenRecording() else { return }
        OverlayController.begin(allowWindowMode: false, hint: "Select the area — capture fires after \(seconds)s (click = full screen)") { r in
            guard let r else { return }
            Countdown.run(seconds: seconds, on: r.screen) {
                Task { @MainActor in
                    do {
                        let shot = try await ScreenGrabber.captureDisplay(r.displayID)
                        let img = try crop(shot, global: r.rect, screen: r.screen)
                        _ = try Output.finish(img, kind: .screenshot, pointSize: r.rect.size)
                    } catch { Permissions.showError("Capture failed", error) }
                }
            }
        }
    }
}

/// Big translucent countdown digits in the centre of a screen.
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen, done: @escaping () -> Void) {
        let size: CGFloat = 140
        let f = CGRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
        let w = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.sharingType = .none
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let box = NSVisualEffectView(frame: CGRect(origin: .zero, size: f.size))
        box.material = .hudWindow; box.state = .active; box.wantsLayer = true; box.layer?.cornerRadius = 28
        label.frame = CGRect(x: 0, y: (size - 90) / 2, width: size, height: 90)
        box.addSubview(label)
        w.contentView = box
        w.orderFrontRegardless()
        var left = seconds
        func tick() {
            if left == 0 { w.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: done); return }
            label.stringValue = "\(left)"
            left -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
        }
        tick()
    }
}

/// Where every still capture ends up: file, clipboard, history, sound, Quick Access.
enum Output {
    static let sound = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

    static func encode(_ img: CGImage, format: ImageFormat) -> Data? {
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dst = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let opts: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(dst, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }

    static func copyToClipboard(_ img: CGImage, pointSize: CGSize) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ns = NSImage(cgImage: img, size: pointSize)
        if let png = encode(img, format: .png) {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let tiff = ns.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            pb.writeObjects([item])
        }
    }

    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    /// Save a still into the save folder with a timestamped unique name.
    static func save(_ img: CGImage, date: Date = Date()) throws -> URL {
        let p = Prefs.shared
        let ext = p.imageFormat == .png ? "png" : "jpg"
        let dir = p.directory(for: .screenshot, date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = Naming.unique(in: dir, name: Naming.filename(.screenshot, date: date, ext: ext))
        guard let data = encode(img, format: p.imageFormat) else { throw GrabError(message: "Could not encode image") }
        try data.write(to: url)
        return url
    }

    @discardableResult
    static func finish(_ img: CGImage, kind: CaptureKind, pointSize: CGSize, presentQuickAccess: Bool = true, isWindow: Bool = false) throws -> CaptureItem {
        let p = Prefs.shared
        var img = img, pointSize = pointSize
        if kind == .screenshot, p.autoBackground == .all || (p.autoBackground == .windows && isWindow),
           let composed = withBackground(img, pointSize: pointSize, MacWallpaper.effective(p.background)) {
            img = composed.image
            pointSize = composed.pointSize
        }
        let date = Date()
        if p.playSound { sound?.stop(); sound?.play() }
        var saved: URL?
        if p.autoSave { saved = try save(img, date: date) }
        if p.autoCopy { copyToClipboard(img, pointSize: pointSize) }

        // History keeps a lossless private copy.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard let png = encode(img, format: .png) else { throw GrabError(message: "Could not encode image") }
        try png.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = HistoryStore.shared.add(fileAt: tmp, kind: kind, savedPath: saved?.path, pixelWidth: img.width, pixelHeight: img.height, date: date)
        let file = entry.map { HistoryStore.shared.url(of: $0) } ?? saved ?? tmp
        let item = CaptureItem(kind: kind, image: img, fileURL: file, savedURL: saved, historyID: entry?.id, pointSize: pointSize)
        if presentQuickAccess && p.showQuickAccess { QuickAccess.shared.present(item) }
        return item
    }

    /// Put a capture on a background (gradient / colour / picture) with the same renderer Annotate uses.
    static func withBackground(_ img: CGImage, pointSize: CGSize, _ bg: AnnotationBackground) -> (image: CGImage, pointSize: CGSize)? {
        let r = AnnotationRenderer(image: img, pointSize: pointSize)
        var doc = AnnotationDocument()
        doc.background = bg
        guard let out = r.flatten(doc) else { return nil }
        return (out, r.canvasSize(doc))
    }

    /// Videos/GIFs: file already written by the recorder at `url` (in the save folder or temp).
    @discardableResult
    static func finishMovie(_ url: URL, kind: CaptureKind, pixelSize: CGSize, pointSize: CGSize) -> CaptureItem {
        let p = Prefs.shared
        var saved: URL? = nil
        var file = url
        if p.autoSave {
            let now = Date()
            let dir = p.directory(for: kind, date: now)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = Naming.unique(in: dir, name: Naming.filename(kind, date: now, ext: url.pathExtension))
            if (try? FileManager.default.moveItem(at: url, to: dst)) != nil { saved = dst; file = dst }
        }
        if p.autoCopy { copyFile(file) }
        let entry = HistoryStore.shared.add(fileAt: file, kind: kind, savedPath: saved?.path, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
        let item = CaptureItem(kind: kind, image: nil, fileURL: entry.map { HistoryStore.shared.url(of: $0) } ?? file,
                               savedURL: saved, historyID: entry?.id, pointSize: pointSize)
        if p.showQuickAccess { QuickAccess.shared.present(item) }
        return item
    }
}
