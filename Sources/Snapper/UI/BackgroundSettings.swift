import AppKit
import SnapKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Background: pick the background once (gradient, colour, wallpaper or your own picture) and
/// Snapper puts window captures on it automatically. The preview is rendered by the same code that renders
/// the real capture, so what you see is exactly what you get.
final class BackgroundSettingsModel: ObservableObject {
    @Published var bg: AnnotationBackground { didSet { Prefs.shared.background = bg; renderPreview() } }
    @Published var auto: AutoBackground { didSet { Prefs.shared.autoBackground = auto } }
    @Published var preview: NSImage?
    @Published var pictures: [URL] = []

    init() {
        bg = Prefs.shared.background
        auto = Prefs.shared.autoBackground
        reloadPictures()
        renderPreview()
    }

    func reloadPictures() {
        var list: [URL] = []
        if let d = BackgroundStore.currentDesktopPicture { list.append(d) }
        for u in BackgroundStore.recents + BackgroundStore.wallpapers where !list.contains(u) { list.append(u) }
        pictures = list
    }

    func isSelected(_ url: URL) -> Bool { bg.imagePath == url.path }

    func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let u = panel.url, let saved = BackgroundStore.importPicture(u) else { return }
        bg.kind = .image(saved.path)
        reloadPictures()
    }

    var solidColor: Color {
        get { if case .solid(let c) = bg.kind { return Color(nsColor: NSColor(cgColor: c.cgColor) ?? .white) }; return .white }
    }
    func setSolid(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        bg.kind = .solid(RGBA(ns.redComponent, ns.greenComponent, ns.blueComponent, 1))
    }

    /// A mock window rendered at 2x, put on the background exactly like a real capture.
    private static let sample: CGImage = {
        let w = 360, h = 220, s: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(CGFloat(w) * s), height: Int(CGFloat(h) * s), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        let body = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)); ctx.fill(body)
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.18, blue: 0.21, alpha: 1)); ctx.fill(CGRect(x: 0, y: h - 28, width: w, height: 28))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 12 + CGFloat(i) * 18, y: CGFloat(h) - 19, width: 11, height: 11))
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13))
        for (i, lw) in [220, 300, 260, 180, 240, 120].enumerated() {
            ctx.addPath(CGPath(roundedRect: CGRect(x: 18, y: CGFloat(h) - 56 - CGFloat(i) * 24, width: CGFloat(lw), height: 9), cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
        return ctx.makeImage()!
    }()

    func renderPreview() {
        let bg = self.bg
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Output.withBackground(Self.sample, pointSize: CGSize(width: 360, height: 220), bg)
            DispatchQueue.main.async {
                guard bg == self.bg, let out else { return }
                self.preview = NSImage(cgImage: out.image, size: out.pointSize)
            }
        }
    }
}

struct BackgroundSettingsView: View {
    @StateObject private var m = BackgroundSettingsModel()

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Group {
                        if let p = m.preview { Image(nsImage: p).resizable().aspectRatio(contentMode: .fit) }
                        else { Color.clear }
                    }
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    Spacer()
                }
                Picker("Use it for", selection: $m.auto) {
                    Text("Window captures").tag(AutoBackground.windows)
                    Text("All screenshots").tag(AutoBackground.all)
                    Text("Only when I ask (Annotate)").tag(AutoBackground.off)
                }
            }
            Section("Background") {
                LabeledContent("Gradient") {
                    HStack(spacing: 6) {
                        ForEach(0..<AnnotationBackground.presets.count, id: \.self) { i in
                            let p = AnnotationBackground.presets[i]
                            Chip(selected: m.bg.preset == i) {
                                LinearGradient(colors: [Color(cgColor: p.0.cgColor), Color(cgColor: p.1.cgColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            } action: { m.bg.kind = .gradient(i) }
                        }
                        ColorPicker("", selection: Binding(get: { m.solidColor }, set: { m.setSolid($0) }), supportsOpacity: false)
                            .labelsHidden()
                            .help("Solid colour")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Picture")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                        Button { m.choosePicture() } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                .frame(width: 44, height: 28)
                                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Choose any picture…")
                        ForEach(m.pictures, id: \.self) { u in
                            Chip(selected: m.isSelected(u), w: 44, h: 28) { Thumb(url: u) } action: { m.bg.kind = .image(u.path) }
                                .help(u.deletingPathExtension().lastPathComponent)
                        }
                    }
                }
            }
            Section("Style") {
                Slider(value: $m.bg.padding, in: 0...160) { Text("Padding") }
                Slider(value: $m.bg.cornerRadius, in: 0...32) { Text("Corners") }
                if m.bg.imagePath != nil {
                    Slider(value: $m.bg.blur, in: 0...100) { Text("Blur picture") }
                }
                Toggle("Shadow", isOn: $m.bg.shadow)
            }
        }
    }
}

private struct Chip<Content: View>: View {
    let selected: Bool
    var w: CGFloat = 36
    var h: CGFloat = 24
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            content()
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Thumb: View {
    let url: URL
    @State private var img: NSImage?
    var body: some View {
        Group {
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
            else { Color.primary.opacity(0.08) }
        }
        .onAppear { BackgroundThumbs.shared.thumb(url) { img = $0 } }
    }
}
