import AVFoundation
import AppKit
import ScreenCaptureKit
import SnapKit

struct RecordError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Host-time clock in seconds — the same clock ScreenCaptureKit stamps its samples with.
func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// One recording: an SCStream over a display rect feeding an AVAssetWriter (.mp4, H.264, HEVC above 4K).
/// All capture/writer state lives on `q`; the public methods are called from the main thread.
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Result {
        let url: URL
        let pixelSize: CGSize
        let pointSize: CGSize
        let duration: Double
        let frames: Int
    }

    let outURL: URL
    let globalRect: CGRect
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    let fps: Int
    let wantsMic: Bool
    /// Snapper windows that must stay visible in the recording (click rings). Every other Snapper window is excluded.
    let keepWindowIDs: [CGWindowID]
    /// Begin with the pause timeline open (countdown): frames are dropped until `resume()`.
    var startPaused = false { didSet { if startPaused { pause() } } }
    /// Stream died on its own (display unplugged, permission revoked). Called on main.
    var onStreamError: ((Error) -> Void)?

    private(set) var plan: RecordPlan?
    /// Set by stop()/discard(); a start() still awaiting SCStream tears its stream down instead of leaking it.
    private var stopRequested = false
    private var stream: SCStream?
    private let q = DispatchQueue(label: "snapper.record", qos: .userInitiated)

    // q-only state
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioIn: AVAssetWriterInput?
    private var timeline = PauseTimeline()
    private var firstPTS: Double?
    private var lastVideoTime = CMTime.invalid
    private var lastAudioTime = CMTime.invalid
    private var lastBuffer: CVPixelBuffer?
    private var frames = 0
    private var closed = false
    private var failure: Error?

    private static let timescale: CMTimeScale = 60_000

    init(globalRect: CGRect, screen: NSScreen, fps: Int, mic: Bool, keepWindowIDs: [CGWindowID] = [], outURL: URL) {
        self.globalRect = globalRect
        self.screenFrame = screen.frame
        self.displayID = screen.displayID
        self.fps = max(1, min(fps, 120))
        self.wantsMic = mic
        self.keepWindowIDs = keepWindowIDs
        self.outURL = outURL
    }

    // MARK: control

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordError(message: "The display to record is no longer connected")
        }
        let filter = Self.filter(content, display: display, keep: keepWindowIDs)
        let scale = CGFloat(filter.pointPixelScale)
        guard let plan = RecordMath.plan(global: globalRect, screenFrame: screenFrame, scale: scale > 0 ? scale : 2) else {
            throw RecordError(message: "The selected area is not on the display")
        }
        self.plan = plan
        let mic = wantsMic ? await Self.micAllowed() : false
        try q.sync { try makeWriter(plan, audio: mic) }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = plan.sourceRect
        cfg.width = plan.pixelWidth
        cfg.height = plan.pixelHeight
        cfg.scalesToFit = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 8
        cfg.captureResolution = .best
        if mic, #available(macOS 15.0, *) { cfg.captureMicrophone = true }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if mic, #available(macOS 15.0, *) { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q) }
        do {
            try await s.startCapture()
        } catch {
            q.sync { closeWriter(discard: true) }
            throw error
        }
        if stopRequested {
            try? await s.stopCapture()
            q.sync { closeWriter(discard: true) }
            throw RecordError(message: "Recording was stopped before it started")
        }
        stream = s
    }

    func pause() { let t = hostNow(); q.async { self.timeline.pause(at: t) } }
    func resume() { let t = hostNow(); q.async { self.timeline.resume(at: t) } }

    /// Recorded seconds so far (pauses excluded); 0 until the first frame.
    var elapsed: Double {
        let now = hostNow()
        return q.sync { firstPTS.map { timeline.elapsed(start: $0, now: now) } ?? 0 }
    }

    /// Stop and write the file. Throws when nothing was captured or the writer failed (the file is removed then).
    func stop() async throws -> Result {
        let end = hostNow()
        stopRequested = true
        await stopStream()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            q.async { self.finish(endHost: end, cont) }
        }
    }

    /// Stop and throw the recording away.
    func discard() async {
        stopRequested = true
        await stopStream()
        q.sync { closeWriter(discard: true) }
    }

    private func stopStream() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: filter / writer setup

    /// Whole display minus every Snapper window except `keep`. Excluding the *application* (not a window list)
    /// also hides Snapper windows that open after recording started (Quick Access, alerts).
    static func filter(_ c: SCShareableContent, display: SCDisplay, keep: [CGWindowID]) -> SCContentFilter {
        let me = getpid()
        let keepWins = c.windows.filter { keep.contains($0.windowID) }
        if let app = c.applications.first(where: { $0.processID == me }) {
            return SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: keepWins)
        }
        let mine = c.windows.filter { $0.owningApplication?.processID == me && !keep.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: mine)
    }

    private static func micAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeWriter(_ plan: RecordPlan, audio: Bool) throws {
        try? FileManager.default.removeItem(at: outURL)
        let w = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = true
        let px = plan.pixelWidth * plan.pixelHeight
        // H.264 hardware encoders top out around 4096x2304; HEVC covers 5K/6K displays.
        let hevc = plan.pixelWidth > 4096 || plan.pixelHeight > 4096 || px > 4096 * 2304
        let bitrate = max(2_000_000, min(px * 6, 60_000_000))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        compression[AVVideoProfileLevelKey] = hevc ? "HEVC_Main_AutoLevel" : AVVideoProfileLevelH264HighAutoLevel
        let settings: [String: Any] = [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.pixelWidth,
            AVVideoHeightKey: plan.pixelHeight,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vin.expectsMediaDataInRealTime = true
        guard w.canAdd(vin) else { throw RecordError(message: "Cannot encode a \(plan.pixelWidth)x\(plan.pixelHeight) video") }
        w.add(vin)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        if audio {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); audioIn = a }
        }
        writer = w
        videoIn = vin
    }

    // MARK: samples (q)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !closed, failure == nil, sb.isValid else { return }
        if type == .screen {
            handleVideo(sb)
        } else if #available(macOS 15.0, *), type == .microphone {
            handleAudio(sb)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let buffer: CVPixelBuffer
        switch status {
        case .complete:
            guard let b = sb.imageBuffer else { return }
            buffer = b
        case .idle:
            // Nothing changed on screen: repeat the last frame so the file keeps a steady frame rate.
            guard let b = lastBuffer else { return }
            buffer = b
        default:
            return
        }
        let pts = sb.presentationTimeStamp.seconds
        guard pts.isFinite, let writer, let videoIn, let adaptor else { return }

        if firstPTS == nil {
            guard status == .complete, timeline.outputTime(for: pts) != nil else { return }
            guard writer.startWriting() else { fail(writer.error); return }
            writer.startSession(atSourceTime: .zero)
            firstPTS = pts
        }
        guard let first = firstPTS, let rel = timeline.relativeTime(for: pts, start: first) else { return }
        let t = CMTime(seconds: max(0, rel), preferredTimescale: Self.timescale)
        if lastVideoTime.isValid && t <= lastVideoTime { return }
        guard videoIn.isReadyForMoreMediaData else { return }      // encoder behind: drop, don't block capture
        if adaptor.append(buffer, withPresentationTime: t) {
            lastVideoTime = t
            lastBuffer = buffer
            frames += 1
        } else {
            fail(writer.error)
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let first = firstPTS, let audioIn, audioIn.isReadyForMoreMediaData, writer?.status == .writing else { return }
        let pts = sb.presentationTimeStamp.seconds
        guard pts.isFinite, let rel = timeline.relativeTime(for: pts, start: first), rel >= 0 else { return }
        let rate = (sb.formatDescription?.audioStreamBasicDescription?.mSampleRate).map { CMTimeScale($0) } ?? 48_000
        let t = CMTime(seconds: rel, preferredTimescale: max(rate, 1))
        if lastAudioTime.isValid && t <= lastAudioTime { return }
        var timing = CMSampleTimingInfo(duration: sb.duration, presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &out) == noErr, let out else { return }
        if audioIn.append(out) { lastAudioTime = t } else if writer?.status == .failed { fail(writer?.error) }
    }

    private func fail(_ e: Error?) {
        if failure == nil { failure = e ?? RecordError(message: "The video writer failed") }
    }

    private func finish(endHost: Double, _ cont: CheckedContinuation<Result, Error>) {
        guard !closed else { cont.resume(throwing: RecordError(message: "Recording already finished")); return }
        if let f = failure { closeWriter(discard: true); cont.resume(throwing: f); return }
        guard let first = firstPTS, let writer, let videoIn, let adaptor, writer.status == .writing, lastVideoTime.isValid else {
            closeWriter(discard: true)
            cont.resume(throwing: RecordError(message: "No video frames were captured"))
            return
        }
        closed = true
        let endRel = timeline.endOutputTime(at: endHost) - timeline.endOutputTime(at: first)
        let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        var end = CMTime(seconds: max(0, endRel), preferredTimescale: Self.timescale)
        if end <= lastVideoTime { end = lastVideoTime + frameDur }
        // Hold the last frame until the stop time so a still screen still yields the full duration.
        let pad = end - frameDur
        if pad > lastVideoTime, let b = lastBuffer, videoIn.isReadyForMoreMediaData, adaptor.append(b, withPresentationTime: pad) {
            frames += 1
        }
        lastBuffer = nil
        videoIn.markAsFinished()
        audioIn?.markAsFinished()
        writer.endSession(atSourceTime: end)
        let plan = self.plan
        let n = frames
        let url = outURL
        writer.finishWriting {
            if writer.status == .completed, let plan {
                cont.resume(returning: Result(url: url, pixelSize: CGSize(width: plan.pixelWidth, height: plan.pixelHeight),
                                              pointSize: plan.globalRect.size, duration: end.seconds, frames: n))
            } else {
                try? FileManager.default.removeItem(at: url)
                cont.resume(throwing: writer.error ?? RecordError(message: "Could not finish the video file"))
            }
        }
    }

    private func closeWriter(discard: Bool) {
        closed = true
        lastBuffer = nil
        if let w = writer, w.status == .writing { w.cancelWriting() }
        writer = nil
        if discard { try? FileManager.default.removeItem(at: outURL) }
    }
}
