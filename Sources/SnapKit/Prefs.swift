import Foundation

public enum ImageFormat: String, CaseIterable, Codable { case png, jpeg }

/// Which captures get the Settings background automatically.
public enum AutoBackground: String, CaseIterable, Codable { case off, windows, all }

/// All user settings, UserDefaults-backed. One place so Settings UI and capture code agree.
public final class Prefs {
    public static let shared = Prefs()
    public let d: UserDefaults
    public init(defaults: UserDefaults = .standard) { d = defaults }

    private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    public var saveDirectory: URL {
        get {
            if let p = d.string(forKey: "saveDirectory"), !p.isEmpty { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapper", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "saveDirectory") }
    }
    /// Sort saves into Screenshots/Recordings/GIFs + month sub-folders inside saveDirectory.
    public var organizeFolders: Bool { get { bool("organizeFolders", true) } set { d.set(newValue, forKey: "organizeFolders") } }
    /// Where a capture of `kind` taken at `date` is saved.
    public func directory(for kind: CaptureKind, date: Date) -> URL {
        organizeFolders ? saveDirectory.appendingPathComponent(Naming.folder(kind, date: date), isDirectory: true) : saveDirectory
    }
    /// Use ⇧⌘2/3/4/5 like CleanShot (and switch the macOS screenshot keys off). Off = ⌥⌘ digits.
    public var useCommandShiftKeys: Bool { get { bool("replaceSystemShortcuts", true) } set { d.set(newValue, forKey: "replaceSystemShortcuts") } }
    /// After capture: write file to saveDirectory.
    public var autoSave: Bool { get { bool("autoSave", true) } set { d.set(newValue, forKey: "autoSave") } }
    /// After capture: put image on clipboard.
    public var autoCopy: Bool { get { bool("autoCopy", true) } set { d.set(newValue, forKey: "autoCopy") } }
    public var showQuickAccess: Bool { get { bool("showQuickAccess", true) } set { d.set(newValue, forKey: "showQuickAccess") } }
    /// Seconds before a Quick Access card closes by itself; 0 = never.
    public var quickAccessAutoClose: Int { get { d.object(forKey: "qaAutoClose") == nil ? 0 : d.integer(forKey: "qaAutoClose") } set { d.set(newValue, forKey: "qaAutoClose") } }
    /// The background set in Settings › Background (also what Annotate's Background button starts from).
    public var background: AnnotationBackground {
        get {
            guard let data = d.data(forKey: "defaultBackground"),
                  var bg = try? JSONDecoder().decode(AnnotationBackground.self, from: data) else {
                return AnnotationBackground(kind: .gradient(1), padding: 56, cornerRadius: 12, shadow: true)
            }
            if let p = bg.imagePath, !FileManager.default.fileExists(atPath: p) { bg.kind = .gradient(1) }
            return bg
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "defaultBackground") } }
    }
    /// Apply that background automatically after capture.
    public var autoBackground: AutoBackground {
        get { AutoBackground(rawValue: d.string(forKey: "autoBackground") ?? "") ?? .windows }
        set { d.set(newValue.rawValue, forKey: "autoBackground") }
    }

    /// Swiping a Quick Access card away deletes the capture (CleanShot just closes it).
    public var swipeDeletes: Bool { get { bool("swipeDeletes", true) } set { d.set(newValue, forKey: "swipeDeletes") } }
    public var playSound: Bool { get { bool("playSound", true) } set { d.set(newValue, forKey: "playSound") } }
    public var windowShadow: Bool { get { bool("windowShadow", true) } set { d.set(newValue, forKey: "windowShadow") } }
    public var showMagnifier: Bool { get { bool("showMagnifier", true) } set { d.set(newValue, forKey: "showMagnifier") } }
    public var showCrosshair: Bool { get { bool("showCrosshair", true) } set { d.set(newValue, forKey: "showCrosshair") } }
    public var hideDesktopIcons: Bool { get { bool("hideDesktopIcons", false) } set { d.set(newValue, forKey: "hideDesktopIcons") } }
    public var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "imageFormat") }
    }
    /// Recording: show mouse clicks as rings.
    public var recordShowClicks: Bool { get { bool("recordShowClicks", true) } set { d.set(newValue, forKey: "recordShowClicks") } }
    public var recordAudioMic: Bool { get { bool("recordAudioMic", false) } set { d.set(newValue, forKey: "recordAudioMic") } }
    public var recordFPS: Int { get { d.object(forKey: "recordFPS") == nil ? 60 : d.integer(forKey: "recordFPS") } set { d.set(newValue, forKey: "recordFPS") } }
}
