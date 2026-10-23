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

    /// What a conversion loses, when it isn't as good as the original (a
    /// yellow tick in the table); nil when nothing that matters is lost.
    public static func limitation(from source: Source, to target: OutputFormat) -> String? {
        guard source.sample.format != target else { return nil }  // the same format
        let from = source.title
        let lossyAudio: Set<String> = ["MP3", "M4A", "OGG", "Opus", "WMA"]
        let losslessAudioTargets: Set<OutputFormat> = [.wav, .aiff, .flac]
        let lossyAudioTargets: Set<OutputFormat> = [.mp3, .m4a, .ogg, .opus, .wma]
        let canBeSeeThrough: Set<String> = ["PNG", "HEIC", "WebP", "AVIF", "TIFF", "GIF", "SVG"]
        let richDocuments: Set<String> = ["DOCX", "Pages", "RTF", "ODT", "HTML", "EPUB", "DOC"]
        switch source.kind {
        case .image:
            if from == "GIF", target != .gif { return "only the first frame of an animated GIF" }
            if target == .gif { return "only 256 colors" }
            if target == .jpeg, canBeSeeThrough.contains(from) { return "see-through parts become white" }
            if target == .ico { return "small icon sizes only (up to 256 × 256)" }
        case .pdf:
            switch target {
            case .docx, .pages, .epub: return "the layout is rebuilt from the pages, so it may not look the same"
            case .md: return "simple formatting only"
            case .txt: return "text only"
            case .xlsx: return "only the tables found on its pages"
            case .pptx: return "each page becomes a picture on a slide (its text can't be edited)"
            default: break
            }
        case .video:
            if target == .gif { return "no sound and only 256 colors (and a big file)" }
        case .audio:
            if lossyAudio.contains(from), lossyAudioTargets.contains(target) { return "it was already compressed: a little more quality is lost" }
            if lossyAudio.contains(from), losslessAudioTargets.contains(target) { return "a much bigger file that doesn't sound any better" }
        case .document:
            if target == .txt, from != "TXT" { return "text only: formatting, pictures and tables are left out" }
            if target == .md, richDocuments.contains(from) { return "simple formatting only (headings, lists, links, tables)" }
            if target == .rtf, richDocuments.contains(from) { return "pictures are left out" }
        case .spreadsheet:
            if [.csv, .tsv].contains(target), !["CSV", "TSV"].contains(from) { return "only the first sheet, as plain values" }
        case .subtitle:
            if target == .txt { return "text only, without the times" }
            if from == "VTT", target == .srt { return "styling and positions are left out" }
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
