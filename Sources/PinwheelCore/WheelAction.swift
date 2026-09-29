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

/// Extra jobs offered on the Option+Shift wheel.
public enum ToolAction: String, CaseIterable, Codable, Sendable {
    case compress
    case resizeHalf
    case stripMetadata
    case extractAudio

    public var title: String {
        switch self {
        case .compress: "Compress"
        case .resizeHalf: "Resize 50%"
        case .stripMetadata: "Strip Info"
        case .extractAudio: "Get Audio"
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: "rectangle.compress.vertical"
        case .resizeHalf: "arrow.down.right.and.arrow.up.left"
        case .stripMetadata: "tag.slash"
        case .extractAudio: "speaker.wave.2"
        }
    }

    public func detail(for kind: FileKind?) -> String {
        switch self {
        case .compress:
            switch kind {
            case .image: "Smaller file, still looks good"
            case .video: "Smaller HEVC video"
            case .audio: "Smaller AAC audio file"
            case .pdf: "Shrinks the images inside"
            case nil: "Smaller files"
            }
        case .resizeHalf: "Half the width and height"
        case .stripMetadata: "Removes location, camera and other hidden info"
        case .extractAudio: "Saves the soundtrack as M4A"
        }
    }

    /// Goes in the output name: "photo (compressed).jpg".
    public var nameSuffix: String {
        switch self {
        case .compress: "compressed"
        case .resizeHalf: "50%"
        case .stripMetadata: "no metadata"
        case .extractAudio: "audio"
        }
    }
}

/// Anything that can sit on a wedge.
public enum WheelAction: Hashable, Codable, Sendable {
    case convert(OutputFormat)
    case tool(ToolAction)

    public var id: String {
        switch self {
        case .convert(let format): "convert.\(format.rawValue)"
        case .tool(let tool): "tool.\(tool.rawValue)"
        }
    }

    /// "Compress" sits on the PDF format wheel as "Smaller PDF".
    public func title(in mode: WheelMode) -> String {
        switch self {
        case .convert(let format): format.title
        case .tool(.compress) where mode == .convert: "Smaller PDF"
        case .tool(let tool): tool.title
        }
    }

    public func symbolName(in mode: WheelMode) -> String {
        switch self {
        case .convert(let format): format.symbolName
        case .tool(.compress) where mode == .convert: "arrow.down.doc"
        case .tool(let tool): tool.symbolName
        }
    }

    public func detail(for kind: FileKind?) -> String {
        switch self {
        case .convert(let format): format.detail(from: kind)
        case .tool(let tool): tool.detail(for: kind)
        }
    }

    /// A short past-tense label for menus and the progress window.
    public var summary: String {
        switch self {
        case .convert(let format): "to \(format.title)"
        case .tool(let tool): tool.title
        }
    }
}
