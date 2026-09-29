import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The broad kind of a file, which decides which wheel it gets.
public enum FileKind: String, CaseIterable, Sendable {
    case image
    case video
    case audio
    case pdf

    /// Formats that macOS has no built-in type for on some systems.
    static let extraVideoExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ogv", "mts", "m2ts", "ts", "vob", "mpg", "mpeg"]
    static let extraAudioExtensions: Set<String> = ["ogg", "oga", "opus", "flac", "wma", "ape", "mka"]

    public static func of(_ url: URL) -> FileKind? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return nil
        }
        if let type = contentType(of: url) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .svg) { return nil }  // vector art; ImageIO can't read it
            if type.conforms(to: .image) { return .image }
            // Check audio before movie: .m4a counts as both in UTType terms.
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        }
        let ext = url.pathExtension.lowercased()
        if extraVideoExtensions.contains(ext) { return .video }
        if extraAudioExtensions.contains(ext) { return .audio }
        return nil
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        }
    }

    public func countLabel(_ count: Int) -> String {
        switch self {
        case .image: count == 1 ? "1 image" : "\(count) images"
        case .video: count == 1 ? "1 video" : "\(count) videos"
        case .audio: count == 1 ? "1 audio file" : "\(count) audio files"
        case .pdf: count == 1 ? "1 PDF" : "\(count) PDFs"
        }
    }

    static func contentType(of url: URL) -> UTType? {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}

/// What Pinwheel knows about one dragged file.
public struct SourceFile: Sendable, Hashable {
    public let url: URL
    public let kind: FileKind?
    /// The file's current format when it is one Pinwheel can also write.
    public let format: OutputFormat?
    /// AVFoundation can't open it (MKV, WebM, OGG…), so ffmpeg has to.
    public let needsFFmpegToRead: Bool

    public init(url: URL) {
        self.url = url
        let kind = FileKind.of(url)
        self.kind = kind
        self.format = OutputFormat.matching(url)
        if kind == .video || kind == .audio {
            self.needsFFmpegToRead = !Self.avFoundationCanRead(url)
        } else {
            self.needsFFmpegToRead = false
        }
    }

    private static let avTypes: [UTType] = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

    static func avFoundationCanRead(_ url: URL) -> Bool {
        guard let type = FileKind.contentType(of: url), !type.isDynamic else { return false }
        return avTypes.contains { type == $0 || type.conforms(to: $0) }
    }
}
