import CoreGraphics
import Foundation

/// Takes something out of a picture: the area is filled from the pixels just
/// around it, each side pulling harder the nearer it is. It works well on
/// plain or smoothly changing backgrounds (a button's label, a stray icon,
/// a name on a page); it can't invent a face or a pattern that isn't there.
enum ObjectEraser {
    /// How many pixels beside the area are looked at on each side.
    static let band = 3

    static func erase(_ area: CGRect, in ctx: CGContext, contentSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: contentSize)
        let region = area.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1, let current = ctx.makeImage() else { return }
        let (w, h) = (Int(region.width), Int(region.height))
        // From the top of the picture (what CGImage.cropping counts from).
        let left = Int(region.minX), top = Int(contentSize.height - region.maxY)
        let total = (width: Int(contentSize.width), height: Int(contentSize.height))

        // The area with its surroundings, as plain bytes (row 0 is the top).
        let x0 = max(left - band, 0), y0 = max(top - band, 0)
        let x1 = min(left + w + band, total.width), y1 = min(top + h + band, total.height)
        let (cw, ch) = (x1 - x0, y1 - y0)
        guard let piece = current.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)) else { return }
        var bytes = [UInt8](repeating: 0, count: cw * ch * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let canvas = CGContext(
                data: buffer.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            canvas.draw(piece, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            return true
        }
        guard drawn else { return }

        func pixel(_ x: Int, _ y: Int) -> [Double] {
            let at = (y * cw + x) * 4
            return [Double(bytes[at]), Double(bytes[at + 1]), Double(bytes[at + 2]), Double(bytes[at + 3])]
        }
        /// The average of up to `band` pixels from (x, y) going `step` each time.
        func strip(_ x: Int, _ y: Int, dx: Int, dy: Int) -> [Double] {
            var sum = [0.0, 0.0, 0.0, 0.0]
            for index in 0..<band {
                let p = pixel(x + dx * index, y + dy * index)
                for channel in 0..<4 { sum[channel] += p[channel] }
            }
            return sum.map { $0 / Double(band) }
        }
        let hasLeft = left - x0 >= band, hasRight = x1 - (left + w) >= band
        let hasTop = top - y0 >= band, hasBottom = y1 - (top + h) >= band
        guard hasLeft || hasRight || hasTop || hasBottom else { return }

        var filled = [UInt8](repeating: 0, count: w * h * 4)
        let ox = left - x0, oy = top - y0  // the area's corner inside the piece
        for row in 0..<h {
            let leftColor = hasLeft ? strip(ox - 1, oy + row, dx: -1, dy: 0) : nil
            let rightColor = hasRight ? strip(ox + w, oy + row, dx: 1, dy: 0) : nil
            for column in 0..<w {
                let topColor = hasTop ? strip(ox + column, oy - 1, dx: 0, dy: -1) : nil
                let bottomColor = hasBottom ? strip(ox + column, oy + h, dx: 0, dy: 1) : nil
                var sum = [0.0, 0.0, 0.0, 0.0], weights = 0.0
                func add(_ color: [Double]?, distance: Int) {
                    guard let color else { return }
                    let weight = 1 / Double(distance * distance)
                    weights += weight
                    for channel in 0..<4 { sum[channel] += color[channel] * weight }
                }
                add(leftColor, distance: column + 1)
                add(rightColor, distance: w - column)
                add(topColor, distance: row + 1)
                add(bottomColor, distance: h - row)
                let at = (row * w + column) * 4
                for channel in 0..<4 { filled[at + channel] = UInt8(min(max((sum[channel] / weights).rounded(), 0), 255)) }
            }
        }

        let result: CGImage? = filled.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let result else { return }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(result, in: region)
        ctx.restoreGState()
    }
}
