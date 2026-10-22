import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SnapKit
import SwiftUI

/// Settings: one compact window with General / Capture / Recording / Shortcuts tabs, all bound to `Prefs`.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: SettingsTab?) {
        if window == nil {
            let model = SettingsModel()
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = model.tab.rawValue
            model.onTabChange = { [weak w] t in w?.title = t.rawValue }
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let tab, let host = window?.contentViewController as? NSHostingController<SettingsView> { host.rootView.model.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func show() { show(tab: nil) }

    @MainActor
    static func registerCLI() {
        CLI.extra["--open-settings"] = { args in
            show(tab: args.first.flatMap { SettingsTab(rawValue: $0.capitalized) })
            return await ToolsCLI.stayAlive()
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", capture = "Capture", recording = "Recording", shortcuts = "Shortcuts"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .shortcuts: return "command"
        }
    }
}

/// Mirrors Prefs into @Published values; every write goes straight back to UserDefaults.
final class SettingsModel: ObservableObject {
    private let p = Prefs.shared
    @Published var tab: SettingsTab = .general { didSet { onTabChange?(tab) } }
    var onTabChange: ((SettingsTab) -> Void)?

    @Published var saveDirectory: URL { didSet { p.saveDirectory = saveDirectory } }
    @Published var autoSave: Bool { didSet { p.autoSave = autoSave } }
    @Published var autoCopy: Bool { didSet { p.autoCopy = autoCopy } }
    @Published var showQuickAccess: Bool { didSet { p.showQuickAccess = showQuickAccess } }
    @Published var quickAccessAutoClose: Int { didSet { p.quickAccessAutoClose = quickAccessAutoClose } }
    @Published var playSound: Bool { didSet { p.playSound = playSound } }
    @Published var imageFormat: ImageFormat { didSet { p.imageFormat = imageFormat } }
    @Published var windowShadow: Bool { didSet { p.windowShadow = windowShadow } }
    @Published var showMagnifier: Bool { didSet { p.showMagnifier = showMagnifier } }
    @Published var showCrosshair: Bool { didSet { p.showCrosshair = showCrosshair } }
    @Published var hideDesktopIcons: Bool { didSet { p.hideDesktopIcons = hideDesktopIcons } }
    @Published var recordFPS: Int { didSet { p.recordFPS = recordFPS } }
    @Published var recordShowClicks: Bool { didSet { p.recordShowClicks = recordShowClicks } }
    @Published var recordAudioMic: Bool { didSet { p.recordAudioMic = recordAudioMic } }
    @Published var replaceSystemShortcuts: Bool {
        didSet {
            p.useCommandShiftKeys = replaceSystemShortcuts
            SystemShortcuts.setMacOSScreenshotKeys(enabled: !replaceSystemShortcuts)
            HotKeyCenter.shared.reload()
            refreshBindings()
        }
    }
    @Published var organizeFolders: Bool { didSet { p.organizeFolders = organizeFolders } }
    @Published var launchAtLogin: Bool = false
    @Published var loginError: String?
    @Published var bindings: [BindingRow] = []

    struct BindingRow: Identifiable {
        let id: Int
        let title: String
        let keys: String
        let failed: Bool
    }

    init() {
        saveDirectory = p.saveDirectory
        autoSave = p.autoSave
        autoCopy = p.autoCopy
        showQuickAccess = p.showQuickAccess
        quickAccessAutoClose = p.quickAccessAutoClose
        playSound = p.playSound
        imageFormat = p.imageFormat
        windowShadow = p.windowShadow
        showMagnifier = p.showMagnifier
        showCrosshair = p.showCrosshair
        hideDesktopIcons = p.hideDesktopIcons
        recordFPS = p.recordFPS
        recordShowClicks = p.recordShowClicks
        recordAudioMic = p.recordAudioMic
        replaceSystemShortcuts = p.useCommandShiftKeys
        organizeFolders = p.organizeFolders
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshBindings()
    }

    /// Only an installed, signed .app can register itself as a login item.
    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        guard isBundledApp else {
            loginError = "Only available when running the installed Snapper.app."
            launchAtLogin = false
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if on && status == .requiresApproval {
            loginError = "Approve Snapper in System Settings › General › Login Items."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url }
    }

    func refreshBindings() {
        let failed = HotKeyCenter.shared.failed
        let all = HotKeyCenter.shared.bindings
        // `failed` lists actions in registration order; flag the binding of each failed action (cmd-shift ones last).
        var remainingFailures = failed
        var rows: [BindingRow] = []
        for (i, b) in all.enumerated().reversed() {
            var isFailed = false
            if let k = remainingFailures.lastIndex(of: b.action) { remainingFailures.remove(at: k); isFailed = true }
            rows.append(BindingRow(id: i, title: b.action.title, keys: Self.keyString(b), failed: isFailed))
        }
        bindings = rows.reversed()
    }

    static func keyString(_ b: HotKeyCenter.Binding) -> String {
        var s = ""
        if b.carbonMods & controlKey != 0 { s += "⌃" }
        if b.carbonMods & optionKey != 0 { s += "⌥" }
        if b.carbonMods & shiftKey != 0 { s += "⇧" }
        if b.carbonMods & cmdKey != 0 { s += "⌘" }
        return s + b.char.uppercased()
    }

    static func openScreenshotShortcutsPane() {
        let urls = ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
                    "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"]
        for u in urls { if let url = URL(string: u), NSWorkspace.shared.open(url) { return } }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch model.tab {
                case .general: general
                case .capture: capture
                case .recording: recording
                case .shortcuts: shortcuts
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .controlSize(.small)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                Button { model.tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 15, weight: .regular)).frame(height: 18)
                        Text(t.rawValue).font(.system(size: 10.5, weight: .medium))
                    }
                    .frame(width: 74, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(model.tab == t ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(model.tab == t ? Color.primary.opacity(0.08) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    // MARK: tabs
    private var general: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Launch at login")
                    if let e = model.loginError ?? (model.isBundledApp ? nil : "Only when running the installed Snapper.app") {
                        Text(e)
                    }
                }
                .disabled(!model.isBundledApp)
                Toggle("Play sound", isOn: $model.playSound)
            }
            Section("After capture") {
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.saveDirectory.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(model.saveDirectory.lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .help(model.saveDirectory.path)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                Toggle(isOn: $model.organizeFolders) {
                    Text("Organize into folders")
                    Text("Screenshots / Recordings / GIFs, then one folder per month")
                }
                Toggle("Save automatically", isOn: $model.autoSave)
                Toggle("Copy to clipboard", isOn: $model.autoCopy)
                Toggle("Show Quick Access overlay", isOn: $model.showQuickAccess)
                Picker("Close overlay after", selection: $model.quickAccessAutoClose) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 20, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .disabled(!model.showQuickAccess)
            }
        }
    }

    private var capture: some View {
        Form {
            Section("Screenshots") {
                Picker("File format", selection: $model.imageFormat) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Include window shadow", isOn: $model.windowShadow)
                Toggle("Hide desktop icons", isOn: $model.hideDesktopIcons)
            }
            Section("Selection") {
                Toggle("Show magnifier", isOn: $model.showMagnifier)
                Toggle("Show crosshair", isOn: $model.showCrosshair)
            }
        }
    }

    private var recording: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $model.recordFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Highlight mouse clicks", isOn: $model.recordShowClicks)
                Toggle("Record microphone audio", isOn: $model.recordAudioMic)
            }
        }
    }

    private var shortcuts: some View {
        Form {
            Section {
                Toggle(isOn: $model.replaceSystemShortcuts) {
                    Text("Use ⇧⌘2 / ⇧⌘3 / ⇧⌘4 / ⇧⌘5 (CleanShot keys)")
                    Text("Window, full screen, area and All-In-One. Snapper switches the macOS screenshot keys off for you; turning this off gives them back.")
                }
                if model.replaceSystemShortcuts {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Turn off the macOS ones in System Settings › Keyboard › Keyboard Shortcuts › Screenshots, or they win.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Open…") { SettingsModel.openScreenshotShortcutsPane() }
                    }
                }
            }
            Section("Shortcuts") {
                ForEach(model.bindings) { b in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if b.failed {
                                Label("In use", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .help("Another app already owns this shortcut")
                            }
                            Text(b.keys)
                                .font(.system(size: 12, weight: .medium, design: .rounded).monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        }
                    } label: {
                        Text(b.title)
                    }
                }
            }
        }
        .onAppear { model.refreshBindings() }
    }
}
