import AppKit
import ScreenCaptureKit
import SnapKit

struct GrabError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static func withDisplayID(_ id: CGDirectDisplayID) -> NSScreen? { screens.first { $0.displayID == id } }
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
    /// Height of the primary (menu-bar) display — the pivot for Quartz <-> AppKit coordinates.
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

/// ScreenCaptureKit wrappers. Snapper's own windows (overlays, Quick Access cards, pins) are always excluded.
enum ScreenGrabber {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func excluded(_ c: SCShareableContent, extraExcluded: [CGWindowID] = []) -> [SCWindow] {
        let me = getpid()
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let hideIcons = Prefs.shared.hideDesktopIcons
        return c.windows.filter { w in
            if w.owningApplication?.processID == me { return true }
            if extraExcluded.contains(w.windowID) { return true }
            if hideIcons, w.owningApplication?.bundleIdentifier == "com.apple.finder", w.windowLayer == iconLevel { return true }
            return false
        }
    }

    /// Full-resolution image of one display.
    static func captureDisplay(_ id: CGDirectDisplayID, content given: SCShareableContent? = nil, showCursor: Bool = false) async throws -> CGImage {
        let c: SCShareableContent
        if let given { c = given } else { c = try await content() }
        guard let d = c.displays.first(where: { $0.displayID == id }) else { throw GrabError(message: "Display \(id) not found") }
        let filter = SCContentFilter(display: d, excludingWindows: excluded(c))
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(filter.contentRect.width * scale)
        cfg.height = Int(filter.contentRect.height * scale)
        cfg.showsCursor = showCursor
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Every connected display at once (freeze-frame for the selection overlay).
    static func captureAllDisplays() async throws -> [CGDirectDisplayID: CGImage] {
        let c = try await content()
        var out: [CGDirectDisplayID: CGImage] = [:]
        for s in NSScreen.screens {
            out[s.displayID] = try await captureDisplay(s.displayID, content: c)
        }
        return out
    }

    /// A single window, un-occluded, optionally with its drop shadow on a transparent background.
    static func captureWindow(_ id: CGWindowID, shadow: Bool = Prefs.shared.windowShadow) async throws -> CGImage {
        let c = try await content()
        guard let w = c.windows.first(where: { $0.windowID == id }) else { throw GrabError(message: "Window \(id) is gone") }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(filter.contentRect.width * scale)
        cfg.height = Int(filter.contentRect.height * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = !shadow
        cfg.shouldBeOpaque = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Visible normal windows front-to-back, in AppKit global coordinates, excluding Snapper's own.
    static func windowList() -> [(id: CGWindowID, rect: CGRect, owner: String)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        let ph = NSScreen.primaryHeight
        var out: [(CGWindowID, CGRect, String)] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let qr = CGRect(dictionaryRepresentation: bd),
                  qr.width > 40, qr.height > 40,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01 else { continue }
            out.append((id, Geo.quartzToAppKit(qr, primaryHeight: ph), (w[kCGWindowOwnerName as String] as? String) ?? ""))
        }
        return out.map { (id: $0.0, rect: $0.1, owner: $0.2) }
    }
}
