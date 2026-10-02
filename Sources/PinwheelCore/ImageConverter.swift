import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image conversions with ImageIO (the same engine Preview uses).
public enum ImageConverter {
    public static func convert(_ source: URL, to format: OutputFormat, destination: URL, options: ConversionOptions) throws {
        let src = try open(source)
        let index = CGImageSourceGetPrimaryImageIndex(src)

        if format == .pdf {
            try writePDF(from: src, index: index, title: source.deletingPathExtension().lastPathComponent, destination: destination)
            return
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let settings = encoderSettings(for: format, options: options)
        let dest = try makeDestination(destination, format: format)
        if format == .jpeg, properties[kCGImagePropertyHasAlpha] as? Bool == true {
            // JPEG has no transparency. Without this, see-through areas turn black.
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else {
                throw ConversionError.unreadable(source.lastPathComponent)
            }
            let flat = try flattenOnWhite(image)
            CGImageDestinationAddImage(dest, flat, metadata(from: properties).merging(settings) { $1 } as CFDictionary)
        } else {
            // Copies pixels *and* metadata (date, camera, orientation…).
            CGImageDestinationAddImageFromSource(dest, src, index, settings as CFDictionary)
        }
        try finalize(dest, destination)
    }

    /// Saves an image that was drawn in memory (e.g. a PDF page).
    static func write(_ image: CGImage, to url: URL, format: OutputFormat, options: ConversionOptions) throws {
        let dest = try makeDestination(url, format: format)
        CGImageDestinationAddImage(dest, image, encoderSettings(for: format, options: options) as CFDictionary)
        try finalize(dest, url)
    }

    // MARK: - Helpers shared with the image tools

    static func encoderSettings(for format: OutputFormat, options: ConversionOptions) -> [CFString: Any] {
        switch format {
        case .jpeg: [kCGImageDestinationLossyCompressionQuality: options.jpegQuality]
        case .heic: [kCGImageDestinationLossyCompressionQuality: options.heicQuality]
        case .tiff: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]  // LZW, lossless
        default: [:]
        }
    }

    static func open(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return src
    }

    static func makeDestination(_ url: URL, format: OutputFormat) throws -> CGImageDestination {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        return dest
    }

    static func finalize(_ dest: CGImageDestination, _ url: URL) throws {
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }

    /// The metadata parts of an image's properties, safe to hand to a new file.
    static func metadata(from properties: [CFString: Any]) -> [CFString: Any] {
        let keys: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyOrientation,
            kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
        ]
        return properties.filter { keys.contains($0.key) }
    }

    /// The full-size image with its EXIF rotation already applied.
    static func orientedImage(_ src: CGImageSource, index: Int, maxPixelSize: Int? = nil) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary) else {
            throw ConversionError.unreadable("The image")
        }
        return image
    }

    static func flattenOnWhite(_ image: CGImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.failed("Not enough memory to process the image.") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let flat = ctx.makeImage() else { throw ConversionError.failed("Couldn't process the image.") }
        return flat
    }

    /// One PDF page, sized so the image prints at its own resolution.
    static func writePDF(from src: CGImageSource, index: Int, title: String, destination: URL) throws {
        let (image, box) = try pdfPage(src, index: index)
        var mediaBox = box
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Pinwheel"] as CFDictionary
        guard let ctx = CGContext(destination as CFURL, mediaBox: &mediaBox, info) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Several images in one PDF, a page each, in the order of their names.
    static func combineIntoPDF(_ sources: [URL], destination: URL, progress: @Sendable (Double) -> Void) throws {
        let ordered = sources.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let info = [kCGPDFContextCreator: "Pinwheel"] as CFDictionary
        guard let ctx = CGContext(destination as CFURL, mediaBox: nil, info) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        for (number, url) in ordered.enumerated() {
            try Task.checkCancellation()
            let src = try open(url)
            var (image, box) = try pdfPage(src, index: CGImageSourceGetPrimaryImageIndex(src))
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            progress(Double(number + 1) / Double(ordered.count))
        }
        ctx.closePDF()
    }

    /// The upright image and a page box that prints it at its own resolution.
    private static func pdfPage(_ src: CGImageSource, index: Int) throws -> (CGImage, CGRect) {
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let image = try orientedImage(src, index: index)
        var dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        if dpi < 1 { dpi = 72 }
        let box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        return (image, box)
    }
}
