import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// PDF pages as slides that can be edited: the page as it looks, with its
/// words and pictures painted over in the color around them; the pictures
/// set on it, each to be moved; and the words in text boxes, in their font,
/// size, color and spacing. A scanned or turned page stays a picture.
enum PDFSlides {
    static func slides(_ url: URL, progress: @escaping @Sendable (Double) -> Void) throws -> [SlideDeck.Slide] {
        let pdf = try PDFConverter.open(url)
        var slides: [SlideDeck.Slide] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index), let pageRef = page.pageRef else { continue }
            let lines = PDFStructure.joiningPieces(PDFStructure.lines(of: page, index: index))
            let box = pageRef.getBoxRect(.cropBox)
            let pictures = lines.isEmpty || page.rotation != 0 ? [] : PDFPictures.find(on: pageRef)
            if lines.isEmpty || page.rotation != 0 {
                if let picture = PDFStructure.pagePicture(pageRef) {
                    slides.append(SlideDeck.Slide(data: picture.data, isJPEG: true, size: picture.size))
                }
            } else if let background = background(pageRef, box: box, covering: lines.map(\.frame) + pictures.map(\.frame)) {
                // From the page's bottom left (as PDFs place things) to the slide's top left.
                func topLeft(_ rect: CGRect) -> CGRect {
                    CGRect(x: rect.minX - box.minX, y: box.maxY - rect.maxY, width: rect.width, height: rect.height)
                }
                slides.append(SlideDeck.Slide(
                    data: background, isJPEG: true, size: box.size,
                    pictures: pictures.map { SlideDeck.Placed(data: $0.picture.data, isJPEG: true, frame: topLeft($0.frame)) },
                    texts: textBoxes(lines).map { box in
                        var placed = box
                        placed.frame = topLeft(box.frame)
                        return placed
                    }
                ))
            }
            progress(Double(index + 1) / Double(max(pdf.pageCount, 1)))
        }
        guard !slides.isEmpty else { throw NothingToDo(reason: "There are no pages to make slides of.") }
        return slides
    }

    // MARK: - The page underneath

    /// The page as a JPEG with each of `rects` painted over in the color
    /// around it (the middle of what borders it), so the words and pictures
    /// set on top aren't there twice.
    static func background(_ page: CGPDFPage, box: CGRect, covering rects: [CGRect], dpi: CGFloat = 150) -> Data? {
        let scale = dpi / 72
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard width > 0, height > 0, width * height < 60_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        for rect in rects {
            let area = rect.insetBy(dx: -1.5, dy: -1.5)
            ctx.setFillColor(surrounding(area, pixels: pixels, width: width, height: height, box: box, scale: scale))
            ctx.fill(area)
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The middle color of the pixels just outside `area` (each channel's
    /// median), so a box over words on a colored band gets the band's color.
    private static func surrounding(_ area: CGRect, pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, box: CGRect, scale: CGFloat) -> CGColor {
        let left = Int(((area.minX - box.minX) * scale).rounded(.down)) - 2, right = Int(((area.maxX - box.minX) * scale).rounded(.up)) + 1
        let bottom = Int(((area.minY - box.minY) * scale).rounded(.down)) - 2, top = Int(((area.maxY - box.minY) * scale).rounded(.up)) + 1
        var samples: [[Int]] = [[], [], []]
        func sample(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let pixel = pixels + ((height - 1 - y) * width + x) * 4  // memory starts at the top row
            for channel in 0..<3 { samples[channel].append(Int(pixel[channel])) }
        }
        let stepX = max(1, (right - left) / 60), stepY = max(1, (top - bottom) / 30)
        for x in stride(from: left, through: right, by: stepX) {
            sample(x, bottom)
            sample(x, top)
        }
        for y in stride(from: bottom, through: top, by: stepY) {
            sample(left, y)
            sample(right, y)
        }
        guard !samples[0].isEmpty else { return CGColor(gray: 1, alpha: 1) }
        let median = samples.map { channel in CGFloat(channel.sorted()[channel.count / 2]) / 255 }
        return CGColor(srgbRed: median[0], green: median[1], blue: median[2], alpha: 1)
    }

    // MARK: - Text boxes

    /// The page's lines, grouped into blocks: lines one under the other, in
    /// the same font and size, starting (or centered, or ending) together.
    static func textBoxes(_ lines: [PDFStructure.Line]) -> [SlideDeck.TextBox] {
        var groups: [[PDFStructure.Line]] = []
        for line in lines.sorted(by: { $0.frame.maxY > $1.frame.maxY }) {
            let joins = groups.lastIndex { group in
                guard let last = group.last else { return false }
                let lined = abs(last.frame.minX - line.frame.minX) < max(line.size, 4) * 1.5
                    || abs(last.frame.midX - line.frame.midX) < 3 || abs(last.frame.maxX - line.frame.maxX) < 3
                return lined && abs(last.size - line.size) <= 1 && last.font == line.font && PDFStructure.sameBlock(last, line, gapFactor: 0.8)
            }
            if let joins { groups[joins].append(line) } else { groups.append([line]) }
        }
        return groups.map { group in
            var frame = group.dropFirst().reduce(group[0].frame) { $0.union($1.frame) }
            // Room to spare: another app's letters can be a little wider, and
            // a line that doesn't fit would break in two.
            let room = max(8, frame.width * 0.15)
            let alignment = alignment(of: group)
            frame.size.width += room
            if alignment == "r" { frame.origin.x -= room } else if alignment == "ctr" { frame.origin.x -= room / 2 }
            var sizes: [CGFloat: Int] = [:]
            for line in group { sizes[line.size, default: 0] += line.text.count }
            let spacing = group.count > 1
                ? Double(zip(group, group.dropFirst()).map { $0.frame.midY - $1.frame.midY }.reduce(0, +)) / Double(group.count - 1)
                : nil
            return SlideDeck.TextBox(
                frame: frame,
                lines: group.map { SlideDeck.TextBox.Line(runs: $0.runs, bold: $0.bold) },
                size: Double(sizes.max { $0.value < $1.value }?.key ?? 12),
                font: group[0].font,
                lineSpacing: spacing,
                alignment: alignment
            )
        }
    }

    /// Centered or right-aligned when every line is, and they don't all start together.
    static func alignment(of group: [PDFStructure.Line]) -> String {
        guard group.count > 1 else { return "l" }
        let starts = group.map(\.frame.minX), middles = group.map(\.frame.midX), ends = group.map(\.frame.maxX)
        func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
        if spread(starts) <= 3 { return "l" }
        if spread(middles) <= 4 { return "ctr" }
        if spread(ends) <= 3 { return "r" }
        return "l"
    }
}
