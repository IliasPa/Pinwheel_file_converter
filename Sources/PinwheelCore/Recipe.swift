import Foundation

/// A custom action: several steps done one after the other on each file
/// (e.g. crop to 4:5, fit 1080 px, add a watermark, save as JPEG). Made in
/// Settings for one kind of file, it sits on that kind's tools wheel.
public struct Recipe: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var symbol: String
    public var kind: FileKind
    public var steps: [RecipeStep]

    public init(id: UUID = UUID(), name: String, symbol: String = "wand.and.stars", kind: FileKind, steps: [RecipeStep] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.kind = kind
        self.steps = steps
    }

    /// Symbols offered for custom actions.
    public static let symbols = [
        "wand.and.stars", "sparkles", "star", "heart", "bolt", "paperplane", "envelope", "camera", "photo.on.rectangle",
        "square.and.arrow.up", "film.stack", "music.note.list", "doc.richtext", "archivebox", "flag", "tag",
    ]

    /// "Crop 4:5 → Fit 1080 px → JPEG"
    public var summary: String {
        steps.isEmpty ? "No steps yet" : steps.map(\.title).joined(separator: " → ")
    }

    /// What kind of file each step gets (the first gets `kind`); nil once a
    /// step makes something that isn't a file Pinwheel works on (text, a folder).
    public var kindsBeforeSteps: [FileKind?] {
        var kinds: [FileKind?] = []
        var current: FileKind? = kind
        for step in steps {
            kinds.append(current)
            current = current.flatMap(step.outputKind)
        }
        return kinds
    }

    /// Why the recipe can't be used as it is, or nil when it can.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if steps.isEmpty { return "Add at least one step." }
        for (step, kind) in zip(steps, kindsBeforeSteps) {
            guard let kind else { return "“\(step.title)” comes after a step whose result can't be changed further." }
            if !step.works(on: kind) { return "“\(step.title)” doesn't work on \(kind.pluralTitle.lowercased())." }
        }
        return nil
    }

    /// Whether the result stands in for the original (so "Move the original
    /// to the Trash" applies): not when it ends with text taken from it.
    public var replacesOriginal: Bool {
        !steps.contains { $0 == .extractText }
    }

    /// A name that can go in a file name: "photo (Instagram).jpg".
    public var fileNameSuffix: String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "custom" : cleaned
    }
}

extension FileKind {
    /// "Images", "Videos"… for headings.
    public var pluralTitle: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        }
    }
}

/// One step of a custom action, with its own choices.
public enum RecipeStep: Codable, Sendable, Hashable {
    case convert(OutputFormat)
    case compress
    case sizeLimit(megabytes: Double)
    case resize(ResizeOption)
    case crop(AspectRatio)
    case turn(quarterTurns: Int)
    case flip
    case removeBackground
    case autoEnhance
    case filter(PhotoFilter)
    case frame(FrameStyle)
    case watermark(Watermark)
    case stripMetadata
    case removeLocation
    case extractText
    case makeSearchable
    case extractAudio
    case mute
    case normalize
    case speed(Double)
    case fade(inSeconds: Double, outSeconds: Double)
    case volume(decibels: Double)
    case turnVideo(quarterTurns: Int)

    /// The steps offered when adding one, with their usual choices.
    public static func templates(for kind: FileKind) -> [RecipeStep] {
        switch kind {
        case .image:
            [
                .crop(AspectRatio(4, 5)), .resize(.fit1920), .turn(quarterTurns: 1), .flip, .autoEnhance, .filter(.vivid),
                .removeBackground, .frame(Self.defaultFrame), .watermark(Watermark()), .removeLocation, .stripMetadata,
                .compress, .sizeLimit(megabytes: 2), .convert(.jpeg), .extractText,
            ]
        case .video:
            [
                .turnVideo(quarterTurns: 1), .speed(2), .mute, .fade(inSeconds: 1, outSeconds: 1), .normalize,
                .removeLocation, .stripMetadata, .compress, .sizeLimit(megabytes: 25), .convert(.mp4), .extractAudio,
            ]
        case .audio:
            [
                .normalize, .fade(inSeconds: 1, outSeconds: 2), .volume(decibels: 3), .speed(1.25), .stripMetadata,
                .compress, .sizeLimit(megabytes: 10), .convert(.mp3),
            ]
        case .pdf:
            [.makeSearchable, .compress, .sizeLimit(megabytes: 10), .stripMetadata, .extractText, .convert(.jpeg)]
        }
    }

    static var defaultFrame: FrameStyle {
        var frame = FrameStyle()
        frame.background = .color(.white)
        frame.padding = 0.06
        frame.cornerRadius = 0.04
        frame.shadow = 0.4
        return frame
    }

