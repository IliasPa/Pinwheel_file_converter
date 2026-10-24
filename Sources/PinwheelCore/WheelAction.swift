import Foundation
import UniformTypeIdentifiers

/// A format Pinwheel can write.
public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case png, jpeg, heic, tiff, gif, pdf
    case mp4, mov
    case m4a, mp3, wav, aiff, flac
    case webp, avif, bmp, ico, icns
    case mkv, webm, avi, wmv
    case ogg, opus, wma
    case zip, tar, tgz = "tar.gz", sevenZip = "7z"
    case docx, pages, pptx, xlsx, epub, md, txt, rtf, odt, html, ods, csv, tsv, srt, vtt

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .pdf: .pdf
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .m4a: .mpeg4Audio
        case .mp3: .mp3
        case .wav: .wav
        case .aiff: .aiff
        case .flac: UTType("org.xiph.flac") ?? UTType(filenameExtension: "flac") ?? .audio
        case .webp: .webP
        case .avif: UTType("public.avif") ?? .image
        case .bmp: .bmp
        case .ico: .ico
        case .icns: .icns
        case .avi: .avi
        case .zip: .zip
        default: UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    public var title: String {
        switch self {
        case .m4a: "M4A"
        case .webp: "WebP"
        case .webm: "WebM"
        case .opus: "Opus"
        case .pages: "Pages"
        default: rawValue.uppercased()
        }
    }

    /// What kind of file the result is.
    public var kind: FileKind {
        switch self {
        case .png, .jpeg, .heic, .tiff, .gif, .webp, .avif, .bmp, .ico, .icns: .image
        case .pdf: .pdf
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: .video
        case .m4a, .mp3, .wav, .aiff, .flac, .ogg, .opus, .wma: .audio
        case .zip, .tar, .tgz, .sevenZip: .archive
        case .docx, .pages, .epub, .md, .txt, .rtf, .odt, .html: .document
        case .xlsx, .ods, .csv, .tsv: .spreadsheet
        case .pptx: .presentation
        case .srt, .vtt: .subtitle
        }
    }

    /// The Apple app that writes this format, when only it can.
    public var app: ExternalTool? { self == .pages ? .pages : nil }

    /// Made by ffmpeg whatever the file (macOS can't write these).
    public var needsFFmpeg: Bool {
        [.mp3, .mkv, .webm, .avi, .wmv, .ogg, .opus, .wma].contains(self)
    }

    public var symbolName: String {
        switch self {
        case .png: "photo"
        case .jpeg: "camera"
        case .heic: "photo.stack"
        case .tiff: "doc.richtext"
        case .gif: "square.stack.3d.down.right"
        case .pdf: "doc.text"
        case .mp4: "film"
        case .mov: "video"
        case .m4a: "waveform"
        case .mp3: "music.note"
        case .wav: "waveform.path"
        case .aiff: "waveform.circle"
        case .flac: "hifispeaker"
        case .webp: "globe"
        case .avif: "photo.on.rectangle"
        case .bmp: "squareshape.split.3x3"
        case .ico: "app"
        case .icns: "app.dashed"
        case .mkv: "film.stack"
        case .webm: "play.rectangle"
        case .avi: "video.circle"
        case .wmv: "tv"
        case .ogg: "music.quarternote.3"
        case .opus: "mic"
        case .wma: "music.note.list"
        case .zip: "doc.zipper"
        case .tar: "archivebox"
        case .tgz: "shippingbox"
        case .sevenZip: "cube.box"
        case .docx: "doc.fill"
        case .pages: "doc.richtext"
        case .pptx: "rectangle.stack"
        case .xlsx: "tablecells"
        case .epub: "book"
        case .md: "number.square"
        case .txt: "text.alignleft"
        case .rtf: "textformat"
        case .odt: "doc.circle"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .ods: "tablecells.badge.ellipsis"
        case .csv: "list.bullet.rectangle"
        case .tsv: "list.bullet.indent"
        case .srt: "captions.bubble"
        case .vtt: "text.bubble"
        }
    }

    /// One short line shown in the middle of the wheel while hovering.
    public func detail(from kind: FileKind?) -> String {
        switch self {
        case .png:
            switch kind {
            case .pdf: "One image per page, sharp and lossless"
            case .presentation: "A picture of each slide, in a folder"
            default: "Lossless, keeps transparency"
            }
        case .jpeg:
            switch kind {
            case .pdf: "One photo per page, small files"
            case .presentation: "A photo of each slide, in a folder"
            default: "Small files, works everywhere"
            }
        case .heic: "Half the size of JPEG, same quality"
        case .tiff: "Lossless, for print and editing"
        case .gif: kind == .video ? "Animated GIF of the clip" : "Works in any browser or chat; animations keep moving"
        case .pdf:
            switch kind {
            case .document: "Looks the same everywhere, ready to print"
            case .spreadsheet: "The sheets as tables, ready to print"
            case .presentation: "A page for each slide"
            default: "A PDF page for each image"
            }
        case .mp4: kind == .image ? "Animated pictures only: a video of it, often 10 times smaller" : "Plays everywhere"
        case .mov: "QuickTime movie"
        case .m4a: kind == .video ? "Just the sound, AAC" : "AAC, small and good quality"
        case .mp3: kind == .video ? "Just the sound, MP3" : "Plays on any device"
        case .wav: "Uncompressed, universal"
        case .aiff: "Uncompressed, Apple"
        case .flac: "Lossless and compressed"
        case .webp: kind == .video ? "Animated, in full colors and much smaller than a GIF (the GIF settings below)" : "Small files for websites; animations keep moving"
        case .avif: "The smallest files, sharp details"
        case .bmp: "Uncompressed, for older apps"
        case .ico: "Windows icon, 16 to 256 pixels"
        case .icns: "Mac icon, 16 to 1024 pixels"
        case .mkv: "Keeps every track; plays in VLC and IINA"
        case .webm: kind == .image ? "Animated pictures only: a video for websites, see-through parts kept" : "For websites: VP9 picture, Opus sound"
        case .avi: "For older players and TVs"
        case .wmv: "For Windows Media Player"
        case .ogg: "Ogg Vorbis, an open format"
        case .opus: "The best sound for its size"
        case .wma: "Windows Media Audio"
        case .zip: "Opens on any computer"
        case .tar: "Unix archive, not compressed"
        case .tgz: "Compressed Unix archive"
        case .sevenZip: "The smallest archives"
        case .docx: kind == .pdf ? "Word, with text you can edit" : "Word"
        case .pages: "Apple Pages (made by Pages)"
        case .pptx: kind == .pdf ? "PowerPoint, a slide for each page" : "PowerPoint (made by Keynote)"
        case .xlsx: kind == .pdf ? "Excel, the tables on each page" : "Excel workbook"
        case .epub: "A book for Books and e-readers"
        case .md: "Markdown text"
        case .txt: kind == .subtitle ? "Just the words" : "Plain text"
        case .rtf: "Rich text, for TextEdit"
        case .odt: "OpenDocument, for LibreOffice"
        case .html: "A web page"
        case .ods: "OpenDocument spreadsheet"
        case .csv: "Comma-separated, for any app"
        case .tsv: "Tab-separated"
        case .srt: "SubRip subtitles, for most players"
        case .vtt: "WebVTT subtitles, for the web"
        }
    }

    /// The format a file already has, when it's one Pinwheel writes.
    public static func matching(_ url: URL) -> OutputFormat? {
        // Told by name where the type can't tell: Opus is Ogg audio too,
        // and archives (".tar.gz" is two extensions).
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tgz }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "opus": return .opus
        case "zip": return .zip
        case "tar": return .tar
        case "7z": return .sevenZip
        case "markdown", "mdown": return .md
        case "htm", "xhtml": return .html
        case "text": return .txt
        case "tab": return .tsv
        default: break
        }
        // Documents are told by name: their types vary between systems.
        if let format = allCases.first(where: { $0.fileExtension == ext }), ![.image, .video, .audio, .pdf].contains(format.kind) {
            return format
        }
        guard let type = FileKind.contentType(of: url) else { return nil }
        // .m4a files are "com.apple.m4a-audio", a kind of MPEG-4 audio.
        if type == m4aFileType { return .m4a }
        return allCases.first { $0.kind != .archive && $0.utType == type }
    }

    private static let m4aFileType = UTType("com.apple.m4a-audio")
}

