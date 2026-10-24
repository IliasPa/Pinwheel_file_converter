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
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                // Podcasts and downloads are often sound alone in an .mp4.
                return MovieTracks.hasOnlySound(url) ? .audio : .video
            }
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

/// The tracks of an MP4 or QuickTime movie, read from its "moov" box: the
/// file's header, wherever it is in the file. Quick: a few reads.
enum MovieTracks {
    static let extensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2"]

    /// Sound tracks and no picture track. False when it can't tell.
    static func hasOnlySound(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()), let handlers = handlers(of: url) else { return false }
        return handlers.contains("soun") && !handlers.contains("vide")
    }

    /// A picture track with see-through parts (ProRes 4444 with alpha):
    /// its description says 32 bits a pixel.
    static func hasSeeThroughPicture(_ url: URL) -> Bool {
        guard extensions.contains(url.pathExtension.lowercased()), let moov = moov(of: url) else { return false }
        var search = moov.startIndex
        let marker = Data("stsd".utf8)
        while let found = moov[search...].range(of: marker) {
            // Version and flags, the count, then the first entry: a picture's
            // depth is 74 bytes into its data, and its color table (-1) after.
            let depth = found.upperBound + 8 + 8 + 74
            if depth + 4 <= moov.endIndex, Int(moov[depth]) << 8 | Int(moov[depth + 1]) == 32,
               moov[depth + 2] == 0xFF, moov[depth + 3] == 0xFF {
                return true
            }
            search = found.upperBound
        }
        return false
    }

    /// Each track's kind ("vide", "soun", "text"…).
    static func handlers(of url: URL) -> [String]? {
        moov(of: url).map(handlerTypes)
    }

    /// The "moov" box, wherever it is in the file.
    private static func moov(of url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        // The top-level boxes, to the "moov" one.
        while offset + 8 <= size {
            try? file.seek(toOffset: offset)
            guard let header = try? file.read(upToCount: 16), header.count >= 8 else { return nil }
            var length = UInt64(header.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            let kind = String(decoding: header[4..<8], as: UTF8.self)
            if length == 1, header.count == 16 { length = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) } }
            if length == 0 { length = size - offset }
            guard length >= 8 else { return nil }
            if kind == "moov" {
                // (A header this big belongs to hours of video: no need to read it.)
                guard length < 16_000_000 else { return nil }
                try? file.seek(toOffset: offset)
                return try? file.read(upToCount: Int(length))
            }
            offset += length
        }
        return nil
    }

    /// Every "hdlr" box's handler type: 4 bytes after its version, flags and a reserved word.
    private static func handlerTypes(in moov: Data) -> [String] {
        var types: [String] = []
        var search = moov.startIndex
        let marker = Data("hdlr".utf8)
        while let found = moov[search...].range(of: marker) {
            let type = found.upperBound + 8
            if type + 4 <= moov.endIndex { types.append(String(decoding: moov[type..<(type + 4)], as: UTF8.self)) }
            search = found.upperBound
        }
        return types
    }
}
