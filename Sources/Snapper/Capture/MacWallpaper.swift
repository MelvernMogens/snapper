import AppKit
import ScreenCaptureKit
import SnapKit

/// "Use Mac wallpaper": saves the desktop picture ONCE when you press the button in Settings
/// (the wallpaper's own image file when it exists, else a snapshot of the live wallpaper window).
enum MacWallpaper {
    static var snapshotURL: URL { BackgroundStore.directory.appendingPathComponent("mac-wallpaper.png") }

    /// The wallpaper saved when you pressed "Use" / "Update" in Settings. Captures just read this file —
    /// nothing is grabbed from the screen at capture time.
    static var path: String? {
        FileManager.default.fileExists(atPath: snapshotURL.path) ? snapshotURL.path : nil
    }

    /// The background Settings describes, with the Mac wallpaper swapped in when that mode is on.
    static func effective(_ bg: AnnotationBackground) -> AnnotationBackground {
        guard Prefs.shared.followMacWallpaper, let p = path else { return bg }
        var b = bg
        b.kind = .image(p)
        return b
    }

    private static var refreshing = false
    private static var waiters: [() -> Void] = []
    private static var observers: [Any] = []

    /// Re-snapshot the live wallpaper window (cheap: one window, once). Calls `done` on the main thread.
    static func refresh(done: (() -> Void)? = nil) {
        guard CGPreflightScreenCaptureAccess() else { done?(); return }
        if let done { waiters.append(done) }
        guard !refreshing else { return }          // the running refresh will call us back
        refreshing = true
        if let file = BackgroundStore.currentDesktopPicture, let img = BackgroundImageCache.decode(file, maxPixel: 5120),
           let data = Output.encode(img, format: .png) {
            try? FileManager.default.createDirectory(at: BackgroundStore.directory, withIntermediateDirectories: true)
            try? data.write(to: snapshotURL, options: .atomic)
            BackgroundImageCache.shared.forget(snapshotURL.path)
            refreshing = false
            let w = waiters; waiters.removeAll(); w.forEach { $0() }
            return
        }
        Task { @MainActor in
            defer {
                refreshing = false
                let w = waiters; waiters.removeAll()
                w.forEach { $0() }
            }
            guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            let main = NSScreen.main ?? NSScreen.screens[0]
            let mainBounds = CGDisplayBounds(main.displayID)
            let candidates = c.windows.filter {
                ($0.title ?? "").hasPrefix("Wallpaper") || $0.owningApplication?.bundleIdentifier == "com.apple.wallpaper.agent"
            }
            guard let w = candidates.first(where: { $0.frame.intersects(mainBounds) }) ?? candidates.first else { NSLog("Snapper wallpaper: no wallpaper window"); return }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(filter.contentRect.width * scale)
            cfg.height = Int(filter.contentRect.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let img: CGImage
            do { img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) }
            catch { NSLog("Snapper wallpaper snapshot failed: \(error.localizedDescription)"); return }
            guard img.width > 64, let data = Output.encode(img, format: .png) else { NSLog("Snapper wallpaper: empty image \(img.width)"); return }
            try? FileManager.default.createDirectory(at: BackgroundStore.directory, withIntermediateDirectories: true)
            try? data.write(to: snapshotURL, options: .atomic)
            BackgroundImageCache.shared.forget(snapshotURL.path)
        }
    }

}
