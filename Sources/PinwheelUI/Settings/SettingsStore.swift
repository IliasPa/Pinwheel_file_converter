import Foundation
import Observation
import PinwheelCore

/// Where new files go, as chosen in Settings.
enum SaveLocationChoice: String, CaseIterable {
    case nextToOriginal, downloads, custom

    var title: String {
        switch self {
        case .nextToOriginal: "Next to the original"
        case .downloads: "In Downloads"
        case .custom: "In a folder I choose"
        }
    }
}

/// Which engine reads text in pictures and scanned pages.
enum TextRecognitionChoice: String, CaseIterable {
    case automatic, apple, tesseract

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .apple: "Apple (built in)"
        case .tesseract: "Tesseract"
        }
    }
}

/// Saved rename rules, offered again in the Rename window.
struct RenamePreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var rules: [RenameRule]
}

/// Every setting, saved in the app's preferences as soon as it changes.
@Observable
final class SettingsStore {
    private enum Key: String {
        case glassLevel, hapticFeedback, hoverSound, hoverSoundName, hoverSoundVolume
        case showProgressWindow, revealInFinder, moveOriginalToTrash, notifyWhenDone
        case saveLocation, customFolderPath
        case jpegQuality, heicQuality, compressQuality, resize, combineImagesIntoOnePDF, pdfDPI
        case videoQuality, videoMaxSize, audioBitRate, gifWidth, gifFPS, gifMaxSeconds
        case maxConcurrentJobs, ffmpegPath
        case hiddenTools, knownTools, hiddenFormats
        case textRecognition
    }

    @ObservationIgnored private let defaults: UserDefaults

    // Appearance and feedback
    var glassLevel: GlassLevel { didSet { save(glassLevel.rawValue, .glassLevel) } }
    var hapticFeedback: Bool { didSet { save(hapticFeedback, .hapticFeedback) } }
    var hoverSound: Bool { didSet { save(hoverSound, .hoverSound) } }
    var hoverSoundName: String { didSet { save(hoverSoundName, .hoverSoundName) } }
    /// 0...1
    var hoverSoundVolume: Double { didSet { save(hoverSoundVolume, .hoverSoundVolume) } }

    // After converting
    var showProgressWindow: Bool { didSet { save(showProgressWindow, .showProgressWindow) } }
    var revealInFinder: Bool { didSet { save(revealInFinder, .revealInFinder) } }
    /// After a successful conversion, put the original file in the Trash.
    var moveOriginalToTrash: Bool { didSet { save(moveOriginalToTrash, .moveOriginalToTrash) } }
    /// A macOS notification when a conversion took 10 seconds or more.
    var notifyWhenDone: Bool { didSet { save(notifyWhenDone, .notifyWhenDone) } }
    var saveLocation: SaveLocationChoice { didSet { save(saveLocation.rawValue, .saveLocation) } }
    var customFolderPath: String { didSet { save(customFolderPath, .customFolderPath) } }

    // Images and PDFs
    var jpegQuality: Double { didSet { save(jpegQuality, .jpegQuality) } }
    var heicQuality: Double { didSet { save(heicQuality, .heicQuality) } }
    var compressQuality: Double { didSet { save(compressQuality, .compressQuality) } }
    var resize: ResizeOption { didSet { save(resize.rawValue, .resize) } }
    var combineImagesIntoOnePDF: Bool { didSet { save(combineImagesIntoOnePDF, .combineImagesIntoOnePDF) } }
    var pdfDPI: Int { didSet { save(pdfDPI, .pdfDPI) } }

    // Video and audio
    var videoQuality: VideoQuality { didSet { save(videoQuality.rawValue, .videoQuality) } }
    var videoMaxSize: VideoMaxSize { didSet { save(videoMaxSize.rawValue, .videoMaxSize) } }
    /// kbps
    var audioBitRate: Int { didSet { save(audioBitRate, .audioBitRate) } }
    var gifWidth: Int { didSet { save(gifWidth, .gifWidth) } }
    var gifFPS: Int { didSet { save(gifFPS, .gifFPS) } }
    /// 0 means no limit.
    var gifMaxSeconds: Int { didSet { save(gifMaxSeconds, .gifMaxSeconds) } }

