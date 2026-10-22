import AVFoundation
import AppKit
import ImageIO
import SnapKit
import UniformTypeIdentifiers

/// MP4 → looping GIF with ImageIO only (no ffmpeg). Identical consecutive frames are merged into one longer frame.
enum GIFEncoder {
    struct Info { let width: Int; let height: Int; let frames: Int }

    static func convert(_ movie: URL, to out: URL, fps: Int = 15, maxWidth: Int = 960) async throws -> Info {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordError(message: "The recording has no video")
        }
        let natural = try await track.load(.naturalSize)
        let size = RecordMath.gifSize(pixelWidth: Int(natural.width), pixelHeight: Int(natural.height), maxWidth: maxWidth)
        let plan = RecordMath.gifFrames(duration: duration, fps: max(1, fps))
        guard !plan.isEmpty else { throw RecordError(message: "The recording is empty") }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size.width, height: size.height)
        let tol = CMTime(seconds: 0.5 / Double(max(1, fps)), preferredTimescale: 60_000)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        try? FileManager.default.removeItem(at: out)
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else {
            throw RecordError(message: "Could not create the GIF file")
        }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        var pending: (image: CGImage, bytes: Data?, cs: Int)?
        var written = 0
        func flush() {
            guard let p = pending else { return }
            let d = Double(p.cs) / 100
            CGImageDestinationAddImage(dst, p.image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: d, kCGImagePropertyGIFUnclampedDelayTime: d,
            ]] as CFDictionary)
            written += 1
        }
        for f in plan {
            let time = CMTime(seconds: f.time, preferredTimescale: 60_000)
            let img: CGImage
            do { img = try await gen.image(at: time).image } catch {
                // A frame that can't be decoded just extends the previous one.
                if pending != nil { pending!.cs += f.delayCS }
                continue
            }
            let bytes = img.dataProvider?.data as Data?
            if let p = pending, let b = bytes, p.bytes == b, p.image.width == img.width {
                pending!.cs += f.delayCS
                continue
            }
            flush()
            pending = (img, bytes, f.delayCS)
        }
        flush()
        guard written > 0, CGImageDestinationFinalize(dst) else {
            try? FileManager.default.removeItem(at: out)
            throw RecordError(message: "Could not write the GIF")
        }
        return Info(width: size.width, height: size.height, frames: written)
    }
}
