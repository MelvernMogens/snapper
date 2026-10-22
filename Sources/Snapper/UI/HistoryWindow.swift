import AppKit
import Quartz
import QuickLookThumbnailing
import SnapKit
import SwiftUI

/// Capture History: a grid of every capture HistoryStore keeps, newest first.
/// Click selects · Space / eye button = Quick Look · double-click = Annotate (screenshots) or open (videos/GIFs)
/// · right-click = Copy / Show in Finder / Pin / Delete.
enum HistoryWindow {
    private static var window: HistoryNSWindow?

    static func show() {
        if window == nil {
            let w = HistoryNSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 540),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            w.title = "Capture History"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            // An empty compact toolbar gives a 38pt title bar; the SwiftUI header sits inline with the traffic lights.
            w.toolbar = NSToolbar(identifier: "SnapperHistory")
            w.toolbarStyle = .unifiedCompact
            w.minSize = CGSize(width: 460, height: 320)
            w.contentViewController = NSHostingController(rootView: HistoryView(model: w.model))
            w.setContentSize(CGSize(width: 780, height: 540))
            w.center()
            w.setFrameAutosaveName("SnapperHistory")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: actions shared by the grid and its context menu
    static func open(_ e: HistoryEntry) {
        let url = HistoryStore.shared.url(of: e)
        if e.kind == .screenshot { Annotator.open(url: url) } else { NSWorkspace.shared.open(url) }
    }

    static func copy(_ e: HistoryEntry) {
        let url = HistoryStore.shared.url(of: e)
        if e.kind == .screenshot, let img = ToolsImage.load(url) {
            Output.copyToClipboard(img, pointSize: pointSize(e))
        } else {
            Output.copyFile(url)
        }
    }

    static func revealURL(_ e: HistoryEntry) -> URL {
        if let p = e.savedPath, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return HistoryStore.shared.url(of: e)
    }

    static func showInFinder(_ e: HistoryEntry) { NSWorkspace.shared.activateFileViewerSelecting([revealURL(e)]) }

    static func pin(_ e: HistoryEntry) {
        let url = HistoryStore.shared.url(of: e)
        guard e.kind == .screenshot, let img = ToolsImage.load(url) else { NSSound.beep(); return }
        Pinner.pin(CaptureItem(kind: .screenshot, image: img, fileURL: url,
                               savedURL: e.savedPath.map { URL(fileURLWithPath: $0) }, historyID: e.id, pointSize: pointSize(e)))
    }

    static func delete(_ e: HistoryEntry) { HistoryStore.shared.remove(id: e.id) }

    static func pointSize(_ e: HistoryEntry) -> CGSize {
        let s = ToolsImage.defaultScale
        return CGSize(width: CGFloat(e.pixelWidth) / s, height: CGFloat(e.pixelHeight) / s)
    }

    // MARK: CLI
    @MainActor
    static func registerCLI() {
        CLI.extra["--open-history"] = { _ in
            show()
            return await ToolsCLI.stayAlive()
        }
        CLI.extra["--seed-history"] = { args in await HistorySeeder.seed(count: Int(args.first ?? "") ?? 8) }
        CLI.extra["--unseed-history"] = { _ in HistorySeeder.unseed() }
    }
}

/// Owns Quick Look for the grid (the panel looks for a controller up the responder chain).
final class HistoryNSWindow: NSWindow, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model = HistoryModel()

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model.selected == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let e = model.selectedEntry else { return nil }
        return HistoryStore.shared.url(of: e) as NSURL
    }

    func toggleQuickLook() {
        guard model.selectedEntry != nil, let p = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible { p.orderOut(nil); return }
        makeKey()
        p.makeKeyAndOrderFront(nil)
        p.reloadData()
    }

    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible else { return }
        p.reloadData()
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", screenshots = "Screenshots", recordings = "Recordings"
    var id: String { rawValue }
    func matches(_ k: CaptureKind) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return k == .screenshot
        case .recordings: return k != .screenshot
        }
    }
}

final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = HistoryStore.shared.entries
    @Published var filter: HistoryFilter = .all
    @Published var selected: UUID?
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: HistoryStore.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.entries = HistoryStore.shared.entries
            if let s = self.selected, !self.entries.contains(where: { $0.id == s }) { self.selected = nil }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    var visible: [HistoryEntry] { entries.filter { filter.matches($0.kind) } }
    var selectedEntry: HistoryEntry? { selected.flatMap { id in entries.first { $0.id == id } } }

    /// Arrow-key selection in the visible list.
    func move(_ delta: Int) {
        let v = visible
        guard !v.isEmpty else { return }
        guard let s = selected, let i = v.firstIndex(where: { $0.id == s }) else { selected = v.first?.id; return }
        selected = v[min(max(i + delta, 0), v.count - 1)].id
    }
}

