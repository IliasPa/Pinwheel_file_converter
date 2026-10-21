import Foundation

/// Where new files go.
public enum SaveLocation: Sendable, Equatable, Codable {
    case nextToOriginal
    case downloads
    case folder(URL)
}

/// What "Resize" does to an image.
public enum ResizeOption: String, CaseIterable, Codable, Sendable {
    case quarter, half, threeQuarters
    case fit1080, fit1280, fit1920, fit2048, fit2560, fit3840

    /// Shown on the wedge and in Settings.
    public var title: String {
        switch self {
        case .quarter: "Resize 25%"
        case .half: "Resize 50%"
        case .threeQuarters: "Resize 75%"
        case .fit1080: "Fit 1080 px"
        case .fit1280: "Fit 1280 px"
        case .fit1920: "Fit 1920 px"
        case .fit2048: "Fit 2048 px"
        case .fit2560: "Fit 2560 px"
        case .fit3840: "Fit 3840 px"
        }
    }

    public var detail: String {
        switch self {
        case .quarter: "A quarter of the width and height"
        case .half: "Half the width and height"
        case .threeQuarters: "Three quarters of the width and height"
        default: "The longest side becomes at most \(fitSize ?? 0) pixels"
        }
    }

    /// Goes in the output name: "photo (50%).jpg", "photo (1920px).jpg".
    public var nameSuffix: String {
        switch self {
        case .quarter: "25%"
        case .half: "50%"
        case .threeQuarters: "75%"
        default: "\(fitSize ?? 0)px"
        }
    }

    var fitSize: Int? {
        switch self {
        case .fit1080: 1080
        case .fit1280: 1280
        case .fit1920: 1920
        case .fit2048: 2048
        case .fit2560: 2560
        case .fit3840: 3840
        default: nil
        }
    }

    /// The new longest side, or nil when the image is already small enough.
    public func newLongSide(from longSide: Int) -> Int? {
        switch self {
        case .quarter: max(1, longSide / 4)
        case .half: max(1, longSide / 2)
        case .threeQuarters: max(1, longSide * 3 / 4)
        default: fitSize.flatMap { longSide > $0 ? $0 : nil }
        }
    }
}

/// How hard "Compress" squeezes a video.
public enum VideoQuality: String, CaseIterable, Codable, Sendable {
    case smaller, balanced, best

    public var title: String {
        switch self {
        case .smaller: "Smallest file"
        case .balanced: "Balanced"
        case .best: "Best quality"
        }
    }

    /// HEVC bits per pixel per frame used to pick the bit rate.
    var bitsPerPixel: Double {
        switch self {
        case .smaller: 0.045
        case .balanced: 0.075
        case .best: 0.12
        }
    }

    /// x264 quality for videos that go through ffmpeg (lower is better).
    var crf: Int {
        switch self {
        case .smaller: 30
        case .balanced: 26
        case .best: 22
        }
    }
}

/// The largest size "Compress" keeps for a video.
public enum VideoMaxSize: String, CaseIterable, Codable, Sendable {
    case original, p2160, p1080, p720

    public var title: String {
        switch self {
        case .original: "Keep the original size"
        case .p2160: "At most 4K (3840 px)"
        case .p1080: "At most 1080p (1920 px)"
        case .p720: "At most 720p (1280 px)"
        }
    }

    /// Longest side in pixels, or nil for "keep".
    var longSide: Int? {
        switch self {
        case .original: nil
        case .p2160: 3840
        case .p1080: 1920
        case .p720: 1280
        }
    }
}

/// User-adjustable settings, copied into each job when it starts.
public struct ConversionOptions: Sendable, Equatable, Codable {
    /// 0...1 quality for JPEG output.
    public var jpegQuality: Double = 0.85
    /// 0...1 quality for HEIC output.
    public var heicQuality: Double = 0.80
    /// 0...1 quality for WebP output.
    public var webpQuality: Double = 0.80
    /// 0...1 quality for AVIF output.
    public var avifQuality: Double = 0.70
    /// 0...1 quality used by Compress for images (and pictures inside PDFs).
    public var compressQuality: Double = 0.60
    /// Compress results that save less than this share are thrown away.
    public var minimumSaving: Double = 0.03
    public var resize: ResizeOption = .half
    public var videoQuality: VideoQuality = .balanced
    public var videoMaxSize: VideoMaxSize = .original
    /// Bit rate of AAC audio made by Compress, in bits per second.
    public var audioBitRate: Int = 128_000
    /// Width in pixels of GIFs made from video (height keeps the aspect ratio).
    public var gifWidth: Int = 480
    /// Frames per second of GIFs made from video.
    public var gifFPS: Int = 15
    /// Only the first this-many seconds of a video become a GIF (nil: all of it).
    public var gifMaxSeconds: Int? = 15
    /// Resolution when turning PDF pages into images.
    public var pdfDPI: Double = 150
    /// Resolution of the pictures inside a PDF after Compress.
    public var pdfImageDPI: Double = 144
    /// Several images dropped on "PDF" become one PDF with a page each.
    public var combineImagesIntoOnePDF = true
    public var saveLocation: SaveLocation = .nextToOriginal
    /// Used when the chosen place can't be written to (e.g. a read-only disk).
    public var fallbackFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// Where ffmpeg is, or nil when it isn't installed.
    public var ffmpegURL: URL?
    /// Where pngquant is (for compressing PNGs), or nil.
    public var pngquantURL: URL?
    /// Where cwebp is (for WebP pictures), or nil.
    public var cwebpURL: URL?
    /// How text is read in pictures and scanned pages (Get Text, Searchable).
    public var textRecognition = TextRecognition()

