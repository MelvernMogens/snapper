import AppKit
import SnapKit

/// Headless entry points used for verification (no overlay, no UI). Returns an exit code, or nil to keep running as an app.
/// Feature modules register more commands in `CLI.extra`.
enum CLI {
    @MainActor
    static var extra: [String: ([String]) async -> Int32] = [:]

    @MainActor
    static func run(_ args: [String]) async -> Int32? {
        registerFeatureCommands()
        let cmd = args[0]
        let rest = Array(args.dropFirst())
        func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
        func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        do {
            switch cmd {
            case "--help":
                out("Snapper CLI: --probe | --capture-fullscreen OUT.png | --capture-rect x,y,w,h OUT.png | --capture-window <id> OUT.png | --windows | " + extra.keys.sorted().joined(separator: " | "))
                return 0
            case "--probe":
                out("screenRecording=\(CGPreflightScreenCaptureAccess())")
                for s in NSScreen.screens { out("screen \(s.displayID) frame=\(s.frame) scale=\(s.backingScaleFactor)") }
                out("saveDirectory=\(Prefs.shared.saveDirectory.path) history=\(HistoryStore.shared.entries.count)")
                return 0
            case "--allinone":
                AllInOne.start()
                while true { try? await Task.sleep(for: .seconds(60)) }
            case "--shortcuts":
                out("useCommandShiftKeys=\(Prefs.shared.useCommandShiftKeys) macOSKeysEnabled=\(SystemShortcuts.macOSScreenshotKeysEnabled())")
                for b in HotKeyCenter.shared.bindings { out("\(b.action.rawValue) \(b.char) mods=\(b.carbonMods)") }
                return 0
            case "--windows":
                for w in ScreenGrabber.windowList().prefix(15) { out("\(w.id)\t\(w.owner)\t\(w.rect)") }
                return 0
            case "--capture-fullscreen":
                let s = NSScreen.screens[0]
                let img = try await ScreenGrabber.captureDisplay(s.displayID)
                try write(img, rest.first ?? "/tmp/snapper-full.png"); out("\(img.width)x\(img.height)")
                return 0
            case "--capture-rect":
                let n = rest[0].split(separator: ",").compactMap { Double($0) }
                let r = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
                let s = NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.screens[0]
                let shot = try await ScreenGrabber.captureDisplay(s.displayID)
                let img = try Capture.crop(shot, global: r, screen: s)
                try write(img, rest[1]); out("\(img.width)x\(img.height)")
                return 0
            case "--capture-window":
                let img = try await ScreenGrabber.captureWindow(CGWindowID(rest[0])!)
                try write(img, rest[1]); out("\(img.width)x\(img.height)")
                return 0
            case "--finish-test":
                // Apply the Settings background to an image like a real capture would: --finish-test IN.png OUT.png window|area
                guard let inImg = CGImageSourceCreateWithURL(URL(fileURLWithPath: rest[0]) as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
                    err("cannot read \(rest[0])"); return 1 }
                let isWindow = rest.count > 2 && rest[2] == "window"
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let composed = Output.withBackground(inImg, pointSize: CGSize(width: CGFloat(inImg.width) / scale, height: CGFloat(inImg.height) / scale), Prefs.shared.background)
                let p = Prefs.shared
                let mode = p.autoBackground
                let use = mode == .all || (mode == .windows && isWindow)
                let outImg = (use ? composed?.image : nil) ?? inImg
                try write(outImg, rest[1])
                out("mode=\(mode.rawValue) applied=\(use && composed != nil) size=\(outImg.width)x\(outImg.height)")
                return 0
            default:
                if let f = extra[cmd] { return await f(rest) }
                err("unknown command \(cmd)"); return 2
            }
        } catch {
            err("error: \(error.localizedDescription)"); return 1
        }
    }

    static func write(_ img: CGImage, _ path: String) throws {
        guard let d = Output.encode(img, format: .png) else { throw GrabError(message: "encode failed") }
        try d.write(to: URL(fileURLWithPath: path))
    }
}
