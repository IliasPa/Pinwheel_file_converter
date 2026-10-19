import CoreGraphics
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
            pixelate(box(first, last), in: ctx, contentSize: mapping.contentSize)
        }
    }

    static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func arrow(from start: CGPoint, to end: CGPoint, width: CGFloat, in ctx: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = min(max(width * 4.2, 6), length * 0.7)
        let spread = CGFloat.pi / 7
        // The shaft stops inside the head, so its round end doesn't poke out.
        let shaftEnd = CGPoint(x: end.x - cos(angle) * head * 0.7, y: end.y - sin(angle) * head * 0.7)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
        ctx.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))
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
    static func pixelate(_ area: CGRect, in ctx: CGContext, contentSize: CGSize) {
        let region = area.integral.intersection(CGRect(origin: .zero, size: contentSize))
        guard !region.isNull, region.width >= 2, region.height >= 2, let current = ctx.makeImage() else { return }
        // CGImage.cropping counts y from the top.
        let flipped = CGRect(x: region.minX, y: contentSize.height - region.maxY, width: region.width, height: region.height)
        guard let piece = current.cropping(to: flipped) else { return }
        let block = max(4, max(contentSize.width, contentSize.height) / 90, min(region.width, region.height) / 8)
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
