import CoreGraphics

/// Pure coordinate math. Kept out of the app target so it is unit-tested.
public enum Geo {
    /// Rect spanned by two drag points, in whatever space the points are in.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Convert a rect in a bottom-left-origin view (points) into a top-left-origin pixel rect
    /// inside an image of `imageSize` pixels that covers the whole view. Result is integral and clamped.
    public static func pixelRect(viewRect: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let flippedY = viewSize.height - viewRect.maxY
        let r = CGRect(x: viewRect.minX * sx, y: flippedY * sy,
                       width: viewRect.width * sx, height: viewRect.height * sy).integral
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Quartz window bounds (top-left origin of the primary display, points) -> AppKit global
    /// coordinates (bottom-left origin of the primary display).
    public static func quartzToAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Keep a rect inside bounds by moving it (not shrinking) when possible.
    public static func clampMove(_ r: CGRect, into bounds: CGRect) -> CGRect {
        var o = r.origin
        o.x = max(bounds.minX, min(o.x, bounds.maxX - r.width))
        o.y = max(bounds.minY, min(o.y, bounds.maxY - r.height))
        return CGRect(origin: o, size: r.size).intersection(bounds)
    }

    /// Rect resized from one dragged corner/edge handle. `handle` uses x/y in -1...1 (0 = untouched axis).
    public static func resize(_ r: CGRect, handle: (x: Int, y: Int), by d: CGVector, minSize: CGFloat = 4) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if handle.x < 0 { minX += d.dx } else if handle.x > 0 { maxX += d.dx }
        if handle.y < 0 { minY += d.dy } else if handle.y > 0 { maxY += d.dy }
        if maxX - minX < minSize { if handle.x < 0 { minX = maxX - minSize } else { maxX = minX + minSize } }
        if maxY - minY < minSize { if handle.y < 0 { minY = maxY - minSize } else { maxY = minY + minSize } }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
