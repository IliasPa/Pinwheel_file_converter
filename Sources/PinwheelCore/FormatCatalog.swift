import Foundation

/// Which wedges each kind of file gets.
public enum FormatCatalog {
    /// The most wedges a wheel shows. More get too small to hit easily.
    public static let maxWedges = 9

    /// Everything a kind of file can get, in wheel order (clockwise from the
    /// top). Images have more tools than fit; Settings chooses which show.
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
            [
                .tool(.compress), .tool(.resize), .tool(.removeBackground), .open(.crop),
                .open(.adjust), .open(.background), .open(.markup), .open(.watermark), .open(.info),
                .tool(.stripMetadata), .tool(.extractText),
            ]
        case (.video, .tools):
            [.tool(.compress), .tool(.stripMetadata), .tool(.extractAudio), .tool(.mute), .open(.trim), .open(.info)]
        case (.audio, .tools):
            [.tool(.compress), .tool(.stripMetadata), .tool(.normalize), .open(.trim), .open(.info)]
        case (.pdf, .tools):
            [
                .tool(.compress), .tool(.stripMetadata), .tool(.merge), .tool(.split), .open(.organize),
                .tool(.extractText), .open(.password), .open(.info),
            ]
        }
    }

    /// Tools left off the wheel until switched on in Settings. Images have
    /// eleven; these two have a stand-in (Info… can remove the info too).
    public static let defaultHidden: Set<String> = [
        hiddenKey(.image, .tool(.stripMetadata)),
        hiddenKey(.image, .tool(.extractText)),
    ]

    /// How a hidden tool is remembered: "image:tool.stripMetadata".
    public static func hiddenKey(_ kind: FileKind, _ action: WheelAction) -> String {
        "\(kind.rawValue):\(action.id)"
    }

    /// Wedges valid for *every* file, minus hidden tools, at most `maxWedges`.
    /// Files Pinwheel can't handle (folders, text files…) leave nothing in
    /// common, so the wheel shows no wedges. Converting a file to the format
    /// it already has is left out.
    public static func actions(for files: [SourceFile], mode: WheelMode, hidden: Set<String> = []) -> [WheelAction] {
        guard !files.isEmpty else { return [] }
        let kinds = files.map(\.kind)
        guard !kinds.contains(nil) else { return [] }

        func visible(_ kind: FileKind) -> [WheelAction] {
            actions(for: kind, mode: mode).filter { !hidden.contains(hiddenKey(kind, $0)) }
        }
        var result = visible(kinds[0]!)
        for kind in Set(kinds.compactMap { $0 }) {
            let allowed = Set(visible(kind))
            result.removeAll { !allowed.contains($0) }
        }
        if mode == .convert {
            let formats = Set(files.map(\.format))
            if formats.count == 1, let only = formats.first! {
                result.removeAll { $0 == .convert(only) }
            }
            // Several pictures can also become one.
            if files.count > 1 && kinds.allSatisfy({ $0 == .image }) {
                result.append(.open(.collage))
            }
        }
        return Array(result.prefix(maxWedges))
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
