import AVFoundation
import Foundation
import ImageIO

/// The Option+Shift tools: Compress, Resize, Strip Info, Get Audio.
enum ToolConverter {
    /// Containers AVFoundation can re-save with the metadata removed.
    static let avVideoContainers: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v, "3gp": .mobile3GPP]
    static let avAudioContainers: [String: AVFileType] = [
        "m4a": .m4a, "m4b": .m4a, "wav": .wav, "aif": .aiff, "aiff": .aiff, "aifc": .aifc, "caf": .caf,
    ]

    static func usesFFmpeg(_ tool: ToolAction, for file: SourceFile) -> Bool {
        if file.needsFFmpegToRead { return true }
        let ext = file.url.pathExtension.lowercased()
        switch (file.kind, tool) {
        case (.video, .stripMetadata): return avVideoContainers[ext] == nil
        case (.audio, .stripMetadata): return avAudioContainers[ext] == nil
        default: return false
        }
    }

    static func run(
        _ tool: ToolAction,
        file: SourceFile,
        plan: OutputPlan,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch file.kind {
        case .image:
            guard let format = plan.format else { throw ConversionError.unsupported(destination.pathExtension.uppercased()) }
            progress(0.1)
            try await ImageTools.run(tool, source: file.url, format: format, destination: destination, options: options)
        case .pdf:
            progress(0.1)
            switch tool {
            case .compress:
                try PDFConverter.compress(file.url, destination: destination, quality: options.compressQuality, dpi: options.pdfImageDPI)
            case .stripMetadata:
                try PDFConverter.stripMetadata(file.url, destination: destination)
            default:
                throw ConversionError.unsupported("\(tool.title) for PDFs")
            }
        case .video, .audio:
            try await MediaTools.run(tool, file: file, destination: destination, options: options, progress: progress)
        case nil:
            throw ConversionError.unsupported(file.url.lastPathComponent)
        }
    }
}

// MARK: - Images

enum ImageTools {
    static func run(_ tool: ToolAction, source: URL, format: OutputFormat, destination: URL, options: ConversionOptions) async throws {
        let src = try ImageConverter.open(source)
        if CGImageSourceGetCount(src) > 1, CGImageSourceGetType(src) as String? == OutputFormat.gif.utType.identifier {
            throw ConversionError.failed("\(tool.title) doesn't work on animated GIFs yet.")
        }
        switch tool {
        case .compress where format == .png:
            try await compressPNG(source, src, to: destination, options: options)
        case .compress:
            try compress(src, to: destination, format: format, quality: options.compressQuality)
        case .resize:
            try resize(src, to: destination, format: format, options: options)
        case .stripMetadata:
            try stripMetadata(src, to: destination, format: format)
        case .extractAudio:
            throw ConversionError.unsupported("Getting audio from an image")
        }
    }

    /// Same pixels, lower quality setting. Metadata is kept.
    static func compress(_ src: CGImageSource, to url: URL, format: OutputFormat, quality: Double) throws {
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let settings: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        let dest = try ImageConverter.makeDestination(url, format: format)
        if format == .jpeg, properties[kCGImagePropertyHasAlpha] as? Bool == true,
           let image = CGImageSourceCreateImageAtIndex(src, index, nil) {
            let flat = try ImageConverter.flattenOnWhite(image)
            CGImageDestinationAddImage(dest, flat, ImageConverter.metadata(from: properties).merging(settings) { $1 } as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, src, index, settings as CFDictionary)
        }
        try ImageConverter.finalize(dest, url)
    }

