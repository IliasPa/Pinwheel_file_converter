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
        var settings: [CFString: Any] = [:]
        switch format {
        case .jpeg: settings[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality
        case .heic: settings[kCGImageDestinationLossyCompressionQuality] = options.heicQuality
        case .tiff: settings[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]  // LZW, lossless
        default: break
        }

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

    // MARK: - Helpers shared with the image tools

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
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let image = try orientedImage(src, index: index)
        var dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        if dpi < 1 { dpi = 72 }
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Pinwheel"] as CFDictionary
        guard let ctx = CGContext(destination as CFURL, mediaBox: &box, info) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
