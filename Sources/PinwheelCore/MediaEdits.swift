import AVFoundation
import Foundation

/// Mute, the video and audio editor, and Save Frame. Cutting, muting and
/// turning copy the picture as it is (fast, no quality loss).
enum MediaEdits {
    /// The editor's job. Returns a note for the progress window, if any.
    static func edit(
        _ file: SourceFile, edit: MediaEdit, destination: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        if edit.isTrimOnly {
            let duration = try await AVURLAsset(url: file.url).load(.duration).seconds
            let (start, end) = edit.range(duration: duration)
            if edit.isEmpty(duration: duration) { throw NothingToDo(reason: "Nothing was changed, so nothing was saved.") }
            try await trim(file, from: start, to: end, destination: destination, options: options, progress: progress)
            return nil
        }
        if file.kind == .audio {
            // Normalizing alone does nothing to a file that's already right.
            let loudnessOnly = edit.normalize && edit.speed == 1 && edit.fadeIn == 0 && edit.fadeOut == 0 && edit.start <= 0 && edit.end == nil
            return try await AudioProcessor.process(
                file.url, edit: edit, to: destination, ffmpegURL: options.ffmpegURL,
                skipIfAlreadyNormal: loudnessOnly, progress: progress
            ).note
        }
        return try await editVideo(file.url, edit: edit, destination: destination, options: options, progress: progress)
    }

    /// The picture is copied as it is (turned with its orientation flag,
    /// retimed for a new speed); a changed soundtrack is made first and put in.
    static func editVideo(
        _ source: URL, edit: MediaEdit, destination: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let (start, end) = edit.range(duration: duration)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ConversionError.failed("\(source.lastPathComponent) has no picture.") }

