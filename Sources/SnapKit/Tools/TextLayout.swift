import Foundation

/// One recognized text box. `rect` is normalized 0...1 with origin BOTTOM-LEFT (Vision's convention).
public struct TextBox: Equatable {
    public let text: String
    public let rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public enum TextLayout {
    /// Fraction of the shorter box height that must overlap vertically to count as the same line.
    private static let overlapRatio = 0.5
    /// Vertical gap, in median line heights, that starts a new paragraph.
    private static let paragraphGap = 1.5

    public static func join(_ boxes: [TextBox]) -> String {
        let items: [(text: String, rect: CGRect)] = boxes.compactMap {
            let t = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : (t, $0.rect.standardized)
        }
        guard !items.isEmpty else { return "" }

        // Origin is bottom-left, so reading order is descending y.
        let sorted = items.sorted {
            $0.rect.midY != $1.rect.midY ? $0.rect.midY > $1.rect.midY : $0.rect.minX < $1.rect.minX
        }

        var lines: [[(text: String, rect: CGRect)]] = []
        for item in sorted {
            if var last = lines.last, last.contains(where: { sameLine($0.rect, item.rect) }) {
                last.append(item)
                lines[lines.count - 1] = last
            } else {
                lines.append([item])
            }
        }

        let heights = lines.map { line in
            line.map(\.rect.maxY).max()! - line.map(\.rect.minY).min()!
        }
        let median = heights.sorted()[heights.count / 2]

        var out = ""
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let above = lines[i - 1].map(\.rect.minY).min()!
                let gap = above - line.map(\.rect.maxY).max()!
                out += (median > 0 && gap > paragraphGap * median) ? "\n\n" : "\n"
            }
            out += line.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
        }
        return out
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let shorter = min(a.height, b.height)
        if shorter <= 0 { return overlap >= 0 }
        if overlap > overlapRatio * shorter { return true }
        if a.midY >= b.minY && a.midY <= b.maxY { return true }
        if b.midY >= a.minY && b.midY <= a.maxY { return true }
        return false
    }
}
