import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Loads (and caches) picture backgrounds. Shared by every renderer; thread-safe.
public final class BackgroundImageCache: @unchecked Sendable {
    public static let shared = BackgroundImageCache()

    /// Longest edge pictures are decoded at. Plenty for screenshot-sized output, cheap to redraw.
    public var maxPixel = 3840

    private let lock = NSLock()
    private var sharp: [String: CGImage] = [:]
    private var blurred: [String: CGImage] = [:]
    private var missing: Set<String> = []
    private lazy var ci = CIContext(options: [.useSoftwareRenderer: false])

    /// Picture at `path`, optionally blurred (`blur` 0…100). nil if the file can't be read.
    public func image(path: String, blur: CGFloat = 0) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let base = loadLocked(path) else { return nil }
        let b = Int(max(0, min(100, blur)).rounded())
        guard b > 0 else { return base }
        let key = "\(b)|\(path)"
        if let c = blurred[key] { return c }
        let src = CIImage(cgImage: base)
        let f = CIFilter(name: "CIGaussianBlur")
        f?.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
        f?.setValue(CGFloat(b) / 100 * 0.04 * CGFloat(max(base.width, base.height)), forKey: kCIInputRadiusKey)
        guard let out = f?.outputImage?.cropped(to: src.extent), let cg = ci.createCGImage(out, from: src.extent) else { return base }
        if blurred.count >= 1 { blurred.removeAll() }
        blurred[key] = cg
        return cg
    }

    /// Release every decoded picture (called once a capture is done — they are re-read when needed).
    public func purge() {
        lock.lock(); defer { lock.unlock() }
        sharp.removeAll(); blurred.removeAll()
    }

    /// Drop a cached picture (e.g. the file was replaced).
    public func forget(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        sharp[path] = nil; missing.remove(path)
        blurred = blurred.filter { !$0.key.hasSuffix("|" + path) }
    }

    private func loadLocked(_ path: String) -> CGImage? {
        if let c = sharp[path] { return c }
        if missing.contains(path) { return nil }
        guard let img = Self.decode(URL(fileURLWithPath: path), maxPixel: maxPixel) else { missing.insert(path); return nil }
        if sharp.count >= 2 { sharp.removeAll() }
        sharp[path] = img
        return img
    }

    /// Decode an image file, downsampled so its longest edge is at most `maxPixel` (EXIF orientation applied).
    public static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Built-in wallpapers and the user's own background pictures.
public enum BackgroundLibrary {
    public static let systemWallpaperDirectory = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp", "gif", "bmp"]

    public static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Full-resolution still wallpapers shipped with macOS (`*.heic` in Desktop Pictures; folders and
    /// `.madesktop` aerials skipped), sorted by name.
    public static func systemWallpapers(in dir: URL = systemWallpaperDirectory) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return items.filter { u in
            guard u.pathExtension.lowercased() == "heic" else { return false }
            return (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