    /// The same kind of step, used to tell "Resize" apart from "Crop" in menus.
    public var name: String {
        switch self {
        case .convert: "Convert"
        case .compress: "Compress"
        case .sizeLimit: "Size Limit"
        case .resize: "Resize"
        case .crop: "Crop"
        case .turn: "Turn"
        case .flip: "Flip"
        case .removeBackground: "Remove Background"
        case .autoEnhance: "Auto Enhance"
        case .filter: "Filter"
        case .frame: "Background and Frame"
        case .watermark: "Watermark"
        case .stripMetadata: "Strip All Info"
        case .removeLocation: "Remove Location"
        case .extractText: "Get Text"
        case .makeSearchable: "Make Searchable"
        case .extractAudio: "Get Audio"
        case .mute: "Mute"
        case .normalize: "Even Out Loudness"
        case .speed: "Speed"
        case .fade: "Fade In and Out"
        case .volume: "Volume"
        case .turnVideo: "Turn"
        }
    }

    /// The step with its choice: "Crop 4:5", "Fit 1920 px", "JPEG".
    public var title: String {
        switch self {
        case .convert(let format): "To \(format.title)"
        case .sizeLimit(let megabytes): "Under \(SizeLimit.title(megabytes: megabytes))"
        case .resize(let option): option.title
        case .crop(let aspect): "Crop \(aspect.title)"
        case .turn(let turns), .turnVideo(let turns): turns == 2 ? "Turn 180°" : (turns == 3 ? "Turn Left" : "Turn Right")
        case .filter(let filter): "Filter: \(filter.title)"
        case .speed(let speed): "Speed \(MediaEdit.speedTitle(speed))"
        case .fade(let fadeIn, let fadeOut): "Fade \(Self.seconds(fadeIn)) / \(Self.seconds(fadeOut))"
        case .volume(let decibels): String(format: "Volume %+.0f dB", decibels)
        case .watermark(let mark): mark.kind == .logo ? "Logo Watermark" : "Watermark “\(mark.text)”"
        default: name
        }
    }

