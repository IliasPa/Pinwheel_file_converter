import Foundation

/// What each kind of file can become: the tables in Settings › Compatibility.
/// Worked out from the format wheels themselves, so they can't drift apart.
public enum Compatibility {
    /// A kind of file Pinwheel reads: one row of a table.
    public struct Source: Hashable, Sendable, Identifiable {
        public let title: String
        /// What else the row stands for, when it's more than one format.
        public let detail: String?
        /// A pretend file of this kind (it doesn't need to exist).
        public let sample: SourceFile

        init(_ title: String, _ fileExtension: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
            sample = SourceFile(url: URL(fileURLWithPath: "/tmp/Pinwheel sample.\(fileExtension)"))
        }

        public var id: String { title }
        public var kind: FileKind { sample.kind! }
    }

    /// One box of a table.
    public enum Cell: Equatable, Sendable {
        /// The file already is this format.
        case same
        /// It converts; `needs` is the extra tool that does it, if any.
        case converts(needs: ExternalTool?)
        case no
    }

    public struct Row: Sendable, Identifiable {
        public let source: Source
        /// One per target of its section, in that order.
        public let cells: [Cell]

        public var id: String { source.id }
    }

    /// One kind of file: its rows, against everything they can become.
    public struct Section: Sendable, Identifiable {
        public let kind: FileKind
        public let targets: [OutputFormat]
        public let rows: [Row]

        public var id: FileKind { kind }
    }

    public static let sources: [Source] = [
        Source("PNG", "png"), Source("JPEG", "jpg"), Source("HEIC", "heic"), Source("WebP", "webp"), Source("AVIF", "avif"),
        Source("TIFF", "tiff"), Source("GIF", "gif"), Source("BMP", "bmp"), Source("SVG", "svg", detail: "Drawings, made into pictures"),
        Source("RAW", "dng", detail: "Camera RAW: DNG, CR2, NEF, ARW and more"),
        Source("PDF", "pdf"),
        Source("MP4", "mp4"), Source("MOV", "mov"), Source("M4V", "m4v"), Source("MKV", "mkv"), Source("WebM", "webm"),
        Source("AVI", "avi"), Source("WMV", "wmv"),
        Source("MP3", "mp3"), Source("M4A", "m4a"), Source("WAV", "wav"), Source("AIFF", "aiff"), Source("FLAC", "flac"),
        Source("OGG", "ogg", detail: "Ogg Vorbis"), Source("Opus", "opus"), Source("WMA", "wma"),
        Source("ZIP", "zip"), Source("TAR", "tar"), Source("TAR.GZ", "tar.gz"), Source("7Z", "7z"), Source("RAR", "rar"),
    ]

    /// Columns come in this order in every table: pictures, PDF, video,
    /// audio (MP3 before M4A, as in the rows), archives.
    public static let order: [OutputFormat] = [
        .png, .jpeg, .heic, .webp, .avif, .tiff, .gif, .bmp, .ico, .icns, .pdf,
        .mp4, .mov, .mkv, .webm, .avi, .wmv,
        .mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus, .wma,
        .zip, .tar, .tgz, .sevenZip,
    ]

    public static let sections: [Section] = [FileKind.image, .pdf, .video, .audio, .archive].map(section)

    static func section(_ kind: FileKind) -> Section {
        let sources = sources.filter { $0.kind == kind }
        var formats = Set(FormatCatalog.actions(for: kind, mode: .convert).compactMap { action -> OutputFormat? in
            if case .convert(let format) = action { return format }
            return nil
        })
        formats.formUnion(sources.compactMap(\.sample.format))  // for each row's own dash
        let targets = order.filter(formats.contains)
        let rows = sources.map { source in Row(source: source, cells: targets.map { cell(from: source.sample, to: $0) }) }
        return Section(kind: kind, targets: targets, rows: rows)
    }

    static func cell(from file: SourceFile, to target: OutputFormat) -> Cell {
        guard let kind = file.kind else { return .no }
        if file.format == target { return .same }
        let action = WheelAction.convert(target)
        guard FormatCatalog.actions(for: kind, mode: .convert).contains(action) else { return .no }
        return .converts(needs: tool(for: action, file: file))
    }

    /// The extra tool a wedge takes for this file, if any.
    static func tool(for action: WheelAction, file: SourceFile) -> ExternalTool? {
        if action == .convert(.webp) { return .cwebp }
        return ConversionEngine.usesFFmpeg(action, for: file) ? .ffmpeg : nil
    }

    /// The extra tool this wedge takes for every file of the kind (ffmpeg
    /// for MP3 and GIFs of videos, cwebp for WebP), not only for files
    /// macOS can't read.
    public static func tool(for action: WheelAction, kind: FileKind) -> ExternalTool? {
        guard let readable = sources.first(where: { $0.kind == kind && !$0.sample.needsFFmpegToRead }) else { return nil }
        return tool(for: action, file: readable.sample)
    }
}
