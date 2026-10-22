import AppKit

extension CLI {
    /// Each feature module adds its own headless test commands here (one line each).
    @MainActor
    static func registerFeatureCommands() {
        Annotator.registerCLI()
        Recorder.registerCLI()
        OCR.registerCLI()
        ScrollCapture.registerCLI()
        Pinner.registerCLI()
        HistoryWindow.registerCLI()
        SettingsWindow.registerCLI()
        QuickAccess.registerCLI()
    }
}