        let composition = AVMutableComposition()
        for track in videoTracks {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            copy.preferredTransform = turned(
                try await track.load(.preferredTransform), naturalSize: try await track.load(.naturalSize), quarterTurns: edit.quarterTurns
            )
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var note: String?
        let soundShare = edit.changesSound && !edit.mute ? 0.5 : 0
        if !edit.mute, let sound = try await asset.loadTracks(withMediaType: .audio).first {
            if edit.changesSound {
                let processed = work.appendingPathComponent("sound.m4a")
                note = try await AudioProcessor.process(source, edit: edit, to: processed, ffmpegURL: options.ffmpegURL) {
                    progress($0 * soundShare)
                }.note
                let made = AVURLAsset(url: processed)
                if let track = try await made.loadTracks(withMediaType: .audio).first,
                   let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try copy.insertTimeRange(CMTimeRange(start: .zero, duration: try await made.load(.duration)), of: track, at: .zero)
                }
            } else if let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try copy.insertTimeRange(range, of: sound, at: .zero)
            }
        }
        if edit.speed != 1 {
            // The sound was already stretched; the picture's frames are retimed.
            let length = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / edit.speed)
            for track in composition.tracks(withMediaType: .video) {
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: length)
            }
        }

        let fileType = ToolConverter.avVideoContainers[source.pathExtension.lowercased()] ?? .mov
        let metadata = try await asset.load(.metadata)
        let report: @Sendable (Double) -> Void = { progress(soundShare + $0 * (1 - soundShare)) }
        do {
            try await MediaConverter.export(composition, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: destination, metadata: metadata, progress: report)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some changes can't be copied as they are; encode the picture again.
            try? FileManager.default.removeItem(at: destination)
            try await MediaConverter.export(composition, preset: AVAssetExportPresetHighestQuality, fileType: fileType, to: destination, metadata: metadata, progress: report)
        }
        return note
    }

    /// A track's orientation, turned clockwise by quarter turns of what's
    /// shown (video transforms use y pointing down).
    static func turned(_ transform: CGAffineTransform, naturalSize: CGSize, quarterTurns: Int) -> CGAffineTransform {
        var result = transform
        let box = CGRect(origin: .zero, size: naturalSize).applying(transform)
        var shown = CGSize(width: abs(box.width), height: abs(box.height))
        for _ in 0..<((quarterTurns % 4) + 4) % 4 {
            // (x, y) → (height − y, x)
            result = result.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: shown.height, ty: 0))
            shown = CGSize(width: shown.height, height: shown.width)
        }
        return result
    }

    /// The same video without its soundtrack.
    static func mute(_ source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw ConversionError.failed("\(source.lastPathComponent) has no picture.")
        }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw NothingToDo(reason: "This video has no sound, so nothing was changed.")
        }
        let composition = AVMutableComposition()
        for track in videoTracks {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            let range = try await track.load(.timeRange)
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        let fileType = ToolConverter.avVideoContainers[source.pathExtension.lowercased()] ?? .mov
        try await MediaConverter.export(
            composition, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: destination,
            metadata: try await asset.load(.metadata), progress: progress
        )
    }

    /// Whether a file has a soundtrack (asks ffprobe for files macOS can't open).
    static func hasSound(_ file: SourceFile, ffmpeg: URL) async throws -> Bool {
        if !file.needsFFmpegToRead {
            return try await !AVURLAsset(url: file.url).loadTracks(withMediaType: .audio).isEmpty
        }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return true }
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", file.url.path,
        ])
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keeps `start...end` (seconds). The output's extension, chosen by
    /// `OutputPlanner.trimOutput`, decides how: the same container is cut
    /// as it is (by macOS, or by ffmpeg for MP3, FLAC…); otherwise the part
    /// becomes MOV (video) or M4A (audio).
    static func trim(
        _ file: SourceFile, from start: Double, to end: Double, destination: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ext = file.url.pathExtension.lowercased()
        let outExt = destination.pathExtension.lowercased()
        let containers = file.kind == .video ? ToolConverter.avVideoContainers : ToolConverter.avAudioContainers
        let range = CMTimeRange(
            start: CMTime(seconds: max(start, 0), preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        let viaFFmpeg: (URL) async throws -> Void = { ffmpeg in
            try await FFmpeg.convert(
                ffmpeg: ffmpeg, input: file.url, output: destination,
                arguments: ["-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end), "-map", "0", "-c", "copy"],
                duration: end - start, progress: progress
            )
        }

        if outExt == ext, containers[ext] == nil {
            // Only ffmpeg can cut this kind of file without converting it.
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            try await viaFFmpeg(ffmpeg)
            return
        }
        let asset = AVURLAsset(url: file.url)
        if outExt == ext, let fileType = containers[ext] {
            try await MediaConverter.appleThenFFmpeg(destination: destination, ffmpegURL: options.ffmpegURL) {
                try await MediaConverter.export(
                    asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: destination,
                    timeRange: range, progress: progress
                )
            } ffmpeg: { ffmpeg in
                try await viaFFmpeg(ffmpeg)
            }
        } else if file.kind == .video {
            try await MediaConverter.export(
                asset, preset: AVAssetExportPresetPassthrough, fileType: .mov, to: destination,
                timeRange: range, progress: progress
            )
        } else {
            try await MediaConverter.export(
                asset, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: destination,
                timeRange: range, progress: progress
            )
        }
    }

    /// The exact frame at `seconds`, upright and turned as shown, as a JPEG.
    static func saveFrame(_ source: URL, at seconds: Double, quarterTurns: Int = 0, destination: URL, options: ConversionOptions) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)).image
        } catch {
            throw ConversionError.failed("Couldn't get that frame: \(error.localizedDescription)")
        }
        if quarterTurns % 4 != 0 {
            var turn = ImageEdit()
            turn.quarterTurns = ((quarterTurns % 4) + 4) % 4
            image = try StudioRenderer.render(StudioSource(image: image), mask: nil, edit: turn)
        }
        try ImageConverter.write(image, to: destination, format: .jpeg, options: options)
    }
}
