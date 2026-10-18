import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A point in a picture from 0 to 1 across and down (0,0 is the top left),
/// so the same edit fits the preview and the full-size picture.
public struct RelativePoint: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func offset(dx: Double, dy: Double) -> RelativePoint {
        RelativePoint(x: x + dx, y: y + dy)
    }
}

/// A rectangle in a picture from 0 to 1 across and down.
public struct RelativeRect: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = RelativeRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// From a rectangle in pixels (y down) of a picture this size.
    public init(_ rect: CGRect, in size: CGSize) {
        self.init(
            x: rect.minX / max(size.width, 1), y: rect.minY / max(size.height, 1),
            width: rect.width / max(size.width, 1), height: rect.height / max(size.height, 1)
        )
    }

    /// In pixels (y down) of a picture this size.
    public func pixels(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    /// The same part of the picture after turning it a quarter turn.
    func turned(clockwise: Bool) -> RelativeRect {
        clockwise
            ? RelativeRect(x: 1 - y - height, y: x, width: height, height: width)
            : RelativeRect(x: y, y: 1 - x - width, width: height, height: width)
    }

    func flipped(horizontally: Bool) -> RelativeRect {
        horizontally
            ? RelativeRect(x: 1 - x - width, y: y, width: width, height: height)
            : RelativeRect(x: x, y: 1 - y - height, width: width, height: height)
    }
}

public struct PixelSize: Codable, Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// A shape such as 16:9 (width : height).
public struct AspectRatio: Codable, Sendable, Equatable, Hashable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = max(width, 0.001)
        self.height = max(height, 0.001)
    }

    public static let square = AspectRatio(1, 1)
    /// Offered in the crop and canvas pickers (landscape; each can be turned).
    public static let presets = [square, AspectRatio(4, 3), AspectRatio(3, 2), AspectRatio(5, 4), AspectRatio(16, 9)]

    /// Width divided by height.
    public var value: Double { width / height }
    public var flipped: AspectRatio { AspectRatio(height, width) }
    public var isPortrait: Bool { height > width }

    /// "16:9"
    public var title: String {
        func short(_ number: Double) -> String {
            number.rounded() == number ? String(Int(number)) : String(format: "%.2f", number)
        }
        return "\(short(width)):\(short(height))"
    }
}

/// A color for markup and backgrounds (sRGB, 0...1).
public struct MarkupColor: Codable, Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "#4338CA"
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    public static let red = MarkupColor(hex: 0xFF3B30)
    public static let orange = MarkupColor(hex: 0xFF9500)
    public static let yellow = MarkupColor(hex: 0xFFCC00)
    public static let green = MarkupColor(hex: 0x34C759)
    public static let blue = MarkupColor(hex: 0x007AFF)
    public static let purple = MarkupColor(hex: 0xAF52DE)
    public static let black = MarkupColor(0, 0, 0)
    public static let white = MarkupColor(1, 1, 1)
    public static let palette: [MarkupColor] = [red, orange, yellow, green, blue, purple, black, white]
    /// Solid backgrounds offered for the frame.
    public static let backgrounds: [MarkupColor] = [
        white, MarkupColor(hex: 0xF2F2F7), MarkupColor(hex: 0x1C1C1E), black,
        MarkupColor(hex: 0xFDE68A), MarkupColor(hex: 0xBFDBFE), MarkupColor(hex: 0xBBF7D0), MarkupColor(hex: 0xFBCFE8),
    ]

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// Light colors get dark text on top, and the other way round.
    public var isLight: Bool { luminance > 0.6 }
    /// Black and near-black: their text gets a light glow instead of a shadow.
    public var isDark: Bool { luminance < 0.2 }

    private var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
}

/// Ready-made backgrounds for the frame, top-left to bottom-right.
public enum GradientPreset: String, CaseIterable, Codable, Sendable {
    case pinwheel, ocean, sky, mint, sunrise, peach, candy, lavender, dusk, graphite

