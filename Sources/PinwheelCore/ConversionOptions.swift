import Foundation

/// User-adjustable settings, copied into each job when it starts.
public struct ConversionOptions: Sendable, Equatable {
    /// 0...1 quality for JPEG output.
    public var jpegQuality: Double = 0.85
    /// 0...1 quality for HEIC output.
    public var heicQuality: Double = 0.80
    /// 0...1 quality used by the Compress tool (images, and pictures inside PDFs).
    public var compressQuality: Double = 0.60
    /// Width in pixels of GIFs made from video (height keeps the aspect ratio).
    public var gifWidth: Int = 480
    /// Frames per second of GIFs made from video.
    public var gifFPS: Int = 15
    /// Resolution when turning PDF pages into images.
    public var pdfDPI: Double = 150
    /// Where ffmpeg is, or nil when it isn't installed.
    public var ffmpegURL: URL?

    public init() {}
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