    // System
    /// Files converted at the same time; 0 means automatic.
    var maxConcurrentJobs: Int { didSet { save(maxConcurrentJobs, .maxConcurrentJobs) } }
    /// Empty means "find ffmpeg automatically".
    var ffmpegPath: String { didSet { save(ffmpegPath, .ffmpegPath) } }

    // The wheels
    /// Tools left off the Option+Shift wheel ("image:tool.stripMetadata").
    var hiddenTools: Set<String> { didSet { save(Array(hiddenTools).sorted(), .hiddenTools) } }
    /// Formats left off the Shift wheel ("image:convert.tiff").
    var hiddenFormats: Set<String> { didSet { save(Array(hiddenFormats).sorted(), .hiddenFormats) } }
    /// Custom actions, each on its kind's tools wheel.
    var recipes: [Recipe] { didSet { saveJSON(recipes, Self.recipesKey) } }
    /// Rename rules saved under a name.
    var renamePresets: [RenamePreset] { didSet { saveJSON(renamePresets, Self.renamePresetsKey) } }

    // Text recognition
    var textRecognition: TextRecognitionChoice { didSet { save(textRecognition.rawValue, .textRecognition) } }
    /// Bumped when a language file is added, so views showing what's installed refresh.
    var languagesChanged = 0

    private static let factory = ConversionOptions()

