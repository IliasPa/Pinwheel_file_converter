import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Turns markup positions (0...1 of the turned picture) into pixels of the
/// cropped and resized picture they're drawn on.
struct MarkupMapping: Sendable {
    /// The turned picture's size, and the crop in its pixels (y down).
    let turnedSize: CGSize
    let crop: CGRect
    /// The picture being drawn on.
    let contentSize: CGSize
    /// Pixels of the original per pixel of the turned picture drawn here
    /// (below 1 when a smaller copy is shown): the ruler tells the real size.
    var originalScale: CGFloat = 1

    var scaleX: CGFloat { contentSize.width / max(crop.width, 1) }
    var scaleY: CGFloat { contentSize.height / max(crop.height, 1) }

    /// In pixels of the content, y up (as Core Graphics draws).
    func point(_ point: RelativePoint) -> CGPoint {
        let x = (point.x * turnedSize.width - crop.minX) * scaleX
        let yDown = (point.y * turnedSize.height - crop.minY) * scaleY
        return CGPoint(x: x, y: contentSize.height - yDown)
    }

    /// A share of the turned picture's longer side, in content pixels.
    func length(_ share: Double) -> CGFloat {
        share * max(turnedSize.width, turnedSize.height) * (scaleX + scaleY) / 2
    }
}

