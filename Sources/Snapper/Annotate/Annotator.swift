import AppKit
import ImageIO
import SnapKit
import UniformTypeIdentifiers

/// Public entry points (kept stable for QuickAccess / AppDelegate / CLI).
enum Annotator {
    @MainActor static var editors: [AnnotateEditor] = []

    /// Posted when an editor opened for a CaptureItem closes; `object` is that CaptureItem.
    /// (Its `image` / `pointSize` already reflect the last Save or Copy.)
    static let didClose = Notification.Name("SnapperAnnotateDidClose")

    static func open(url: URL) {
        MainActor.assumeIsolated {
            guard let (img, pts) = loadImage(url) else { NSSound.beep(); return }
            present(AnnotateEditor(image: img, pointSize: pts, item: nil, sourceURL: url))
        }
    }

    static func open(item: CaptureItem) {
        open(item: item, background: false)
    }

    /// Open the editor with the Background panel showing and the last-used background applied
    /// (first wallpaper if none yet). For Quick Access' "Background" button.
    static func openWithBackground(item: CaptureItem) {
        open(item: item, background: true)
    }

    static func open(item: CaptureItem, background: Bool) {
        MainActor.assumeIsolated {
            let e: AnnotateEditor
            if let img = item.image {
                e = AnnotateEditor(image: img, pointSize: item.pointSize, item: item, sourceURL: item.savedURL ?? item.fileURL)
            } else if let (img, pts) = loadImage(item.fileURL) {
                item.image = img
                e = AnnotateEditor(image: img, pointSize: pts, item: item, sourceURL: item.savedURL ?? item.fileURL)
            } else { NSSound.beep(); return }
            present(e)
            if background { e.showBackground(BackgroundStore.defaultForWindowShots) }
        }
    }

    /// Open a file with the Background panel showing.
    static func openWithBackground(url: URL) {
        open(url: url)
        MainActor.assumeIsolated { editors.last?.showBackground(BackgroundStore.defaultForWindowShots) }
    }

    @MainActor private static func present(_ e: AnnotateEditor) {
        editors.append(e)
        e.show()
    }

    @MainActor static func closed(_ e: AnnotateEditor) { editors.removeAll { $0 === e } }

