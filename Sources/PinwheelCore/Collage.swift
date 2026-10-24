import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// How several pictures become one: a collage or a contact sheet.
public struct CollageSpec: Codable, Sendable, Equatable {
    public enum Layout: String, CaseIterable, Codable, Sendable {
        /// Equal cells; pictures are cropped to fill them.
        case grid
        /// Rows of equal height; every picture keeps its shape.
        case rows
        /// A grid with each picture whole and its name underneath.
        case contactSheet

        public var title: String {
            switch self {
            case .grid: "Grid"
            case .rows: "Rows"
            case .contactSheet: "Contact Sheet"
            }
        }
    }

    public var layout = Layout.grid
    /// Pictures across (0: automatic).
    public var columns = 0
    /// Space between the pictures, as a share of the width.
    public var spacing = 0.012
    /// Space around them, as a share of the width.
    public var margin = 0.025
    /// Rounding of each picture's corners, as a share of its shorter side (0...0.5).
    public var cornerRadius = 0.0
    public var background = MarkupColor.white
    /// The grid's cell shape (nil: the pictures' usual shape).
    public var cellAspect: AspectRatio? = .square
    /// The result's width in pixels.
    public var width = 3000
    /// A heading for contact sheets (empty: none).
    public var title = ""
    public var format = OutputFormat.jpeg

    public init() {}

    public static let widths = [1500, 2000, 3000, 4000, 6000]
}

/// Where everything goes, in pixels with y down.
public struct CollageLayout: Sendable, Equatable {
    public var canvas: CGSize
    /// One per picture, in order.
    public var cells: [CGRect]
    /// Contact sheets: the name under each picture.
    public var captions: [CGRect] = []
    public var titleRect: CGRect?
    /// Pictures fill their cells (cropping) rather than fit inside them.
    public var fills: Bool

