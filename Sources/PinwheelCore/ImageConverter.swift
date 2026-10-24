import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image conversions with ImageIO (the same engine Preview uses).
public enum ImageConverter {
    public static func convert(_ source: URL, to format: OutputFormat, destination: URL, options: ConversionOptions) throws {
        if format == .pdf && SVGImage.isSVG(source) {
            try SVGImage.writePDF(source, destination: destination)
            return
        }
        let src = try open(source)
        let index = CGImageSourceGetPrimaryImageIndex(src)

        if format == .pdf {
            try writePDF(from: src, index: index, title: source.deletingPathExtension().lastPathComponent, destination: destination)
            return
        }
        if format == .ico {
            try IconWriter.writeICO(src, destination: destination)
            return
        }
        guard format != .icns, format != .webp else {
            throw ConversionError.unsupported("\(format.title) here")  // made by other tools (see ConversionEngine)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let settings = encoderSettings(for: format, options: options)
        let dest = try makeDestination(destination, format: format)
        if format == .gif {
            // Upright (GIF has no orientation), in 256 colors of its own, dithered.
            let image = try orientedImage(src, index: index)
            CGImageDestinationAddImage(dest, GIFPalette.dithered(image) ?? image, nil)
        } else if format == .bmp {
            // BMP takes plain 8-bit color: ImageIO wrote palette pictures
            // (and HDR ones) as raw bytes without a BMP header.
            let image = try standard(try orientedImage(src, index: index))
            CGImageDestinationAddImage(dest, image, uprightMetadata(from: properties).merging(settings) { $1 } as CFDictionary)
        } else if format == .avif, (properties[kCGImagePropertyOrientation] as? Int ?? 1) != 1 {
            // AVIF files don't keep which way is up: the picture is turned upright first.
            let image = try orientedImage(src, index: index)
            CGImageDestinationAddImage(dest, image, uprightMetadata(from: properties).merging(settings) { $1 } as CFDictionary)
        } else if format == .jpeg, properties[kCGImagePropertyHasAlpha] as? Bool == true {
            // JPEG has no transparency. Without this, see-through areas turn black.
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else {
                throw ConversionError.unreadable(source.lastPathComponent)
            }
            let flat = try flatten(image, onto: options.jpegBackground)
            CGImageDestinationAddImage(dest, flat, metadata(from: properties).merging(settings) { $1 } as CFDictionary)
        } else {
            // Copies pixels *and* metadata (date, camera, orientation…).
            CGImageDestinationAddImageFromSource(dest, src, index, settings as CFDictionary)
        }
        try finalize(dest, destination)
    }

    /// WebP, made by cwebp (macOS can't write it) from a lossless PNG of
    /// the upright picture, so nothing is lost on the way.
    static func writeWebP(_ source: URL, destination: URL, options: ConversionOptions) async throws {
        guard let cwebp = options.cwebpURL else {
            throw ConversionError.failed("WebP needs cwebp. Install it with: \(ExternalTool.cwebp.installCommand)")
        }
        let src = try open(source)
        // cwebp ignores color profiles: it gets plain sRGB (a 16-bit or
        // linear gray PNG came out far too dark).
        let image = try standard(try orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src)))
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try write(image, to: png, format: .png, options: options)
        let quality = Int((options.webpQuality * 100).rounded())
        let result = try await ProcessRunner.run(cwebp, ["-quiet", "-q", "\(quality)", "-alpha_q", "100", png.path, "-o", destination.path])
        guard result.status == 0 else {
            let reason = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it stopped with an error"
            throw ConversionError.failed("cwebp couldn't make the WebP: \(reason)")
        }
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
        case .avif: [kCGImageDestinationLossyCompressionQuality: options.avifQuality]
        case .tiff: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]  // LZW, lossless
        default: [:]
        }
    }

    static func open(_ url: URL) throws -> CGImageSource {
        if SVGImage.isSVG(url) { return try SVGImage.source(url) }
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

    /// The metadata for a new picture that's already upright and may have
    /// a new size: orientation 1, no old pixel dimensions.
    static func uprightMetadata(from properties: [CFString: Any]) -> [CFString: Any] {
        var metadata = metadata(from: properties)
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return metadata
    }

    /// Whether the picture has a transparency channel (false if unreadable).
    static func hasAlpha(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any]
        else { return false }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// Whether some of the picture really is see-through. Many pictures have
    /// a transparency channel with every pixel opaque (screenshots often
    /// do); those can become JPEG. Looked at on a small copy, so it's quick.
    static func hasTransparentPixels(_ url: URL) -> Bool {
        guard hasAlpha(url), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = try? orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxPixelSize: 256),
              let ctx = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        for index in stride(from: 3, to: image.width * image.height * 4, by: 4) where pixels[index] < 250 {
            return true
        }
        return false
    }

    /// The full-size image with its EXIF rotation already applied.
    public static func orientedImage(_ src: CGImageSource, index: Int, maxPixelSize: Int? = nil) throws -> CGImage {
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

    /// The picture as 8-bit sRGB (with its transparency, if it has any):
    /// what formats and tools that don't manage color expect. Pictures
    /// that already are come back as they are.
    static func standard(_ image: CGImage) throws -> CGImage {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.name == CGColorSpace.sRGB,
           !image.bitmapInfo.contains(.floatComponents) {
            return image
        }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        ) else { throw ConversionError.failed("Not enough memory to process the image.") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = ctx.makeImage() else { throw ConversionError.failed("Couldn't process the image.") }
        return result
    }

    /// A JPEG or PNG whose file ends early (a download that stopped):
    /// ImageIO shows what's there, leaves the rest gray, and says nothing,
    /// so the file's own end mark is looked for.
    static func isCutShort(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else { return false }
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data.suffix(64).range(of: Data("IEND".utf8)) == nil
        }
        guard bytes.starts(with: [0xFF, 0xD8]) else { return false }
        // Past the header's parts (where a thumbnail with its own end can
        // hide) to the picture itself; it ends with FF D9.
        var at = data.startIndex + 2
        while at + 4 <= data.endIndex, data[at] == 0xFF {
            let marker = data[at + 1]
            if marker == 0xDA { break }  // the picture's data starts
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) || marker == 0xFF { at += marker == 0xFF ? 1 : 2; continue }
            at += 2 + (Int(data[at + 2]) << 8 | Int(data[at + 3]))
        }
        guard at < data.endIndex else { return true }
        return data[at...].range(of: Data([0xFF, 0xD9])) == nil
    }

    /// The picture on a solid color (JPEG has no transparency), given as
    /// "#RRGGBB" (Settings › Wheels › Formats › JPEG); white if it can't be read.
    static func flatten(_ image: CGImage, onto background: String = "#FFFFFF") throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError.failed("Not enough memory to process the image.") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(color(hex: background) ?? CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let flat = ctx.makeImage() else { throw ConversionError.failed("Couldn't process the image.") }
        return flat
    }

    /// "#RRGGBB" (or "RRGGBB") as an sRGB color.
    static func color(hex: String) -> CGColor? {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
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