/// Draws arrows, boxes, pen strokes, text, number badges and blurred-out areas.
enum MarkupPainter {
    static func draw(_ annotation: Annotation, in ctx: CGContext, mapping: MarkupMapping) {
        let points = annotation.points.map(mapping.point)
        guard let first = points.first, let last = points.last else { return }
        let size = max(mapping.length(annotation.size), 1)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(annotation.color.cgColor)
        ctx.setFillColor(annotation.color.cgColor)
        ctx.setLineWidth(size)

        switch annotation.kind {
        case .arrow:
            arrow(from: first, to: last, width: size, in: ctx)
        case .rectangle:
            ctx.stroke(box(first, last))
        case .ellipse:
            ctx.strokeEllipse(in: box(first, last))
        case .pen:
            ctx.addPath(smoothPath(points))
            ctx.strokePath()
        case .highlighter:
            // One path, so crossings don't get darker; multiply keeps text readable.
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.45)
            ctx.setLineCap(.square)
            ctx.addPath(smoothPath(points))
            ctx.strokePath()
        case .text:
            text(annotation.lines, at: first, height: size, color: annotation.color, glow: true, in: ctx)
        case .number:
            badge(annotation.text, at: first, diameter: size, color: annotation.color, in: ctx)
        case .redact:
            pixelate(box(first, last), in: ctx, contentSize: mapping.contentSize, coarseness: coarseness(annotation.strength))
        case .line:
            ctx.move(to: first)
            ctx.addLine(to: last)
            ctx.strokePath()
        case .blur:
            softBlur(box(first, last), in: ctx, contentSize: mapping.contentSize, heaviness: coarseness(annotation.strength, range: 3))
        case .spotlight:
            spotlight(box(first, last), in: ctx, contentSize: mapping.contentSize, dimming: 0.2 + 0.7 * annotation.strength)
        case .roundedBox:
            let area = box(first, last)
            let radius = min(area.width, area.height) * 0.22
            ctx.addPath(CGPath(roundedRect: area, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case .filledBox:
            // See-through enough to read what's under it, with a solid edge.
            let area = box(first, last)
            ctx.setFillColor(annotation.color.cgColor.copy(alpha: 0.28) ?? annotation.color.cgColor)
            ctx.fill(area)
            ctx.stroke(area)
        case .doubleArrow:
            doubleArrow(from: first, to: last, width: size, in: ctx)
        case .erase:
            ObjectEraser.erase(box(first, last), in: ctx, contentSize: mapping.contentSize)
        case .dashedLine:
            ctx.setLineDash(phase: 0, lengths: [size * 3, size * 2.2])
            ctx.setLineCap(.butt)
            ctx.move(to: first)
            ctx.addLine(to: last)
            ctx.strokePath()
        case .checkmark:
            let area = box(first, last)
            guard area.width > 1, area.height > 1 else { return }
            ctx.move(to: CGPoint(x: area.minX + area.width * 0.08, y: area.minY + area.height * 0.5))
            ctx.addLine(to: CGPoint(x: area.minX + area.width * 0.36, y: area.minY + area.height * 0.18))
            ctx.addLine(to: CGPoint(x: area.minX + area.width * 0.92, y: area.minY + area.height * 0.86))
            ctx.strokePath()
        case .cross:
            let area = box(first, last)
            guard area.width > 1, area.height > 1 else { return }
            ctx.move(to: CGPoint(x: area.minX + area.width * 0.12, y: area.minY + area.height * 0.12))
            ctx.addLine(to: CGPoint(x: area.maxX - area.width * 0.12, y: area.maxY - area.height * 0.12))
            ctx.move(to: CGPoint(x: area.minX + area.width * 0.12, y: area.maxY - area.height * 0.12))
            ctx.addLine(to: CGPoint(x: area.maxX - area.width * 0.12, y: area.minY + area.height * 0.12))
            ctx.strokePath()
        case .measure:
            let pixels = hypot(
                (annotation.points[annotation.points.count - 1].x - annotation.points[0].x) * mapping.turnedSize.width,
                (annotation.points[annotation.points.count - 1].y - annotation.points[0].y) * mapping.turnedSize.height
            ) / max(mapping.originalScale, 0.000_001)
            ruler(from: first, to: last, pixels: pixels, width: size, color: annotation.color, in: ctx)
        }
    }

    /// How much coarser or finer than standard: 0.5 is 1×, 0 is `1/2^range`…
    /// and 1 is `2^range` (a range of 1 gives ½× to 2×).
    static func coarseness(_ strength: Double, range: Double = 1) -> CGFloat {
        CGFloat(pow(2, (min(max(strength, 0), 1) - 0.5) * 2 * range))
    }

    /// Dims everything except the area, so it stands out.
    static func spotlight(_ area: CGRect, in ctx: CGContext, contentSize: CGSize, dimming: Double = 0.55) {
        let hole = area.intersection(CGRect(origin: .zero, size: contentSize))
        guard !hole.isNull, hole.width >= 2, hole.height >= 2 else { return }
        let radius = min(hole.width, hole.height) * 0.08
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: contentSize))
        path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: dimming))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// Smoothly blurs an area (the blocks of `pixelate` are the other way).
    static func softBlur(_ area: CGRect, in ctx: CGContext, contentSize: CGSize, heaviness: CGFloat = 1) {
        let region = area.integral.intersection(CGRect(origin: .zero, size: contentSize))
        guard !region.isNull, region.width >= 2, region.height >= 2, let current = ctx.makeImage() else { return }
        let flipped = CGRect(x: region.minX, y: contentSize.height - region.maxY, width: region.width, height: region.height)
        guard let piece = current.cropping(to: flipped) else { return }
        let sigma = max(3, max(contentSize.width, contentSize.height) / 160, min(region.width, region.height) / 14) * heaviness
        let source = CIImage(cgImage: piece)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: source.extent)
        guard let result = StudioRenderer.context.createCGImage(blurred, from: source.extent) else { return }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.draw(result, in: region)
        ctx.restoreGState()
    }

    /// A line with a bar at each end and its length in pixels in the middle.
    static func ruler(from start: CGPoint, to end: CGPoint, pixels: CGFloat, width: CGFloat, color: MarkupColor, in ctx: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let cap = max(width * 3, 6)
        ctx.move(to: start)
        ctx.addLine(to: end)
        for point in [start, end] {
            ctx.move(to: CGPoint(x: point.x - sin(angle) * cap, y: point.y + cos(angle) * cap))
            ctx.addLine(to: CGPoint(x: point.x + sin(angle) * cap, y: point.y - cos(angle) * cap))
        }
        ctx.strokePath()

        let label = "\(Int(pixels.rounded())) px"
        let height = max(width * 2.2, 11)
        let measured = textSize([label], height: height)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let pill = CGRect(
            x: middle.x - measured.width / 2 - height * 0.45, y: middle.y - measured.height / 2 - height * 0.1,
            width: measured.width + height * 0.9, height: measured.height + height * 0.2
        )
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.fillPath()
        text([label], at: middle, height: height, color: color.isLight ? .black : .white, glow: false, in: ctx)
    }

    static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func arrow(from start: CGPoint, to end: CGPoint, width: CGFloat, in ctx: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = min(max(width * 4.2, 6), length * 0.7)
        // The shaft stops inside the head, so its round end doesn't poke out.
        let shaftEnd = CGPoint(x: end.x - cos(angle) * head * 0.7, y: end.y - sin(angle) * head * 0.7)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        arrowHead(at: end, angle: angle, head: head, width: width, in: ctx)
    }

    /// One shaft with a head at each end (each end is the tip exactly).
    static func doubleArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, in ctx: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = min(max(width * 4.2, 6), length * 0.35)
        let inset = head * 0.7
        ctx.move(to: CGPoint(x: start.x + cos(angle) * inset, y: start.y + sin(angle) * inset))
        ctx.addLine(to: CGPoint(x: end.x - cos(angle) * inset, y: end.y - sin(angle) * inset))
        ctx.strokePath()
        arrowHead(at: end, angle: angle, head: head, width: width, in: ctx)
        arrowHead(at: start, angle: angle + .pi, head: head, width: width, in: ctx)
    }

    /// A filled triangle whose tip is `tip`, pointing the way `angle` says.
    static func arrowHead(at tip: CGPoint, angle: CGFloat, head: CGFloat, width: CGFloat, in ctx: CGContext) {
        let spread = CGFloat.pi / 7
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x - head * cos(angle - spread), y: tip.y - head * sin(angle - spread)))
        ctx.addLine(to: CGPoint(x: tip.x - head * cos(angle + spread), y: tip.y - head * sin(angle + spread)))
        ctx.closePath()
        ctx.setLineWidth(width * 0.6)
        ctx.drawPath(using: .fillStroke)
    }

    /// A smooth line through the points (curves through their midpoints).
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: first)  // a dot
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Lines of bold text centered on `center`, `height` pixels tall each.
    /// A soft shadow keeps them readable anywhere (a light glow for black text).
    static func text(_ lines: [String], at center: CGPoint, height: CGFloat, color: MarkupColor, glow: Bool, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, height, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, height, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cgColor] as CFDictionary
        let built = lines.map { CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, $0 as CFString, attributes)!) }
        let lineHeight = height * 1.2
        let top = center.y + lineHeight * CGFloat(built.count) / 2

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.textMatrix = .identity
        if glow {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -height * 0.03), blur: height * 0.2,
                color: color.isDark ? CGColor(gray: 1, alpha: 0.75) : CGColor(gray: 0, alpha: 0.5)
            )
        }
        for (index, line) in built.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let lineTop = top - lineHeight * CGFloat(index)
            let baseline = lineTop - (lineHeight - ascent - descent) / 2 - ascent
            ctx.textPosition = CGPoint(x: center.x - width / 2, y: baseline)
            CTLineDraw(line, ctx)
        }
    }

    /// How much room `text(_:at:height:…)` takes.
    static func textSize(_ lines: [String], height: CGFloat) -> CGSize {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, height, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, height, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let width = lines.map { line -> CGFloat in
            let built = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, line as CFString, attributes)!)
            return CGFloat(CTLineGetTypographicBounds(built, nil, nil, nil))
        }.max() ?? 0
        return CGSize(width: max(width, 1), height: height * 1.2 * CGFloat(max(lines.count, 1)))
    }

    /// A filled circle with a number in it, for numbered steps.
    static func badge(_ label: String, at center: CGPoint, diameter: CGFloat, color: MarkupColor, in ctx: CGContext) {
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -diameter * 0.04), blur: diameter * 0.15, color: CGColor(gray: 0, alpha: 0.3))
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(diameter * 0.07)
        ctx.strokeEllipse(in: circle.insetBy(dx: diameter * 0.035, dy: diameter * 0.035))
        text([label], at: center, height: diameter * 0.52, color: color.isLight ? .black : .white, glow: false, in: ctx)
    }

    /// Replaces an area with big blocks of its average colors, so text and
    /// faces in it can't be read.
    static func pixelate(_ area: CGRect, in ctx: CGContext, contentSize: CGSize, coarseness: CGFloat = 1) {
        let region = area.integral.intersection(CGRect(origin: .zero, size: contentSize))
        guard !region.isNull, region.width >= 2, region.height >= 2, let current = ctx.makeImage() else { return }
        // CGImage.cropping counts y from the top.
        let flipped = CGRect(x: region.minX, y: contentSize.height - region.maxY, width: region.width, height: region.height)
        guard let piece = current.cropping(to: flipped) else { return }
        let block = max(3, max(4, max(contentSize.width, contentSize.height) / 90, min(region.width, region.height) / 8) * coarseness)
        let columns = max(1, Int((region.width / block).rounded()))
        let rows = max(1, Int((region.height / block).rounded()))
        guard let small = CGContext(
            data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
            space: piece.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .high  // averages the pixels in each block
        small.draw(piece, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let blocks = small.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(blocks, in: region)
        ctx.restoreGState()
    }
}