/// Jobs offered on the Option+Shift wheel, plus the jobs the editor
/// windows make (from `edit` on, which never sit on a wedge themselves).
public enum ToolAction: String, CaseIterable, Codable, Sendable {
    case compress
    case resize
    case stripMetadata
    case extractAudio
    case removeBackground
    case extractText
    case mute
    case merge
    case split
    case normalize
    case makeSearchable
    // Made by an editor window, with what was chosen there.
    case edit
    case editInfo
    case editMedia
    case saveFrame
    case protect
    case collage
    case organize
    case sizeLimit
    /// Files and folders into one .zip (the file actions wheel).
    case archive
    /// An archive's contents into a folder.
    case extract
    /// Faces and text in a picture, blurred out.
    case blurPrivate
    /// A sound into a video with moving bars (from the Visualizer window).
    case visualize

    /// The general name; Resize shows its chosen size on the wheel instead.
    public var title: String {
        switch self {
        case .compress: "Compress"
        case .resize: "Resize"
        case .stripMetadata: "Strip Info"
        case .extractAudio: "Get Audio"
        case .removeBackground: "Remove BG"
        case .extractText: "Get Text"
        case .mute: "Mute"
        case .merge: "Merge"
        case .split: "Split Pages"
        case .normalize: "Normalize"
        case .makeSearchable: "Searchable"
        case .edit: "Edit"
        case .editInfo: "Edit Info"
        case .editMedia: "Edit"
        case .saveFrame: "Save Frame"
        case .protect: "Add Password"
        case .collage: "Collage"
        case .organize: "Organize Pages"
        case .sizeLimit: "Size Limit"
        case .archive: "ZIP"
        case .extract: "Extract"
        case .blurPrivate: "Blur Faces & Text"
        case .visualize: "Visualizer"
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: "rectangle.compress.vertical"
        case .resize: "arrow.down.right.and.arrow.up.left"
        case .stripMetadata: "tag.slash"
        case .extractAudio: "speaker.wave.2"
        case .removeBackground: "person.and.background.dotted"
        case .extractText: "text.viewfinder"
        case .mute: "speaker.slash"
        case .merge: "arrow.triangle.merge"
        case .split: "scissors"
        case .normalize: "speaker.wave.2.circle"
        case .makeSearchable: "doc.text.magnifyingglass"
        case .edit: "slider.horizontal.3"
        case .editInfo: "info.circle"
        case .editMedia: "timeline.selection"
        case .saveFrame: "camera.viewfinder"
        case .protect: "lock.doc"
        case .collage: "square.grid.2x2"
        case .organize: "rectangle.grid.2x2"
        case .sizeLimit: "gauge.with.dots.needle.bottom.50percent"
        case .archive: "doc.zipper"
        case .extract: "tray.and.arrow.up"
        case .blurPrivate: "eye.slash"
        case .visualize: "waveform.circle"
        }
    }

