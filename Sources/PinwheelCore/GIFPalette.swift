import CoreGraphics
import Foundation

/// GIF holds 256 colors, and macOS's encoder picks them without dithering:
/// smooth shading turns into bands. Here the 255 colors that suit the
/// picture best are chosen (median cut, then refined), and Floyd–Steinberg
/// dithering mixes neighboring ones so shading stays smooth. See-through
/// parts become GIF's one see-through color.
enum GIFPalette {
    struct Color: Equatable {
        var red: Int32, green: Int32, blue: Int32
    }

    /// The picture in at most 255 colors (and see-through), dithered; nil
    /// when it can't be drawn.
    static func dithered(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let pixels = rgba(image) else { return nil }
        defer { pixels.deallocate() }
        let palette = choose(pixels: pixels, count: width * height)
        dither(pixels, width: width, height: height, palette: palette)
        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// RGBA, 8 bits each, not premultiplied: see-through pixels (less than
    /// half covered) have alpha 0, the rest 255.
    private static func rgba(_ image: CGImage) -> UnsafeMutablePointer<UInt8>? {
        let count = image.width * image.height
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 4)
        guard let ctx = CGContext(
            data: pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            pixels.deallocate()
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for index in 0..<count {
            let pixel = pixels + index * 4
            let alpha = Int(pixel[3])
            if alpha < 128 {
                pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; pixel[3] = 0
            } else if alpha < 255 {
                for channel in 0..<3 { pixel[channel] = UInt8(min(255, Int(pixel[channel]) * 255 / alpha)) }
                pixel[3] = 255
            }
        }
        return pixels
    }

    // MARK: - Choosing the colors

    /// The picture's colors counted in a 32 × 32 × 32 grid, split into up
    /// to 255 boxes (always the one with the most pixels times its widest
    /// side, at its median), then refined twice: each box's color moves to
    /// the middle of the colors nearest to it.
    static func choose(pixels: UnsafePointer<UInt8>, count: Int, colors: Int = 255) -> [Color] {
        var counts = [Int](repeating: 0, count: 32_768)
        var sums = [Int](repeating: 0, count: 32_768 * 3)
        for index in 0..<count {
            let pixel = pixels + index * 4
            guard pixel[3] != 0 else { continue }
            let bin = Int(pixel[0] >> 3) << 10 | Int(pixel[1] >> 3) << 5 | Int(pixel[2] >> 3)
            counts[bin] += 1
            sums[bin * 3] += Int(pixel[0]); sums[bin * 3 + 1] += Int(pixel[1]); sums[bin * 3 + 2] += Int(pixel[2])
        }
        let used = (0..<32_768).filter { counts[$0] > 0 }
        guard !used.isEmpty else { return [Color(red: 0, green: 0, blue: 0)] }
        func mean(_ bin: Int) -> Color {
            let n = counts[bin]
            return Color(red: Int32(sums[bin * 3] / n), green: Int32(sums[bin * 3 + 1] / n), blue: Int32(sums[bin * 3 + 2] / n))
        }
        func coordinate(_ bin: Int, _ axis: Int) -> Int { (bin >> (10 - axis * 5)) & 31 }

        var boxes: [[Int]] = [used]
        func score(_ box: [Int]) -> (Int, Int) {  // (weight, widest axis)
            guard box.count > 1 else { return (0, 0) }
            var widest = 0, axis = 0
            for candidate in 0..<3 {
                let values = box.map { coordinate($0, candidate) }
                let range = (values.max() ?? 0) - (values.min() ?? 0)
                if range > widest { widest = range; axis = candidate }
            }
            return (box.reduce(0) { $0 + counts[$1] } * widest, axis)
        }
        var scores = [score(used)]
        while boxes.count < colors {
            guard let pick = scores.indices.max(by: { scores[$0].0 < scores[$1].0 }), scores[pick].0 > 0 else { break }
            let axis = scores[pick].1
            let sorted = boxes[pick].sorted { coordinate($0, axis) < coordinate($1, axis) }
            let total = sorted.reduce(0) { $0 + counts[$1] }
            var running = 0, cut = 1
            for (offset, bin) in sorted.enumerated() {
                running += counts[bin]
                if running * 2 >= total { cut = max(1, min(sorted.count - 1, offset + 1)); break }
            }
            let low = Array(sorted[..<cut]), high = Array(sorted[cut...])
            boxes[pick] = low
            scores[pick] = score(low)
            boxes.append(high)
            scores.append(score(high))
        }

        var palette = boxes.map { box -> Color in
            let n = box.reduce(0) { $0 + counts[$1] }
            let red = box.reduce(0) { $0 + sums[$1 * 3] }, green = box.reduce(0) { $0 + sums[$1 * 3 + 1] }
            let blue = box.reduce(0) { $0 + sums[$1 * 3 + 2] }
            return Color(red: Int32(red / n), green: Int32(green / n), blue: Int32(blue / n))
        }
        let means = used.map(mean)
        for _ in 0..<2 {
            var totals = [(Int, Int, Int, Int)](repeating: (0, 0, 0, 0), count: palette.count)
            for (offset, bin) in used.enumerated() {
                let nearest = nearestIndex(to: means[offset], in: palette)
                let n = counts[bin]
                totals[nearest].0 += n
                totals[nearest].1 += sums[bin * 3]; totals[nearest].2 += sums[bin * 3 + 1]; totals[nearest].3 += sums[bin * 3 + 2]
            }
            for index in palette.indices where totals[index].0 > 0 {
                let n = totals[index].0
                palette[index] = Color(red: Int32(totals[index].1 / n), green: Int32(totals[index].2 / n), blue: Int32(totals[index].3 / n))
            }
        }
        return palette
    }

    /// Nearest by distance weighted for the eye (green counts most).
    static func nearestIndex(to color: Color, in palette: [Color]) -> Int {
        var best = 0, bestDistance = Int32.max
        for (index, candidate) in palette.enumerated() {
            let red = color.red - candidate.red, green = color.green - candidate.green, blue = color.blue - candidate.blue
            let distance = 3 * red * red + 4 * green * green + 2 * blue * blue
            if distance < bestDistance {
                bestDistance = distance
                best = index
                if distance == 0 { break }
            }
        }
        return best
    }

    // MARK: - Dithering

    /// Floyd–Steinberg, a row left to right and the next right to left, so
    /// the leftover error doesn't drift one way. Nearest colors are
    /// remembered per 6-bit color, so each is looked for once.
    private static func dither(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, palette: [Color]) {
        var cache = [Int16](repeating: -1, count: 262_144)
        // Errors (in sixteenths) for this row and the next, 3 channels each,
        // with a pixel of room at both ends.
        let stride = (width + 2) * 3
        let rows = UnsafeMutablePointer<Int32>.allocate(capacity: stride * 2)
        rows.initialize(repeating: 0, count: stride * 2)
        defer { rows.deallocate() }
        var current = rows, next = rows + stride
        for y in 0..<height {
            let forward = y % 2 == 0
            next.update(repeating: 0, count: stride)
            for step in 0..<width {
                let x = forward ? step : width - 1 - step
                let pixel = pixels + (y * width + x) * 4
                guard pixel[3] != 0 else { continue }  // see-through: nothing to carry
                let slot = (x + 1) * 3
                let red = min(255, max(0, Int32(pixel[0]) + current[slot] / 16))
                let green = min(255, max(0, Int32(pixel[1]) + current[slot + 1] / 16))
                let blue = min(255, max(0, Int32(pixel[2]) + current[slot + 2] / 16))
                let key = Int(red >> 2) << 12 | Int(green >> 2) << 6 | Int(blue >> 2)
                var chosen = Int(cache[key])
                if chosen < 0 {
                    chosen = nearestIndex(to: Color(red: red, green: green, blue: blue), in: palette)
                    cache[key] = Int16(chosen)
                }
                let color = palette[chosen]
                pixel[0] = UInt8(color.red); pixel[1] = UInt8(color.green); pixel[2] = UInt8(color.blue)
                // 7/16 ahead, 3/16 behind below, 5/16 below, 1/16 ahead below.
                let ahead = forward ? slot + 3 : slot - 3, behind = forward ? slot - 3 : slot + 3
                let errorRed = red - color.red, errorGreen = green - color.green, errorBlue = blue - color.blue
                current[ahead] += errorRed * 7; current[ahead + 1] += errorGreen * 7; current[ahead + 2] += errorBlue * 7
                next[behind] += errorRed * 3; next[behind + 1] += errorGreen * 3; next[behind + 2] += errorBlue * 3
                next[slot] += errorRed * 5; next[slot + 1] += errorGreen * 5; next[slot + 2] += errorBlue * 5
                next[ahead] += errorRed; next[ahead + 1] += errorGreen; next[ahead + 2] += errorBlue
            }
            swap(&current, &next)
        }
    }
}