/// Downscaled thumbnails, generated off the main thread and cached by file + modification date.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "snapper.thumbs", qos: .userInitiated, attributes: .concurrent)

    private func key(_ url: URL) -> NSString {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(m)" as NSString
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: key(url)) }

    func load(_ url: URL, kind: CaptureKind, maxPixel: Int = 480, done: @escaping @MainActor (NSImage?) -> Void) {
        let k = key(url)
        if let hit = cache.object(forKey: k) { Task { @MainActor in done(hit) }; return }
        if kind == .recording {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel / 2, height: maxPixel / 2),
                                                   scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                let img = rep?.nsImage
                if let img { self?.cache.setObject(img, forKey: k) }
                Task { @MainActor in done(img) }
            }
            return
        }
        queue.async { [weak self] in
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: maxPixel]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    img = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                }
            }
            if let img { self?.cache.setObject(img, forKey: k) }
            Task { @MainActor in done(img) }
        }
    }
}

// MARK: - SwiftUI

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var confirmClear = false
    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.visible.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.visible) { e in
                            HistoryCell(entry: e, selected: model.selected == e.id)
                                .onTapGesture(count: 2) { HistoryWindow.open(e) }
                                .simultaneousGesture(TapGesture().onEnded { model.selected = e.id; quickLookWindow?.refreshQuickLook() })
                                .contextMenu { menu(e) }
                        }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
                .onTapGesture { model.selected = nil }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 460, minHeight: 300)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { quickLookWindow?.toggleQuickLook(); return .handled }
        .onKeyPress(.return) { if let e = model.selectedEntry { HistoryWindow.open(e) }; return .handled }
        .onKeyPress(.leftArrow) { model.move(-1); quickLookWindow?.refreshQuickLook(); return .handled }
        .onKeyPress(.rightArrow) { model.move(1); quickLookWindow?.refreshQuickLook(); return .handled }
        .onKeyPress(.delete) { if let e = model.selectedEntry { HistoryWindow.delete(e) }; return .handled }
        .alert("Clear capture history?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { HistoryStore.shared.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(model.entries.count) items from history. Files you saved elsewhere are kept.")
        }
    }

    private var quickLookWindow: HistoryNSWindow? { NSApp.windows.compactMap { $0 as? HistoryNSWindow }.first }

    private var header: some View {
        HStack(spacing: 10) {
            Text("History")
                .font(.system(size: 13, weight: .semibold))
            Text("\(model.visible.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Spacer()
            Picker("", selection: $model.filter) {
                ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(model.entries.isEmpty)
            .help("Remove every item from history")
        }
        .padding(.leading, 84)      // clear the traffic lights (title bar is transparent)
        .padding(.trailing, 12)
        .frame(height: 38)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.entries.isEmpty ? "No captures yet" : "Nothing matches this filter")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if model.entries.isEmpty {
                Text("Screenshots and recordings you take show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func menu(_ e: HistoryEntry) -> some View {
        Button(e.kind == .screenshot ? "Open in Annotate" : "Open") { HistoryWindow.open(e) }
        Button("Quick Look") { model.selected = e.id; quickLookWindow?.toggleQuickLook() }
        Divider()
        Button("Copy") { HistoryWindow.copy(e) }
        Button("Show in Finder") { HistoryWindow.showInFinder(e) }
        if e.kind == .screenshot { Button("Pin to Screen") { HistoryWindow.pin(e) } }
        Divider()
        Button("Delete from History", role: .destructive) { HistoryWindow.delete(e) }
    }
}

struct HistoryCell: View {
    let entry: HistoryEntry
    let selected: Bool
    @State private var thumb: NSImage?
    @State private var hover = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d"); return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                badge.padding(6)
                if hover {
                    Button { HistoryWindow.copy(entry) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.65)))
                    .help("Copy")
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(height: 112)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.18 : 0.08), lineWidth: selected ? 2 : 1)
            )
            HStack(spacing: 4) {
                Text(verbatim: dateLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: "\(entry.pixelWidth)×\(entry.pixelHeight)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(entry.savedPath.map { ($0 as NSString).lastPathComponent } ?? "Not saved to disk")
        .onAppear(perform: loadThumb)
    }

    @ViewBuilder private var badge: some View {
        switch entry.kind {
        case .screenshot:
            EmptyView()     // the default kind needs no label; only videos/GIFs get a badge
        case .recording, .gif:
            HStack(spacing: 3) {
                Image(systemName: entry.kind == .gif ? "photo.on.rectangle.angled" : "video.fill").font(.system(size: 8, weight: .bold))
                Text(entry.kind == .gif ? "GIF" : "VIDEO").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.7)))
        }
    }

    private var dateLabel: String {
        let cal = Calendar.current
        let t = Self.timeFmt.string(from: entry.date)
        if cal.isDateInToday(entry.date) { return "Today \(t)" }
        if cal.isDateInYesterday(entry.date) { return "Yesterday \(t)" }
        return "\(Self.dayFmt.string(from: entry.date)), \(t)"
    }

    private func loadThumb() {
        guard thumb == nil else { return }
        let url = HistoryStore.shared.url(of: entry)
        if let hit = ThumbnailCache.shared.cached(url) { thumb = hit; return }
        ThumbnailCache.shared.load(url, kind: entry.kind) { img in thumb = img }
    }
}