    public func detail(for kind: FileKind?, options: ConversionOptions = ConversionOptions()) -> String {
        switch self {
        case .compress:
            switch kind {
            case .image: "Smaller file in the same format"
            case .video: "Smaller HEVC video"
            case .audio: "Smaller AAC audio file"
            case .pdf: "Shrinks the images inside"
            default: "Smaller files"
            }
        case .resize: options.resize.detail
        case .stripMetadata: "Removes location, camera and other hidden info"
        case .extractAudio: "Saves the soundtrack as M4A"
        case .removeBackground: "Keeps the subject, on a see-through PNG"
        case .extractText: kind == .pdf ? "All the text as a .txt file, scanned pages too" : "The text in the picture, as a .txt file"
        case .mute: "Removes the sound, keeps the picture"
        case .merge: "Joins the PDFs into one, in name order"
        case .split: "One PDF per page, in a folder"
        case .normalize: "Evens out the loudness (−16 LUFS, like streaming apps)"
        case .makeSearchable: "Scanned pages get their text, to search and copy"
        case .edit: "Your edits"
        case .editInfo: "Your changes to the file's info"
        case .editMedia: "Your edits"
        case .saveFrame: "One frame as a JPEG"
        case .protect: "Asks for a password to open"
        case .collage: "Several photos in one picture"
        case .organize: "The pages in your order"
        case .sizeLimit: "Smaller than the size you chose"
        case .archive: "All of them in one .zip file"
        case .extract: "Its files, in a folder beside it"
        case .blurPrivate: "Every face and all text, blurred out"
        case .visualize: "A video of the sound, to share"
        }
    }

