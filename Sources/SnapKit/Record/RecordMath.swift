import CoreGraphics
import Foundation

/// Pause bookkeeping for a recording, in capture-clock seconds (host time).
/// Frames captured while paused are dropped; frames after a resume are shifted back by the total paused time,
/// so the output has no gap.
public struct PauseTimeline: Equatable {
    public private(set) var pausedAt: Double?
    public private(set) var intervals: [ClosedRange<Double>] = []

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    /// Seconds spent paused in closed intervals (an open pause is not counted).
    public var totalPaused: Double { intervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    public mutating func pause(at t: Double) {
        guard pausedAt == nil else { return }
        pausedAt = t
    }

    public mutating func resume(at t: Double) {
        guard let p = pausedAt else { return }
        pausedAt = nil
        if t > p { intervals.append(p...t) }
    }

    /// Output-time for a capture timestamp, or nil when the timestamp falls inside a pause (frame must be dropped).
    /// Frames stamped before a pause began are kept, even if they are delivered after `pause` was called.
    public func outputTime(for t: Double) -> Double? {
        if let p = pausedAt, t >= p { return nil }
        var offset = 0.0
        for i in intervals {
            if t >= i.lowerBound && t < i.upperBound { return nil }
            if t >= i.upperBound { offset += i.upperBound - i.lowerBound }
        }
        return t - offset
    }

    /// Output-time for the END of a recording stopped at `t`: an open pause (or a pause containing `t`) clamps
    /// the end to where that pause began. Never nil, unlike `outputTime(for:)`.
    public func endOutputTime(at t: Double) -> Double {
        var t = t
        if let p = pausedAt, t > p { t = p }
        var offset = 0.0
        for i in intervals {
            if t > i.lowerBound && t < i.upperBound { t = i.lowerBound }
        }
        for i in intervals where i.upperBound <= t { offset += i.upperBound - i.lowerBound }
        return t - offset
    }

    /// Output seconds of capture timestamp `t` relative to the first recorded frame at `start`, or nil when
    /// `t` falls in a pause. Pauses that happened before `start` (e.g. paused before the first frame) don't count.
    public func relativeTime(for t: Double, start: Double) -> Double? {
        guard let o = outputTime(for: t) else { return nil }
        return o - endOutputTime(at: start)
    }

    /// Recorded (un-paused) seconds between `start` and `now`.
    public func elapsed(start: Double, now: Double) -> Double {
        let end = pausedAt.map { min($0, now) } ?? now
        var paused = 0.0
        for i in intervals where i.upperBound > start {
            paused += min(i.upperBound, end) - max(i.lowerBound, start)
        }
        return max(0, end - start - max(0, paused))
    }
}

/// Where and how big to capture, derived from a selection.
public struct RecordPlan: Equatable {
    /// Display-local, top-left origin, points (what SCStreamConfiguration.sourceRect wants).
    public let sourceRect: CGRect
    /// Output pixel size, always even (H.264/HEVC 4:2:0 needs it).
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The pixel-snapped rect actually recorded, back in AppKit global points (for the border/HUD).
    public let globalRect: CGRect
}

public enum RecordMath {
    /// Plan a capture of `global` (AppKit global points, bottom-left origin) on a display whose AppKit frame is
    /// `screenFrame` at `scale` pixels per point. The rect is clipped to the display, snapped to whole pixels and
    /// trimmed to even pixel dimensions. Nil when nothing of it is on that display.
    public static func plan(global: CGRect, screenFrame sf: CGRect, scale: CGFloat) -> RecordPlan? {
        guard scale > 0, sf.width > 0, sf.height > 0 else { return nil }
        let r = global.standardized.intersection(sf)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let screenPxW = Int((sf.width * scale).rounded())
        let screenPxH = Int((sf.height * scale).rounded())
        let lx = r.minX - sf.minX
        let ty = sf.maxY - r.maxY                       // flip to top-left origin
        func axis(_ origin: CGFloat, _ length: CGFloat, _ limit: Int) -> (Int, Int)? {
            var p0 = Int((origin * scale).rounded())
            let p1 = Int(((origin + length) * scale).rounded())
            var n = p1 - p0
            n -= n % 2
            if n < 2 { n = 2 }
            if n > limit { n = limit - limit % 2 }
            guard n >= 2 else { return nil }
            p0 = max(0, min(p0, limit - n))
            return (p0, n)
        }
        guard let (px, w) = axis(lx, r.width, screenPxW), let (py, h) = axis(ty, r.height, screenPxH) else { return nil }
        let src = CGRect(x: CGFloat(px) / scale, y: CGFloat(py) / scale, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        let g = CGRect(x: sf.minX + src.minX, y: sf.maxY - src.maxY, width: src.width, height: src.height)
        return RecordPlan(sourceRect: src, pixelWidth: w, pixelHeight: h, globalRect: g)
    }

    /// GIF output size: fit within `maxWidth` keeping aspect, never upscale, at least 1x1.
    public static func gifSize(pixelWidth w: Int, pixelHeight h: Int, maxWidth: Int = 960) -> (width: Int, height: Int) {
        guard w > 0, h > 0 else { return (1, 1) }
        if w <= maxWidth { return (w, h) }
        let s = Double(maxWidth) / Double(w)
        return (maxWidth, max(1, Int((Double(h) * s).rounded())))
    }

    /// GIF frames for a clip: sample time (seconds) and delay (centiseconds, GIF's unit).
    /// Times sit on a centisecond grid so the delays add up to the real duration (no drift at 15 fps).
    public static func gifFrames(duration: Double, fps: Int) -> [(time: Double, delayCS: Int)] {
        guard duration > 0, fps > 0 else { return [] }
        let totalCS = max(1, Int((duration * 100).rounded()))
        var out: [(Double, Int)] = []
        var i = 0
        while true {
            let cs = Int((Double(i) * 100 / Double(fps)).rounded())
            if cs >= totalCS { break }
            let next = min(totalCS, Int((Double(i + 1) * 100 / Double(fps)).rounded()))
            out.append((Double(cs) / 100, max(1, next - cs)))
            i += 1
        }
        return out.map { (time: $0.0, delayCS: $0.1) }
    }

    /// "0:07", "12:34", "1:02:03".
    public static func formatElapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "x,y,w,h" → rect (CLI).
    public static func parseRect(_ s: String) -> CGRect? {
        let n = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4, n.allSatisfy({ $0 != nil }) else { return nil }
        let v = n.map { $0! }
        guard v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}
