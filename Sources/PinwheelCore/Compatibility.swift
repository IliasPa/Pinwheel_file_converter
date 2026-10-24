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
        Source("DOCX", "docx", detail: "Word"), Source("Pages", "pages"), Source("RTF", "rtf"), Source("ODT", "odt"),
        Source("MD", "md", detail: "Markdown"), Source("TXT", "txt"), Source("HTML", "html"), Source("EPUB", "epub"),
        Source("DOC", "doc", detail: "Word 97–2004"),
        Source("XLSX", "xlsx", detail: "Excel"), Source("ODS", "ods"), Source("CSV", "csv"), Source("TSV", "tsv"),
        Source("XLS", "xls", detail: "Excel 97–2004, read by Numbers"), Source("Numbers", "numbers"),
        Source("PPTX", "pptx", detail: "PowerPoint, read by Keynote"), Source("PPT", "ppt", detail: "PowerPoint 97–2004, read by Keynote"),
        Source("Keynote", "key"),
        Source("SRT", "srt"), Source("VTT", "vtt", detail: "WebVTT"),
    ]

    /// Columns come in this order in every table: pictures, PDF, video,
    /// audio (MP3 before M4A, as in the rows), archives.
    public static let order: [OutputFormat] = [
        .png, .jpeg, .heic, .webp, .avif, .tiff, .gif, .bmp, .ico, .icns, .pdf,
        .mp4, .mov, .mkv, .webm, .avi, .wmv,
        .mp3, .m4a, .wav, .aiff, .flac, .ogg, .opus, .wma,
        .zip, .tar, .tgz, .sevenZip,
        .docx, .pages, .rtf, .odt, .md, .txt, .html, .epub,
        .xlsx, .ods, .csv, .tsv, .pptx, .srt, .vtt,
    ]

    public static let sections: [Section] = [FileKind.image, .pdf, .video, .audio, .archive, .document, .spreadsheet, .presentation, .subtitle].map(section)

    static func section(_ kind: FileKind) -> Section {
        let sources = sources.filter { $0.kind == kind }
        var formats = Set(FormatCatalog.actions(for: kind, mode: .convert).compactMap { action -> OutputFormat? in
            if case .convert(let format) = action { return format }
            return nil
        })
        formats.formUnion(sources.compactMap(\.sample.format))  // for each row's own dash
        if kind == .image { formats.formUnion([.mp4, .webm]) }  // animated pictures (GIF) as videos
        let targets = order.filter(formats.contains)
        let rows = sources.map { source in Row(source: source, cells: targets.map { cell(from: source.sample, to: $0) }) }
        return Section(kind: kind, targets: targets, rows: rows)
    }

    static func cell(from file: SourceFile, to target: OutputFormat) -> Cell {
        guard let kind = file.kind else { return .no }
        if file.format == target { return .same }
        let action = WheelAction.convert(target)
        let animations = kind == .image && file.format == .gif ? FormatCatalog.forAnimations : []
        guard (FormatCatalog.actions(for: kind, mode: .convert) + animations).contains(action) else { return .no }
        return .converts(needs: tool(for: action, file: file))
    }

    /// What a conversion loses, when it isn't as good as the original (a
    /// yellow tick in the table); nil when nothing that matters is lost.
    /// A format that holds less by its nature (an icon's sizes, plain text,
    /// lossless sound from compressed sound) isn't a loss: that's the point
    /// of choosing it.
    public static func limitation(from source: Source, to target: OutputFormat) -> String? {
        guard source.sample.format != target else { return nil }  // the same format
        let from = source.title
        let lossyAudio: Set<String> = ["MP3", "M4A", "OGG", "Opus", "WMA"]
        let lossyAudioTargets: Set<OutputFormat> = [.mp3, .m4a, .ogg, .opus, .wma]
        let canBeSeeThrough: Set<String> = ["PNG", "HEIC", "WebP", "AVIF", "TIFF", "GIF", "SVG"]
        let richDocuments: Set<String> = ["DOCX", "Pages", "RTF", "ODT", "HTML", "EPUB", "DOC"]
        switch source.kind {
        case .image:
            if from == "GIF", target == .mp4 { return "see-through parts get a solid color (MP4 has none)" }
            if from == "GIF", !AnimatedPicture.keepsMotion.contains(target) { return "only the first frame of an animated GIF" }
            if target == .gif { return "only 256 colors (mixed finely, so shading stays smooth)" }
            if target == .jpeg, canBeSeeThrough.contains(from) {
                return "see-through parts get a solid color (white, or the one chosen in Settings › Wheels › Formats)"
            }
        case .pdf:
            switch target {
            case .docx, .pages, .epub: return "the layout is rebuilt from the pages (text, pictures, tables, columns), so it may not look exactly the same"
            case .md: return "simple formatting only"
            case .xlsx: return "only the tables found on its pages"
            case .pptx: return "the words become text boxes over a picture of the page, so it may not look exactly the same"
            default: break
            }
        case .video:
            if target == .gif { return "no sound and only 256 colors (and a big file)" }
            if target == .webp { return "no sound (an animated picture)" }
        case .audio:
            if from == "Opus", target == .ogg { return nil }  // the same sound, in an .ogg file
            if from == "M4A", lossyAudioTargets.contains(target) {
                return "most M4A files were already compressed (AAC): a little more quality is lost (none from Apple Lossless)"
            }
            if lossyAudio.contains(from), lossyAudioTargets.contains(target) {
                return "it was already compressed: a little more quality is lost (Pinwheel keeps at least its bit rate)"
            }
        case .document:
            if target == .md, richDocuments.contains(from) { return "simple formatting only (headings, lists, links, tables, pictures)" }
        case .spreadsheet:
            if [.csv, .tsv].contains(target), !["CSV", "TSV"].contains(from) {
                return "plain values, without formulas or formatting (each sheet a file of its own)"
            }
        case .subtitle:
            if from == "VTT", target == .srt { return "exact positions and sizes become top, middle or bottom, left or right" }
        case .archive, .presentation:
            break
        }
        return nil
    }

    /// The extra tool (or Apple app) a wedge takes for this file, if any.
    static func tool(for action: WheelAction, file: SourceFile) -> ExternalTool? {
        if action == .convert(.webp) { return .cwebp }
        if let app = ConversionEngine.app(for: action, file: file) { return app }
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
