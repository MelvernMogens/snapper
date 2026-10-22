import Foundation

/// 8-bit grayscale image, row-major, row 0 = TOP.
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func row(_ y: Int) -> ArraySlice<UInt8> {
        let start = y * width
        return pixels[start ..< start + width]
    }
}

/// One contiguous run of source rows copied from one frame into the stitched output.
public struct StitchSlice: Equatable {
    public let frame: Int
    public let rows: Range<Int>

    public init(frame: Int, rows: Range<Int>) {
        self.frame = frame
        self.rows = rows
    }
}

public enum Stitcher {
    // MARK: - Tuning

    /// Columns kept in the horizontally reduced working copy. Rows are never reduced:
    /// the offset has to stay pixel-exact vertically.
    private static let workColumns = 32
    /// Coarse horizontal bins per row used by the candidate scan.
    private static let binCount = 4
    /// Upper bound on probe rows (one per stratum of the search band).
    private static let maxProbes = 64
    /// Candidate offsets taken from the coarse scan into the dense verification.
    private static let candidateCount = 6
    /// Per-pixel mean absolute difference still considered "the same content".
    private static let acceptMeanDiff = 3.5
    /// Per-pixel mean absolute difference considered "no movement at all".
    private static let identicalMeanDiff = 1.0
    /// Per-pixel mean absolute difference for a row that did not change.
    private static let rowMatchTolerance = 2
    /// Probe rows that must fall inside the verified band before an offset is trusted.
    private static let minProbesInBand = 8

    // MARK: - Offset search

    public static func findOffset(prev: GrayImage, next: GrayImage) -> Int? {
        let w = prev.width, h = prev.height
        guard w > 0, h > 0, next.width == w, next.height == h,
              prev.pixels.count == w * h, next.pixels.count == w * h else { return nil }

        return prev.pixels.withUnsafeBufferPointer { pb -> Int? in
            next.pixels.withUnsafeBufferPointer { nb -> Int? in
                guard let p = pb.baseAddress, let n = nb.baseAddress else { return nil }
                guard h >= 24 else { return meanDiff(p, n, count: w * h) <= identicalMeanDiff ? 0 : nil }
                return search(p, n, w, h)
            }
        }
    }

    private static func search(_ p: UnsafePointer<UInt8>, _ n: UnsafePointer<UInt8>, _ w: Int, _ h: Int) -> Int? {
        // Band excluding the regions where sticky headers / footers usually live.
        let bandLo = max(1, h * 15 / 100)
        let bandHi = h - h * 8 / 100
        guard bandHi - bandLo >= 16 else { return meanDiff(p, n, count: w * h) <= identicalMeanDiff ? 0 : nil }

        let cols = max(1, min(workColumns, w))
        let bins = max(1, min(binCount, cols))

        // One horizontally reduced copy per frame, plus coarse bin sums per row.
        let miniP = UnsafeMutablePointer<UInt8>.allocate(capacity: h * cols)
        let miniN = UnsafeMutablePointer<UInt8>.allocate(capacity: h * cols)
        let sigP = UnsafeMutablePointer<Int32>.allocate(capacity: h * bins)
        let sigN = UnsafeMutablePointer<Int32>.allocate(capacity: h * bins)
        defer {
            miniP.deallocate(); miniN.deallocate(); sigP.deallocate(); sigN.deallocate()
        }
        reduce(p, w, h, cols, bins, miniP, sigP)
        reduce(n, w, h, cols, bins, miniN, sigN)

        // Stratified probe rows: textured, unlike their neighbour, spread evenly over the band.
        var horiz = [Int](repeating: 0, count: h)   // x16 fixed point
        var vert = [Int](repeating: 0, count: h)    // x16 fixed point
        for y in bandLo ..< bandHi {
            let r = miniP + y * cols, u = miniP + (y - 1) * cols
            var hs = 0, vs = 0
            var last = Int(r[0])
            vs = abs(last - Int(u[0]))
            for c in 1 ..< cols {
                let v = Int(r[c])
                hs += abs(v - last)
                vs += abs(v - Int(u[c]))
                last = v
            }
            horiz[y] = cols > 1 ? (hs * 16) / (cols - 1) : 0
            vert[y] = (vs * 16) / cols
        }

        var probes = pickProbes(horiz: horiz, vert: vert, lo: bandLo, hi: bandHi, horizFloor: 32, vertFloor: 16)
        if probes.count < minProbesInBand {
            probes = pickProbes(horiz: horiz, vert: vert, lo: bandLo, hi: bandHi, horizFloor: 8, vertFloor: 4)
        }
        let unchanged = { miniMeanDiff(miniP, miniN, cols: cols, height: h) <= identicalMeanDiff }
        if probes.count < minProbesInBand {
            // No texture to match on: only an unchanged frame can be answered honestly.
            return unchanged() ? 0 : nil
        }

        // Coarse pass: bin-signature SAD over the probe rows, every candidate offset.
        let maxD = min(h - 1, max(1, (h * 85) / 100))
        var cand: [(score: Double, d: Int)] = []
        cand.reserveCapacity(maxD)
        var start = 0
        for d in 0 ..< maxD {
            // A probe is usable only when both frames land inside the band: y and y - d.
            while start < probes.count && probes[start] < d + bandLo { start += 1 }
            let used = probes.count - start
            if used < minProbesInBand { break }   // probes ascending: it only gets worse
            var total: Int32 = 0
            for k in start ..< probes.count {
                let a = sigP + probes[k] * bins, b = sigN + (probes[k] - d) * bins
                if bins == 4 {   // unrolled: this loop runs ~h times per call
                    total += abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) + abs(a[3] - b[3])
                } else {
                    for i in 0 ..< bins { total += abs(a[i] - b[i]) }
                }
            }
            cand.append((Double(total) / Double(used), d))
        }
        guard !cand.isEmpty else { return unchanged() ? 0 : nil }

