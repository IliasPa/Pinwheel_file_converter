import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// A picture loaded for editing: upright, and maybe smaller than the
/// original (for previews).
public struct StudioSource: @unchecked Sendable {
    public let image: CGImage
    /// The original picture's upright size in pixels.
    public let fullSize: CGSize
    public let hasAlpha: Bool

    public init(image: CGImage, fullSize: CGSize? = nil, hasAlpha: Bool? = nil) {
        self.image = image
        self.fullSize = fullSize ?? CGSize(width: image.width, height: image.height)
        self.hasAlpha = hasAlpha ?? StudioRenderer.hasAlpha(image)
    }

    public var size: CGSize { CGSize(width: image.width, height: image.height) }
    /// Pixels of `image` per pixel of the original (1 for the full picture).
    public var scale: Double { Double(image.width) / max(fullSize.width, 1) }

    /// `maxPixelSize` limits the longer side (for previews); nil loads it all.
    public static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> StudioSource {
        let src = try ImageConverter.open(url)
        let index = CGImageSourceGetPrimaryImageIndex(src)
        if CGImageSourceGetCount(src) > 1, CGImageSourceGetType(src) as String? == OutputFormat.gif.utType.identifier {
            throw ConversionError.failed("Editing doesn't work on animated GIFs yet.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let longSide = max(width, height)
        let image = try ImageConverter.orientedImage(
            src, index: index, maxPixelSize: maxPixelSize.map { min($0, max(longSide, 1)) }
        )
        var upright = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        if upright.width < 1 || upright.height < 1 { upright = CGSize(width: image.width, height: image.height) }
        return StudioSource(image: image, fullSize: upright, hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool)
    }
}

/// The edited picture before the markup and frame are drawn on it.
public struct StudioContent: @unchecked Sendable {
    public let image: CGImage
    /// The same without the background removed, kept only when a blurred
    /// backdrop needs it.
    public let plain: CGImage?
}

/// Draws an `ImageEdit`. The editor's preview and the saved file both come
/// from here, so what you see is what you get.
public enum StudioRenderer {
    /// Thread-safe and costly to make, so there's one.
    static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Geometry

    /// The picture's size after its quarter turns.
    public static func turnedSize(_ size: CGSize, _ edit: ImageEdit) -> CGSize {
        edit.quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    /// The part kept, in whole pixels of the turned picture (y down). With a
    /// fixed shape, the crop is fitted to it (for pictures of other sizes).
    public static func cropRect(in size: CGSize, _ edit: ImageEdit) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        var rect = (edit.crop ?? .full).pixels(in: size).intersection(bounds)
        if rect.isNull || rect.width < 1 || rect.height < 1 { rect = bounds }
        if let aspect = edit.aspect { rect = fitted(rect, aspect: aspect.value, in: size) }
        let width = size.width.rounded(), height = size.height.rounded()
        let minX = min(rect.minX.rounded(), width - 1), minY = min(rect.minY.rounded(), height - 1)
        let maxX = min(max(rect.maxX.rounded(), minX + 1), width)
        let maxY = min(max(rect.maxY.rounded(), minY + 1), height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// About the same middle and area as `rect`, with the given shape
    /// (width / height), inside a picture of `size`.
    public static func fitted(_ rect: CGRect, aspect: Double, in size: CGSize) -> CGRect {
        let area = max(rect.width * rect.height, 1)
        var width = (area * aspect).squareRoot()
        var height = width / aspect
        let fit = min(1, size.width / width, size.height / height)
        width *= fit
        height *= fit
        let x = min(max(rect.midX - width / 2, 0), size.width - width)
        let y = min(max(rect.midY - height / 2, 0), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The largest rectangle of this shape that fits, in the middle.
    public static func largest(aspect: Double, in size: CGSize) -> CGRect {
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// The edited picture's size before the frame, for an original this big.
    public static func contentSize(for size: CGSize, _ edit: ImageEdit) -> PixelSize {
        if let output = edit.outputSize { return output }
        let crop = cropRect(in: turnedSize(size, edit), edit)
        return PixelSize(width: Int(crop.width), height: Int(crop.height))
    }

    /// The whole result's size, frame included.
    public static func finalSize(for size: CGSize, _ edit: ImageEdit) -> PixelSize {
        let canvas = canvas(for: contentSize(for: size, edit).cgSize, style: edit.frame).size
        return PixelSize(width: Int(canvas.width), height: Int(canvas.height))
    }

    /// The frame's size, and where the picture sits in it.
    static func canvas(for content: CGSize, style: FrameStyle) -> (size: CGSize, picture: CGRect) {
        guard style.isActive else { return (content, CGRect(origin: .zero, size: content)) }
        let pad = (style.padding * max(content.width, content.height)).rounded()
        var width = content.width + 2 * pad
        var height = content.height + 2 * pad
        if let aspect = style.canvasAspect?.value {
            if width / height < aspect { width = (height * aspect).rounded() } else { height = (width / aspect).rounded() }
        }
        let picture = CGRect(
            x: ((width - content.width) / 2).rounded(), y: ((height - content.height) / 2).rounded(),
            width: content.width, height: content.height
        )
        return (CGSize(width: width, height: height), picture)
    }

    // MARK: - Drawing

    /// The whole edit: content, markup and frame.
    public static func render(_ source: StudioSource, mask: CGImage?, edit: ImageEdit) throws -> CGImage {
        let content = try content(source, mask: mask, edit: edit)
        let marked = try drawMarkup(on: content.image, edit: edit, source: source)
        return try framed(marked, plain: content.plain, style: edit.frame)
    }

    /// The picture turned, cropped, resized, cut out and adjusted. `mask` is
    /// the subject (see `SubjectMask`), used when the edit removes the background.
    public static func content(_ source: StudioSource, mask: CGImage?, edit: ImageEdit) throws -> StudioContent {
        var image = CIImage(cgImage: source.image)
        var cutout: CIImage?
        if edit.removeBackground, let mask {
            var subject = CIImage(cgImage: mask)
            if mask.width != source.image.width || mask.height != source.image.height {
                subject = subject.transformed(by: CGAffineTransform(
                    scaleX: CGFloat(source.image.width) / CGFloat(mask.width),
                    y: CGFloat(source.image.height) / CGFloat(mask.height)
                ))
            }
            cutout = subject
        }
        image = turned(image, edit)
        cutout = cutout.map { turned($0, edit) }

        // Core Image's y points up; the crop's points down.
        let size = image.extent.size
        let crop = cropRect(in: size, edit)
        let ciCrop = CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height)
        let toOrigin = CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY)
        image = image.cropped(to: ciCrop).transformed(by: toOrigin)
        cutout = cutout?.cropped(to: ciCrop).transformed(by: toOrigin)

        var outSize = crop.size
        if let target = edit.outputSize {
            outSize = CGSize(
                width: max(1, (Double(target.width) * source.scale).rounded()),
                height: max(1, (Double(target.height) * source.scale).rounded())
            )
            image = resized(image, to: outSize)
            cutout = cutout.map { resized($0, to: outSize) }
        }
        let extent = CGRect(origin: .zero, size: outSize)
        let plain = adjusted(image, edit.adjustments).cropped(to: extent)
        var result = plain
        if let cutout {
            result = plain.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: cutout,
            ]).cropped(to: extent)
        }
        let space = outputColorSpace(for: source.image)
        let picture = try render(result, extent: extent, colorSpace: space)
        let backdrop = cutout != nil && edit.frame.background == .blur
            ? try render(plain, extent: extent, colorSpace: space)
            : nil
        return StudioContent(image: picture, plain: backdrop)
    }

    /// Draws the markup (plus `extra`, such as one still being drawn) over
    /// the content made from the same source and edit.
    public static func drawMarkup(
        on content: CGImage, edit: ImageEdit, source: StudioSource, extra: Annotation? = nil
    ) throws -> CGImage {
        var annotations = edit.markup
        if let extra { annotations.append(extra) }
        guard !annotations.isEmpty else { return content }
        let turned = turnedSize(source.size, edit)
        let mapping = MarkupMapping(
            turnedSize: turned, crop: cropRect(in: turned, edit),
            contentSize: CGSize(width: content.width, height: content.height)
        )
        let ctx = try bitmapContext(width: content.width, height: content.height, colorSpace: outputColorSpace(for: content))
        ctx.draw(content, in: CGRect(x: 0, y: 0, width: content.width, height: content.height))
        for annotation in annotations {
            MarkupPainter.draw(annotation, in: ctx, mapping: mapping)
        }
        return try image(of: ctx)
    }

    /// Puts the picture on its background with padding, rounded corners and
    /// a shadow. `plain` (the picture before its background was removed)
    /// feeds a blurred backdrop.
    public static func framed(_ picture: CGImage, plain: CGImage?, style: FrameStyle) throws -> CGImage {
        guard style.isActive else { return picture }
        let content = CGSize(width: picture.width, height: picture.height)
        let (size, rect) = canvas(for: content, style: style)
        let ctx = try bitmapContext(width: Int(size.width), height: Int(size.height), colorSpace: outputColorSpace(for: picture))
        let all = CGRect(origin: .zero, size: size)
        ctx.interpolationQuality = .high

        switch style.background {
        case .clear:
            break
        case .color(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(all)
        case .gradient(let preset):
            let colors = preset.colors.map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                ctx.drawLinearGradient(
                    gradient, start: CGPoint(x: all.minX, y: all.maxY), end: CGPoint(x: all.maxX, y: all.minY),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
        case .blur:
            if let backdrop = blurredCover(plain ?? picture, size: size) {
                ctx.draw(backdrop, in: all)
            }
        }

        let unit = max(content.width, content.height)
        let shortSide = min(content.width, content.height)
        let radius = min(style.cornerRadius * shortSide, shortSide / 2)
        let layer = radius >= 0.5 ? try rounded(picture, radius: radius) : picture
        if style.shadow > 0 {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -unit * 0.015 * style.shadow),
                blur: unit * 0.06 * style.shadow,
                color: CGColor(gray: 0, alpha: 0.2 + 0.35 * style.shadow)
            )
        }
        ctx.draw(layer, in: rect)
        return try image(of: ctx)
    }

    // MARK: - Helpers

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Mirrors and turns in exact quarter turns, ending at (0, 0).
    static func turned(_ image: CIImage, _ edit: ImageEdit) -> CIImage {
        var result = image
        if edit.mirrored {
            result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0))
        }
        for _ in 0..<(edit.quarterTurns % 4) {
            // Clockwise, with Core Image's y pointing up: (x, y) → (y, -x).
            result = result.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0))
        }
        let extent = result.extent
        return result.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// Exactly `size` pixels, with good-quality resampling.
    static func resized(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        let scaleY = size.height / extent.height
        let scaleX = size.width / extent.width
        return image.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    static func adjusted(_ input: CIImage, _ settings: Adjustments) -> CIImage {
        guard !settings.isNeutral else { return input }
        let extent = input.extent
        let unit = max(extent.width, extent.height)
        var image = input
        if settings.auto {
            // No face search: it would run Vision inside Core Image, which is
            // slow for a live preview and can't take turns (see VisionTurns).
            for filter in image.autoAdjustmentFilters(options: [.redEye: false, .features: [CIFeature]()]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage { image = output }
            }
        }
        // Clamped, so blurs and sharpening near the edges don't fade out.
        image = image.clampedToExtent()
        if settings.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        }
        if settings.highlights < 0 || settings.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(settings.highlights, 0),
                "inputShadowAmount": settings.shadows,
            ])
        }
        if settings.highlights > 0 {
            let lift = settings.highlights
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.04 * lift),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.12 * lift),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        if settings.contrast != 0 || settings.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + settings.contrast * 0.5,
                kCIInputSaturationKey: 1 + settings.saturation,
                kCIInputBrightnessKey: 0,
            ])
        }
        if settings.warmth != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - 2500 * settings.warmth, y: 0),
            ])
        }
        switch settings.filter {
        case .original:
            break
        case .vivid:
            image = image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.7])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputSaturationKey: 1.1, kCIInputBrightnessKey: 0])
        case .sepia:
            image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        default:
            if let name = settings.filter.ciFilterName { image = image.applyingFilter(name) }
        }
        if settings.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: settings.sharpness * 1.2,
                kCIInputRadiusKey: min(max(1.69 * unit / 2000, 0.5), 5),
            ])
        }
        if settings.vignette > 0 {
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: unit * 0.62,
                kCIInputIntensityKey: settings.vignette,
                "inputFalloff": 0.6,
            ])
        }
        return image.cropped(to: extent)
    }

    /// Fills `size` with the picture (cropping what sticks out), heavily
    /// blurred. Worked out small and drawn larger: a blur hides that.
    static func blurredCover(_ picture: CGImage, size: CGSize) -> CGImage? {
        let work = min(1, 360 / max(size.width, size.height))
        let target = CGRect(x: 0, y: 0, width: (size.width * work).rounded(.up), height: (size.height * work).rounded(.up))
        var image = CIImage(cgImage: picture)
        let fill = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        image = image.transformed(by: CGAffineTransform(
            translationX: (target.width - image.extent.width) / 2, y: (target.height - image.extent.height) / 2
        ))
        image = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(target.width, target.height) * 0.05])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.15, kCIInputBrightnessKey: -0.03, kCIInputContrastKey: 1])
            .cropped(to: target)
        return context.createCGImage(image, from: target, format: .RGBA8, colorSpace: outputColorSpace(for: picture))
    }

    static func rounded(_ picture: CGImage, radius: CGFloat) throws -> CGImage {
        let ctx = try bitmapContext(width: picture.width, height: picture.height, colorSpace: outputColorSpace(for: picture))
        let rect = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(picture, in: rect)
        return try image(of: ctx)
    }

    static func render(_ image: CIImage, extent: CGRect, colorSpace: CGColorSpace) throws -> CGImage {
        guard let result = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ConversionError.failed("Not enough memory to draw the picture.")
        }
        return result
    }

    /// The picture's own RGB color space (e.g. Display P3), else sRGB.
    static func outputColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func bitmapContext(width: Int, height: Int, colorSpace: CGColorSpace) throws -> CGContext {
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.failed("Not enough memory to draw the picture.")
        }
        return ctx
    }

    static func image(of ctx: CGContext) throws -> CGImage {
        guard let image = ctx.makeImage() else { throw ConversionError.failed("Couldn't draw the picture.") }
        return image
    }
}

/// Saves what the image editor (or Remove BG) made, at full size.
enum StudioExporter {
    static func export(_ url: URL, edit: ImageEdit, format: OutputFormat, destination: URL, options: ConversionOptions) throws {
        let source = try StudioSource.load(url)
        var mask: CGImage?
        if edit.removeBackground {
            guard let subject = try SubjectMask.make(for: source.image) else {
                throw NothingToDo(reason: "No clear subject was found, so nothing was saved.")
            }
            mask = subject
        }
        try Task.checkCancellation()
        var image = try StudioRenderer.render(source, mask: mask, edit: edit)
        if format == .jpeg, StudioRenderer.hasAlpha(image) {
            image = try ImageConverter.flattenOnWhite(image)  // JPEG has no transparency
        }
        try Task.checkCancellation()

        // Keeps the date, camera and place; the new picture is upright.
        let src = try ImageConverter.open(url)
        let properties = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] ?? [:]
        let settings = ImageConverter.encoderSettings(for: format, options: options)
        let dest = try ImageConverter.makeDestination(destination, format: format)
        CGImageDestinationAddImage(dest, image, ImageConverter.uprightMetadata(from: properties).merging(settings) { $1 } as CFDictionary)
        try ImageConverter.finalize(dest, destination)
    }
}
