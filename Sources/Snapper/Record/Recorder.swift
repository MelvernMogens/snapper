import AVFoundation
import AppKit
import ScreenCaptureKit
import SnapKit

/// Screen recording (MP4) and GIF recording, CleanShot-style:
/// pick an area (Space = window, click = full screen) → 3-2-1 → record with a dashed border and a small control pill.
/// The menu-bar icon turns into a red stop button with the elapsed time; clicking it (or the hotkey again) stops.
final class Recorder: NSObject {
    static let shared = Recorder()

    private enum Phase { case idle, selecting, countdown, recording, finishing }
    private var phase: Phase = .idle
    private var gif = false
    private var rect: CGRect = .zero
    private var screen: NSScreen?
    private var rec: StreamRecorder?
    private var border: RecordBorder?
    private var rings: ClickRings?
    private var controls: RecordControls?
    private var ticker: Timer?
    private var countdownLeft: Int?
    private var paused = false
    private var savedMenu: NSMenu?
    private var statusHijacked = false

    static let gifFPS = 15

    var isActive: Bool { phase != .idle }

    // MARK: entry

    func start(gif: Bool) {
        switch phase {
        case .recording: stop(); return
        case .countdown: cancel(); return
        case .selecting, .finishing: return
        case .idle: break
        }
        guard Permissions.ensureScreenRecording() else { return }
        self.gif = gif
        phase = .selecting
        let hint = gif ? "Select an area to record as GIF — Space: window · click: full screen · Esc: cancel"
                       : "Select an area to record — Space: window · click: full screen · Esc: cancel"
        let began = OverlayController.begin(allowWindowMode: true, hint: hint) { [weak self] r in
            guard let self else { return }
            guard let r else { self.phase = .idle; return }
            // Window pick: record the window's region (clipped to its display).
            self.begin(rect: r.rect, screen: r.screen)
        }
        if began == nil { phase = .idle; NSSound.beep() }
    }

    /// Record a rect that was already chosen elsewhere (All-In-One).
    func record(rect: CGRect, screen: NSScreen, gif: Bool) {
        guard phase == .idle, Permissions.ensureScreenRecording() else { return }
        self.gif = gif
        begin(rect: rect, screen: screen)
    }

    private func begin(rect: CGRect, screen: NSScreen) {
        let fps = gif ? min(Self.gifFPS, max(1, Prefs.shared.recordFPS)) : max(1, Prefs.shared.recordFPS)
        guard let plan = RecordMath.plan(global: rect, screenFrame: screen.frame, scale: screen.backingScaleFactor) else {
            phase = .idle; NSSound.beep(); return
        }
        self.rect = plan.globalRect
        self.screen = screen
        paused = false
        phase = .countdown
        countdownLeft = Prefs.shared.recordCountdown ? 3 : 0

        border = RecordBorder(rect: plan.globalRect)
        border?.show()
        if Prefs.shared.recordShowClicks {
            rings = ClickRings(rect: plan.globalRect)
            rings?.show()
        }
        controls = RecordControls(near: plan.globalRect, screen: screen) { [weak self] c in self?.handle(c) }
        controls?.show()
        hijackStatusItem()
        refreshUI()

        // The stream starts (paused) during the countdown so recording begins the instant it hits zero.
        startStream(fps: fps)
        countdownTick()
    }

    private func startStream(fps: Int) {
        guard let screen else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Snapper-\(UUID().uuidString).mp4")
        let r = StreamRecorder(globalRect: rect, screen: screen, fps: fps, mic: Prefs.shared.recordAudioMic && !gif,
                               keepWindowIDs: rings.map { [$0.windowID] } ?? [], outURL: url)
        r.startPaused = phase == .countdown || paused
        r.onStreamError = { [weak self, weak r] e in
            guard let self, let r, self.rec === r, self.phase == .recording || self.phase == .countdown else { return }
            NSLog("Snapper recording stream stopped: \(e.localizedDescription)")
            self.stop()
        }
        rec = r
        Task { @MainActor in
            do {
                try await r.start()
            } catch {
                guard self.rec === r else { return }
                self.teardown()
                if !CGPreflightScreenCaptureAccess() || (error as NSError).code == SCStreamError.userDeclined.rawValue {
                    Permissions.ensureScreenRecording()
                } else {
                    Permissions.showError("Recording failed to start", error)
                }
            }
        }
    }

