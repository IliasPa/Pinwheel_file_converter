import AVFoundation
import Foundation
import VideoToolbox

/// Compress for videos: HEVC at a bit rate picked from the quality setting
/// and the picture size, never higher than the original's. The size is kept
/// unless Settings asks for a limit (4K, 1080p, 720p).
enum VideoCompressor {
    static func compress(
        _ source: URL,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let quality = options.videoQuality
        try await encode(
            source, destination: destination, longSide: options.videoMaxSize.longSide,
            audioBitRate: options.audioBitRate, progress: progress
        ) { size, fps, sourceBitRate in
            targetBitRate(width: size.width, height: size.height, fps: fps, quality: quality, sourceBitRate: sourceBitRate)
        }
    }

    /// What a video is, for working out how to make it smaller.
    struct Probe: Sendable {
        /// Upright size in pixels.
        var size: CGSize
        var fps: Double
        var duration: Double
        var hasSound: Bool
    }

    static func probe(_ source: URL) async throws -> Probe {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.failed("\(source.lastPathComponent) is only sound, with no picture.")
        }
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let upright = naturalSize.applying(transform)
        return Probe(
            size: CGSize(width: abs(upright.width), height: abs(upright.height)),
            fps: Double(frameRate > 0 ? frameRate : 30),
            duration: try await asset.load(.duration).seconds,
            hasSound: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        )
    }

    /// HEVC at the bit rate `bitRate` picks (from the encoded size, the
    /// frame rate and the original's bit rate), at most `longSide` pixels.
    /// `peakBytesPerSecond` caps any one second, for a size that must hold.
    static func encode(
        _ source: URL,
        destination: URL,
        longSide: Int?,
        audioBitRate: Int,
        peakBytesPerSecond: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        bitRate pickBitRate: (_ size: (width: Int, height: Int), _ fps: Double, _ sourceBitRate: Double) -> Int
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.failed("\(source.lastPathComponent) has no picture to compress.")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform, frameRate, sourceBitRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate
        )
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.metadata)

        let size = targetSize(naturalSize, longSide: longSide)
        let fps = Double(frameRate > 0 ? frameRate : 30)
        let bitRate = pickBitRate(size, fps, Double(sourceBitRate))
        // A see-through video (ProRes 4444 with alpha) stays see-through, as
        // HEVC with alpha; read without it, the colors hidden there showed.
        let seeThrough = try await hasAlpha(videoTrack)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: seeThrough ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: destination.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        defer { removeOptimizingCopy(of: destination) }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: seeThrough ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ]
        if let peakBytesPerSecond, var properties = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any] {
            properties[kVTCompressionPropertyKey_DataRateLimits as String] = [peakBytesPerSecond, 1]
            videoSettings[AVVideoCompressionPropertiesKey] = properties
        }
        if seeThrough, !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
        }
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264  // no HEVC encoder: fall back to H.264
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform  // keeps portrait videos upright
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let output: AVAssetReaderTrackOutput
            let input: AVAssetWriterInput
            let (descriptions, sourceAudioRate) = try await audioTrack.load(.formatDescriptions, .estimatedDataRate)
            if let description = descriptions.first,
               CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC,
               sourceAudioRate > 0, Double(sourceAudioRate) <= Double(audioBitRate) * 1.1 {
                // Already small AAC: copy it as it is (no quality loss, no growth).
                output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
            } else {
                let format = try await AudioFormat.of(audioTrack)
                output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: format.pcmSettings)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.aacSettings(bitRate: audioBitRate))
            }
            reader.add(output)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioOutput = output
            audioInput = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw ConversionError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "Couldn't read the video.")
        }
        writer.startSession(atSourceTime: .zero)

        // Feed both tracks in turn; the writer wants them interleaved. On a
        // thread of its own: reading waits for the decoder, which on macOS 26
        // needs Swift's shared threads itself (with all of them waiting here,
        // nothing moved on a Mac with few cores).
        let pipeline = Handoff(value: (reader, writer, videoOutput, videoInput, audioOutput, audioInput))
        try await Blocking.run { isCancelled in
            let (reader, writer, videoOutput, videoInput, audioOutput, audioInput) = pipeline.value
            var videoDone = false
            var audioDone = audioInput == nil
            do {
                while !videoDone || !audioDone {
                    if isCancelled() { throw CancellationError() }
                    var fed = false
                    if !videoDone, videoInput.isReadyForMoreMediaData {
                        if let buffer = videoOutput.copyNextSampleBuffer() {
                            guard videoInput.append(buffer) else { throw writeError(writer) }
                            if duration > 0 { progress(min(buffer.presentationTimeStamp.seconds / duration, 0.99)) }
                        } else {
                            videoInput.markAsFinished()
                            videoDone = true
                        }
                        fed = true
                    }
                    if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                        if let buffer = audioOutput.copyNextSampleBuffer() {
                            guard audioInput.append(buffer) else { throw writeError(writer) }
                        } else {
                            audioInput.markAsFinished()
                            audioDone = true
                        }
                        fed = true
                    }
                    if !fed { Thread.sleep(forTimeInterval: 0.002) }
                }
                if reader.status == .failed {
                    throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the video.")
                }
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writeError(writer) }
    }

    /// The picture has a see-through part: 32 bits a pixel, or said so.
    static func hasAlpha(_ track: AVAssetTrack) async throws -> Bool {
        try await track.load(.formatDescriptions).contains { description in
            CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool == true
                || CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int == 32
        }
    }

    /// Making the file start playing before it's all downloaded, the writer
    /// works on a copy named "<file>.sb-…", which macOS 27 leaves behind.
    /// It's named after `destination`, a name Pinwheel picked fresh, so
    /// nothing else can match it.
    static func removeOptimizingCopy(of destination: URL) {
        let folder = destination.deletingLastPathComponent()
        let prefix = destination.lastPathComponent + ".sb-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The encoded size: the original, or smaller to fit `longSide`. Even
    /// numbers, as video encoders need.
    static func targetSize(_ natural: CGSize, longSide: Int?) -> (width: Int, height: Int) {
        var width = abs(natural.width)
        var height = abs(natural.height)
        if let longSide, max(width, height) > CGFloat(longSide) {
            let scale = CGFloat(longSide) / max(width, height)
            width *= scale
            height *= scale
        }
        func even(_ value: CGFloat) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(width), even(height))
    }

    /// Bits per second for the chosen quality, kept below the original's.
    static func targetBitRate(width: Int, height: Int, fps: Double, quality: VideoQuality, sourceBitRate: Double) -> Int {
        var rate = max(Double(width * height) * fps * quality.bitsPerPixel, 250_000)
        if sourceBitRate > 0 {
            rate = min(rate, sourceBitRate * 0.8)
        }
        return max(Int(rate), 50_000)
    }

    private static func writeError(_ writer: AVAssetWriter) -> ConversionError {
        .failed(writer.error?.localizedDescription ?? "Couldn't write the video.")
    }
}
