import CoreGraphics
import Foundation
import PDFKit
import Quartz

/// PDF conversions with PDFKit.
enum PDFConverter {
    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// One image per page. A one-page PDF becomes a single image; a longer
    /// one becomes a folder of images. Returns the file or folder written.
    static func renderPages(
        _ source: URL,
        to format: OutputFormat,
        destination: URL,
        options: ConversionOptions,
        progress: @Sendable (Double) -> Void
    ) throws -> URL {
        let document = try open(source)
        let count = document.pageCount
        guard count > 0 else { throw ConversionError.failed("\(source.lastPathComponent) has no pages.") }

        if count > 1 {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let base = source.deletingPathExtension().lastPathComponent
        let digits = String(count).count
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.pageRef else { continue }
            let image = try render(page, dpi: options.pdfDPI)
            let number = String(index + 1)
            let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
            let url = count == 1
                ? destination
                : destination.appendingPathComponent("\(base) page \(padded).\(format.fileExtension)")
            try ImageConverter.write(image, to: url, format: format, options: options)
            progress(Double(index + 1) / Double(count))
        }
        return destination
    }

    /// Re-saves the PDF with its pictures as JPEGs at screen resolution (like
    /// Preview's "Reduce File Size", but at a quality you choose). Text and
    /// drawings stay sharp and selectable.
    static func compress(_ source: URL, destination: URL, quality: Double) throws {
        let document = try open(source)
        // PDFKit's own "save images as JPEG" options don't change the file on
        // current macOS, so apply a Quartz filter while saving instead.
        guard let filter = reduceSizeFilter(quality: quality) else {
            throw ConversionError.failed("macOS's PDF size filter isn't available.")
        }
        let written = document.write(to: destination, withOptions: [
            PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter,
        ])
        guard written else { throw ConversionError.cannotWrite(destination.lastPathComponent) }
    }

    static func reduceSizeFilter(quality: Double) -> QuartzFilter? {
        let properties: [String: Any] = [
            "Name": "Pinwheel Smaller PDF",
            "FilterType": 1,
            "Domains": ["Applications": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": min(max(quality, 0.1), 1),
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": 144,
                    "ImageScaleInterpolate": true,
                    "ImageSizeMax": 2400,
                    "ImageSizeMin": 0,
                ],
            ]]],
        ]
        return QuartzFilter(properties: properties)
            ?? QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
    }

    // MARK: - Helpers

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        guard !document.isLocked else {
            throw ConversionError.failed("\(url.lastPathComponent) is password-protected.")
        }
        return document
    }

    /// Draws a page on white at the given resolution, honouring its rotation.
    static func render(_ page: CGPDFPage, dpi: Double) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let quarterTurned = abs(Int(page.rotationAngle)) % 180 == 90
        let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        // Cap huge pages (posters, maps) so they can't use gigabytes of memory.
        let scale = min(CGFloat(dpi / 72), 12_000 / max(size.width, size.height, 1))
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.failed("Not enough memory to draw the page.") }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ConversionError.failed("Couldn't draw the page.") }
        return image
    }
}
