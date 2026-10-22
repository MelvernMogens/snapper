import AppKit

enum Permissions {
    /// True if Screen Recording is granted. Otherwise triggers the system prompt once and explains.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Snapper needs Screen Recording access"
        a.informativeText = "Turn on Snapper in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Snapper."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    static func showError(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}
