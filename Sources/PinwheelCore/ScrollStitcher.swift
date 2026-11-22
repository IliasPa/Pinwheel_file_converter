import CoreGraphics
import Foundation

/// Joins pictures of a scrolling area into one tall picture.
///
/// Feed it a picture of the same area each time it may have moved (the user
/// scrolls down). It finds how far the content moved since the last picture
/// it kept, keeps only the new rows, and ignores pictures where nothing
/// moved, where the match isn't clear (a blank page), or where the content
/// jumped too far to follow. A bar that stays put while the rest scrolls (a
/// website's header or footer) is kept once, not repeated.
public struct ScrollStitcher: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case started
        /// New rows were added: how many.
        case added(Int)
        /// Nothing moved.
        case unchanged
        /// It moved, but the pictures can't be matched (too far, or a blank area).
        case lost
        /// The picture is too tall to go on.
        case full
    }

    /// The tallest result (pictures this tall are about the limit of the drawing system).
    public static let maxHeight = 30_000
    /// Columns are averaged into this many blocks to compare rows quickly.
    static let blocks = 16

    private var width = 0
    private var height = 0
    private var first: CGImage?
    private var strips: [CGImage] = []
    private var last: CGImage?
    private var lastSignature: [Float] = []
    private var lastRowTexture: [Bool] = []
    /// Rows at the top and bottom that never move (set by the first scroll).
    private var fixedTop = 0
    private var fixedBottom = 0
    private var bandsKnown = false
    private var addedRows = 0

    public init() {}

    public var frameCount: Int { (first == nil ? 0 : 1) + strips.count }
    /// How tall the result is now.
    public var resultHeight: Int { first == nil ? 0 : height + addedRows }

    // MARK: - Adding pictures

    @discardableResult
    public mutating func add(_ frame: CGImage) -> Outcome {
        guard let current = Signature(frame) else { return .lost }
        guard let first, let previous = last else {
            (width, height) = (frame.width, frame.height)
            self.first = frame
            last = frame
            lastSignature = current.values
            lastRowTexture = current.texture
            return .started
        }
        _ = first
        guard frame.width == width, frame.height == height else { return .lost }
        if resultHeight >= Self.maxHeight { return .full }

        let rows = height, blocks = Self.blocks
        // Rows that are the same in both pictures, from the top and the bottom.
        let same = (0..<rows).map { rowDifference(lastSignature, current.values, $0, $0) < 0.8 }
        if same.allSatisfy({ $0 }) { return .unchanged }

        var top = fixedTop, bottom = fixedBottom
        if !bandsKnown {
            top = run(same, from: 0, step: 1)
            bottom = run(same, from: rows - 1, step: -1)
            // A band counts only if it has something in it: a blank margin that
            // happens to look the same twice is just page.
            if !(0..<top).contains(where: { lastRowTexture[$0] }) { top = 0 }
            if !((rows - bottom)..<rows).contains(where: { lastRowTexture[$0] }) { bottom = 0 }
            let limit = rows / 3
            top = top < 6 ? 0 : min(top, limit)
            bottom = bottom < 6 ? 0 : min(bottom, limit)
        }

        let usable = rows - top - bottom
        let minOverlap = max(usable / 8, 24)
        guard usable > minOverlap * 2 else { return .lost }
        let maxShift = usable - minOverlap
        // A quick look at every shift (every 8th row), then a careful one at the best few.
        var rough = [Float](repeating: .infinity, count: maxShift + 1)
        for shift in 1...maxShift {
            rough[shift] = shiftError(shift, previous: lastSignature, current: current.values, top: top, bottom: bottom, rows: rows, blocks: blocks, stride: 8)
        }
        let candidates = (1...maxShift).sorted { rough[$0] < rough[$1] }.prefix(8)
        var best = 0
        var bestError = Float.infinity
        for candidate in candidates {
            for shift in max(candidate - 1, 1)...min(candidate + 1, maxShift) {
                let error = shiftError(shift, previous: lastSignature, current: current.values, top: top, bottom: bottom, rows: rows, blocks: blocks, stride: 2)
                if error < bestError { (best, bestError) = (shift, error) }
            }
        }
        let sorted = rough[1...].sorted()
        let median = sorted[sorted.count / 2]
        // A clear match: close, and much closer than the typical wrong shift.
        guard best > 0, bestError < 6, median - bestError > 4 else {
            return same.filter({ $0 }).count > rows * 9 / 10 ? .unchanged : .lost
        }

        if !bandsKnown {
            (fixedTop, fixedBottom, bandsKnown) = (top, bottom, true)
        }
        let newRows = CGRect(x: 0, y: height - fixedBottom - best, width: width, height: best)
        guard let strip = frame.cropping(to: newRows) else { return .lost }
        strips.append(strip)
        addedRows += best
        _ = previous
        last = frame
        lastSignature = current.values
        lastRowTexture = current.texture
        return .added(best)
    }

    /// How many rows in a row are `true`, from a row going `step`.
    private func run(_ flags: [Bool], from start: Int, step: Int) -> Int {
        var count = 0, index = start
        while index >= 0, index < flags.count, flags[index] { count += 1; index += step }
        return count
    }

    private func rowDifference(_ a: [Float], _ b: [Float], _ rowA: Int, _ rowB: Int) -> Float {
        let blocks = Self.blocks
        var sum: Float = 0
        for block in 0..<blocks { sum += abs(a[rowA * blocks + block] - b[rowB * blocks + block]) }
        return sum / Float(blocks)
    }

    /// The average difference (0...255) when the new picture's rows sit `shift`
    /// rows higher than the previous picture's.
    private func shiftError(_ shift: Int, previous: [Float], current: [Float], top: Int, bottom: Int, rows: Int, blocks: Int, stride: Int) -> Float {
        var sum: Float = 0, count: Float = 0
        // New row r is the previous picture's row r + shift.
        var row = top
        let end = rows - bottom - shift
        previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { now in
                while row < end {
                    let a = row * blocks, b = (row + shift) * blocks
                    for block in 0..<blocks { sum += abs(now[a + block] - prev[b + block]) }
                    count += Float(blocks)
                    row += stride
                }
            }
        }
        return count > 0 ? sum / count : .infinity
    }

    // MARK: - The result

    /// The joined picture (nil before the first picture).
    public func result() -> CGImage? {
        guard let first else { return nil }
        let footer = fixedBottom
        let total = height + addedRows
        guard let ctx = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        var used = 0
        func place(_ piece: CGImage) {
            used += piece.height
            ctx.draw(piece, in: CGRect(x: 0, y: total - used, width: width, height: piece.height))
        }
        let body = strips.isEmpty ? first : (first.cropping(to: CGRect(x: 0, y: 0, width: width, height: height - footer)) ?? first)
        place(body)
        for strip in strips { place(strip) }
        if !strips.isEmpty, footer > 0, let last, let band = last.cropping(to: CGRect(x: 0, y: height - footer, width: width, height: footer)) {
            place(band)
        }
        return ctx.makeImage()
    }

    // MARK: - Row signatures

    /// Each row as the average brightness of `blocks` slices of it.
    private struct Signature {
        let values: [Float]
        /// Rows with something in them (not one flat color).
        let texture: [Bool]

        init?(_ image: CGImage) {
            let (w, h, blocks) = (image.width, image.height, ScrollStitcher.blocks)
            guard w >= blocks, h > 0 else { return nil }
            var pixels = [UInt8](repeating: 0, count: w * h)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            var values = [Float](repeating: 0, count: h * blocks)
            var texture = [Bool](repeating: false, count: h)
            let span = w / blocks
            for row in 0..<h {
                var low: Float = 255, high: Float = 0
                for block in 0..<blocks {
                    var sum = 0
                    let start = row * w + block * span
                    for column in stride(from: 0, to: span, by: 2) { sum += Int(pixels[start + column]) }
                    let value = Float(sum) / Float((span + 1) / 2)
                    values[row * blocks + block] = value
                    low = min(low, value); high = max(high, value)
                }
                texture[row] = high - low > 6
            }
            self.values = values
            self.texture = texture
        }
    }
}