    /// Pixels + point size. Uses the file's DPI when present; Snapper's own PNGs carry none, so those
    /// are assumed to be at the main screen's backing scale (they are screen captures).
    static func loadImage(_ url: URL) -> (CGImage, CGSize)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var scale: CGFloat = 1
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            scale = max(1, CGFloat(dpi) / 72)
        } else {
            scale = NSScreen.main?.backingScaleFactor ?? 2
        }
        if CGFloat(img.width) / scale < 40 || CGFloat(img.height) / scale < 40 { scale = 1 }
        return (img, CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
    }

    /// Encode with the DPI that matches the point size, so Preview/Finder show it at the right size.
    static func encode(_ img: CGImage, format: ImageFormat, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dst = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if format == .jpeg { opts[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dst, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }

    @MainActor static func registerCLI() {
        CLI.extra["--annotate-demo"] = { args in
            guard args.count >= 2 else { FileHandle.standardError.write("usage: --annotate-demo IN.png OUT.png\n".data(using: .utf8)!); return 2 }
            guard let (img, pts) = loadImage(URL(fileURLWithPath: args[0])) else {
                FileHandle.standardError.write("cannot read \(args[0])\n".data(using: .utf8)!); return 1
            }
            let r = AnnotationRenderer(image: img, pointSize: pts)
            let doc = demoDocument(size: pts)
            guard let out = r.flatten(doc), let data = encode(out, format: .png, scale: r.scale) else { return 1 }
            do { try data.write(to: URL(fileURLWithPath: args[1])) } catch { return 1 }
            print("\(out.width)x\(out.height) annotations=\(doc.annotations.count)")
            return 0
        }
        CLI.extra["--background-demo"] = { args in
            guard args.count >= 2 else {
                FileHandle.standardError.write("usage: --background-demo IN.png OUT.png [picture] [padding] [noshadow]\n".data(using: .utf8)!); return 2
            }
            guard let (img, pts) = loadImage(URL(fileURLWithPath: args[0])) else {
                FileHandle.standardError.write("cannot read \(args[0])\n".data(using: .utf8)!); return 1
            }
            guard let pic = args.count > 2 ? args[2] : BackgroundStore.wallpapers.first?.path else {
                FileHandle.standardError.write("no wallpaper found\n".data(using: .utf8)!); return 1
            }
            let pad = args.count > 3 ? CGFloat(Double(args[3]) ?? 64) : 64
            let r = AnnotationRenderer(image: img, pointSize: pts)
            let shadow = !(args.count > 4 && args[4] == "noshadow")
            let doc = AnnotationDocument(background: AnnotationBackground(kind: .image(pic), padding: pad, shadow: shadow))
            guard let out = r.flatten(doc), let data = encode(out, format: .png, scale: r.scale) else { return 1 }
            do { try data.write(to: URL(fileURLWithPath: args[1])) } catch { return 1 }
            print("\(out.width)x\(out.height) background=\(pic) ownShadow=\(r.hasTransparentEdges)")
            return 0
        }
        CLI.extra["--annotate-open"] = { args in
            guard let path = args.first else { return 2 }
            NSApp.activate(ignoringOtherApps: true)
            if args.dropFirst().contains("--background") {
                openWithBackground(url: URL(fileURLWithPath: path))
            } else {
                open(url: URL(fileURLWithPath: path))
            }
            if args.dropFirst().contains("--demo"), let e = Annotator.editors.last {
                e.loadDemo()
            }
            // Keep the process alive as a normal app until killed.
            while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        }
    }

    /// One of each tool, laid out relative to the image size (image points, y down).
    static func demoDocument(size s: CGSize) -> AnnotationDocument {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s.width * x, y: s.height * y) }
        var a: [Annotation] = []
        a.append(Annotation(kind: .blur, start: P(0.06, 0.08), end: P(0.30, 0.20)))
        a.append(Annotation(kind: .blur, start: P(0.06, 0.24), end: P(0.30, 0.32), blurStyle: .pixelate))
        a.append(Annotation(kind: .spotlight, start: P(0.55, 0.50), end: P(0.92, 0.88)))
        a.append(Annotation(kind: .rect, start: P(0.38, 0.10), end: P(0.62, 0.30), color: .red, lineWidth: 5))
        a.append(Annotation(kind: .rect, start: P(0.66, 0.10), end: P(0.74, 0.18), color: .blue, lineWidth: 5, filled: true))
        a.append(Annotation(kind: .ellipse, start: P(0.76, 0.10), end: P(0.94, 0.34), color: .green, lineWidth: 5))
        a.append(Annotation(kind: .arrow, start: P(0.20, 0.62), end: P(0.37, 0.33), color: .red, lineWidth: 5))
        a.append(Annotation(kind: .arrow, start: P(0.40, 0.75), end: P(0.56, 0.62), color: .orange, lineWidth: 3))
        a.append(Annotation(kind: .line, start: P(0.06, 0.90), end: P(0.40, 0.90), color: .purple, lineWidth: 3))
        let hl = (0...24).map { i in P(0.06 + CGFloat(i) * 0.012, 0.42 + sin(CGFloat(i) / 4) * 0.004) }
        a.append(Annotation(kind: .highlighter, start: hl[0], end: hl.last!, points: hl, color: .yellow, lineWidth: 5))
        let pen = (0...40).map { i -> CGPoint in let t = CGFloat(i) / 40; return P(0.06 + t * 0.2, 0.80 + sin(t * .pi * 3) * 0.03) }
        a.append(Annotation(kind: .pencil, start: pen[0], end: pen.last!, points: pen, color: .blue, lineWidth: 3))
        a.append(Annotation(kind: .text, start: P(0.06, 0.50), color: .red, text: "Snapper Annotate", fontSize: 32, textBackground: true))
        a.append(Annotation(kind: .text, start: P(0.06, 0.60), color: .white, text: "Plain text, two lines\nwith a soft halo", fontSize: 22))
        for (i, p) in [P(0.60, 0.55), P(0.70, 0.62), P(0.80, 0.70)].enumerated() {
            a.append(Annotation(kind: .counter, start: p, color: .red, lineWidth: 5, number: i + 1))
        }
        return AnnotationDocument(annotations: a)
    }
}