    public var colors: [MarkupColor] {
        switch self {
        case .pinwheel: [MarkupColor(hex: 0x4338CA), MarkupColor(hex: 0x2563EB), MarkupColor(hex: 0x0D9488)]
        case .ocean: [MarkupColor(hex: 0x2E3192), MarkupColor(hex: 0x1BFFFF)]
        case .sky: [MarkupColor(hex: 0x89F7FE), MarkupColor(hex: 0x66A6FF)]
        case .mint: [MarkupColor(hex: 0xD4FC79), MarkupColor(hex: 0x96E6A1)]
        case .sunrise: [MarkupColor(hex: 0xFF9A8B), MarkupColor(hex: 0xFF6A88), MarkupColor(hex: 0xFF99AC)]
        case .peach: [MarkupColor(hex: 0xFFECD2), MarkupColor(hex: 0xFCB69F)]
        case .candy: [MarkupColor(hex: 0xFA709A), MarkupColor(hex: 0xFEE140)]
        case .lavender: [MarkupColor(hex: 0xA18CD1), MarkupColor(hex: 0xFBC2EB)]
        case .dusk: [MarkupColor(hex: 0x0F2027), MarkupColor(hex: 0x203A43), MarkupColor(hex: 0x2C5364)]
        case .graphite: [MarkupColor(hex: 0x434343), MarkupColor(hex: 0x000000)]
        }
    }
}

/// What goes behind the picture when it gets a frame.
public enum Backdrop: Codable, Sendable, Equatable, Hashable {
    /// See-through (saved as PNG).
    case clear
    case color(MarkupColor)
    case gradient(GradientPreset)
    /// The picture itself, blurred and enlarged.
    case blur
}

/// Background, padding, rounded corners and shadow around the picture.
public struct FrameStyle: Codable, Sendable, Equatable {
    public var background: Backdrop = .clear
    /// Space around the picture, as a share of its longer side (0...0.5).
    public var padding = 0.0
    /// Corner rounding, as a share of the picture's shorter side (0...0.5).
    public var cornerRadius = 0.0
    /// 0...1
    public var shadow = 0.0
    /// The shape of the whole result, or nil to just add the padding.
    public var canvasAspect: AspectRatio?

    public init() {}

    public var isActive: Bool {
        padding > 0 || cornerRadius > 0 || shadow > 0 || background != .clear || canvasAspect != nil
    }
}

/// Built-in looks, applied after the sliders.
public enum PhotoFilter: String, CaseIterable, Codable, Sendable {
    case original, vivid, mono, noir, tonal, sepia, chrome, fade, instant, process, transfer

    public var title: String {
        switch self {
        case .original: "Original"
        default: rawValue.capitalized
        }
    }

    /// The Core Image filter, for the ones that are a single built-in filter.
    var ciFilterName: String? {
        switch self {
        case .original, .vivid, .sepia: nil
        case .mono: "CIPhotoEffectMono"
        case .noir: "CIPhotoEffectNoir"
        case .tonal: "CIPhotoEffectTonal"
        case .chrome: "CIPhotoEffectChrome"
        case .fade: "CIPhotoEffectFade"
        case .instant: "CIPhotoEffectInstant"
        case .process: "CIPhotoEffectProcess"
        case .transfer: "CIPhotoEffectTransfer"
        }
    }
}

/// Light and color. Every slider is 0 when untouched; most go from -1 to 1.
public struct Adjustments: Codable, Sendable, Equatable {
    /// Apple's automatic enhancement, applied first.
    public var auto = false
    /// In stops, -2...2.
    public var exposure = 0.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var saturation = 0.0
    public var warmth = 0.0
    /// 0...1
    public var sharpness = 0.0
    /// 0...1
    public var vignette = 0.0
    public var filter = PhotoFilter.original

    public init() {}

    public var isNeutral: Bool { self == Adjustments() }
}

/// A drawing on the picture: an arrow, a box, some text…
public struct Annotation: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case arrow, rectangle, ellipse, pen, highlighter, text, number, redact

        /// Drawn by dragging from one corner (or end) to the other.
        public var isTwoPoint: Bool {
            switch self {
            case .arrow, .rectangle, .ellipse, .redact: true
            case .pen, .highlighter, .text, .number: false
            }
        }

        /// Placed with a click.
        public var isPlaced: Bool { self == .text || self == .number }
    }

    public var id: UUID
    public var kind: Kind
    /// Where it is, in the turned picture before cropping (0...1, y down).
    /// Shapes and arrows have two points (start and end), pen strokes many,
    /// text and numbers one (their middle).
    public var points: [RelativePoint]
    public var color: MarkupColor
    /// Line width, or text height, or the number badge's diameter, as a
    /// share of the turned picture's longer side.
    public var size: Double
    public var text: String

    public init(
        id: UUID = UUID(), kind: Kind, points: [RelativePoint], color: MarkupColor, size: Double, text: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.size = size
        self.text = text
    }

    /// Roughly the area it covers (0...1 of the turned picture), for clicking on it.
    public func bounds(aspect: Double) -> RelativeRect {
        guard let first = points.first else { return RelativeRect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        // `size` is a share of the longer side; turn it into x and y shares.
        let sx = aspect >= 1 ? size : size * aspect.reciprocal
        let sy = aspect >= 1 ? size * aspect : size
        let (padX, padY): (Double, Double) = switch kind {
        case .text:
            (sx * 0.32 * Double(max(longestLine, 1)), sy * 0.7 * Double(lineCount))
        case .number: (sx * 0.5, sy * 0.5)
        case .highlighter: (sx * 2.5, sy * 2.5)
        default: (sx * 2, sy * 2)
        }
        return RelativeRect(x: minX - padX, y: minY - padY, width: maxX - minX + 2 * padX, height: maxY - minY + 2 * padY)
    }

    var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    private var lineCount: Int { max(lines.count, 1) }
    private var longestLine: Int { lines.map(\.count).max() ?? 0 }

    func turned(clockwise: Bool) -> Annotation {
        var copy = self
        copy.points = points.map { clockwise ? RelativePoint(x: 1 - $0.y, y: $0.x) : RelativePoint(x: $0.y, y: 1 - $0.x) }
        return copy
    }

    func flipped(horizontally: Bool) -> Annotation {
        var copy = self
        copy.points = points.map { horizontally ? RelativePoint(x: 1 - $0.x, y: $0.y) : RelativePoint(x: $0.x, y: 1 - $0.y) }
        return copy
    }
}