    /// PNG stays PNG. pngquant (if installed) reduces the colors, usually
    /// shrinking the file a lot with no visible change; without it only a
    /// lossless re-save is possible, which rarely helps.
    static func compressPNG(_ source: URL, _ src: CGImageSource, to url: URL, options: ConversionOptions) async throws {
        guard let pngquant = options.pngquantURL else {
            let dest = try ImageConverter.makeDestination(url, format: .png)
            CGImageDestinationAddImageFromSource(dest, src, CGImageSourceGetPrimaryImageIndex(src), nil)
            try ImageConverter.finalize(dest, url)
            return
        }
        let quality = Int((options.compressQuality * 100).rounded())
        let result = try await ProcessRunner.run(pngquant, [
            "--quality=\(max(0, quality - 20))-\(min(100, quality + 25))",
            "--speed=3", "--strip",
            "--output", url.path, "--", source.path,
        ])
        switch result.status {
        case 0:
            return
        case 98, 99:
            throw NothingToDo(reason: "This PNG can't get smaller without visible changes, so nothing was saved.")
        default:
            let reason = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it stopped with an error"
            throw ConversionError.failed("pngquant: \(reason)")
        }
    }

    /// Resizes as chosen in Settings, upright, metadata kept.
    static func resize(_ src: CGImageSource, to url: URL, format: OutputFormat, options: ConversionOptions) throws {
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard let newLongSide = options.resize.newLongSide(from: max(width, height)) else {
            throw NothingToDo(reason: "Already no bigger than \(options.resize.fitSize ?? 0) pixels, so nothing was changed.")
        }
        let image = try ImageConverter.orientedImage(src, index: index, maxPixelSize: newLongSide)

        // The new image is already upright, and its size has changed.
        var metadata = ImageConverter.metadata(from: properties)
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        var settings = ImageConverter.encoderSettings(for: format, options: options)
        if format == .jpeg || format == .heic {
            settings[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        let dest = try ImageConverter.makeDestination(url, format: format)
        CGImageDestinationAddImage(dest, image, metadata.merging(settings) { $1 } as CFDictionary)
        try ImageConverter.finalize(dest, url)
    }

    /// Removes location, camera, dates and other hidden info. When the format
    /// stays the same the picture itself is copied untouched (no quality loss).
    static func stripMetadata(_ src: CGImageSource, to url: URL, format: OutputFormat) throws {
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        if let sourceType = CGImageSourceGetType(src), sourceType as String == format.utType.identifier,
           let dest = CGImageDestinationCreateWithURL(url as CFURL, sourceType, 1, nil) {
            let clean = CGImageMetadataCreateMutable()
            if orientation != 1 {
                // Keep only which way is up, so the photo isn't shown sideways.
                CGImageMetadataSetValueMatchingImageProperty(
                    clean, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber
                )
            }
            let copyOptions: [CFString: Any] = [
                kCGImageDestinationMetadata: clean,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            if CGImageDestinationCopyImageSource(dest, src, copyOptions as CFDictionary, nil),
               !containsPrivateInfo(url) {
                return
            }
            try? FileManager.default.removeItem(at: url)
        }

        // Otherwise redraw the picture with nothing but its orientation.
        guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else {
            throw ConversionError.unreadable("The image")
        }
        var settings: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if format == .jpeg || format == .heic {
            settings[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        let dest = try ImageConverter.makeDestination(url, format: format)
        CGImageDestinationAddImage(dest, image, settings as CFDictionary)
        try ImageConverter.finalize(dest, url)
    }

    /// True when a file still has location, camera or date information.
    static func containsPrivateInfo(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        if props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyIPTCDictionary] != nil { return true }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let privateTIFF: [CFString] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFSoftware]
        let privateExif: [CFString] = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifUserComment]
        return privateTIFF.contains { tiff[$0] != nil } || privateExif.contains { exif[$0] != nil }
    }
}

// MARK: - Video and audio

enum MediaTools {
    static func run(
        _ tool: ToolAction,
        file: SourceFile,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if ToolConverter.usesFFmpeg(tool, for: file) {
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            try await runFFmpeg(tool, file: file, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
            return
        }
        try await MediaConverter.appleThenFFmpeg(destination: destination, ffmpegURL: options.ffmpegURL) {
            try await runApple(tool, file: file, destination: destination, options: options, progress: progress)
        } ffmpeg: { ffmpeg in
            try await runFFmpeg(tool, file: file, destination: destination, ffmpeg: ffmpeg, options: options, progress: progress)
        }
    }

    private static func runApple(
        _ tool: ToolAction, file: SourceFile, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch (file.kind, tool) {
        case (.video, .compress):
            try await VideoCompressor.compress(file.url, destination: destination, options: options, progress: progress)
        case (.video, .extractAudio):
            try await MediaConverter.exportAudioM4A(file.url, destination: destination, progress: progress)
        case (.video, .stripMetadata), (.audio, .stripMetadata):
            let ext = file.url.pathExtension.lowercased()
            guard let fileType = ToolConverter.avVideoContainers[ext] ?? ToolConverter.avAudioContainers[ext] else {
                throw ConversionError.needsFFmpeg
            }
            try await MediaConverter.export(
                AVURLAsset(url: file.url), preset: AVAssetExportPresetPassthrough, fileType: fileType,
                to: destination, stripMetadata: true, progress: progress
            )
        case (.audio, .compress):
            try await AudioCompressor.compress(file.url, destination: destination, bitRate: options.audioBitRate, progress: progress)
        default:
            throw ConversionError.unsupported("\(tool.title) for \(file.url.lastPathComponent)")
        }
    }

    private static func runFFmpeg(
        _ tool: ToolAction, file: SourceFile, destination: URL, ffmpeg: URL,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let audioRate = "\(options.audioBitRate / 1000)k"
        let arguments: [String]
        switch (file.kind, tool) {
        case (.video, .compress):
            var video = ["-c:v", "libx264", "-preset", "medium", "-crf", "\(options.videoQuality.crf)", "-pix_fmt", "yuv420p"]
            if let side = options.videoMaxSize.longSide {
                // Fit inside side×side, keep the shape, never enlarge.
                video += ["-vf", "scale='min(\(side),iw)':'min(\(side),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"]
            }
            arguments = ["-map", "0:v:0", "-map", "0:a:0?"] + video + ["-c:a", "aac", "-b:a", audioRate, "-movflags", "+faststart"]
        case (.video, .extractAudio):
            arguments = ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case (.video, .stripMetadata):
            arguments = ["-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"]
        case (.audio, .compress):
            arguments = ["-vn", "-c:a", "aac", "-b:a", audioRate]
        case (.audio, .stripMetadata):
            // Audio only: this also drops embedded cover art.
            arguments = ["-map", "0:a", "-map_metadata", "-1", "-c", "copy"]
        default:
            throw ConversionError.unsupported("\(tool.title) for \(file.url.lastPathComponent)")
        }
        let duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg)
        try await FFmpeg.convert(
            ffmpeg: ffmpeg, input: file.url, output: destination,
            arguments: arguments, duration: duration, progress: progress
        )
    }
}

/// Re-encodes a soundtrack as AAC at a chosen bit rate, keeping its tags.
enum AudioCompressor {
    static func compress(
        _ source: URL, destination: URL, bitRate: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("\(source.lastPathComponent) has no sound.")
        }
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.metadata)
        let format = try await AudioFormat.of(track)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: format.pcmSettings)
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.aacSettings(bitRate: bitRate))
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw ConversionError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        writer.startSession(atSourceTime: .zero)
        do {
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard input.append(buffer) else {
                    throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't write the audio.")
                }
                if duration > 0 {
                    progress(min(buffer.presentationTimeStamp.seconds / duration, 0.99))
                }
            }
            if reader.status == .failed {
                throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the audio.")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't write the audio.")
        }
    }
}

/// Channels and sample rate of a soundtrack, and the settings to read it as
/// PCM and write it as AAC (which allows at most 2 channels and 48 kHz).
struct AudioFormat {
    let channels: Int
    let sampleRate: Double

    static func of(_ track: AVAssetTrack) async throws -> AudioFormat {
        let descriptions = try await track.load(.formatDescriptions)
        let stream = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return AudioFormat(
            channels: max(1, min(Int(stream?.mChannelsPerFrame ?? 2), 2)),
            sampleRate: min(stream?.mSampleRate ?? 44_100, 48_000)
        )
    }

    var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    func aacSettings(bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
    }
}
