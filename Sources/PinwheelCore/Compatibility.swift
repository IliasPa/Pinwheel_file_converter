import Foundation

/// What each kind of file can become: the table in Settings › Compatibility.
/// Worked out from the format wheels themselves, so it can't drift from them.
public enum Compatibility {
    /// A kind of file Pinwheel reads: one row of the table.
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

    /// One box of the table.
    public enum Cell: Equatable, Sendable {
        /// The file already is this format.
        case same
        case converts(needsFFmpeg: Bool)
        case no
    }

    public struct Row: Sendable, Identifiable {
        public let source: Source
        /// One per `targets`, in that order.
        public let cells: [Cell]

        public var id: String { source.id }
    }

    /// The rows, grouped by kind as on the wheels.
    public static let sources: [Source] = [
        Source("PNG", "png"), Source("JPEG", "jpg"), Source("HEIC", "heic"), Source("TIFF", "tiff"), Source("GIF", "gif"),
        Source("WebP", "webp"), Source("AVIF", "avif"), Source("BMP", "bmp"),
        Source("RAW", "dng", detail: "Camera RAW: DNG, CR2, NEF, ARW and more"),
        Source("PDF", "pdf"),
        Source("MP4", "mp4"), Source("MOV", "mov"), Source("M4V", "m4v"),
        Source("MKV", "mkv"), Source("WebM", "webm"), Source("AVI", "avi"),
        Source("MP3", "mp3"), Source("M4A", "m4a"), Source("WAV", "wav"), Source("AIFF", "aiff"),
        Source("FLAC", "flac"), Source("OGG", "ogg", detail: "Ogg Vorbis and Opus"),
    ]

    /// The columns: every format Pinwheel writes, audio in the rows' order
    /// (MP3 first), so the dashes run straight down.
    public static let targets: [OutputFormat] = [.png, .jpeg, .heic, .tiff, .gif, .pdf, .mp4, .mov, .mp3, .m4a, .wav, .aiff, .flac]

    public static let rows: [Row] = sources.map { source in
        Row(source: source, cells: targets.map { cell(from: source.sample, to: $0) })
    }

    static func cell(from file: SourceFile, to target: OutputFormat) -> Cell {
        guard let kind = file.kind else { return .no }
        if file.format == target { return .same }
        let action = WheelAction.convert(target)
        guard FormatCatalog.actions(for: kind, mode: .convert).contains(action) else { return .no }
        return .converts(needsFFmpeg: ConversionEngine.usesFFmpeg(action, for: file))
    }

    /// Whether this wedge takes ffmpeg for every file of the kind (MP3,
    /// GIFs of videos), not only for files macOS can't read.
    public static func needsFFmpeg(_ action: WheelAction, for kind: FileKind) -> Bool {
        guard let readable = sources.first(where: { $0.kind == kind && !$0.sample.needsFFmpegToRead }) else { return false }
        return ConversionEngine.usesFFmpeg(action, for: readable.sample)
    }
}