private extension Double {
    var reciprocal: Double { 1 / Swift.max(self, 0.000_001) }
}

/// Everything the image editor does to a picture, in the order it's done:
/// turn and flip, crop, resize, remove the background, adjust, draw the
/// markup, add the frame. Positions are 0...1, so the same edit fits the
/// preview, the full-size picture, and other pictures edited together.
public struct ImageEdit: Codable, Sendable, Equatable {
    /// Clockwise quarter turns (0...3), done after `mirrored`.
    public var quarterTurns = 0
    /// Flipped left to right, before turning.
    public var mirrored = false
    /// The part to keep, in the turned picture (nil: all of it).
    public var crop: RelativeRect?
    /// The crop's shape, kept when the edit is used on pictures of another
    /// size (nil: free).
    public var aspect: AspectRatio?
    /// The exact size of the result before any frame (nil: the crop's size).
    public var outputSize: PixelSize?
    /// Keep only the subject (people, pets, objects), see-through around it.
    public var removeBackground = false
    public var adjustments = Adjustments()
    public var markup: [Annotation] = []
    public var frame = FrameStyle()
    /// nil: automatic (keeps the format, or PNG when the result is see-through).
    public var format: OutputFormat?

    public init() {}

    /// Nothing would change.
    public var isEmpty: Bool {
        var neutral = self
        neutral.format = nil
        if neutral.crop == .full { neutral.crop = nil }
        return neutral == ImageEdit()
    }

    // MARK: - Turning and flipping

    /// Turns the picture a quarter turn; the crop and markup turn with it.
    public mutating func rotate(clockwise: Bool) {
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        crop = crop?.turned(clockwise: clockwise)
        aspect = aspect?.flipped
        outputSize = outputSize.map { PixelSize(width: $0.height, height: $0.width) }
        markup = markup.map { $0.turned(clockwise: clockwise) }
    }

    /// Flips the picture as it's seen now; the crop and markup follow.
    public mutating func flip(horizontally: Bool) {
        // Kept as "mirror, then turn": flipping what's seen changes both.
        quarterTurns = horizontally ? (4 - quarterTurns) % 4 : (6 - quarterTurns) % 4
        mirrored.toggle()
        crop = crop?.flipped(horizontally: horizontally)
        markup = markup.map { $0.flipped(horizontally: horizontally) }
    }

    // MARK: - Output

    /// Whether the result has see-through parts.
    public func hasTransparency(sourceHasAlpha: Bool) -> Bool {
        let picture = removeBackground || sourceHasAlpha
        guard frame.isActive else { return picture }
        guard frame.background == .clear else { return false }  // the background fills everything
        return picture || frame.padding > 0 || frame.cornerRadius > 0 || frame.shadow > 0 || frame.canvasAspect != nil
    }

    /// The format to save in: the chosen one, else the original's (camera
    /// RAW becomes JPEG, other formats PNG), or PNG when parts are see-through.
    public func outputFormat(for file: SourceFile, hasAlpha: Bool) -> OutputFormat {
        if let format { return format }
        let source = file.format
        if hasTransparency(sourceHasAlpha: hasAlpha) {
            return source == .heic || source == .tiff ? source! : .png
        }
        if let source, [.jpeg, .heic, .png, .tiff].contains(source) { return source }
        if let type = FileKind.contentType(of: file.url), type.conforms(to: .rawImage) { return .jpeg }
        return .png
    }
}