// MARK: - test data

/// `--seed-history N`: adds N real captures (crops of the current screen) through Output.finish with
/// auto-save/copy/sound off for the run, plus one GIF entry; `--unseed-history` removes exactly those entries.
enum HistorySeeder {
    static let record = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapper-seeded-history.json")

    @MainActor
    static func seed(count: Int) async -> Int32 {
        let p = Prefs.shared
        // Restore the raw stored values afterwards (absent keys stay absent so defaults keep applying).
        let keys = ["autoSave", "autoCopy", "playSound"]
        let before = keys.map { p.d.object(forKey: $0) }
        p.autoSave = false; p.autoCopy = false; p.playSound = false
        defer { for (k, v) in zip(keys, before) { if let v { p.d.set(v, forKey: k) } else { p.d.removeObject(forKey: k) } } }
        var ids: [String] = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: record))) ?? []
        let screen = NSScreen.screens[0]
        let shot = try? await ScreenGrabber.captureDisplay(screen.displayID)
        let f = screen.frame
        let rects: [CGRect] = [
            CGRect(x: 0, y: f.height - 300, width: 520, height: 300), CGRect(x: f.width / 3, y: f.height / 3, width: 400, height: 400),
            CGRect(x: 0, y: 0, width: f.width, height: f.height), CGRect(x: 40, y: 80, width: 300, height: 600),
            CGRect(x: f.width - 700, y: f.height - 200, width: 700, height: 200), CGRect(x: 200, y: 200, width: 640, height: 400),
        ]
        for i in 0..<count {
            let r = rects[i % rects.count].intersection(f)
            let img: CGImage? = shot.flatMap { try? Capture.crop($0, global: r, screen: screen) } ?? synthetic(i)
            guard let img, let item = try? Output.finish(img, kind: .screenshot, pointSize: r.size, presentQuickAccess: false),
                  let id = item.historyID else { continue }
            ids.append(id.uuidString)
        }
        // One GIF so the kind badge / filter can be checked.
        if let gif = makeGIF(), let e = HistoryStore.shared.add(fileAt: gif, kind: .gif, savedPath: nil, pixelWidth: 240, pixelHeight: 160) {
            ids.append(e.id.uuidString)
            try? FileManager.default.removeItem(at: gif)
        }
        try? JSONEncoder().encode(ids).write(to: record)
        ToolsCLI.out("seeded \(count + 1) entries; history now \(HistoryStore.shared.entries.count)")
        return 0
    }

    @MainActor
    static func unseed() -> Int32 {
        let ids = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: record))) ?? []
        for s in ids { if let id = UUID(uuidString: s) { HistoryStore.shared.remove(id: id) } }
        try? FileManager.default.removeItem(at: record)
        ToolsCLI.out("removed \(ids.count) seeded entries; history now \(HistoryStore.shared.entries.count)")
        return 0
    }

    private static func synthetic(_ i: Int) -> CGImage? {
        let w = 600, h = 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let hue = CGFloat(i % 6) / 6
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func makeGIF() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapper-seed-\(UUID().uuidString).gif")
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 6, nil) else { return nil }
        for i in 0..<6 {
            guard let ctx = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            ctx.setFillColor(NSColor.systemTeal.cgColor)
            ctx.fillEllipse(in: CGRect(x: 20 + i * 30, y: 50, width: 60, height: 60))
            if let img = ctx.makeImage() {
                CGImageDestinationAddImage(dst, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            }
        }
        return CGImageDestinationFinalize(dst) ? url : nil
    }
}
