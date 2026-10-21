import AVFoundation
import Foundation

/// Mute, the video and audio editor, and Save Frame. Cutting, muting and
/// turning copy the picture as it is (fast, no quality loss); cropping draws
/// it anew.
enum MediaEdits {
    /// The editor's job. Returns a note for the progress window, if any.
    static func edit(
        _ file: SourceFile, edit: MediaEdit, destination: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        if !edit.splits.isEmpty {
            return try await split(file, edit: edit, into: destination, options: options, progress: progress)
        }
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
                && edit.bleeps.isEmpty && edit.channels == .unchanged
            return try await AudioProcessor.process(
                file.url, edit: edit, to: destination, ffmpegURL: options.ffmpegURL,
                skipIfAlreadyNormal: loudnessOnly, progress: progress
            ).note
        }
        return try await editVideo(file.url, edit: edit, destination: destination, options: options, progress: progress)
    }

    /// The part cut into pieces, each with the same changes, as files in the
    /// folder `destination` ("Clip part 1.mov"…).
    static func split(
        _ file: SourceFile, edit: MediaEdit, into folder: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        let duration = try await AVURLAsset(url: file.url).load(.duration).seconds
        let pieces = edit.pieces(duration: duration)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw ConversionError.cannotWrite(folder.lastPathComponent)
        }
        let base = file.url.deletingPathExtension().lastPathComponent
        let digits = String(pieces.count).count
        var notes: [String] = []
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            var part = edit
            part.splits = []
            (part.start, part.end) = (piece.start, piece.end)
            let ext = part.isTrimOnly ? OutputPlanner.trimOutput(for: file, options: options).1 : OutputPlanner.editedMediaOutput(for: file, options: options).1
            let number = String(index + 1)
            let name = "\(base) part \(String(repeating: "0", count: digits - number.count) + number).\(ext)"
            let share = 1 / Double(pieces.count)
            if let note = try await self.edit(file, edit: part, destination: folder.appendingPathComponent(name), options: options, progress: {
                progress((Double(index) + $0) * share)
            }) {
                notes.append(note)
            }
        }
        return notes.first
    }

    /// The picture is copied as it is (turned with its orientation flag,
    /// retimed for a new speed), or drawn anew when cropped; a changed
    /// soundtrack is made first and put in.
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
        var shownSize = CGSize.zero
        for track in videoTracks {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            let naturalSize = try await track.load(.naturalSize)
            copy.preferredTransform = turned(try await track.load(.preferredTransform), naturalSize: naturalSize, quarterTurns: edit.quarterTurns)
            if shownSize == .zero {
                let box = CGRect(origin: .zero, size: naturalSize).applying(copy.preferredTransform)
                shownSize = CGSize(width: abs(box.width), height: abs(box.height))
            }
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
        if let crop = edit.crop, let track = composition.tracks(withMediaType: .video).first {
            // The kept part of the picture is drawn into a frame its size.
            let video = cropped(track, shownSize: shownSize, crop: crop, duration: composition.duration)
            try await MediaConverter.export(
                composition, preset: AVAssetExportPresetHighestQuality, fileType: fileType, to: destination, metadata: metadata,
                videoComposition: video, progress: report
            )
            return note
        }
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

    /// Draws `crop` (a share of the picture as shown) of the track into a
    /// frame of that size, at the track's frame rate.
    static func cropped(_ track: AVMutableCompositionTrack, shownSize: CGSize, crop: RelativeRect, duration: CMTime) -> AVVideoComposition {
        let box = crop.pixels(in: shownSize)
        // Sizes in whole, even pixels, as video encoders want.
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(track.preferredTransform.concatenating(CGAffineTransform(translationX: -box.minX.rounded(), y: -box.minY.rounded())), at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)], timeRange: CMTimeRange(start: .zero, duration: duration)
        ))
        let rate = track.nominalFrameRate
        return AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(rate > 0 ? rate.rounded() : 30)), instructions: [instruction],
            renderSize: CGSize(width: even(box.width), height: even(box.height))
        ))
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

    /// The exact frame at `seconds`, upright, turned and cropped as shown, as a JPEG.
    static func saveFrame(
        _ source: URL, at seconds: Double, quarterTurns: Int = 0, crop: RelativeRect? = nil, destination: URL, options: ConversionOptions
    ) async throws {
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
        if let crop, let part = image.cropping(to: crop.pixels(in: CGSize(width: image.width, height: image.height)).integral) {
            image = part
        }
        try ImageConverter.write(image, to: destination, format: .jpeg, options: options)
    }
}