    private func countdownTick() {
        guard phase == .countdown, let n = countdownLeft else { return }
        if n <= 0 { goLive(); return }
        border?.setCountdown(n)
        refreshUI()
        countdownLeft = n - 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.countdownTick() }
    }

    private func goLive() {
        guard phase == .countdown else { return }
        countdownLeft = nil
        border?.setCountdown(nil)
        phase = .recording
        rec?.resume()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshUI() }
        refreshUI()
    }

    // MARK: commands

    private func handle(_ c: RecordControls.Cmd) {
        switch c {
        case .stop: phase == .countdown ? goLive() : stop()
        case .pause: togglePause()
        case .restart: restart()
        case .cancel: cancel()
        }
    }

    func togglePause() {
        guard phase == .recording, let rec else { return }
        paused.toggle()
        paused ? rec.pause() : rec.resume()
        border?.setPaused(paused)
        refreshUI()
    }

    /// Throw the take away and start again on the same area (no countdown).
    func restart() {
        guard phase == .recording || phase == .countdown, let old = rec else { return }
        rec = nil
        let fps = old.fps
        Task { await old.discard() }
        paused = false
        border?.setPaused(false)
        if phase == .countdown { goLive() }
        startStream(fps: fps)
        refreshUI()
    }

    func cancel() {
        guard phase == .countdown || phase == .recording, let r = rec else { teardown(); return }
        rec = nil
        teardown()
        Task { await r.discard() }
    }

    func stop() {
        guard phase == .recording || phase == .countdown, let r = rec else { cancel(); return }
        phase = .finishing
        let isGIF = gif
        let shownRect = rect
        rec = nil
        teardown(keepPhase: true)
        Task { @MainActor in
            defer { self.phase = .idle }
            do {
                let res = try await r.stop()
                if isGIF {
                    let gifURL = res.url.deletingPathExtension().appendingPathExtension("gif")
                    defer { try? FileManager.default.removeItem(at: res.url) }
                    let info = try await GIFEncoder.convert(res.url, to: gifURL, fps: Self.gifFPS)
                    Output.finishMovie(gifURL, kind: .gif, pixelSize: CGSize(width: info.width, height: info.height), pointSize: shownRect.size)
                } else {
                    Output.finishMovie(res.url, kind: .recording, pixelSize: res.pixelSize, pointSize: res.pointSize)
                }
                if Prefs.shared.playSound { Output.sound?.stop(); Output.sound?.play() }
            } catch {
                Permissions.showError(isGIF ? "GIF recording failed" : "Recording failed", error)
            }
        }
    }

    // MARK: UI state

    private func refreshUI() {
        let elapsed = rec?.elapsed ?? 0
        controls?.update(elapsed: elapsed, paused: paused, counting: phase == .countdown ? (countdownLeft.map { $0 + 1 } ?? 0) : nil)
        guard statusHijacked, let b = AppDelegate.shared?.statusItem?.button else { return }
        b.title = phase == .countdown ? "" : " " + RecordMath.formatElapsed(elapsed)
    }

    private func teardown(keepPhase: Bool = false) {
        ticker?.invalidate(); ticker = nil
        border?.close(); border = nil
        rings?.close(); rings = nil
        controls?.close(); controls = nil
        countdownLeft = nil
        paused = false
        restoreStatusItem()
        if !keepPhase { phase = .idle }
    }

    /// Menu-bar icon → red stop + timer; a click stops instead of opening the menu.
    private func hijackStatusItem() {
        guard !statusHijacked, let item = AppDelegate.shared?.statusItem, let b = item.button else { return }
        statusHijacked = true
        savedMenu = item.menu
        item.menu = nil
        item.length = NSStatusItem.variableLength
        let img = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        img?.isTemplate = true
        b.image = img
        b.contentTintColor = .systemRed
        b.imagePosition = .imageLeading
        b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        b.title = ""
        b.target = self
        b.action = #selector(statusClicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func restoreStatusItem() {
        guard statusHijacked, let ad = AppDelegate.shared, let item = ad.statusItem, let b = item.button else { return }
        statusHijacked = false
        b.target = nil
        b.action = nil
        b.title = ""
        b.imagePosition = .imageOnly
        item.length = NSStatusItem.squareLength
        item.menu = savedMenu ?? ad.menu
        savedMenu = nil
        ad.setIdleIcon()
    }

    @objc private func statusClicked() {
        if phase == .countdown { cancel() } else { stop() }
    }
}

