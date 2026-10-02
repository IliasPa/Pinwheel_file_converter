import AVFoundation
import Foundation

/// Video and audio conversions. Apple's frameworks do the work when they can;
/// ffmpeg only handles MP3, GIFs from video, and files AVFoundation can't open.
enum MediaConverter {
    /// Returns a note for the progress window (e.g. "only the first 15 seconds").
    static func convert(
        _ file: SourceFile,
        to format: OutputFormat,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        if ConversionEngine.usesFFmpeg(.convert(format), for: file) {
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            return try await convertWithFFmpeg(file, to: format, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
        }
        var note: String?
        try await appleThenFFmpeg(destination: destination, ffmpegURL: options.ffmpegURL) {
            try await convertWithApple(file, to: format, destination: destination, progress: progress)
        } ffmpeg: { ffmpeg in
            note = try await convertWithFFmpeg(file, to: format, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
        }
        return note
    }

    /// Apple's frameworks first. If they fail on a file they said they could
    /// read (some OGG or FLAC variants, unusual codecs), ffmpeg gets a try;
    /// if that fails too, the first (clearer) error is reported.
    static func appleThenFFmpeg(
        destination: URL,
        ffmpegURL: URL?,
        apple: () async throws -> Void,
        ffmpeg: (URL) async throws -> Void
    ) async throws {
        do {
            try await apple()
        } catch is CancellationError {
            throw CancellationError()
        } catch let skip as NothingToDo {
            throw skip
        } catch {
            let original = error
            guard let ffmpegURL else { throw original }
            try? FileManager.default.removeItem(at: destination)
            do {
                try await ffmpeg(ffmpegURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw original
            }
        }
    }

    private static func convertWithFFmpeg(
        _ file: SourceFile, to format: OutputFormat, destination: URL, ffmpeg: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        var arguments = ffmpegArguments(for: format, options: options)
        var duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg)
        var note: String?
        if format == .gif, let limit = options.gifMaxSeconds {
            arguments = ["-t", "\(limit)"] + arguments
            if let full = duration, full > Double(limit) + 0.5 {
                note = "Only the first \(limit) seconds (you can change this in Settings)."
            }
            duration = duration.map { min($0, Double(limit)) }
        }
        try await FFmpeg.convert(
            ffmpeg: ffmpeg, input: file.url, output: destination,
            arguments: arguments, duration: duration, progress: progress
        )
        return note
    }

    private static func convertWithApple(
        _ file: SourceFile, to format: OutputFormat, destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch format {
        case .mp4, .mov:
            try await convertVideo(file.url, to: format, destination: destination, progress: progress)
        case .m4a:
            try await exportAudioM4A(file.url, destination: destination, progress: progress)
        case .wav, .aiff, .flac:
            try AudioFileConverter.convert(file.url, to: format, destination: destination, progress: progress)
        default:
            throw ConversionError.unsupported("\(format.title) from \(file.url.lastPathComponent)")
        }
    }

    // MARK: - AVFoundation

    /// MP4/MOV. Copies the streams as they are (fast, no quality loss) when the
    /// new container allows it; otherwise re-encodes to H.264.
    static func convertVideo(
        _ source: URL, to format: OutputFormat, destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw ConversionError.failed("\(source.lastPathComponent) has no picture to convert.")
        }
        let fileType: AVFileType = format == .mp4 ? .mp4 : .mov

        var copyStreams = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType
        )
        if copyStreams && format == .mp4 {
            // "MP4" is picked for compatibility, which in practice means H.264.
            for track in videoTracks {
                let descriptions = try await track.load(.formatDescriptions)
                if descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) != kCMVideoCodecType_H264 }) {
                    copyStreams = false
                }
            }
        }
        if copyStreams {
            do {
                try await export(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: destination, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some files pass the check but still can't be copied; re-encode instead.
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try await export(asset, preset: AVAssetExportPresetHighestQuality, fileType: fileType, to: destination, progress: progress)
    }

    /// Sound only, as AAC in an .m4a file.
    static func exportAudioM4A(
        _ source: URL, destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ConversionError.failed("\(source.lastPathComponent) has no sound.")
        }
        try await export(asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: destination, progress: progress)
    }

    /// Exports with AVAssetExportSession, reporting progress. Cancelling the
    /// task cancels the export.
    static func export(
        _ asset: AVURLAsset,
        preset: String,
        fileType: AVFileType,
        to url: URL,
        stripMetadata: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("macOS can't export this file.")
        }
        session.shouldOptimizeForNetworkUse = true
        if stripMetadata {
            // No title, location, device or dates; the filter also catches
            // anything left inside the individual tracks.
            session.metadata = []
            session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        }
        // The watcher only reads the session's progress stream, which is
        // made for exactly that, so sharing the session with it is safe.
        let shared = ExportSessionBox(session)
        let watcher = Task {
            for await state in shared.session.states(updateInterval: 0.15) {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: fileType)
        progress(1)
    }

    // MARK: - ffmpeg

    static func ffmpegArguments(for format: OutputFormat, options: ConversionOptions) -> [String] {
        switch format {
        case .mp4, .mov:
            [
                "-map", "0:v:0", "-map", "0:a:0?",
                "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            ]
        case .gif:
            // Two-pass palette for good colors; never upscale small videos.
            [
                "-an", "-vf",
                "fps=\(options.gifFPS),scale='min(\(options.gifWidth),iw)':-1:flags=lanczos,"
                    + "split[a][b];[a]palettegen=stats_mode=diff[p];"
                    + "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                "-loop", "0",
            ]
        case .m4a: ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .mp3: ["-vn", "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"]
        case .wav: ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: ["-vn", "-c:a", "pcm_s16be"]
        case .flac: ["-vn", "-c:a", "flac"]
        case .png, .jpeg, .heic, .tiff, .pdf: []
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// WAV, AIFF and FLAC with Core Audio (built into macOS; no ffmpeg needed).
enum AudioFileConverter {
    static func convert(
        _ source: URL, to format: OutputFormat, destination: URL,
        progress: @Sendable (Double) -> Void
    ) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        let sourceFormat = input.fileFormat
        let bitDepth = sourceBitDepth(sourceFormat)

        var settings: [String: Any] = [
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: sourceFormat.channelCount,
        ]
        switch format {
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = bitDepth
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = bitDepth
        default:
            throw ConversionError.unsupported(format.title)
        }
        if let layout = sourceFormat.channelLayout, sourceFormat.channelCount > 2 {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }

        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        defer { output.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw ConversionError.failed("Not enough memory to convert the audio.")
        }
        let total = max(Double(input.length), 1)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            progress(Double(input.framePosition) / total)
        }
    }

    /// 24-bit when the source has more than 16 bits of detail, else 16-bit.
    static func sourceBitDepth(_ format: AVAudioFormat) -> Int {
        if let bits = format.settings[AVLinearPCMBitDepthKey] as? Int, bits > 16 {
            return 24
        }
        let description = format.streamDescription.pointee
        if description.mFormatID == kAudioFormatFLAC || description.mFormatID == kAudioFormatAppleLossless {
            // Flags 2...4 mean 20, 24 or 32-bit source data.
            return description.mFormatFlags >= 2 ? 24 : 16
        }
        return 16
    }
}