        cand.sort { $0.score < $1.score }
        var tryD = Set<Int>(cand.prefix(candidateCount).map { $0.d })
        for delta in -2 ... 2 {                      // pixel-exact refinement around the winner
            let d = cand[0].d + delta
            if d > 0 && d < maxD { tryD.insert(d) }
        }

        // Dense pass: per-pixel verification over the overlapping part of the band.
        let minRows = max(16, h / 24)
        let rowStep = max(1, (bandHi - bandLo) / 512)
        func dense(_ d: Int, limit: Double) -> Double? {
            let y0 = bandLo + d          // keeps next's own header/footer out of the comparison
            let y1 = max(y0, min(h, bandHi))
            guard y1 - y0 >= minRows else { return nil }
            var rows = 0
            for y in stride(from: y0, to: y1, by: rowStep) { _ = y; rows += 1 }
            let cap = limit.isFinite ? Int(limit * Double(rows * cols)) : Int.max
            var total = 0
            for y in stride(from: y0, to: y1, by: rowStep) {
                let a = miniP + y * cols, b = miniN + (y - d) * cols
                for c in 0 ..< cols { total += abs(Int(a[c]) - Int(b[c])) }
                if total > cap { return nil }
            }
            return Double(total) / Double(rows * cols)
        }

        guard let d0 = dense(0, limit: .infinity) else { return unchanged() ? 0 : nil }
        if d0 <= identicalMeanDiff { return 0 }

        var bestD = 0
        var bestMean = Double.infinity
        for d in tryD.sorted() where d > 0 {
            // Only trust an offset whose verified band actually contains texture.
            var inBand = 0
            for y in probes where y >= bandLo + d && y < bandHi { inBand += 1 }
            guard inBand >= minProbesInBand else { continue }
            if let m = dense(d, limit: min(bestMean, acceptMeanDiff)), m < bestMean {
                bestMean = m
                bestD = d
            }
        }