    private static func seconds(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    public var symbolName: String {
        switch self {
        case .convert(let format): format.symbolName
        case .compress: ToolAction.compress.symbolName
        case .sizeLimit: ToolAction.sizeLimit.symbolName
        case .resize: ToolAction.resize.symbolName
        case .crop: "crop"
        case .turn, .turnVideo: "rotate.right"
        case .flip: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .removeBackground: ToolAction.removeBackground.symbolName
        case .autoEnhance: "wand.and.stars"
        case .filter: "camera.filters"
        case .frame: "photo.artframe"
        case .watermark: "signature"
        case .stripMetadata: ToolAction.stripMetadata.symbolName
        case .removeLocation: "location.slash"
        case .extractText: ToolAction.extractText.symbolName
        case .makeSearchable: ToolAction.makeSearchable.symbolName
        case .extractAudio: ToolAction.extractAudio.symbolName
        case .mute: ToolAction.mute.symbolName
        case .normalize: ToolAction.normalize.symbolName
        case .speed: "gauge.with.dots.needle.67percent"
        case .fade: "waveform.path.ecg"
        case .volume: "speaker.wave.3"
        }
    }

    /// Whether the step can work on this kind of file.
    public func works(on kind: FileKind) -> Bool {
        switch self {
        case .convert(let format):
            switch kind {
            case .image: [.png, .jpeg, .heic, .tiff, .gif, .pdf].contains(format)
            case .video: [.mp4, .mov, .gif, .m4a, .mp3].contains(format)
            case .audio: [.mp3, .m4a, .wav, .aiff, .flac].contains(format)
            case .pdf: [.png, .jpeg, .heic, .tiff].contains(format)
            }
        case .compress, .sizeLimit, .stripMetadata: true
        case .removeLocation: kind == .image || kind == .video
        case .resize, .crop, .turn, .flip, .removeBackground, .autoEnhance, .filter, .frame, .watermark: kind == .image
        case .extractText: kind == .image || kind == .pdf
        case .makeSearchable: kind == .pdf
        case .extractAudio, .mute, .turnVideo: kind == .video
        case .normalize, .speed, .fade, .volume: kind == .video || kind == .audio
        }
    }

    /// The kind of file the step makes, or nil when it makes something
    /// Pinwheel can't change further (a text file, a folder of pages).
    public func outputKind(from kind: FileKind) -> FileKind? {
        switch self {
        case .convert(let format):
            switch format {
            case .pdf: return .pdf
            case .gif, .png, .jpeg, .heic, .tiff: return kind == .pdf ? nil : .image  // a PDF's pages may become a folder
            case .m4a, .mp3, .wav, .aiff, .flac: return .audio
            case .mp4, .mov: return .video
            }
        case .extractText: return nil
        case .extractAudio: return .audio
        default: return kind
        }
    }

    /// The job that does this step on one file.
    public func job(for file: SourceFile) -> (action: WheelAction, parameters: JobParameters?) {
        switch self {
        case .convert(let format): return (.convert(format), nil)
        case .compress: return (.tool(.compress), nil)
        case .sizeLimit(let megabytes): return (.tool(.sizeLimit), .sizeLimit(bytes: SizeLimit.bytes(megabytes: megabytes)))
        case .resize: return (.tool(.resize), nil)  // the size goes in the options (see RecipeRunner)
        case .crop(let aspect):
            var edit = ImageEdit()
            edit.aspect = aspect
            return (.tool(.edit), .image(edit))
        case .turn(let turns):
            var edit = ImageEdit()
            edit.quarterTurns = ((turns % 4) + 4) % 4
            return (.tool(.edit), .image(edit))
        case .flip:
            var edit = ImageEdit()
            edit.mirrored = true
            return (.tool(.edit), .image(edit))
        case .removeBackground: return (.tool(.removeBackground), nil)
        case .autoEnhance:
            var edit = ImageEdit()
            edit.adjustments.auto = true
            return (.tool(.edit), .image(edit))
        case .filter(let filter):
            var edit = ImageEdit()
            edit.adjustments.filter = filter
            return (.tool(.edit), .image(edit))
        case .frame(let style):
            var edit = ImageEdit()
            edit.frame = style
            return (.tool(.edit), .image(edit))
        case .watermark(let mark):
            var edit = ImageEdit()
            edit.watermark = mark
            return (.tool(.edit), .image(edit))
        case .stripMetadata: return (.tool(.stripMetadata), nil)
        case .removeLocation: return (.tool(.editInfo), .metadata(MetadataEdit(removeLocation: true)))
        case .extractText: return (.tool(.extractText), nil)
        case .makeSearchable: return (.tool(.makeSearchable), nil)
        case .extractAudio: return (.tool(.extractAudio), nil)
        case .mute: return (.tool(.mute), nil)
        case .normalize: return (.tool(.normalize), nil)
        case .speed(let speed):
            var edit = MediaEdit()
            edit.speed = speed
            return (.tool(.editMedia), .media(edit))
        case .fade(let fadeIn, let fadeOut):
            var edit = MediaEdit()
            edit.fadeIn = fadeIn
            edit.fadeOut = fadeOut
            return (.tool(.editMedia), .media(edit))
        case .volume(let decibels):
            var edit = MediaEdit()
            edit.volume = decibels
            return (.tool(.editMedia), .media(edit))
        case .turnVideo(let turns):
            var edit = MediaEdit()
            edit.quarterTurns = ((turns % 4) + 4) % 4
            return (.tool(.editMedia), .media(edit))
        }
    }
}

/// Runs a custom action on one file: each step makes a new file in a
/// private folder, which the next step starts from. A step with nothing to
/// do (a picture already small enough) is passed over, with a note.
enum RecipeRunner {
    static func run(
        _ recipe: Recipe, file: SourceFile, destination: URL, baseName: String, suffix: String, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (output: URL, note: String?) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var current = file
        var notes: [String] = []
        var changed = false
        let naming = OutputNaming()
        for (number, step) in recipe.steps.enumerated() {
            try Task.checkCancellation()
            guard let kind = current.kind, step.works(on: kind) else {
                throw ConversionError.failed("“\(step.title)” can't be done on \(current.url.lastPathComponent).")
            }
            let folder = work.appendingPathComponent("\(number + 1)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var stepOptions = options
            stepOptions.saveLocation = .folder(folder)
            stepOptions.fallbackFolder = folder
            if case .resize(let size) = step { stepOptions.resize = size }
            let (action, parameters) = step.job(for: current)
            let request = ConversionRequest(file: current, action: action, parameters: parameters)
            let total = Double(recipe.steps.count)
            let result = try await ConversionEngine.run(request, options: stepOptions, naming: naming) { value in
                progress((Double(number) + value) / total * 0.98)
            }
            if let output = result.outputs.first {
                current = SourceFile(url: output)
                changed = true
            } else if let note = result.note {
                notes.append("\(step.title): \(note)")
            }
        }
        guard changed else {
            throw NothingToDo(reason: notes.isEmpty ? "None of the steps changed anything, so nothing was saved." : notes.joined(separator: " "))
        }
        let output = try place(current.url, at: destination, baseName: baseName, suffix: suffix)
        return (output, notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Moves the result to `destination`, or, when the steps made another
    /// kind of file than expected (a folder of pages, another extension),
    /// to a free name beside it that fits.
    static func place(_ result: URL, at destination: URL, baseName: String, suffix: String) throws -> URL {
        let isFolder = (try? result.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let expectedExtension = destination.pathExtension
        let actualExtension = isFolder ? "" : result.pathExtension
        if expectedExtension.lowercased() == actualExtension.lowercased(),
           (try? FileManager.default.moveItem(at: result, to: destination)) != nil {
            return destination
        }
        let folder = destination.deletingLastPathComponent()
        for attempt in 1...999 {
            let candidate = OutputNaming.candidate(
                in: folder, baseName: baseName, suffix: suffix,
                fileExtension: isFolder || actualExtension.isEmpty ? nil : actualExtension, attempt: attempt
            )
            if (try? FileManager.default.moveItem(at: result, to: candidate)) != nil { return candidate }
        }
        throw ConversionError.cannotWrite(destination.lastPathComponent)
    }
}
