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

/// The fixed shortcut table. Default prefix is ⌥⌘ + digit so nothing collides with macOS's own ⌘⇧3/4/5.
/// With Prefs.replaceSystemShortcuts on, ⌘⇧3/4/5 are also bound (Settings disables the macOS ones).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var handler: (Action) -> Void = { _ in }
    private var keys: [HotKey] = []
    private(set) var failed: [Action] = []

    struct Binding { let action: Action; let keyCode: Int; let carbonMods: Int; let char: String }

    var bindings: [Binding] {
        let oc = optionKey | cmdKey
        var b: [Binding] = [
            Binding(action: .fullscreen, keyCode: kVK_ANSI_3, carbonMods: oc, char: "3"),
            Binding(action: .area, keyCode: kVK_ANSI_4, carbonMods: oc, char: "4"),
            Binding(action: .window, keyCode: kVK_ANSI_5, carbonMods: oc, char: "5"),
            Binding(action: .previousArea, keyCode: kVK_ANSI_6, carbonMods: oc, char: "6"),
            Binding(action: .recordVideo, keyCode: kVK_ANSI_7, carbonMods: oc, char: "7"),
            Binding(action: .ocr, keyCode: kVK_ANSI_8, carbonMods: oc, char: "8"),
            Binding(action: .history, keyCode: kVK_ANSI_9, carbonMods: oc, char: "9"),
            Binding(action: .scrolling, keyCode: kVK_ANSI_0, carbonMods: oc, char: "0"),
        ]
        if UserDefaults.standard.bool(forKey: "replaceSystemShortcuts") {
            let cs = cmdKey | shiftKey
            b += [
                Binding(action: .fullscreen, keyCode: kVK_ANSI_3, carbonMods: cs, char: "3"),
                Binding(action: .area, keyCode: kVK_ANSI_4, carbonMods: cs, char: "4"),
                Binding(action: .recordVideo, keyCode: kVK_ANSI_5, carbonMods: cs, char: "5"),
            ]
        }
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