    /// Goes in the output name: "photo (compressed).jpg".
    public func nameSuffix(options: ConversionOptions = ConversionOptions()) -> String {
        switch self {
        case .compress: "compressed"
        case .resize: options.resize.nameSuffix
        case .stripMetadata: "no metadata"
        case .extractAudio: "audio"
        case .removeBackground: "no background"
        case .extractText: "text"
        case .mute: "muted"
        case .merge: "merged"
        case .split: "pages"
        case .normalize: "normalized"
        case .makeSearchable: "searchable"
        case .edit, .editInfo, .editMedia: "edited"
        case .saveFrame: "frame"
        case .protect: "protected"
        case .collage: "collage"
        case .organize: "organized"
        case .sizeLimit: "smaller"
        case .archive: "zipped"
        case .extract: "extracted"
        case .blurPrivate: "blurred"
        case .visualize: "visualizer"
        }
    }
}

/// Wedges that open a window to choose the details first ("Crop…"). The
/// window then starts a job (see `tool`) with what was chosen.
public enum Editor: String, CaseIterable, Codable, Sendable {
    // The tabs of the image editor.
    case crop, adjust, background, markup, watermark
    case info
    /// The video and audio editor (trim, speed, turn, fades, loudness, GIF).
    case trim
    case password, collage, organize
    /// Under a chosen file size ("10 MB for email").
    case sizeLimit
    /// Many files renamed at once, by rules.
    case rename
    /// QR codes and barcodes in pictures, read out.
    case codes
    /// A sound into a video with moving bars.
    case visualizer

    public var title: String {
        switch self {
        case .crop: "Crop…"
        case .adjust: "Edit…"
        case .background: "Add BG…"
        case .markup: "Markup…"
        case .watermark: "Watermark…"
        case .info: "Info…"
        case .trim: "Edit…"
        case .password: "Password…"
        case .collage: "Collage…"
        case .organize: "Organize…"
        case .sizeLimit: "Size Limit…"
        case .rename: "Rename…"
        case .codes: "Read Codes…"
        case .visualizer: "Visualizer…"
        }
    }

    public var symbolName: String {
        switch self {
        case .crop: "crop"
        case .adjust: "slider.horizontal.3"
        case .background: "photo.artframe"
        case .markup: "pencil.tip.crop.circle"
        case .watermark: "signature"
        case .info: "info.circle"
        case .trim: "timeline.selection"
        case .password: "lock.doc"
        case .collage: "square.grid.2x2"
        case .organize: "rectangle.grid.2x2"
        case .sizeLimit: ToolAction.sizeLimit.symbolName
        case .rename: "character.cursor.ibeam"
        case .codes: "qrcode.viewfinder"
        case .visualizer: ToolAction.visualize.symbolName
        }
    }