// MARK: - CLI

extension Recorder {
    @MainActor static func registerCLI() {
        CLI.extra["--record-test"] = { args in await cliRecord(args, gif: false) }
        CLI.extra["--gif-test"] = { args in await cliRecord(args, gif: true) }
    }

    /// `--record-test x,y,w,h SECONDS OUT.mp4 [--clicks] [--pause A,B]` — headless recording of an AppKit-global rect.
    /// `--clicks` shows the click-ring window and fires a ring in the middle every 0.5 s (verifies it is captured).
    /// `--pause A,B` pauses at A seconds and resumes at B seconds (wall clock from start).
    @MainActor
    private static func cliRecord(_ args: [String], gif: Bool) async -> Int32 {
        func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
        guard args.count >= 3, let rect = RecordMath.parseRect(args[0]), let secs = Double(args[1]), secs > 0 else {
            err("usage: \(gif ? "--gif-test" : "--record-test") x,y,w,h SECONDS OUT [--clicks] [--pause A,B]"); return 2
        }
        let outURL = URL(fileURLWithPath: args[2])
        let clicks = args.contains("--clicks")
        var pause: (Double, Double)?
        if let i = args.firstIndex(of: "--pause"), i + 1 < args.count {
            let p = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if p.count == 2, p[1] > p[0] { pause = (p[0], p[1]) }
        }
        guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }),
              screen.frame.intersects(rect) else { err("rect is not on any display"); return 2 }
        let fps = gif ? gifFPS : max(1, Prefs.shared.recordFPS)
        var rings: ClickRings?
        if clicks, let plan = RecordMath.plan(global: rect, screenFrame: screen.frame, scale: screen.backingScaleFactor) {
            rings = ClickRings(rect: plan.globalRect)
            rings?.window.orderFrontRegardless()
        }
        defer { rings?.close() }
        let tmp = gif ? FileManager.default.temporaryDirectory.appendingPathComponent("Snapper-\(UUID().uuidString).mp4") : outURL
        let r = StreamRecorder(globalRect: rect, screen: screen, fps: fps, mic: false,
                               keepWindowIDs: rings.map { [$0.windowID] } ?? [], outURL: tmp)
        do {
            try await r.start()
            let t0 = Date()
            var paused = false, resumed = false
            while Date().timeIntervalSince(t0) < secs {
                let t = Date().timeIntervalSince(t0)
                if let p = pause {
                    if !paused, t >= p.0 { r.pause(); paused = true }
                    if paused, !resumed, t >= p.1 { r.resume(); resumed = true }
                }
                if let rings, Int(t * 10) % 5 == 0 {
                    let f = rings.window.frame
                    rings.ring(at: CGPoint(x: f.midX + CGFloat.random(in: -60...60), y: f.midY + CGFloat.random(in: -40...40)))
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let res = try await r.stop()
            out(String(format: "recorded %dx%d %.2fs %d frames", Int(res.pixelSize.width), Int(res.pixelSize.height), res.duration, res.frames))
            if gif {
                defer { try? FileManager.default.removeItem(at: tmp) }
                let info = try await GIFEncoder.convert(tmp, to: outURL, fps: gifFPS)
                out("gif \(info.width)x\(info.height) \(info.frames) frames")
            }
            out(outURL.path)
            return 0
        } catch {
            await r.discard()
            err("error: \(error.localizedDescription)")
            return 1
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
