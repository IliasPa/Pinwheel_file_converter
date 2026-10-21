import AppKit
import ImageIO
import UniformTypeIdentifiers

/// SVG drawings. macOS reads them with NSImage (ImageIO can't), so they're
/// drawn as a picture first, big enough to stay sharp, and then go wherever
/// any other picture goes. A PDF keeps them as drawings.
enum SVGImage {
    /// The long side of the picture an SVG becomes, unless it's drawn bigger.
    static let longSide: CGFloat = 2048

    static func isSVG(_ url: URL) -> Bool {
        FileKind.contentType(of: url)?.conforms(to: .svg) == true
    }

    static func load(_ url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return image
    }

    /// The drawing as a picture, read like any other.
    static func source(_ url: URL) throws -> CGImageSource {
        let image = try load(url)
        let scale = max(1, longSide / max(image.size.width, image.size.height))
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError.failed("Not enough memory to draw \(url.lastPathComponent).") }
        draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), on: ctx)
        let png = NSMutableData()
        guard let picture = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("Couldn't draw \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, picture, nil)
        guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(png, nil) else {
            throw ConversionError.failed("Couldn't draw \(url.lastPathComponent).")
        }
        return src
    }

    /// A PDF page the size of the drawing, still made of lines and shapes.
    static func writePDF(_ url: URL, destination: URL) throws {
        let image = try load(url)
        var box = CGRect(origin: .zero, size: image.size)
        let info = [kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent, kCGPDFContextCreator: "Pinwheel"] as CFDictionary
        guard let ctx = CGContext(destination as CFURL, mediaBox: &box, info) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        ctx.beginPDFPage(nil)
        draw(image, in: box, on: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private static func draw(_ image: NSImage, in rect: CGRect, on ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Icons: one file with the picture at several sizes, fitted into a square
/// (see-through around it when the picture isn't square).
enum IconWriter {
    /// An ICO holds at most six pictures (ImageIO's limit): the usual ones.
    static let icoSizes = [16, 32, 48, 64, 128, 256]
    /// A Mac icon's sizes, each also at twice the pixels (up to 1024).
    static let icnsPoints = [16, 32, 128, 256, 512]

    static func writeICO(_ src: CGImageSource, destination: URL) throws {
        let image = try ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src))
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, OutputFormat.ico.utType.identifier as CFString, icoSizes.count, nil) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        for size in icoSizes {
            CGImageDestinationAddImage(dest, try square(image, size: size), nil)
        }
        try ImageConverter.finalize(dest, destination)
    }

    /// The way Apple makes Mac icons: a set of PNGs, put together by iconutil.
    static func writeICNS(_ source: URL, destination: URL) async throws {
        let src = try ImageConverter.open(source)
        let image = try ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src))
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString).iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for points in icnsPoints {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try ImageConverter.write(try square(image, size: points * scale), to: iconset.appendingPathComponent(name), format: .png, options: ConversionOptions())
            }
        }
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/iconutil"), ["-c", "icns", iconset.path, "-o", destination.path])
        guard result.status == 0 else {
            throw ConversionError.failed("Couldn't make the Mac icon: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func square(_ image: CGImage, size: Int) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError.failed("Not enough memory to make the icon.") }
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height))
        guard let icon = ctx.makeImage() else { throw ConversionError.failed("Couldn't make the icon.") }
        return icon
    }
}
