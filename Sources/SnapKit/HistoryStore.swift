import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let kind: CaptureKind
    public let date: Date
    /// File name inside the history directory (a private copy, survives the user deleting the original).
    public let file: String
    /// Where the user-visible file was saved, if it was.
    public var savedPath: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
}

/// Every capture gets a private copy in the history directory, indexed by index.json.
/// Capped at `limit` entries; the oldest files are deleted when trimmed.
public final class HistoryStore {
    public static let changed = Notification.Name("SnapperHistoryChanged")
    public static let shared = HistoryStore(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snapper/History", isDirectory: true))

    public let dir: URL
    public let limit: Int
    public private(set) var entries: [HistoryEntry] = []   // newest first
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    public init(dir: URL, limit: Int = 300) {
        self.dir = dir
        self.limit = limit
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
        }
    }

    public func url(of e: HistoryEntry) -> URL { dir.appendingPathComponent(e.file) }

    @discardableResult
    public func add(fileAt src: URL, kind: CaptureKind, savedPath: String?, pixelWidth: Int, pixelHeight: Int, date: Date = Date()) -> HistoryEntry? {
        let id = UUID()
        let name = id.uuidString + "." + src.pathExtension
        do { try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name)) } catch { return nil }
        let e = HistoryEntry(id: id, kind: kind, date: date, file: name, savedPath: savedPath, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        entries.insert(e, at: 0)
        while entries.count > limit { let old = entries.removeLast(); try? FileManager.default.removeItem(at: url(of: old)) }
        persist()
        return e
    }

    /// Replace the stored file for an entry (e.g. after annotating).
    public func replaceFile(id: UUID, with src: URL) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        let dst = url(of: e)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        persist()
    }

    public func setSavedPath(id: UUID, _ path: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].savedPath = path
        persist()
    }

    public func remove(id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(of: entries[i]))
        entries.remove(at: i)
        persist()
    }

    public func clear() {
        for e in entries { try? FileManager.default.removeItem(at: url(of: e)) }
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
        NotificationCenter.default.post(name: HistoryStore.changed, object: self)
    }
}