    /// `sizes` are the pictures' upright sizes, in order.
    public static func make(for sizes: [CGSize], spec: CollageSpec) -> CollageLayout {
        let count = max(sizes.count, 1)
        let width = CGFloat(max(spec.width, 100))
        let margin = (spec.margin * width).rounded()
        let gap = (spec.spacing * width).rounded()
        let aspects = sizes.map { $0.width / max($0.height, 1) }.sorted()
        let typical = aspects.isEmpty ? 1 : aspects[aspects.count / 2]
        let columns = spec.columns > 0 ? min(spec.columns, count) : automaticColumns(count)
        let available = width - 2 * margin

        switch spec.layout {
        case .grid, .contactSheet:
            let sheet = spec.layout == .contactSheet
            let aspect = spec.cellAspect?.value ?? typical
            let cellWidth = (available - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let cellHeight = cellWidth / aspect
            let captionHeight = sheet ? (cellWidth * 0.13).rounded() : 0
            let titleHeight = sheet && !spec.title.isEmpty ? (width * 0.045).rounded() : 0
            let rowCount = Int((Double(count) / Double(columns)).rounded(.up))
            let rowHeight = cellHeight + captionHeight
            var layout = CollageLayout(
                canvas: CGSize(width: width, height: (2 * margin + titleHeight + CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * gap).rounded()),
                cells: [], fills: !sheet
            )
            if titleHeight > 0 {
                layout.titleRect = CGRect(x: margin, y: margin, width: available, height: titleHeight)
            }
            for index in 0..<sizes.count {
                let row = index / columns, column = index % columns
                // The last row, if not full, sits in the middle.
                let inRow = row == rowCount - 1 ? sizes.count - row * columns : columns
                let offset = CGFloat(columns - inRow) * (cellWidth + gap) / 2
                let x = margin + offset + CGFloat(column) * (cellWidth + gap)
                let y = margin + titleHeight + CGFloat(row) * (rowHeight + gap)
                layout.cells.append(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
                if sheet {
                    layout.captions.append(CGRect(x: x, y: y + cellHeight, width: cellWidth, height: captionHeight))
                }
            }
            return layout

        case .rows:
            // Fill rows at about `columns` pictures each, then scale every
            // row to the full width.
            let target = available / (CGFloat(columns) * typical)
            var rows: [[Int]] = [[]]
            var rowAspect: CGFloat = 0
            for (index, size) in sizes.enumerated() {
                let aspect = size.width / max(size.height, 1)
                rows[rows.count - 1].append(index)
                rowAspect += aspect
                let rowWidth = rowAspect * target + CGFloat(rows[rows.count - 1].count - 1) * gap
                if rowWidth >= available && index < sizes.count - 1 {
                    rows.append([])
                    rowAspect = 0
                }
            }
            var cells = [CGRect](repeating: .zero, count: sizes.count)
            var y = margin
            for (number, row) in rows.enumerated() where !row.isEmpty {
                let aspects = row.map { sizes[$0].width / max(sizes[$0].height, 1) }
                let room = available - CGFloat(row.count - 1) * gap
                var height = room / aspects.reduce(0, +)
                // A short last row keeps the usual height instead of growing.
                if number == rows.count - 1 { height = min(height, target) }
                let used = aspects.reduce(0, +) * height + CGFloat(row.count - 1) * gap
                var x = margin + (available - used) / 2
                for (index, aspect) in zip(row, aspects) {
                    cells[index] = CGRect(x: x, y: y, width: aspect * height, height: height)
                    x += aspect * height + gap
                }
                y += height + gap
            }
            return CollageLayout(canvas: CGSize(width: width, height: (y - gap + margin).rounded()), cells: cells, fills: true)
        }
    }

    static func automaticColumns(_ count: Int) -> Int {
        max(1, Int(Double(count).squareRoot().rounded(.up)))
    }
}

public enum CollageRenderer {
    /// Draws the collage. `pictures` are upright, in order; any size will do
    /// (each is scaled into its cell).
    public static func render(_ pictures: [CGImage], names: [String], spec: CollageSpec, layout: CollageLayout) throws -> CGImage {
        let size = layout.canvas
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try StudioRenderer.bitmapContext(width: Int(size.width), height: Int(size.height), colorSpace: space)
        ctx.setFillColor(spec.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        // Drawing uses y up; the layout's rectangles are y down.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let ink: MarkupColor = spec.background.isLight || spec.background.alpha < 0.5
            ? MarkupColor(0.25, 0.25, 0.27) : MarkupColor(0.85, 0.85, 0.87)

        for (index, picture) in pictures.enumerated() where index < layout.cells.count {
            let cell = layout.cells[index]
            let pictureSize = CGSize(width: picture.width, height: picture.height)
            var target = cell
            var source: CGImage? = picture
            if layout.fills {
                // Crop the middle of the picture to the cell's shape.
                let scale = max(cell.width / pictureSize.width, cell.height / pictureSize.height)
                let crop = CGSize(width: cell.width / scale, height: cell.height / scale)
                source = picture.cropping(to: CGRect(
                    x: ((pictureSize.width - crop.width) / 2).rounded(), y: ((pictureSize.height - crop.height) / 2).rounded(),
                    width: crop.width.rounded(), height: crop.height.rounded()
                ))
            } else {
                // Whole, centered across and sitting on its name (contact sheets).
                let scale = min(cell.width / pictureSize.width, cell.height / pictureSize.height)
                let fitted = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
                let y = layout.captions.isEmpty ? cell.midY - fitted.height / 2 : cell.maxY - fitted.height
                target = CGRect(x: cell.midX - fitted.width / 2, y: y, width: fitted.width, height: fitted.height)
            }
            guard let source else { continue }
            let rect = flipped(target)
            ctx.saveGState()
            let radius = min(spec.cornerRadius * min(rect.width, rect.height), min(rect.width, rect.height) / 2)
            if radius >= 0.5 {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.clip()
            }
            ctx.draw(source, in: rect)
            ctx.restoreGState()

            if index < layout.captions.count, index < names.count {
                caption(names[index], in: flipped(layout.captions[index]), color: ink, ctx: ctx)
            }
        }
        if let title = layout.titleRect, !spec.title.isEmpty {
            let rect = flipped(title)
            MarkupPainter.text([spec.title], at: CGPoint(x: rect.midX, y: rect.midY), height: rect.height * 0.55, color: ink, glow: false, in: ctx)
        }
        return try StudioRenderer.image(of: ctx)
    }

    /// One line, shortened in the middle when it doesn't fit.
    static func caption(_ text: String, in rect: CGRect, color: MarkupColor, ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, rect.height * 0.38, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.38, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cgColor] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
        let ellipsis = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attributes)!)
        let fitted = CTLineCreateTruncatedLine(line, rect.width * 0.96, .middle, ellipsis) ?? line
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(fitted, &ascent, &descent, &leading)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY - (ascent - descent) / 2)
        CTLineDraw(fitted, ctx)
        ctx.restoreGState()
    }

    /// Upright sizes, read without decoding the pictures.
    public static func sizes(of urls: [URL]) throws -> [CGSize] {
        try urls.map { url in
            let src = try ImageConverter.open(url)
            let properties = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 1
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 1
            let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
    }

    /// Each picture, upright, no bigger than its cell needs.
    public static func load(_ urls: [URL], layout: CollageLayout, sizes: [CGSize]) throws -> [CGImage] {
        try zip(urls, zip(layout.cells, sizes)).map { url, item in
            let (cell, size) = item
            // Filling a cell may need more than the cell's long side.
            let scale = layout.fills
                ? max(cell.width / size.width, cell.height / size.height)
                : min(cell.width / size.width, cell.height / size.height)
            let needed = Int((max(size.width, size.height) * scale).rounded(.up)) + 2
            let src = try ImageConverter.open(url)
            return try ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxPixelSize: min(needed, Int(max(size.width, size.height))))
        }
    }

    /// The whole job: several pictures in, one collage file out.
    static func export(_ urls: [URL], spec: CollageSpec, format: OutputFormat, destination: URL, options: ConversionOptions, progress: @Sendable (Double) -> Void) throws {
        let sizes = try sizes(of: urls)
        let layout = CollageLayout.make(for: sizes, spec: spec)
        progress(0.2)
        let pictures = try load(urls, layout: layout, sizes: sizes)
        try Task.checkCancellation()
        progress(0.7)
        var image = try render(pictures, names: urls.map(\.lastPathComponent), spec: spec, layout: layout)
        if format == .jpeg, spec.background.alpha < 1 { image = try ImageConverter.flatten(image, onto: options.jpegBackground) }
        try ImageConverter.write(image, to: destination, format: format, options: options)
    }
}
