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
    /// one becomes a folder of images (`destination` is then the folder).
    /// Pages are drawn several at a time, one per processor core.
    static func renderPages(
        _ source: URL,
        to format: OutputFormat,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let count = try open(source).pageCount  // also stops at password-protected PDFs
        guard count > 0 else { throw ConversionError.failed("\(source.lastPathComponent) has no pages.") }

        if count > 1 {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let base = source.deletingPathExtension().lastPathComponent
        let digits = String(count).count
        let pageURL: @Sendable (Int) -> URL = { index in
            guard count > 1 else { return destination }
            let number = String(index + 1)
            let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
            return destination.appendingPathComponent("\(base) page \(padded).\(format.fileExtension)")
        }

        let pages = PageQueue(count: count, progress: progress)
        try await withTaskCancellationHandler {
            let lanes = min(count, ProcessInfo.processInfo.activeProcessorCount, 8)
            DispatchQueue.concurrentPerform(iterations: lanes) { _ in
                // Each thread opens the PDF itself, so no two share a document.
                guard let document = CGPDFDocument(source as CFURL) else {
                    pages.fail(ConversionError.unreadable(source.lastPathComponent))
                    return
                }
                if !document.isUnlocked { _ = document.unlockWithPassword("") }
                while let index = pages.next() {
                    do {
                        if let page = document.page(at: index + 1) {  // CGPDFDocument counts from 1
                            let image = try render(page, dpi: options.pdfDPI)
                            try ImageConverter.write(image, to: pageURL(index), format: format, options: options)
                        }
                        pages.finished()
                    } catch {
                        pages.fail(error)
                        return
                    }
                }
            }
            try pages.check()
        } onCancel: {
            pages.stop()
        }
        try Task.checkCancellation()
    }

    /// Re-saves the PDF with its pictures as JPEGs at screen resolution (like
    /// Preview's "Reduce File Size", but at a quality you choose). Text and
    /// drawings stay sharp and selectable.
    static func compress(_ source: URL, destination: URL, quality: Double, dpi: Double) throws {
        let document = try open(source)
        // PDFKit's own "save images as JPEG" options don't change the file on
        // current macOS, so apply a Quartz filter while saving instead.
        guard let filter = reduceSizeFilter(quality: quality, dpi: dpi) else {
            throw ConversionError.failed("macOS's PDF size filter isn't available.")
        }
        let written = document.write(to: destination, withOptions: [
            PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter,
        ])
        guard written else { throw ConversionError.cannotWrite(destination.lastPathComponent) }
    }

    /// Removes the author, title, subject, keywords and app names.
    static func stripMetadata(_ source: URL, destination: URL) throws {
        let document = try open(source)
        document.documentAttributes = [:]
        guard document.write(to: destination) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
    }

    static func reduceSizeFilter(quality: Double, dpi: Double) -> QuartzFilter? {
        let properties: [String: Any] = [
            "Name": "Pinwheel Smaller PDF",
            "FilterType": 1,
            "Domains": ["Applications": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": min(max(quality, 0.1), 1),
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": dpi,
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

/// Hands out page numbers to the drawing threads and keeps count, so the
/// progress bar moves page by page and the first error stops everyone.
private final class PageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private let progress: @Sendable (Double) -> Void
    private var nextIndex = 0
    private var done = 0
    private var stopped = false
    private var error: Error?

    init(count: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.count = count
        self.progress = progress
    }

    /// The next page to draw, or nil when all are taken or the job stopped.
    func next() -> Int? {
        lock.withLock {
            guard !stopped, nextIndex < count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
    }

    func finished() {
        let value = lock.withLock {
            done += 1
            return Double(done) / Double(count)
        }
        progress(value)
    }

    func fail(_ error: Error) {
        lock.withLock {
            if self.error == nil { self.error = error }
            stopped = true
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    func check() throws {
        if let error = lock.withLock({ error }) { throw error }
    }
}
