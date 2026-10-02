import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import PinwheelCore

struct MediaConverterTests {
    private func tracks(_ url: URL) async throws -> (video: Int, audio: Int, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).count
        let audio = try await asset.loadTracks(withMediaType: .audio).count
        return (video, audio, try await asset.load(.duration).seconds)
    }

    // MARK: - AVFoundation / Core Audio (no ffmpeg)

    @Test func videoToMP4KeepsPictureAndSound() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source)
        #expect(!ConversionEngine.usesFFmpeg(.convert(.mp4), for: SourceFile(url: source)))

        let recorder = ProgressRecorder()
        let output = try await runConversion(source, .convert(.mp4), progress: recorder.record)
        #expect(output.lastPathComponent == "clip (converted).mp4")
        let info = try await tracks(output)
        #expect(info.video == 1 && info.audio == 1)
        #expect(abs(info.seconds - 1) < 0.2)
        #expect(recorder.values.last == 1)
    }

    @Test func mp4ToMOV() async throws {
        let folder = try TempFolder()
        let mov = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: mov)
        let mp4 = try await runConversion(mov, .convert(.mp4))
        let back = try await runConversion(mp4, .convert(.mov))
        #expect(back.lastPathComponent == "clip (converted) (converted).mov")
        #expect(try await tracks(back).video == 1)
    }

    @Test func videoToM4AKeepsOnlyTheSound() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source)
        let output = try await runConversion(source, .convert(.m4a))
        let info = try await tracks(output)
        #expect(info.video == 0 && info.audio == 1)
    }

    @Test func silentVideoToM4AExplainsWhy() async throws {
        let folder = try TempFolder()
        let source = folder.file("silent.mov")
        try await MediaFixtures.makeVideo(at: source, withAudio: false)
        await #expect(throws: ConversionError.self) {
            try await runConversion(source, .convert(.m4a))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.file("silent (converted).m4a").path))
    }

    @Test(arguments: [OutputFormat.m4a, .aiff, .flac, .wav])
    func audioConversions(format: OutputFormat) async throws {
        let folder = try TempFolder()
        let source = folder.file("tone.\(format == .wav ? "aiff" : "wav")")
        if format == .wav {
            let wav = folder.file("tmp.wav")
            try MediaFixtures.makeWAV(at: wav)
            try AudioFileConverter.convert(wav, to: .aiff, destination: source) { _ in }
        } else {
            try MediaFixtures.makeWAV(at: source)
        }
        #expect(!ConversionEngine.usesFFmpeg(.convert(format), for: SourceFile(url: source)))

        let output = try await runConversion(source, .convert(format))
        #expect(output.pathExtension == format.fileExtension)
        let file = try AVAudioFile(forReading: output)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 1) < 0.1)
        #expect(file.fileFormat.channelCount == 2)
        let expectedID: AudioFormatID = switch format {
        case .m4a: kAudioFormatMPEG4AAC
        case .flac: kAudioFormatFLAC
        default: kAudioFormatLinearPCM
        }
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == expectedID)
    }

    // MARK: - ffmpeg

    @Test(.enabled(if: ffmpegInstalled))
    func videoToAnimatedGIF() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source)
        #expect(ConversionEngine.usesFFmpeg(.convert(.gif), for: SourceFile(url: source)))
        let output = try await runConversion(source, .convert(.gif))
        let gif = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(gif) > 5)
        #expect(CGImageSourceGetType(gif) as String? == "com.compuserve.gif")
    }

    @Test(.enabled(if: ffmpegInstalled))
    func videoAndAudioToMP3() async throws {
        let folder = try TempFolder()
        let video = folder.file("clip.mov")
        let wav = folder.file("tone.wav")
        try await MediaFixtures.makeVideo(at: video)
        try MediaFixtures.makeWAV(at: wav)
        for source in [video, wav] {
            let output = try await runConversion(source, .convert(.mp3))
            #expect(output.pathExtension == "mp3")
            let file = try AVAudioFile(forReading: output)
            #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 1) < 0.15)
        }
    }

    @Test(.enabled(if: ffmpegInstalled))
    func mkvIsReadThroughFFmpeg() async throws {
        let folder = try TempFolder()
        let mov = folder.file("clip.mov")
        let mkv = folder.file("clip.mkv")
        try await MediaFixtures.makeVideo(at: mov)
        try await MediaFixtures.ffmpegTranscode(mov, to: mkv, arguments: ["-c", "copy"])
        let file = SourceFile(url: mkv)
        #expect(file.kind == .video && file.needsFFmpegToRead)
        #expect(FormatCatalog.actions(for: [file], mode: .convert).contains(.convert(.mp4)))

        let output = try await runConversion(mkv, .convert(.mp4))
        let info = try await tracks(output)
        #expect(info.video == 1 && info.audio == 1)
    }

    @Test(.enabled(if: ffmpegInstalled))
    func oggAudioConverts() async throws {
        let folder = try TempFolder()
        let wav = folder.file("tone.wav")
        let ogg = folder.file("tone.ogg")
        try MediaFixtures.makeWAV(at: wav, sampleRate: 48_000)
        try await MediaFixtures.ffmpegTranscode(wav, to: ogg, arguments: ["-c:a", "libopus", "-b:a", "64k"])
        // Newer macOS versions read Ogg Opus themselves; either way it must convert.
        #expect(SourceFile(url: ogg).kind == .audio)

        let output = try await runConversion(ogg, .convert(.wav))
        let file = try AVAudioFile(forReading: output)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 1) < 0.1)
    }

    @Test(.enabled(if: ffmpegInstalled))
    func cancellingStopsFFmpegAndDeletesThePartialFile() async throws {
        let folder = try TempFolder()
        let source = folder.file("long.mov")
        try await MediaFixtures.makeVideo(at: source, seconds: 40, width: 640, height: 480, withAudio: false)
        var options = ConversionOptions()
        options.gifWidth = 640
        options.gifMaxSeconds = nil
        let request = ConversionRequest(file: SourceFile(url: source), action: .convert(.gif))
        let job = Task { try await runRequest(request, options: options) }
        try await Task.sleep(for: .milliseconds(400))
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(left == ["long.mov"])
    }

    // MARK: - Availability

    @Test func ffmpegFormatsAreGrayedOutWithoutIt() throws {
        let video = SourceFile(url: URL(fileURLWithPath: "/tmp/a.mov"))
        let mkv = SourceFile(url: URL(fileURLWithPath: "/tmp/a.mkv"))
        #expect(ConversionEngine.availability(of: .convert(.mp4), for: [video], ffmpegAvailable: false) == .available)
        guard case .unavailable(let reason) = ConversionEngine.availability(of: .convert(.gif), for: [video], ffmpegAvailable: false) else {
            Issue.record("GIF from video should need ffmpeg")
            return
        }
        #expect(reason.contains("ffmpeg"))
        #expect(ConversionEngine.availability(of: .convert(.mp4), for: [mkv], ffmpegAvailable: false) != .available)
        #expect(ConversionEngine.availability(of: .convert(.mp4), for: [mkv], ffmpegAvailable: true) == .available)
    }

    @Test func ffmpegArgumentsDontUpscaleGIFs() {
        var options = ConversionOptions()
        options.gifWidth = 320
        options.gifFPS = 12
        let arguments = MediaConverter.ffmpegArguments(for: .gif, options: options)
        let filter = arguments.firstIndex(of: "-vf").map { arguments[$0 + 1] } ?? ""
        #expect(filter.hasPrefix("fps=12,scale='min(320,iw)'"))
    }
}

/// Collects progress values reported from background threads.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var record: @Sendable (Double) -> Void {
        { [self] value in
            lock.lock()
            stored.append(value)
            lock.unlock()
        }
    }
}
