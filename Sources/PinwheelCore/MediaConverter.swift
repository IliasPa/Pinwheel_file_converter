import AVFoundation
import Foundation

/// Video and audio conversions. Apple's frameworks do the work when they can;
/// ffmpeg only handles MP3, GIFs from video, and files AVFoundation can't open.
enum MediaConverter {
    /// Returns a note for the progress window (e.g. "only the first 15 seconds").
    /// `part` (from the video editor) makes a GIF of just that part, at that
    /// speed and turned that way.
    static func convert(
        _ file: SourceFile,
        to format: OutputFormat,
        destination: URL,
        options: ConversionOptions,
        part: MediaEdit? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        if ConversionEngine.usesFFmpeg(.convert(format), for: file) {
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            if format == .gif, let part {
                try await gif(of: file, part: part, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
                return nil
            }
            if format == .webp {
                return try await AnimatedPicture.webp(fromVideo: file, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
            }
            return try await convertWithFFmpeg(file, to: format, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
        }
        // A see-through video into MP4: macOS would show the colors hidden
        // behind the see-through parts; ffmpeg puts black there.
        if format == .mp4, let ffmpeg = options.ffmpegURL, await FFmpeg.streams(of: file.url, ffmpeg: ffmpeg)?.alpha == true {
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
        if format.kind == .audio, let stream = await FFmpeg.audioStream(of: file, ffmpeg: ffmpeg),
           let kept = audioArguments(for: format, source: stream) {
            arguments = kept
        }
        var withoutSubtitles: [String]?
        if let streams = await FFmpeg.streams(of: file.url, ffmpeg: ffmpeg) {
            try check(streams, file: file, format: format)
            let plain = arguments
            arguments = fitted(plain, to: streams, format: format)
            if !streams.subtitles.isEmpty { withoutSubtitles = fitted(plain, to: streams, format: format, withSubtitles: false) }
        }
        var duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg)
        var note: String?
        if format == .gif, let limit = options.gifMaxSeconds {
            arguments = ["-t", "\(limit)"] + arguments
            if let full = duration, full > Double(limit) + 0.5 {
                note = "Only the first \(limit) seconds (you can change this in Settings › Wheels › Formats)."
            }
            duration = duration.map { min($0, Double(limit)) }
        }
        do {
            try await FFmpeg.convert(
                ffmpeg: ffmpeg, input: file.url, output: destination,
                arguments: arguments, duration: duration, progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Subtitles of a kind the container can't take: without them.
            // MKV first copies the streams as they are, and ffmpegs without
            // libvorbis or libopus have their own (simpler) encoders.
            for retry in [withoutSubtitles, secondTry(for: format)].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: destination)
                do {
                    try await FFmpeg.convert(ffmpeg: ffmpeg, input: file.url, output: destination, arguments: retry, duration: duration, progress: progress)
                    return note
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            throw error
        }
        return note
    }

    /// Sound that was already compressed keeps at least its own bit rate,
    /// up to what the format holds, so as little as possible is lost again;
    /// Opus goes between .opus and .ogg as it is, not compressed again.
    /// nil: the usual settings do.
    static func audioArguments(for format: OutputFormat, source: FFmpeg.AudioStream) -> [String]? {
        if source.codec == "opus", format == .opus || format == .ogg { return ["-vn", "-c:a", "copy"] }
        guard source.isLossy, let rate = source.bitRate else { return nil }
        let kbps = rate / 1000
        switch format {
        case .mp3 where kbps > 190:
            let kept = [224, 256, 320].first { $0 >= kbps } ?? 320
            return ["-vn", "-c:a", "libmp3lame", "-b:a", "\(kept)k", "-id3v2_version", "3"]
        case .ogg where kbps > 160:
            let quality = kbps <= 192 ? 6 : kbps <= 224 ? 7 : kbps <= 256 ? 8 : 9
            return ["-vn", "-c:a", "libvorbis", "-q:a", "\(quality)"]
        case .opus where kbps > 128:
            return ["-vn", "-c:a", "libopus", "-b:a", "\(min(256, kbps))k"]
        case .wma where kbps > 192:
            return ["-vn", "-c:a", "wmav2", "-b:a", "\(min(320, kbps))k"]
        case .m4a where kbps > 256:
            return ["-vn", "-c:a", "aac", "-b:a", "320k"]
        default:
            return nil
        }
    }

    /// A copy macOS can decode (H.264 or ProRes, AAC), named as the
    /// original, in `folder`: for files whose codec macOS opens but can't decode.
    static func readableCopy(of file: SourceFile, in folder: URL, ffmpeg: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent).appendingPathExtension(file.kind == .audio ? "m4a" : "mov")
        let arguments = file.kind == .audio
            ? ["-map", "0:a:0", "-c:a", "alac", "-map_metadata", "0"]
            : ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "256k", "-map_metadata", "0"]
        try await FFmpeg.convert(ffmpeg: ffmpeg, input: file.url, output: copy, arguments: arguments, duration: nil) { _ in }
        return copy
    }

    /// Sound into a sound format needs sound; a video format needs a picture.
    static func check(_ streams: FFmpeg.Streams, file: SourceFile, format: OutputFormat) throws {
        let name = file.url.lastPathComponent
        if format.kind == .audio, streams.channels == nil {
            throw NothingToDo(reason: "\(name) has no sound, so there's nothing to save.")
        }
        if format.kind == .video || format == .gif || format == .webp, !streams.video {
            throw ConversionError.failed("\(name) is only sound, with no picture. Choose M4A or MP3 instead.")
        }
    }

    /// The usual arguments, made to fit what the file has: every sound track
    /// and the subtitles go into containers that hold them, the title and
    /// cover go along with the sound, and sound the format can't hold (5.1
    /// in WMA, 96 kHz) is brought down to what it can.
    static func fitted(_ arguments: [String], to streams: FFmpeg.Streams, format: OutputFormat, withSubtitles: Bool = true) -> [String] {
        var result = arguments
        // Every sound track (languages, commentary) in the containers made for that.
        if [.mp4, .mov, .mkv, .webm].contains(format), let index = result.firstIndex(of: "0:a:0?") {
            result[index] = "0:a?"
        }
        // Subtitles inside: kept as text where the container takes it.
        var kept = 0
        for subtitle in streams.subtitles where withSubtitles {
            let text = FFmpeg.Streams.textSubtitles.contains(subtitle.codec)
            let codec: String? = switch format {
            case .mp4, .mov: text ? "mov_text" : nil
            case .mkv: ["mov_text", "webvtt", "text"].contains(subtitle.codec) ? "srt" : "copy"
            case .webm: text ? "webvtt" : nil
            default: nil
            }
            guard let codec else { continue }
            result += ["-map", "0:\(subtitle.index)", "-c:s:\(kept)", codec]
            kept += 1
        }
        // See-through parts: WebM keeps them; formats that can't get black
        // behind them (else the colors hidden there showed through).
        if streams.alpha {
            if format == .webm, let index = result.firstIndex(of: "yuv420p") {
                result[index] = "yuva420p"
                result += ["-auto-alt-ref", "0"]
            } else if [.mp4, .mov, .avi, .wmv, .gif].contains(format) {
                if let index = result.firstIndex(of: "-vf") {
                    result[index + 1] = "premultiply=inplace=1," + result[index + 1]
                } else if let index = result.firstIndex(of: "-c:v") {
                    result.insert(contentsOf: ["-vf", "premultiply=inplace=1"], at: index)
                }
            }
        }
        // Sound the format can't hold.
        let audioCodec = result.firstIndex(of: "-c:a").map { result[$0 + 1] } ?? (result.contains("-c") ? "copy" : "")
        if let channels = streams.channels, channels > 2 {
            switch audioCodec {
            case "wmav2", "libmp3lame", "vorbis", "opus":
                result += ["-ac", "2"]
            case "libopus":
                // Opus holds up to 7.1, in the usual layouts ("5.1", not "5.1(side)").
                let layout = (streams.layout ?? "").replacingOccurrences(of: "(side)", with: "").replacingOccurrences(of: "(wide)", with: "")
                if ["3.0", "quad", "5.0", "5.1", "6.1", "7.1"].contains(layout) {
                    result += ["-af", "aformat=channel_layouts=\(layout)", "-mapping_family", "1"]
                } else {
                    result += ["-ac", "2"]
                }
            default:
                break
            }
        }
        if let rate = streams.sampleRate, rate > 48_000, ["wmav2", "libmp3lame", "libopus", "opus"].contains(audioCodec) {
            result += ["-ar", "48000"]
        }
        // The title and such, from the sound stream when that's where they are (Ogg, Opus).
        if streams.tagsOnSound { result += ["-map_metadata", "0:s:a:0"] }
        // The album cover, into formats that show one.
        if let cover = streams.cover, [.mp3, .flac, .m4a].contains(format), let vn = result.firstIndex(of: "-vn") {
            result.replaceSubrange(vn...vn, with: ["-map", "0:a:0", "-map", "0:\(cover)", "-c:v", "copy", "-disposition:v:0", "attached_pic"])
        }
        return result
    }

    /// What to try when the first ffmpeg arguments fail, if anything.
    static func secondTry(for format: OutputFormat) -> [String]? {
        switch format {
        case .mkv:
            ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case .ogg:
            ["-vn", "-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-b:a", "192k"]
        case .opus:
            ["-vn", "-c:a", "opus", "-strict", "experimental", "-ar", "48000", "-b:a", "128k"]
        default:
            nil
        }
    }

    /// A GIF of the chosen part: fast seek to it, then retime and turn.
    static func gif(
        of file: SourceFile, part: MediaEdit, destination: URL, ffmpeg: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg) ?? (part.end ?? 0)
        let (start, end) = part.range(duration: max(duration, part.end ?? 0))
        if duration > 0, start >= duration - 0.01 {
            throw NothingToDo(reason: "That part starts after the video ends (it's \(String(format: duration < 1 ? "%.2f" : "%.1f", duration)) seconds long).")
        }
        var filters: [String] = []
        if part.speed != 1 { filters.append("setpts=PTS/\(part.speed)") }
        switch ((part.quarterTurns % 4) + 4) % 4 {
        case 1: filters.append("transpose=1")
        case 2: filters.append("transpose=1,transpose=1")
        case 3: filters.append("transpose=2")
        default: break
        }
        if let crop = part.crop {
            filters.append(String(format: "crop=w=iw*%.4f:h=ih*%.4f:x=iw*%.4f:y=ih*%.4f", crop.width, crop.height, crop.x, crop.y))
        }
        var arguments = ffmpegArguments(for: .gif, options: options)
        if !filters.isEmpty, let index = arguments.firstIndex(of: "-vf") {
            arguments[index + 1] = filters.joined(separator: ",") + "," + arguments[index + 1]
        }
        let span = ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", end - start)]
        do {
            // Seeking before reading is quick…
            try await FFmpeg.convert(
                ffmpeg: ffmpeg, input: file.url, output: destination,
                inputArguments: span, arguments: arguments, duration: (end - start) / part.speed, progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // …but finds nothing in some camcorder files (MTS that don't
            // start at zero): then the video is read from the start.
            try? FileManager.default.removeItem(at: destination)
            try await FFmpeg.convert(
                ffmpeg: ffmpeg, input: file.url, output: destination,
                arguments: span + arguments, duration: end / part.speed, progress: progress
            )
        }
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
            throw ConversionError.failed("\(source.lastPathComponent) is only sound, with no picture. Choose M4A or MP3 instead.")
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
            throw NothingToDo(reason: "\(source.lastPathComponent) has no sound, so there's nothing to save.")
        }
        try await export(asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: destination, progress: progress)
    }

    /// Exports with AVAssetExportSession, reporting progress. Cancelling the
    /// task cancels the export. `metadata` replaces the file's tags (nil
    /// keeps them); `timeRange` keeps just that part; `videoComposition`
    /// draws the picture anew (a crop).
    static func export(
        _ asset: AVAsset,
        preset: String,
        fileType: AVFileType,
        to url: URL,
        stripMetadata: Bool = false,
        metadata: [AVMetadataItem]? = nil,
        timeRange: CMTimeRange? = nil,
        videoComposition: AVVideoComposition? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("macOS can't export this file.")
        }
        session.shouldOptimizeForNetworkUse = true
        if let metadata { session.metadata = metadata }
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
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
        case .mkv:
            // Copies the picture and sound as they are: quick, and nothing is lost.
            ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        case .webm:
            [
                "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-row-mt", "1",
                "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k",
            ]
        case .avi:
            // MPEG-4 and MP3: what older players and TVs expect in an AVI.
            [
                "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "mpeg4", "-vtag", "xvid",
                "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "4",
            ]
        case .wmv:
            [
                "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "wmv2", "-q:v", "3",
                "-c:a", "wmav2", "-b:a", "192k",
            ]
        case .m4a: ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .mp3: ["-vn", "-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"]
        case .wav: ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: ["-vn", "-c:a", "pcm_s16be"]
        case .flac: ["-vn", "-c:a", "flac"]
        case .ogg: ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case .opus: ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case .wma: ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default: []  // not sound or video
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

/// What macOS's media frameworks say when they can't read a file, in words.
enum MediaErrors {
    /// Couldn't open or decode: damaged, or coded in a way macOS can't read.
    static func isUnreadable(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == AVFoundationErrorDomain {
            let codes: Set<Int> = [
                AVError.fileFormatNotRecognized.rawValue, AVError.decoderNotFound.rawValue, AVError.decodeFailed.rawValue,
                AVError.failedToParse.rawValue, AVError.operationNotSupportedForAsset.rawValue, AVError.unknown.rawValue,
                AVError.noLongerPlayable.rawValue, AVError.contentIsUnavailable.rawValue,
            ]
            if codes.contains(error.code) { return true }
        }
        let text = error.localizedDescription
        return ["Cannot Open", "Cannot Decode", "The operation could not be completed", "This media may be damaged", "Operation Stopped"]
            .contains { text.contains($0) }
    }

    static func damaged(_ name: String) -> String {
        "\(name) seems damaged or incomplete (maybe a download that stopped), or it's coded in a way macOS can't read."
    }
}
