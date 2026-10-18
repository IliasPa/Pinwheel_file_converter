import AVFoundation
import Foundation

/// Mute, Trim and Save Frame. Cutting and muting copy the streams as they
/// are (fast, no quality loss).
enum MediaEdits {
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

    /// The exact frame at `seconds`, upright, as a JPEG.
    static func saveFrame(_ source: URL, at seconds: Double, destination: URL, options: ConversionOptions) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)).image
        } catch {
            throw ConversionError.failed("Couldn't get that frame: \(error.localizedDescription)")
        }
        try ImageConverter.write(image, to: destination, format: .jpeg, options: options)
    }
}
