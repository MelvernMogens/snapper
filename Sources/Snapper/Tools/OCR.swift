import AppKit
import SnapKit
import Vision

/// Capture Text: freeze the screen, select an area, recognise the text with Vision, put it on the clipboard.
enum OCR {
    static func captureText() {
        guard OverlayController.current == nil, Permissions.ensureScreenRecording() else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let shots: [CGDirectDisplayID: CGImage]
            do { shots = try await ScreenGrabber.captureAllDisplays() } catch { Permissions.showError("Capture failed", error); return }
            OverlayController.begin(shots: shots, allowWindowMode: false, hint: "Select text to copy") { r in
                guard let r, let shot = shots[r.displayID] else { return }
                let crop: CGImage
                do { crop = try Capture.crop(shot, global: r.rect, screen: r.screen) } catch { return }
                if previous?.processIdentifier != getpid() { previous?.activate() }
                Task.detached(priority: .userInitiated) {
                    let text = (try? recognize(crop)) ?? ""
                    await MainActor.run { deliver(text, screen: r.screen) }
                }
            }
        }
    }

    /// OCR a rect that was already chosen elsewhere (All-In-One).
    static func captureText(rect: CGRect, screen: NSScreen) {
        Task { @MainActor in
            do {
                let shot = try await ScreenGrabber.captureDisplay(screen.displayID)
                let crop = try Capture.crop(shot, global: rect, screen: screen)
                let id = screen.displayID
                Task.detached(priority: .userInitiated) {
                    let text = (try? recognize(crop)) ?? ""
                    await MainActor.run { deliver(text, screen: NSScreen.withDisplayID(id) ?? .underMouse) }
                }
            } catch { Permissions.showError("Capture failed", error) }
        }
    }

    private static func deliver(_ text: String, screen: NSScreen) {
        guard !text.isEmpty else {
            NSSound.beep()
            ToolsHUD.show("No text found", symbol: "text.viewfinder", on: screen)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let n = text.count
        ToolsHUD.show("Copied \(n) character\(n == 1 ? "" : "s")", symbol: "checkmark.circle.fill", on: screen)
    }

    /// Recognised text in reading order ("" when nothing was found). Runs synchronously — call off the main thread.
    static func recognize(_ image: CGImage) throws -> String {
        // Vision misses very small glyphs; upscale tiny selections (e.g. one line of 1x text).
        var input = image
        if image.height < 48, let up = upscale(image, factor: 3) { input = up }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([req])
        let boxes = (req.results ?? []).compactMap { o -> TextBox? in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return TextBox(text: s, rect: o.boundingBox)
        }
        return TextLayout.join(boxes)
    }

    private static func upscale(_ img: CGImage, factor: Int) -> CGImage? {
        let w = img.width * factor, h = img.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    @MainActor
    static func registerCLI() {
        CLI.extra["--ocr-file"] = { args in
            guard let path = args.first else { ToolsCLI.err("usage: --ocr-file IN.png"); return 2 }
            do {
                let img = try ToolsImage.load(path: path)
                let text = try await Task.detached { try recognize(img) }.value
                ToolsCLI.out(text.isEmpty ? "(no text found)" : text)
                return text.isEmpty ? 1 : 0
            } catch { ToolsCLI.err("error: \(error.localizedDescription)"); return 1 }
        }
        CLI.extra["--hud-test"] = { args in
            ToolsHUD.show(args.first ?? "Copied 42 characters")
            return await ToolsCLI.stayAlive()
        }
    }
}