    public func detail(for kind: FileKind?) -> String {
        switch self {
        case .crop: "Choose the shape and size, rotate or flip"
        case .adjust: "Light, color and filters"
        case .background: "Background, padding, corners and shadow"
        case .markup: "Arrows, shapes, text and blur-out"
        case .watermark: "Your name or logo on every picture"
        case .info:
            switch kind {
            case .image: "See and edit title, camera, date, place…"
            case .video, .audio: "See and edit title, artist and more"
            case .pdf: "See and edit title, author and more"
            default: "See and edit the details"
            }
        case .trim: kind == .audio ? "Trim, split, speed, fades, bleeps and channels" : "Trim, split, crop, speed, turn, sound and GIF"
        case .password: "Only people with the password can open it"
        case .collage: "Several photos in one: a grid, rows or a contact sheet"
        case .organize: "Reorder, turn or remove pages, from one PDF or several"
        case .sizeLimit: "Under a size you choose, like 10 MB for email"
        case .rename: "Many files at once: replace, number, dates, case…"
        case .codes: "QR codes and barcodes: copy the text or open the link"
        case .visualizer: "Moving bars over a picture: a video to share"
        }
    }
}

/// Finder chores for any files and folders: the file actions wheel.
public enum FileAction: String, CaseIterable, Codable, Sendable {
    case airDrop, copy, moveTo, copyPath, terminal, quickLook
    /// A floating shelf to park files on and drag them out later.
    case shelf

    public var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .copy: "Copy"
        case .moveTo: "Move To…"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        case .quickLook: "Quick Look"
        case .shelf: "Shelf"
        }
    }

    public var symbolName: String {
        switch self {
        case .airDrop: "dot.radiowaves.left.and.right"
        case .copy: "doc.on.doc"
        case .moveTo: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        case .quickLook: "eye"
        case .shelf: "tray.full"
        }
    }

    public var detail: String {
        switch self {
        case .airDrop: "Send them to a nearby iPhone, iPad or Mac"
        case .copy: "Then paste them in any Finder window"
        case .moveTo: "Choose a folder to move them to"
        case .copyPath: "Their full paths, to paste as text"
        case .terminal: "A Terminal window in their folder"
        case .quickLook: "A preview, as with the Space bar"
        case .shelf: "Parks them on a shelf; drag them off later"
        }
    }
}

/// Anything that can sit on a wedge.
public enum WheelAction: Hashable, Codable, Sendable {
    case convert(OutputFormat)
    case tool(ToolAction)
    /// Opens a window first (the window then starts a `.tool` job).
    case open(Editor)
    /// A custom action from Settings: several steps, one after the other.
    case recipe(Recipe)
    /// A Finder chore, done right away (no job).
    case file(FileAction)

    public var id: String {
        switch self {
        case .convert(let format): "convert.\(format.rawValue)"
        case .tool(let tool): "tool.\(tool.rawValue)"
        case .open(let editor): "open.\(editor.rawValue)"
        case .recipe(let recipe): "recipe.\(recipe.id.uuidString)"
        case .file(let action): "file.\(action.rawValue)"
        }
    }

    /// "Compress" sits on the PDF format wheel as "Smaller PDF"; Resize
    /// shows its chosen size.
    public func title(in mode: WheelMode, options: ConversionOptions = ConversionOptions()) -> String {
        switch self {
        case .convert(let format): format.title
        case .tool(.compress) where mode == .convert: "Smaller PDF"
        case .tool(.resize): options.resize.title
        case .tool(let tool): tool.title
        case .open(let editor): editor.title
        case .recipe(let recipe): recipe.name
        case .file(let action): action.title
        }
    }

    public func symbolName(in mode: WheelMode) -> String {
        switch self {
        case .convert(let format): format.symbolName
        case .tool(.compress) where mode == .convert: "arrow.down.doc"
        case .tool(let tool): tool.symbolName
        case .open(let editor): editor.symbolName
        case .recipe(let recipe): recipe.symbol
        case .file(let action): action.symbolName
        }
    }

    public func detail(for kind: FileKind?, options: ConversionOptions = ConversionOptions()) -> String {
        switch self {
        case .convert(let format): format.detail(from: kind)
        case .tool(let tool): tool.detail(for: kind, options: options)
        case .open(let editor): editor.detail(for: kind)
        case .recipe(let recipe): recipe.summary
        case .file(let action): action.detail
        }
    }
}
