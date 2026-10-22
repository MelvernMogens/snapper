import AppKit
import Carbon.HIToolbox
import SnapKit

/// System-wide hotkeys via Carbon's RegisterEventHotKey — works without Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        self.id = id
        HotKey.installHandler()
        let hkID = EventHotKeyID(signature: OSType(0x534E5052) /* 'SNPR' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The fixed shortcut table.
/// Default = CleanShot X layout: ⇧⌘2 window · ⇧⌘3 fullscreen · ⇧⌘4 area · ⇧⌘5 All-In-One. Snapper turns the macOS
/// screenshot keys off (SystemShortcuts) so these reach us. With the CleanShot keys off, ⌥⌘ digits are used instead.
/// The ⌥⌘ extras (previous area, record, OCR, history, scrolling) are always on.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var handler: (Action) -> Void = { _ in }
    private var keys: [HotKey] = []
    private(set) var failed: [Action] = []

    struct Binding { let action: Action; let keyCode: Int; let carbonMods: Int; let char: String }

    var bindings: [Binding] {
        let oc = optionKey | cmdKey
        var b: [Binding] = []
        if Prefs.shared.useCommandShiftKeys {
            let cs = cmdKey | shiftKey
            b += [
                Binding(action: .window, keyCode: kVK_ANSI_2, carbonMods: cs, char: "2"),
                Binding(action: .fullscreen, keyCode: kVK_ANSI_3, carbonMods: cs, char: "3"),
                Binding(action: .area, keyCode: kVK_ANSI_4, carbonMods: cs, char: "4"),
                Binding(action: .allInOne, keyCode: kVK_ANSI_5, carbonMods: cs, char: "5"),
            ]
        } else {
            b += [
                Binding(action: .window, keyCode: kVK_ANSI_2, carbonMods: oc, char: "2"),
                Binding(action: .fullscreen, keyCode: kVK_ANSI_3, carbonMods: oc, char: "3"),
                Binding(action: .area, keyCode: kVK_ANSI_4, carbonMods: oc, char: "4"),
                Binding(action: .allInOne, keyCode: kVK_ANSI_5, carbonMods: oc, char: "5"),
            ]
        }
        b += [
            Binding(action: .previousArea, keyCode: kVK_ANSI_6, carbonMods: oc, char: "6"),
            Binding(action: .recordVideo, keyCode: kVK_ANSI_7, carbonMods: oc, char: "7"),
            Binding(action: .ocr, keyCode: kVK_ANSI_8, carbonMods: oc, char: "8"),
            Binding(action: .history, keyCode: kVK_ANSI_9, carbonMods: oc, char: "9"),
            Binding(action: .scrolling, keyCode: kVK_ANSI_0, carbonMods: oc, char: "0"),
        ]
        return b
    }

    func reload() {
        keys.removeAll()
        failed.removeAll()
        for (i, b) in bindings.enumerated() {
            let act = b.action
            if let hk = HotKey(id: UInt32(i + 1), keyCode: b.keyCode, modifiers: b.carbonMods, handler: { [weak self] in self?.handler(act) }) {
                keys.append(hk)
            } else {
                failed.append(act)
            }
        }
    }

    /// First binding for the menu's shortcut hint.
    func displayKey(for a: Action) -> (key: String, mods: NSEvent.ModifierFlags)? {
        guard let b = bindings.first(where: { $0.action == a }) else { return nil }
        var m: NSEvent.ModifierFlags = []
        if b.carbonMods & cmdKey != 0 { m.insert(.command) }
        if b.carbonMods & optionKey != 0 { m.insert(.option) }
        if b.carbonMods & shiftKey != 0 { m.insert(.shift) }
        if b.carbonMods & controlKey != 0 { m.insert(.control) }
        return (b.char, m)
    }
}

/// Turns the macOS screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5 and their clipboard variants) on/off, like CleanShot's onboarding.
/// Symbolic hotkey ids: 28 ⇧⌘3, 29 ⌃⇧⌘3, 30 ⇧⌘4, 31 ⌃⇧⌘4, 184 ⇧⌘5. The WindowServer picks the change up via activateSettings -u.
enum SystemShortcuts {
    static let ids = [28, 29, 30, 31, 184]

    static func macOSScreenshotKeysEnabled() -> Bool {
        guard let d = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return true }
        return ids.contains { ((d[String($0)] as? [String: Any])?["enabled"] as? Bool) ?? true }
    }

    @discardableResult
    static func setMacOSScreenshotKeys(enabled: Bool) -> Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        let key = "AppleSymbolicHotKeys" as CFString
        CFPreferencesAppSynchronize(domain)
        var all = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        for id in ids {
            // Keep the existing key parameters; only flip `enabled`.
            var entry = (all[String(id)] as? [String: Any]) ?? defaults[id] ?? [:]
            entry["enabled"] = enabled
            all[String(id)] = entry
        }
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        let ok = CFPreferencesAppSynchronize(domain)
        let a = Process()
        a.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        a.arguments = ["-u"]
        try? a.run(); a.waitUntilExit()
        return ok
    }

    /// Stock key parameters (ascii, keycode, modifiers) in case an entry was never written.
    private static let defaults: [Int: [String: Any]] = [
        28: ["value": ["parameters": [51, 20, 1179648], "type": "standard"]],
        29: ["value": ["parameters": [51, 20, 1441792], "type": "standard"]],
        30: ["value": ["parameters": [52, 21, 1179648], "type": "standard"]],
        31: ["value": ["parameters": [52, 21, 1441792], "type": "standard"]],
        184: ["value": ["parameters": [53, 23, 1179648], "type": "standard"]],
    ]
}
