import Foundation

public enum CaptureKind: String, Codable, CaseIterable {
    case screenshot = "Screenshot"
    case recording = "Recording"
    case gif = "GIF"
}

public enum Naming {
    /// "Snapper 2026-10-22 at 23.30.12.png" — sorts by time, matches macOS screenshot style.
    public static func filename(_ kind: CaptureKind, date: Date, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let label = kind == .screenshot ? "Snapper" : "Snapper \(kind.rawValue)"
        return "\(label) \(f.string(from: date)).\(ext)"
    }

    /// First non-existing URL: name.ext, name 2.ext, name 3.ext …
    public static func unique(in dir: URL, name: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while exists(url) {
            url = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return url
    }
}