        if bestD > 0, bestMean <= acceptMeanDiff, d0 > max(bestMean * 1.8, bestMean + 1.5) { return bestD }
        if d0 <= acceptMeanDiff { return 0 }
        return nil
    }

    /// Horizontally reduce one frame to `cols` columns (each the mean of two samples of its bucket)
    /// and accumulate the coarse bin sums used by the candidate scan. Row count is preserved.
    private static func reduce(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ cols: Int, _ bins: Int,
                               _ mini: UnsafeMutablePointer<UInt8>, _ sig: UnsafeMutablePointer<Int32>) {
        let half = max(1, w / (2 * cols))
        for y in 0 ..< h {
            let row = src + y * w
            let out = mini + y * cols
            let sums = sig + y * bins
            for b in 0 ..< bins { sums[b] = 0 }
            for c in 0 ..< cols {
                let x0 = (c * w) / cols
                let x1 = min(w - 1, x0 + half)
                let v = (Int(row[x0]) + Int(row[x1])) >> 1
                out[c] = UInt8(v)
                sums[(c * bins) / cols] += Int32(v)
            }
        }
    }

    private static func pickProbes(horiz: [Int], vert: [Int], lo: Int, hi: Int,
                                   horizFloor: Int, vertFloor: Int) -> [Int] {
        let len = hi - lo
        guard len > 0 else { return [] }
        let strata = min(maxProbes, len)
        var out: [Int] = []
        out.reserveCapacity(strata)
        for s in 0 ..< strata {
            let a = lo + (len * s) / strata
            let b = lo + (len * (s + 1)) / strata
            var bestY = -1, bestScore = 0
            for y in a ..< b {
                guard horiz[y] >= horizFloor, vert[y] >= vertFloor else { continue }
                let score = horiz[y] + 4 * vert[y]
                if score > bestScore { bestScore = score; bestY = y }
            }
            if bestY >= 0 { out.append(bestY) }
        }
        return out
    }

    /// Mean absolute difference of the reduced copies, sampling every 4th row.
    private static func miniMeanDiff(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>,
                                     cols: Int, height: Int) -> Double {
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 4) {
            let ra = a + y * cols, rb = b + y * cols
            for c in 0 ..< cols { total += abs(Int(ra[c]) - Int(rb[c])) }
            count += cols
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    private static func meanDiff(_ p: UnsafePointer<UInt8>, _ n: UnsafePointer<UInt8>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        var total = 0
        for i in 0 ..< count { total += abs(Int(p[i]) - Int(n[i])) }
        return Double(total) / Double(count)
    }

    // MARK: - Sticky bands

    public static func fixedBands(prev: GrayImage, next: GrayImage, offset: Int) -> (top: Int, bottom: Int) {
        let w = prev.width, h = prev.height
        guard w > 0, h > 0, next.width == w, next.height == h,
              prev.pixels.count == w * h, next.pixels.count == w * h, offset > 0 else { return (0, 0) }

        return prev.pixels.withUnsafeBufferPointer { pb in
            next.pixels.withUnsafeBufferPointer { nb -> (top: Int, bottom: Int) in
                guard let p = pb.baseAddress, let n = nb.baseAddress else { return (0, 0) }
                let cap = Int(rowMatchTolerance) * w
                func same(_ y: Int) -> Bool {
                    let a = p + y * w, b = n + y * w
                    var total = 0
                    for x in 0 ..< w {
                        total += abs(Int(a[x]) - Int(b[x]))
                        if total > cap { return false }
                    }
                    return true
                }
                let half = h / 2
                var top = 0
                while top < half, same(top) { top += 1 }
                var bottom = 0
                while bottom < half, same(h - 1 - bottom) { bottom += 1 }
                return (top, bottom)
            }
        }
    }

    // MARK: - Stitch plan

    public static func plan(frameHeight h: Int, offsets: [Int], top: Int, bottom: Int) -> [StitchSlice] {
        guard h > 0 else { return [] }
        let top = max(0, min(top, h))
        let bottom = max(0, min(bottom, h - top))
        let contentEnd = h - bottom

        var out: [StitchSlice] = []
        out.reserveCapacity(offsets.count + 2)
        if contentEnd > 0 { out.append(StitchSlice(frame: 0, rows: 0 ..< contentEnd)) }
        for (i, offset) in offsets.enumerated() {
            guard offset > 0 else { continue }
            let lo = max(top, contentEnd - offset)
            if lo < contentEnd { out.append(StitchSlice(frame: i + 1, rows: lo ..< contentEnd)) }
        }
        if bottom > 0 { out.append(StitchSlice(frame: offsets.count, rows: contentEnd ..< h)) }
        return out
    }
}
