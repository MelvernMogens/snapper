import AppKit
import Carbon.HIToolbox
import SnapKit

/// Every user-facing command. Menu items and hotkeys both route through `AppDelegate.perform`.
enum Action: String, CaseIterable {
    case allInOne, area, fullscreen, window, previousArea, selfTimer
    case ocr, scrolling, pinArea
    case recordVideo, recordGIF
    case history, openInAnnotate, settings

    var title: String {
        switch self {
        case .allInOne: return "All-In-One"
        case .area: return "Capture Area"
        case .fullscreen: return "Capture Fullscreen"
        case .window: return "Capture Window"
        case .previousArea: return "Capture Previous Area"
        case .selfTimer: return "Self-Timer (5s)"
        case .ocr: return "Capture Text (OCR)"
        case .scrolling: return "Scrolling Capture"
        case .pinArea: return "Pin Area to Screen"
        case .recordVideo: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .history: return "Capture History…"
        case .openInAnnotate: return "Open Image in Annotate…"
        case .settings: return "Settings…"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!
    var statusItem: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        if let first = args.first, first.hasPrefix("--") {
            Task { @MainActor in
                if let rc = await CLI.run(args) { exit(rc) }
            }
        }
        setupStatusItem()
        HotKeyCenter.shared.handler = { [weak self] a in self?.perform(a) }
        // CleanShot keys: make sure macOS isn't still holding ⇧⌘3/4/5.
        if Prefs.shared.useCommandShiftKeys && SystemShortcuts.macOSScreenshotKeysEnabled() {
            SystemShortcuts.setMacOSScreenshotKeys(enabled: false)
        }
        HotKeyCenter.shared.reload()
        MacWallpaper.startWatching()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIdleIcon()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func setIdleIcon() {
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapper")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func rebuildMenu() {
        menu.removeAllItems()
        let groups: [[Action]] = [
            [.allInOne],
            [.area, .previousArea, .fullscreen, .window, .selfTimer],
            [.scrolling, .ocr, .pinArea],
            [.recordVideo, .recordGIF],
            [.history, .openInAnnotate],
        ]
        for (i, g) in groups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for a in g { menu.addItem(item(a)) }
        }
        menu.addItem(.separator())
        menu.addItem(item(.settings))
        let quit = NSMenuItem(title: "Quit Snapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ a: Action) -> NSMenuItem {
        let mi = NSMenuItem(title: a.title, action: #selector(menuAction(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = a.rawValue
        if let k = HotKeyCenter.shared.displayKey(for: a) {
            mi.keyEquivalent = k.key
            mi.keyEquivalentModifierMask = k.mods
        }
        if a == .settings { mi.keyEquivalent = ","; mi.keyEquivalentModifierMask = .command }
        return mi
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = Action(rawValue: raw) else { return }
        // Let the menu close before an overlay freezes the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.perform(a) }
    }

    func perform(_ a: Action) {
        switch a {
        case .allInOne: AllInOne.start()
        case .area: Capture.area()
        case .fullscreen: Capture.fullscreen()
        case .window: Capture.area(windowMode: true)
        case .previousArea: Capture.previousArea()
        case .selfTimer: Capture.selfTimer(seconds: 5)
        case .ocr: OCR.captureText()
        case .scrolling: ScrollCapture.start()
        case .pinArea: Capture.area(then: { item in Pinner.pin(item) })
        case .recordVideo: Recorder.shared.start(gif: false)
        case .recordGIF: Recorder.shared.start(gif: true)
        case .history: HistoryWindow.show()
        case .openInAnnotate: openInAnnotate()
        case .settings: SettingsWindow.show()
        }
    }

    private func openInAnnotate() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url { Annotator.open(url: url) }
    }
}
