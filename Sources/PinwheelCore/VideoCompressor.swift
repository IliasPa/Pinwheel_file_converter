import AVFoundation
import Foundation

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

        let size = targetSize(naturalSize, longSide: options.videoMaxSize.longSide)
        let fps = Double(frameRate > 0 ? frameRate : 30)
        let bitRate = targetBitRate(
            width: size.width, height: size.height, fps: fps,
            quality: options.videoQuality, sourceBitRate: Double(sourceBitRate)
        )

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ]
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
            let (descriptions, audioBitRate) = try await audioTrack.load(.formatDescriptions, .estimatedDataRate)
            if let description = descriptions.first,
               CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC,
               audioBitRate > 0, Double(audioBitRate) <= Double(options.audioBitRate) * 1.1 {
                // Already small AAC: copy it as it is (no quality loss, no growth).
                output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
            } else {
                let format = try await AudioFormat.of(audioTrack)
                output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: format.pcmSettings)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.aacSettings(bitRate: options.audioBitRate))
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

        // Feed both tracks in turn; the writer wants them interleaved.
        var videoDone = false
        var audioDone = audioInput == nil
        do {
            while !videoDone || !audioDone {
                try Task.checkCancellation()
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
                if !fed { try await Task.sleep(for: .milliseconds(2)) }
            }
            if reader.status == .failed {
                throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the video.")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writeError(writer) }
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