    private static var defaultValues: [Key: Any] {
        let factory = Self.factory
        return [
            .glassLevel: GlassLevel.defaultLevel.rawValue,
            .hapticFeedback: true,
            .hoverSound: true,
            .hoverSoundName: "Tink",
            .hoverSoundVolume: 0.5,
            .showProgressWindow: true,
            .revealInFinder: true,
            .moveOriginalToTrash: false,
            .notifyWhenDone: true,
            .saveLocation: SaveLocationChoice.nextToOriginal.rawValue,
            .customFolderPath: "",
            .jpegQuality: factory.jpegQuality,
            .heicQuality: factory.heicQuality,
            .compressQuality: factory.compressQuality,
            .resize: factory.resize.rawValue,
            .combineImagesIntoOnePDF: factory.combineImagesIntoOnePDF,
            .pdfDPI: Int(factory.pdfDPI),
            .videoQuality: factory.videoQuality.rawValue,
            .videoMaxSize: factory.videoMaxSize.rawValue,
            .audioBitRate: factory.audioBitRate / 1000,
            .gifWidth: factory.gifWidth,
            .gifFPS: factory.gifFPS,
            .gifMaxSeconds: factory.gifMaxSeconds ?? 0,
            .maxConcurrentJobs: 0,
            .ffmpegPath: "",
            .hiddenTools: Array(FormatCatalog.defaultHidden).sorted(),
            .hiddenFormats: [String](),
            .textRecognition: TextRecognitionChoice.automatic.rawValue,
        ]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Self.defaultValues.map { ($0.key.rawValue, $0.value) }))
        func string(_ key: Key) -> String { defaults.string(forKey: key.rawValue) ?? "" }

        glassLevel = GlassLevel(rawValue: defaults.integer(forKey: Key.glassLevel.rawValue)) ?? .defaultLevel
        hapticFeedback = defaults.bool(forKey: Key.hapticFeedback.rawValue)
        hoverSound = defaults.bool(forKey: Key.hoverSound.rawValue)
        hoverSoundName = string(.hoverSoundName)
        hoverSoundVolume = defaults.double(forKey: Key.hoverSoundVolume.rawValue)
        showProgressWindow = defaults.bool(forKey: Key.showProgressWindow.rawValue)
        revealInFinder = defaults.bool(forKey: Key.revealInFinder.rawValue)
        moveOriginalToTrash = defaults.bool(forKey: Key.moveOriginalToTrash.rawValue)
        notifyWhenDone = defaults.bool(forKey: Key.notifyWhenDone.rawValue)
        saveLocation = SaveLocationChoice(rawValue: string(.saveLocation)) ?? .nextToOriginal
        customFolderPath = string(.customFolderPath)
        jpegQuality = defaults.double(forKey: Key.jpegQuality.rawValue)
        heicQuality = defaults.double(forKey: Key.heicQuality.rawValue)
        compressQuality = defaults.double(forKey: Key.compressQuality.rawValue)
        resize = ResizeOption(rawValue: string(.resize)) ?? .half
        combineImagesIntoOnePDF = defaults.bool(forKey: Key.combineImagesIntoOnePDF.rawValue)
        pdfDPI = defaults.integer(forKey: Key.pdfDPI.rawValue)
        videoQuality = VideoQuality(rawValue: string(.videoQuality)) ?? .balanced
        videoMaxSize = VideoMaxSize(rawValue: string(.videoMaxSize)) ?? .original
        audioBitRate = defaults.integer(forKey: Key.audioBitRate.rawValue)
        gifWidth = defaults.integer(forKey: Key.gifWidth.rawValue)
        gifFPS = defaults.integer(forKey: Key.gifFPS.rawValue)
        gifMaxSeconds = defaults.integer(forKey: Key.gifMaxSeconds.rawValue)
        maxConcurrentJobs = defaults.integer(forKey: Key.maxConcurrentJobs.rawValue)
        ffmpegPath = string(.ffmpegPath)
        hiddenTools = Set(defaults.stringArray(forKey: Key.hiddenTools.rawValue) ?? [])
        hiddenFormats = Set(defaults.stringArray(forKey: Key.hiddenFormats.rawValue) ?? [])
        recipes = Self.loadJSON(defaults, Self.recipesKey) ?? []
        renamePresets = Self.loadJSON(defaults, Self.renamePresetsKey) ?? []
        textRecognition = TextRecognitionChoice(rawValue: string(.textRecognition)) ?? .automatic
        placeNewTools()
    }

    /// Tools added by an update join the wheel where there's room. Where
    /// the wheel was arranged by hand and is full, they wait in Settings
    /// (switched off) instead of pushing out a tool that was chosen.
    private func placeNewTools() {
        let everyTool = FileKind.allCases.flatMap { kind in
            FormatCatalog.actions(for: kind, mode: .tools).map { FormatCatalog.hiddenKey(kind, $0) }
        }
        let stored = defaults.stringArray(forKey: Key.knownTools.rawValue)
        var known = Set(stored ?? [])
        if stored == nil {
            // First start of 0.9: a kind still hiding exactly what 0.8 hid by
            // default gets 0.9's choice; the tools before 0.9 are known.
            for kind in FileKind.allCases {
                let mine = hiddenTools.filter { $0.hasPrefix("\(kind.rawValue):") }
                let oldDefault = Self.defaultsBefore09.filter { $0.hasPrefix("\(kind.rawValue):") }
                if mine == oldDefault {
                    hiddenTools.subtract(mine)
                    hiddenTools.formUnion(FormatCatalog.defaultHidden.filter { $0.hasPrefix("\(kind.rawValue):") })
                }
            }
            known = Self.toolsBefore09
        }
        let fresh = everyTool.filter { !known.contains($0) }
        for kind in FileKind.allCases {
            let tools = FormatCatalog.actions(for: kind, mode: .tools).map { FormatCatalog.hiddenKey(kind, $0) }
            var shown = tools.filter { !hiddenTools.contains($0) }
            // The newest go first, so the wheel keeps what it had.
            for key in tools.reversed() where shown.count > FormatCatalog.maxWedges && fresh.contains(key) && shown.contains(key) {
                hiddenTools.insert(key)
                shown.removeAll { $0 == key }
            }
        }
        defaults.set(everyTool.sorted(), forKey: Key.knownTools.rawValue)
    }

    /// What 0.8 hid by default, and every tool it had.
    private static let defaultsBefore09: Set<String> = ["image:tool.stripMetadata", "image:tool.extractText"]
    private static let toolsBefore09: Set<String> = [
        "image:tool.compress", "image:tool.resize", "image:tool.removeBackground", "image:open.crop", "image:open.adjust",
        "image:open.background", "image:open.markup", "image:open.watermark", "image:open.info", "image:tool.stripMetadata",
        "image:tool.extractText", "video:tool.compress", "video:tool.stripMetadata", "video:tool.extractAudio", "video:tool.mute",
        "video:open.trim", "video:open.info", "audio:tool.compress", "audio:tool.stripMetadata", "audio:tool.normalize",
        "audio:open.trim", "audio:open.info", "pdf:tool.compress", "pdf:tool.stripMetadata", "pdf:tool.merge", "pdf:tool.split",
        "pdf:open.organize", "pdf:tool.extractText", "pdf:open.password", "pdf:open.info",
    ]

    /// The ffmpeg to use: the custom path if it works, else the usual places.
    var ffmpegURL: URL? { FFmpeg.locate(customPath: ffmpegPath) }
    var pngquantURL: URL? { ExternalTool.pngquant.locate() }
    var tesseractURL: URL? { ExternalTool.tesseract.locate() }

    /// Tesseract's languages: in its own folder, plus any Pinwheel downloaded.
    var tesseractLanguages: Set<String> {
        _ = languagesChanged
        guard let program = tesseractURL else { return [] }
        return TesseractData.languages(in: TesseractData.builtInFolder(for: program))
            .union(TesseractData.languages(in: TesseractData.ownFolder))
    }

    /// How text is read, worked out from the choice and what's installed.
    /// Automatic means Tesseract once it can read Greek, else Apple's.
    var resolvedTextRecognition: TextRecognition {
        var recognition = TextRecognition()
        guard let program = tesseractURL, textRecognition != .apple else { return recognition }
        let own = TesseractData.languages(in: TesseractData.ownFolder)
        let builtIn = TesseractData.languages(in: TesseractData.builtInFolder(for: program))
        let available = own.union(builtIn)
        if textRecognition == .automatic && !available.contains("ell") { return recognition }
        recognition.engine = .tesseract
        recognition.tesseractURL = program
        // Pinwheel's folder links Tesseract's own files, so it has them all.
        if !own.isEmpty {
            try? TesseractData.linkBuiltIn(TesseractData.builtInFolder(for: program), into: TesseractData.ownFolder)
            recognition.dataFolder = TesseractData.ownFolder
        }
        let wanted = ["ell", "eng"].filter(available.contains)
        recognition.languages = wanted.isEmpty ? Array(available.sorted().prefix(1)) : wanted
        return recognition
    }

    var concurrencyLimit: ConcurrencyLimit {
        maxConcurrentJobs > 0 ? .fixed(maxConcurrentJobs) : .automatic
    }

    /// A snapshot of the settings for one job.
    var conversionOptions: ConversionOptions {
        var options = ConversionOptions()
        options.jpegQuality = jpegQuality
        options.heicQuality = heicQuality
        options.compressQuality = compressQuality
        options.resize = resize
        options.combineImagesIntoOnePDF = combineImagesIntoOnePDF
        options.pdfDPI = Double(pdfDPI)
        options.videoQuality = videoQuality
        options.videoMaxSize = videoMaxSize
        options.audioBitRate = audioBitRate * 1000
        options.gifWidth = gifWidth
        options.gifFPS = gifFPS
        options.gifMaxSeconds = gifMaxSeconds > 0 ? gifMaxSeconds : nil
        options.saveLocation = switch saveLocation {
        case .nextToOriginal: .nextToOriginal
        case .downloads: .downloads
        case .custom: customFolderPath.isEmpty ? .nextToOriginal : .folder(URL(fileURLWithPath: customFolderPath))
        }
        options.ffmpegURL = ffmpegURL
        options.pngquantURL = pngquantURL
        options.textRecognition = resolvedTextRecognition
        return options
    }

    func resetToDefaults() {
        for key in Self.defaultValues.keys {
            defaults.removeObject(forKey: key.rawValue)
        }
        let fresh = SettingsStore(defaults: defaults)
        glassLevel = fresh.glassLevel
        hapticFeedback = fresh.hapticFeedback
        hoverSound = fresh.hoverSound
        hoverSoundName = fresh.hoverSoundName
        hoverSoundVolume = fresh.hoverSoundVolume
        showProgressWindow = fresh.showProgressWindow
        revealInFinder = fresh.revealInFinder
        moveOriginalToTrash = fresh.moveOriginalToTrash
        notifyWhenDone = fresh.notifyWhenDone
        saveLocation = fresh.saveLocation
        customFolderPath = fresh.customFolderPath
        jpegQuality = fresh.jpegQuality
        heicQuality = fresh.heicQuality
        compressQuality = fresh.compressQuality
        resize = fresh.resize
        combineImagesIntoOnePDF = fresh.combineImagesIntoOnePDF
        pdfDPI = fresh.pdfDPI
        videoQuality = fresh.videoQuality
        videoMaxSize = fresh.videoMaxSize
        audioBitRate = fresh.audioBitRate
        gifWidth = fresh.gifWidth
        gifFPS = fresh.gifFPS
        gifMaxSeconds = fresh.gifMaxSeconds
        maxConcurrentJobs = fresh.maxConcurrentJobs
        ffmpegPath = fresh.ffmpegPath
        hiddenTools = fresh.hiddenTools
        hiddenFormats = fresh.hiddenFormats
        textRecognition = fresh.textRecognition
    }

    /// The last watermark saved from the image editor, offered again next time.
    var lastWatermark: Watermark? {
        get {
            defaults.data(forKey: Self.lastWatermarkKey).flatMap { try? JSONDecoder().decode(Watermark.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.lastWatermarkKey)
        }
    }

    private static let lastWatermarkKey = "lastWatermark"

    /// The size last chosen in Size Limit…, in megabytes.
    var lastSizeLimit: Double {
        get {
            let value = defaults.double(forKey: Self.lastSizeLimitKey)
            return value > 0 ? value : 10
        }
        set { defaults.set(newValue, forKey: Self.lastSizeLimitKey) }
    }

    private static let lastSizeLimitKey = "lastSizeLimit"

    /// The address last given in Send Feedback, offered again (kept on this Mac only).
    var feedbackEmail: String {
        get { defaults.string(forKey: Self.feedbackEmailKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.feedbackEmailKey) }
    }

    private static let feedbackEmailKey = "feedbackEmail"
    private static let recipesKey = "recipes"
    private static let renamePresetsKey = "renamePresets"

    // MARK: - Custom actions

    /// Adds or updates a custom action. A new one goes on its wheel when
    /// there's room; otherwise it waits, switched off, in Settings.
    func saveRecipe(_ recipe: Recipe) {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
            return
        }
        if shownCount(for: recipe.kind) >= FormatCatalog.maxWedges {
            hiddenTools.insert(FormatCatalog.hiddenKey(recipe.kind, .recipe(recipe)))
        }
        recipes.append(recipe)
    }

    func deleteRecipe(_ recipe: Recipe) {
        recipes.removeAll { $0.id == recipe.id }
        hiddenTools.remove(FormatCatalog.hiddenKey(recipe.kind, .recipe(recipe)))
    }

    /// Wedges on a kind's wheel: formats, or tools and custom actions.
    func shownCount(for kind: FileKind, in mode: WheelMode = .tools) -> Int {
        let wedges = FormatCatalog.choices(for: kind, mode: mode)
        let custom = mode == .tools ? recipes.filter { $0.kind == kind }.map(WheelAction.recipe) : []
        return (wedges + custom).filter { isOnWheel($0, for: kind, in: mode) }.count
    }

    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func loadJSON<T: Decodable>(_ defaults: UserDefaults, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// What's left off a wheel. Each wheel has its own: Compress off the
    /// PDF tools wheel leaves Smaller PDF on the PDF format wheel.
    func hidden(in mode: WheelMode) -> Set<String> {
        mode == .tools ? hiddenTools : hiddenFormats
    }

    /// Whether a tool (or, in `.convert`, a format) is on the wheel for this kind of file.
    func isOnWheel(_ action: WheelAction, for kind: FileKind, in mode: WheelMode = .tools) -> Bool {
        !hidden(in: mode).contains(FormatCatalog.hiddenKey(kind, action))
    }

    func setOnWheel(_ action: WheelAction, for kind: FileKind, in mode: WheelMode = .tools, _ shown: Bool) {
        let key = FormatCatalog.hiddenKey(kind, action)
        switch (mode, shown) {
        case (.tools, true): hiddenTools.remove(key)
        case (.tools, false): hiddenTools.insert(key)
        case (.convert, true): hiddenFormats.remove(key)
        case (.convert, false): hiddenFormats.insert(key)
        }
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