    public init() {}
}

/// What an editor window chose, sent along with the job it starts.
public enum JobParameters: Sendable, Equatable, Codable {
    /// The image editor's crop, adjustments, background and markup.
    case image(ImageEdit)
    /// New title, author… from the Info window.
    case metadata(MetadataEdit)
    /// Trim, speed, turn and sound, from the video and audio editor (also
    /// the part a GIF is made from).
    case media(MediaEdit)
    /// Which frame to save, in seconds from the start, turned as shown.
    case frame(seconds: Double, quarterTurns: Int = 0)
    case password(String)
    case collage(CollageSpec)
    case pages(PageArrangement)
    /// The most the result may weigh, in bytes.
    case sizeLimit(bytes: Int64)
}

/// One conversion: usually one file, or several files becoming one PDF.
public struct ConversionRequest: Sendable, Equatable, Codable {
    public var files: [SourceFile]
    public var action: WheelAction
    /// What was chosen in an editor window, for jobs that come from one.
    public var parameters: JobParameters?

    public init(files: [SourceFile], action: WheelAction, parameters: JobParameters? = nil) {
        self.files = files
        self.action = action
        self.parameters = parameters
    }

    public init(file: SourceFile, action: WheelAction, parameters: JobParameters? = nil) {
        self.init(files: [file], action: action, parameters: parameters)
    }

    /// Several images going into one PDF.
    public var isCombinedPDF: Bool {
        action == .convert(.pdf) && files.count > 1 && files.allSatisfy { $0.kind == .image }
    }

    /// Several PDFs joined into one.
    public var isMerge: Bool {
        action == .tool(.merge) && files.count > 1
    }

    /// All the files make one result (a merged PDF, a collage, organized pages, a ZIP).
    public var isCombined: Bool {
        isMerge || action == .tool(.collage) || action == .tool(.organize) || action == .tool(.archive)
    }

    /// Whether the result stands in for the original, so "Move the original
    /// to the Trash" applies. Text, frames, collages and GIFs of a part are
    /// taken *from* files that are still wanted (and may still be open).
    public var replacesOriginal: Bool {
        switch action {
        case .tool(.extractText), .tool(.saveFrame), .tool(.collage), .tool(.archive), .tool(.extract): false
        case .convert(.gif): mediaEdit == nil  // a GIF of a part is taken from the video
        case .recipe(let recipe): recipe.replacesOriginal
        default: true
        }
    }

    /// The size chosen for Size Limit.
    var sizeLimit: Int64? {
        if case .sizeLimit(let bytes)? = parameters { return bytes }
        return nil
    }

    var mediaEdit: MediaEdit? {
        if case .media(let edit)? = parameters { return edit }
        return nil
    }

    /// The image editor's edit (an empty edit when there is none).
    var imageEdit: ImageEdit {
        if case .image(let edit)? = parameters { return edit }
        return ImageEdit()
    }
}

/// What a finished conversion produced.
public struct ConversionResult: Sendable, Equatable, Codable {
    /// The files (or folder) written. Empty when there was nothing to do.
    public var outputs: [URL]
    /// Something worth telling: where it was saved, what was skipped and why.
    public var note: String?

    public var skipped: Bool { outputs.isEmpty }
}

/// Thrown by a converter when there is nothing useful to do (e.g. an image
/// that's already smaller than the resize target). Not a failure.
struct NothingToDo: Error {
    let reason: String
}

public enum ConversionError: LocalizedError, Equatable {
    case unreadable(String)
    case cannotWrite(String)
    case unsupported(String)
    case needsFFmpeg
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) couldn't be opened. It may be damaged or in a format macOS can't read."
        case .cannotWrite(let name): "Couldn't save \(name). Check that the folder isn't read-only."
        case .unsupported(let what): "\(what) isn't supported."
        case .needsFFmpeg: "This needs ffmpeg. Install it with: brew install ffmpeg"
        case .failed(let reason): reason
        }
    }
}

/// Passes on at most about ten progress updates a second (plus the last one),
/// so a chatty converter doesn't flood the screen with redraws.
public final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue = -1.0
    private var lastTime = Date.distantPast

    public init() {}

    public func shouldReport(_ value: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard value >= 1 || (value - lastValue >= 0.005 && now.timeIntervalSince(lastTime) >= 0.1) else { return false }
        lastValue = value
        lastTime = now
        return true
    }
}
