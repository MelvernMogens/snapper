import AppKit

/// STUB — replaced by the Annotate milestone.
enum Annotator {
    static func open(url: URL) { NSWorkspace.shared.open(url) }
    static func open(item: CaptureItem) { NSWorkspace.shared.open(item.savedURL ?? item.fileURL) }
    @MainActor static func registerCLI() {}
}
