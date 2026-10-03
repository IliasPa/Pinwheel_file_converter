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
    }

    /// The ffmpeg to use: the custom path if it works, else the usual places.
    var ffmpegURL: URL? { FFmpeg.locate(customPath: ffmpegPath) }
    var pngquantURL: URL? { ExternalTool.pngquant.locate() }

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
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
