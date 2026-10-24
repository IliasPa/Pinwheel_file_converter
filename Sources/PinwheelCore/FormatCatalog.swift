import Foundation

/// Which wedges each kind of file gets.
public enum FormatCatalog {
    /// The most tools or file actions a wheel shows. More get too small to hit easily.
    public static let maxWedges = 9
    /// Format names are short, so the format wheel holds a few more.
    public static let maxFormats = 12

    public static func maxWedges(in mode: WheelMode) -> Int {
        mode == .convert ? maxFormats : maxWedges
    }

    /// Wedges only animated pictures get (GIF and the like): videos of them.
    public static let forAnimations: [WheelAction] = [.convert(.mp4), .convert(.webm)]

    /// The file actions wheel: the same for any files and folders.
    public static let fileActions: [WheelAction] = FileAction.allCases.map(WheelAction.file) + [.tool(.archive)]

    /// Everything a kind of file can get, in wheel order (clockwise from the
    /// top). Images have more tools than fit; Settings chooses which show.
    public static func actions(for kind: FileKind, mode: WheelMode) -> [WheelAction] {
        switch (kind, mode) {
        case (_, .actions):
            fileActions
        case (.image, .convert):
            [
                .convert(.png), .convert(.jpeg), .convert(.heic), .convert(.webp), .convert(.avif), .convert(.tiff),
                .convert(.gif), .convert(.bmp), .convert(.ico), .convert(.icns), .convert(.pdf),
            ]
        case (.video, .convert):
            [
                .convert(.mp4), .convert(.mov), .convert(.mkv), .convert(.webm), .convert(.avi), .convert(.wmv),
                .convert(.gif), .convert(.webp), .convert(.m4a), .convert(.mp3),
            ]
        case (.audio, .convert):
            [
                .convert(.mp3), .convert(.m4a), .convert(.wav), .convert(.aiff), .convert(.flac), .convert(.ogg),
                .convert(.opus), .convert(.wma),
            ]
        case (.pdf, .convert):
            [
                .convert(.png), .convert(.jpeg), .convert(.heic), .convert(.tiff), .tool(.compress), .convert(.docx),
                .convert(.pages), .convert(.pptx), .convert(.xlsx), .convert(.epub), .convert(.md), .convert(.txt),
            ]
        case (.document, .convert):
            [
                .convert(.pdf), .convert(.docx), .convert(.pages), .convert(.rtf), .convert(.odt), .convert(.md),
                .convert(.txt), .convert(.html), .convert(.epub),
            ]
        case (.spreadsheet, .convert):
            [.convert(.xlsx), .convert(.ods), .convert(.csv), .convert(.tsv), .convert(.pdf)]
        case (.presentation, .convert):
            [.convert(.pdf), .convert(.png), .convert(.jpeg), .convert(.pptx)]
        case (.subtitle, .convert):
            [.convert(.srt), .convert(.vtt), .convert(.txt)]
        case (.archive, .convert):
            [.tool(.extract), .convert(.zip), .convert(.tar), .convert(.tgz), .convert(.sevenZip)]
        case (.image, .tools):
            [
                .tool(.compress), .open(.sizeLimit), .tool(.resize), .tool(.removeBackground), .open(.crop),
                .open(.adjust), .open(.background), .open(.markup), .open(.watermark), .open(.info), .open(.rename),
                .tool(.stripMetadata), .tool(.extractText), .open(.codes), .tool(.blurPrivate),
            ]
        case (.video, .tools):
            [
                .tool(.compress), .open(.sizeLimit), .tool(.stripMetadata), .tool(.extractAudio), .tool(.mute),
                .open(.trim), .open(.info), .open(.rename),
            ]
        case (.audio, .tools):
            [
                .tool(.compress), .open(.sizeLimit), .tool(.stripMetadata), .tool(.normalize), .open(.trim), .open(.visualizer),
                .open(.info), .open(.rename),
            ]
        case (.pdf, .tools):
            [
                .tool(.compress), .open(.sizeLimit), .tool(.stripMetadata), .tool(.merge), .tool(.split), .open(.organize),
                .tool(.makeSearchable), .tool(.extractText), .open(.password), .open(.info), .open(.rename),
            ]
        case (.archive, .tools), (.document, .tools), (.spreadsheet, .tools), (.presentation, .tools), (.subtitle, .tools):
            [.open(.rename)]
        }
    }

    /// Tools left off the wheel until switched on in Settings. Each has a
    /// stand-in: Info… can remove the info too, Searchable makes a PDF's
    /// text copyable, and every tab of the image editor is one click away
    /// once it's open (from Crop… or Edit…).
    public static let defaultHidden: Set<String> = [
        hiddenKey(.image, .tool(.stripMetadata)),
        hiddenKey(.image, .tool(.extractText)),
        hiddenKey(.image, .open(.background)),
        hiddenKey(.image, .open(.markup)),
        hiddenKey(.image, .open(.codes)),
        hiddenKey(.image, .tool(.blurPrivate)),
        hiddenKey(.pdf, .tool(.stripMetadata)),
        hiddenKey(.pdf, .tool(.extractText)),
    ]

    /// Everything Settings lists for a kind's wheel: its wedges, plus
    /// Collage for pictures (it shows only when several are dropped).
    public static func choices(for kind: FileKind, mode: WheelMode) -> [WheelAction] {
        actions(for: kind, mode: mode) + (kind == .image && mode == .convert ? [.open(.collage)] + forAnimations : [])
    }

    /// How a hidden tool or format is remembered: "image:tool.stripMetadata".
    /// Each wheel has its own set, since Compress is on both PDF wheels.
    public static func hiddenKey(_ kind: FileKind, _ action: WheelAction) -> String {
        "\(kind.rawValue):\(action.id)"
    }

    /// Wedges valid for *every* file, minus hidden ones, at most `maxWedges`;
    /// custom actions (`recipes`) come after the tools. Files Pinwheel can't
    /// convert (folders, text files…) can still be renamed, so that's all
    /// their tools wheel has. Converting a file to the format it already has
    /// is left out.
    public static func actions(
        for files: [SourceFile], mode: WheelMode, hidden: Set<String> = [], recipes: [Recipe] = []
    ) -> [WheelAction] {
        guard !files.isEmpty else { return [] }
        if mode == .actions {
            // Any files and folders, whatever they are.
            return Array(fileActions.filter { !hidden.contains(actionKey($0)) }.prefix(maxWedges))
        }
        let kinds = files.map(\.kind)
        guard !kinds.contains(nil) else { return mode == .tools ? [.open(.rename)] : [] }

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
            // Animated pictures can also become videos.
            if kinds.allSatisfy({ $0 == .image }) && files.allSatisfy(\.isAnimated) {
                result += forAnimations.filter { !hidden.contains(hiddenKey(.image, $0)) }
            }
            // Several pictures can also become one.
            if files.count > 1 && kinds.allSatisfy({ $0 == .image }) && !hidden.contains(hiddenKey(.image, .open(.collage))) {
                result.append(.open(.collage))
            }
        } else {
            for recipe in recipes where kinds.allSatisfy({ $0 == recipe.kind }) {
                let action = WheelAction.recipe(recipe)
                if !hidden.contains(hiddenKey(recipe.kind, action)) { result.append(action) }
            }
        }
        return Array(result.prefix(maxWedges(in: mode)))
    }

    /// How a file action left off its wheel is remembered: "file.airDrop".
    public static func actionKey(_ action: WheelAction) -> String {
        action.id
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
