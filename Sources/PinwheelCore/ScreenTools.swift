import CoreGraphics
import Foundation

/// How readable one color is on another, by the WCAG rule (the one web
/// accessibility checks use): a ratio from 1:1 (invisible) to 21:1 (black on white).
public struct ContrastCheck: Sendable, Equatable {
    public let ratio: Double

    public init(_ foreground: MarkupColor, on background: MarkupColor) {
        let a = Self.luminance(foreground), b = Self.luminance(background)
        ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 0 (black) … 1 (white), as the eye sees it.
    static func luminance(_ color: MarkupColor) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    public var isAA: Bool { ratio >= 4.5 }
    public var isAAA: Bool { ratio >= 7 }
    /// Big text (18 pt, or 14 pt bold) and icons or borders need less.
    public var isAALarge: Bool { ratio >= 3 }

    /// "4.8 : 1"
    public var ratioText: String { String(format: "%.1f : 1", (ratio * 10).rounded(.down) / 10) }

    /// What it means for text, in plain words.
    public var verdict: String {
        if isAAA { return "Excellent: passes AAA for all text." }
        if isAA { return "Good: passes AA for normal text." }
        if isAALarge { return "Only big text (or icons and borders) passes. Small text is hard to read." }
        return "Fails: this text would be hard to read."
    }
}

/// Where the edges are in a picture, to make a ruler stop at them.
public struct EdgeMap: Sendable {
    public let width: Int
    public let height: Int
    private let luma: [UInt8]

    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        (self.width, self.height, luma) = (width, height, pixels)
    }

    /// How different a pixel must be from the last to count as an edge.
    static let jump = 18

    private func value(_ x: Int, _ y: Int) -> Int { Int(luma[y * width + x]) }

    /// The space around (x, y) before the nearest edges, going left and right
    /// or up and down: the boundary positions (between pixels) on each side.
    public func span(x: Int, y: Int, horizontal: Bool) -> (start: Int, end: Int) {
        let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
        let reference = value(x, y)
        func walk(_ step: Int) -> Int {
            var (cx, cy) = (x, y)
            while true {
                let (nx, ny) = horizontal ? (cx + step, cy) : (cx, cy + step)
                guard nx >= 0, nx < width, ny >= 0, ny < height else { return horizontal ? cx : cy }
                let next = value(nx, ny)
                if abs(next - value(cx, cy)) > Self.jump || abs(next - reference) > Self.jump * 3 {
                    return horizontal ? cx : cy
                }
                (cx, cy) = (nx, ny)
            }
        }
        let low = walk(-1), high = walk(1)
        return (low, high + 1)
    }

    /// The edge closest to `position` along a horizontal line (at row `line`)
    /// or a vertical one, within `radius` pixels; the position itself if none.
    public func snap(_ position: Int, line: Int, horizontal: Bool, radius: Int) -> Int {
        let line = min(max(line, 0), (horizontal ? height : width) - 1)
        let limit = horizontal ? width : height
        func sample(_ index: Int) -> Int { horizontal ? value(index, line) : value(line, index) }
        for distance in 0...max(radius, 0) {
            for candidate in [position - distance, position + distance] where candidate >= 1 && candidate < limit {
                if abs(sample(candidate) - sample(candidate - 1)) > Self.jump { return candidate }
            }
        }
        return position
    }

    /// The color of one pixel as a hex code, for the zoom's read-out.
    public func gray(x: Int, y: Int) -> Int { value(min(max(x, 0), width - 1), min(max(y, 0), height - 1)) }
}
