import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The broad kind of a file, which decides which wheel it gets.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case image
    case video
    case audio
    case pdf
    case archive
    case document
    case spreadsheet
    case presentation
    case subtitle

    /// The kinds the tools (Compress, Info, custom actions…) work on.
    public static let editable: Set<FileKind> = [.image, .video, .audio, .pdf]

    /// Formats that macOS has no built-in type for on some systems.
    static let extraVideoExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ogv", "mts", "m2ts", "ts", "vob", "mpg", "mpeg"]
    static let extraAudioExtensions: Set<String> = ["ogg", "oga", "opus", "flac", "wma", "ape", "mka"]
    /// Told by name, since documents such as .docx are zip files inside too.
    static let archiveExtensions: Set<String> = ["zip", "tar", "tgz", "gz", "gzip", "tbz", "tbz2", "bz2", "txz", "xz", "rar", "7z"]
    static let documentExtensions: Set<String> = [
        "docx", "docm", "dotx", "doc", "rtf", "rtfd", "odt", "pages", "txt", "text", "md", "markdown", "mdown", "html", "htm", "xhtml", "epub", "webarchive",
    ]
    static let spreadsheetExtensions: Set<String> = ["xlsx", "xlsm", "xls", "ods", "csv", "tsv", "tab", "numbers"]
    static let presentationExtensions: Set<String> = ["pptx", "ppt", "key"]
    static let subtitleExtensions: Set<String> = ["srt", "vtt"]
    /// Documents that can be folders (packages) on disk.
    static let packageExtensions: Set<String> = ["rtfd", "pages", "numbers", "key"]

    public static func of(_ url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, !packageExtensions.contains(ext) {
            return nil
        }
        if archiveExtensions.contains(ext) { return .archive }
        if documentExtensions.contains(ext) { return .document }
        if spreadsheetExtensions.contains(ext) { return .spreadsheet }
        if presentationExtensions.contains(ext) { return .presentation }
        if subtitleExtensions.contains(ext) { return .subtitle }
        if let type = contentType(of: url) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }  // SVG too: it's drawn as a picture first
            // Check audio before movie: .m4a counts as both in UTType terms.
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        }
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
        case .archive: "archivebox"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .subtitle: "captions.bubble"
        }
    }

    public func countLabel(_ count: Int) -> String {
        switch self {
        case .image: count == 1 ? "1 image" : "\(count) images"
        case .video: count == 1 ? "1 video" : "\(count) videos"
        case .audio: count == 1 ? "1 audio file" : "\(count) audio files"
        case .pdf: count == 1 ? "1 PDF" : "\(count) PDFs"
        case .archive: count == 1 ? "1 archive" : "\(count) archives"
        case .document: count == 1 ? "1 document" : "\(count) documents"
        case .spreadsheet: count == 1 ? "1 spreadsheet" : "\(count) spreadsheets"
        case .presentation: count == 1 ? "1 presentation" : "\(count) presentations"
        case .subtitle: count == 1 ? "1 subtitle file" : "\(count) subtitle files"
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
public struct SourceFile: Sendable, Hashable, Codable {
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

    /// A picture that moves (an animated GIF, PNG, WebP or HEIC). Read
    /// from the file each time it's asked.
    public var isAnimated: Bool {
        kind == .image && AnimatedPicture.isAnimated(url)
    }

    private static let avTypes: [UTType] = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

    static func avFoundationCanRead(_ url: URL) -> Bool {
        guard let type = FileKind.contentType(of: url), !type.isDynamic else { return false }
        // AVI is on AVFoundation's list, but it can't open one (H.264 or MPEG-4 inside).
        guard !type.conforms(to: .avi) else { return false }
        return avTypes.contains { type == $0 || type.conforms(to: $0) }
    }
}
