import Foundation

/// Which wedges each kind of file gets.
public enum FormatCatalog {
    public static func actions(for kind: FileKind, mode: WheelMode) -> [WheelAction] {
        switch (kind, mode) {
        case (.image, .convert):
            [.convert(.png), .convert(.jpeg), .convert(.heic), .convert(.tiff), .convert(.gif), .convert(.pdf)]
        case (.video, .convert):
            [.convert(.mp4), .convert(.mov), .convert(.gif), .convert(.m4a), .convert(.mp3)]
        case (.audio, .convert):
            [.convert(.mp3), .convert(.m4a), .convert(.wav), .convert(.aiff), .convert(.flac)]
        case (.pdf, .convert):
            [.convert(.png), .convert(.jpeg), .convert(.heic), .convert(.tiff), .tool(.compress)]
        case (.image, .tools):
            [.tool(.compress), .tool(.resize), .tool(.stripMetadata)]
        case (.video, .tools):
            [.tool(.compress), .tool(.stripMetadata), .tool(.extractAudio)]
        case (.audio, .tools):
            [.tool(.compress), .tool(.stripMetadata)]
        case (.pdf, .tools):
            [.tool(.compress), .tool(.stripMetadata)]
        }
    }

    /// Wedges valid for *every* file. Files Pinwheel can't handle (folders,
    /// text files…) leave nothing in common, so the wheel shows no wedges.
    /// Converting a file to the format it already has is left out.
    public static func actions(for files: [SourceFile], mode: WheelMode) -> [WheelAction] {
        guard !files.isEmpty else { return [] }
        let kinds = files.map(\.kind)
        guard !kinds.contains(nil) else { return [] }

        var result = actions(for: kinds[0]!, mode: mode)
        for kind in Set(kinds.compactMap { $0 }) {
            let allowed = Set(actions(for: kind, mode: mode))
            result.removeAll { !allowed.contains($0) }
        }
        if mode == .convert {
            let formats = Set(files.map(\.format))
            if formats.count == 1, let only = formats.first! {
                result.removeAll { $0 == .convert(only) }
            }
        }
        return result
    }

    /// "3 images", or "3 files" when they're mixed.
    public static func summary(for files: [SourceFile]) -> String {
        let kinds = Set(files.map(\.kind))
        if kinds.count == 1, let kind = kinds.first!, !files.isEmpty {
            return kind.countLabel(files.count)
        }
        return files.count == 1 ? "1 file" : "\(files.count) files"
    }

    public static func symbolName(for files: [SourceFile]) -> String {
        let kinds = Set(files.map(\.kind))
        if kinds.count == 1, let kind = kinds.first! { return kind.symbolName }
        return "doc.on.doc"
    }
}
