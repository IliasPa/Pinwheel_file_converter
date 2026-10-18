import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds the main subjects of a picture (people, pets, objects) with the same
/// on-device model as "Lift subject from background" in Photos.
public enum SubjectMask {
    /// A gray picture the size of `image`: white on the subjects, black
    /// elsewhere, soft at the edges. nil when there's no clear subject.
    public static func make(for image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        let buffer: CVPixelBuffer? = try VisionTurns.take {
            do {
                try handler.perform([request])
            } catch {
                throw ConversionError.failed("Couldn't look for the subject: \(error.localizedDescription)")
            }
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            return try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        }
        guard let buffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let picture = StudioRenderer.context.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: gray) else {
            throw ConversionError.failed("Not enough memory to cut out the subject.")
        }
        return picture
    }
}

/// Vision can deadlock when several of its requests run at once in one
/// process (each waits for room the others are holding), so Pinwheel's
/// requests take turns. Jobs each have their own worker process anyway;
/// this matters for the editor's preview and for the tests.
enum VisionTurns {
    private static let lock = NSLock()

    static func take<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}

/// For pictures without a subject Vision recognizes (logos, icons, drawings
/// on a plain background): the color along the edges is taken as the
/// background and removed from the edges inwards, plus holes of exactly that
/// color (the inside of an "O").
public enum PlainBackground {
    /// Same as `SubjectMask.make`, smaller than the picture when it's big.
    /// nil when the edges aren't one plain color, or nothing would be left.
    public static func mask(for image: CGImage) -> CGImage? {
        let scale = min(1, 2048 / CGFloat(max(image.width, image.height)))
        let width = max(2, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(2, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let count = width * height

        var border: [Int] = []
        for x in 0..<width { border += [x, (height - 1) * width + x] }
        for y in 1..<(height - 1) { border += [y * width, y * width + width - 1] }

        // The edges' average color, which most of them must be close to.
        var sum = (0.0, 0.0, 0.0, 0.0)
        for index in border {
            let p = index * 4
            sum.0 += Double(pixels[p]); sum.1 += Double(pixels[p + 1]); sum.2 += Double(pixels[p + 2]); sum.3 += Double(pixels[p + 3])
        }
        let n = Double(border.count)
        let background = (sum.0 / n, sum.1 / n, sum.2 / n, sum.3 / n)
        guard background.3 > 200 else { return nil }  // already see-through
        func distance(_ index: Int) -> Double {
            let p = index * 4
            let dr = Double(pixels[p]) - background.0, dg = Double(pixels[p + 1]) - background.1
            let db = Double(pixels[p + 2]) - background.2, da = Double(pixels[p + 3]) - background.3
            return (dr * dr + dg * dg + db * db + da * da).squareRoot()
        }
        let tolerance = 32.0
        let plain = border.filter { distance($0) <= tolerance }.count
        guard Double(plain) >= n * 0.9 else { return nil }

        // Flood in from the edges through anything close to that color.
        var isBackground = [Bool](repeating: false, count: count)
        var queue = border.filter { distance($0) <= tolerance }
        for index in queue { isBackground[index] = true }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width, y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let next = ny * width + nx
                if !isBackground[next] && distance(next) <= tolerance {
                    isBackground[next] = true
                    queue.append(next)
                }
            }
        }
        // Holes of the very same color.
        for index in 0..<count where !isBackground[index] && distance(index) <= 10 {
            isBackground[index] = true
        }
        let removed = isBackground.lazy.filter { $0 }.count
        guard removed > count / 50, removed < count - count / 200 else { return nil }  // nothing to remove, or nothing left

        // Opaque subject; soft where it meets the background (anti-aliased edges).
        var mask = [UInt8](repeating: 255, count: count)
        for index in 0..<count {
            if isBackground[index] {
                mask[index] = 0
                continue
            }
            let x = index % width, y = index / width
            let touches = (x > 0 && isBackground[index - 1]) || (x < width - 1 && isBackground[index + 1])
                || (y > 0 && isBackground[index - width]) || (y < height - 1 && isBackground[index + width])
            if touches {
                mask[index] = UInt8(max(0, min(255, (distance(index) - tolerance * 0.4) / (tolerance * 1.6) * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
