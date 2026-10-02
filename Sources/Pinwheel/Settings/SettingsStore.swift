import Foundation
import PinwheelCore

/// Every setting, saved in the app's preferences as soon as it changes.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let glassLevel = "glassLevel"
        static let hapticFeedback = "hapticFeedback"
        static let hoverSound = "hoverSound"
        static let hoverSoundName = "hoverSoundName"
        static let hoverSoundVolume = "hoverSoundVolume"
        static let moveOriginalToTrash = "moveOriginalToTrash"
        static let showProgressWindow = "showProgressWindow"
        static let revealInFinder = "revealInFinder"
        static let jpegQuality = "jpegQuality"
        static let heicQuality = "heicQuality"
        static let compressQuality = "compressQuality"
        static let pdfDPI = "pdfDPI"
        static let gifWidth = "gifWidth"
        static let gifFPS = "gifFPS"
        static let ffmpegPath = "ffmpegPath"
    }

    private let defaults: UserDefaults
    private static let factory = ConversionOptions()

    @Published var glassLevel: GlassLevel { didSet { defaults.set(glassLevel.rawValue, forKey: Key.glassLevel) } }
    @Published var hapticFeedback: Bool { didSet { defaults.set(hapticFeedback, forKey: Key.hapticFeedback) } }
    @Published var hoverSound: Bool { didSet { defaults.set(hoverSound, forKey: Key.hoverSound) } }
    @Published var hoverSoundName: String { didSet { defaults.set(hoverSoundName, forKey: Key.hoverSoundName) } }
    /// 0...1
    @Published var hoverSoundVolume: Double { didSet { defaults.set(hoverSoundVolume, forKey: Key.hoverSoundVolume) } }
    /// After a successful conversion, put the original file in the Trash.
    @Published var moveOriginalToTrash: Bool { didSet { defaults.set(moveOriginalToTrash, forKey: Key.moveOriginalToTrash) } }
    @Published var showProgressWindow: Bool { didSet { defaults.set(showProgressWindow, forKey: Key.showProgressWindow) } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: Key.revealInFinder) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var heicQuality: Double { didSet { defaults.set(heicQuality, forKey: Key.heicQuality) } }
    @Published var compressQuality: Double { didSet { defaults.set(compressQuality, forKey: Key.compressQuality) } }
    @Published var pdfDPI: Int { didSet { defaults.set(pdfDPI, forKey: Key.pdfDPI) } }
    @Published var gifWidth: Int { didSet { defaults.set(gifWidth, forKey: Key.gifWidth) } }
    @Published var gifFPS: Int { didSet { defaults.set(gifFPS, forKey: Key.gifFPS) } }
    /// Empty means "find ffmpeg automatically".
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: Key.ffmpegPath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let factory = Self.factory
        defaults.register(defaults: [
            Key.glassLevel: GlassLevel.defaultLevel.rawValue,
            Key.hapticFeedback: true,
            Key.hoverSound: true,
            Key.hoverSoundName: "Tink",
            Key.hoverSoundVolume: 0.5,
            Key.moveOriginalToTrash: false,
            Key.showProgressWindow: true,
            Key.revealInFinder: true,
            Key.jpegQuality: factory.jpegQuality,
            Key.heicQuality: factory.heicQuality,
            Key.compressQuality: factory.compressQuality,
            Key.pdfDPI: Int(factory.pdfDPI),
            Key.gifWidth: factory.gifWidth,
            Key.gifFPS: factory.gifFPS,
            Key.ffmpegPath: "",
        ])
        glassLevel = GlassLevel(rawValue: defaults.integer(forKey: Key.glassLevel)) ?? GlassLevel.defaultLevel
        hapticFeedback = defaults.bool(forKey: Key.hapticFeedback)
        hoverSound = defaults.bool(forKey: Key.hoverSound)
        hoverSoundName = defaults.string(forKey: Key.hoverSoundName) ?? "Tink"
        hoverSoundVolume = defaults.double(forKey: Key.hoverSoundVolume)
        moveOriginalToTrash = defaults.bool(forKey: Key.moveOriginalToTrash)
        showProgressWindow = defaults.bool(forKey: Key.showProgressWindow)
        revealInFinder = defaults.bool(forKey: Key.revealInFinder)
        jpegQuality = defaults.double(forKey: Key.jpegQuality)
        heicQuality = defaults.double(forKey: Key.heicQuality)
        compressQuality = defaults.double(forKey: Key.compressQuality)
        pdfDPI = defaults.integer(forKey: Key.pdfDPI)
        gifWidth = defaults.integer(forKey: Key.gifWidth)
        gifFPS = defaults.integer(forKey: Key.gifFPS)
        ffmpegPath = defaults.string(forKey: Key.ffmpegPath) ?? ""
    }

    /// The ffmpeg to use: the custom path if it works, else the usual places.
    var ffmpegURL: URL? { FFmpeg.locate(customPath: ffmpegPath) }

    /// A snapshot of the settings for one job.
    var conversionOptions: ConversionOptions {
        var options = ConversionOptions()
        options.jpegQuality = jpegQuality
        options.heicQuality = heicQuality
        options.compressQuality = compressQuality
        options.pdfDPI = Double(pdfDPI)
        options.gifWidth = gifWidth
        options.gifFPS = gifFPS
        options.ffmpegURL = ffmpegURL
        return options
    }

    func resetToDefaults() {
        let factory = Self.factory
        glassLevel = GlassLevel.defaultLevel
        hapticFeedback = true
        hoverSound = true
        hoverSoundName = "Tink"
        hoverSoundVolume = 0.5
        moveOriginalToTrash = false
        showProgressWindow = true
        revealInFinder = true
        jpegQuality = factory.jpegQuality
        heicQuality = factory.heicQuality
        compressQuality = factory.compressQuality
        pdfDPI = Int(factory.pdfDPI)
        gifWidth = factory.gifWidth
        gifFPS = factory.gifFPS
        ffmpegPath = ""
    }
}
