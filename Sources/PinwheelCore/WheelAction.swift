import Foundation
import UniformTypeIdentifiers

/// A format Pinwheel can write.
public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case png, jpeg, heic, tiff, gif, pdf
    case mp4, mov
    case m4a, mp3, wav, aiff, flac

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
        }
    }

    public var title: String {
        switch self {
        case .m4a: "M4A"
        default: rawValue.uppercased()
        }
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
        }
    }

    /// One short line shown in the middle of the wheel while hovering.
    public func detail(from kind: FileKind?) -> String {
        switch self {
        case .png: kind == .pdf ? "One image per page, sharp and lossless" : "Lossless, keeps transparency"
        case .jpeg: kind == .pdf ? "One photo per page, small files" : "Small files, works everywhere"
        case .heic: "Half the size of JPEG, same quality"
        case .tiff: "Lossless, for print and editing"
        case .gif: kind == .video ? "Animated GIF of the clip" : "Works in any browser or chat"
        case .pdf: "A PDF page for each image"
        case .mp4: "Plays everywhere"
        case .mov: "QuickTime movie"
        case .m4a: kind == .video ? "Just the sound, AAC" : "AAC, small and good quality"
        case .mp3: kind == .video ? "Just the sound, MP3" : "Plays on any device"
        case .wav: "Uncompressed, universal"
        case .aiff: "Uncompressed, Apple"
        case .flac: "Lossless and compressed"
        }
    }

    /// The format a file already has, when it's one Pinwheel writes.
    public static func matching(_ url: URL) -> OutputFormat? {
        guard let type = FileKind.contentType(of: url) else { return nil }
        return allCases.first { $0.utType == type }
    }
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
            case nil: "Smaller files"
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
            case nil: "See and edit the details"
            }
        case .trim: kind == .audio ? "Trim, speed, fades and loudness" : "Trim, speed, turn, sound and GIF"
        case .password: "Only people with the password can open it"
        case .collage: "Several photos in one: a grid, rows or a contact sheet"
        case .organize: "Reorder, turn or remove pages, from one PDF or several"
        case .sizeLimit: "Under a size you choose, like 10 MB for email"
        case .rename: "Many files at once: replace, number, dates, case…"
        }
    }

    /// One of the image editor's tabs.
    public var isImageEditor: Bool {
        switch self {
        case .crop, .adjust, .background, .markup, .watermark: true
        case .info, .trim, .password, .collage, .organize, .sizeLimit, .rename: false
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

    public var id: String {
        switch self {
        case .convert(let format): "convert.\(format.rawValue)"
        case .tool(let tool): "tool.\(tool.rawValue)"
        case .open(let editor): "open.\(editor.rawValue)"
        case .recipe(let recipe): "recipe.\(recipe.id.uuidString)"
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
        }
    }

    public func symbolName(in mode: WheelMode) -> String {
        switch self {
        case .convert(let format): format.symbolName
        case .tool(.compress) where mode == .convert: "arrow.down.doc"
        case .tool(let tool): tool.symbolName
        case .open(let editor): editor.symbolName
        case .recipe(let recipe): recipe.symbol
        }
    }

    public func detail(for kind: FileKind?, options: ConversionOptions = ConversionOptions()) -> String {
        switch self {
        case .convert(let format): format.detail(from: kind)
        case .tool(let tool): tool.detail(for: kind, options: options)
        case .open(let editor): editor.detail(for: kind)
        case .recipe(let recipe): recipe.summary
        }
    }

    /// A short past-tense label for menus and the progress window.
    public var summary: String {
        switch self {
        case .convert(let format): "to \(format.title)"
        case .tool(let tool): tool.title
        case .open(let editor): editor.title
        case .recipe(let recipe): recipe.name
        }
    }
}
