import Accelerate
import AVFoundation
import CoreText
import Foundation
import ImageIO

/// How a visualizer video looks.
public struct VisualizerSpec: Codable, Sendable, Equatable {
    public enum Shape: String, Codable, Sendable, CaseIterable {
        case square, landscape, portrait

        public var size: CGSize {
            switch self {
            case .square: CGSize(width: 1080, height: 1080)
            case .landscape: CGSize(width: 1920, height: 1080)
            case .portrait: CGSize(width: 1080, height: 1920)
            }
        }

        public var title: String {
            switch self {
            case .square: "Square (1:1)"
            case .landscape: "Wide (16:9)"
            case .portrait: "Tall (9:16)"
            }
        }
    }

    public enum Style: String, Codable, Sendable, CaseIterable {
        /// The sound's pitches as bars, low on the left, mirrored up and down.
        case bars
        /// The sound's wave, like an oscilloscope.
        case wave

        public var title: String {
            switch self {
            case .bars: "Bars"
            case .wave: "Wave"
            }
        }
    }

    public var shape = Shape.square
    public var style = Style.bars
    public var color = MarkupColor.white
    /// A picture behind the sound (its path); nil: the gradient.
    public var picture: String?
    public var gradient = GradientPreset.dusk
    /// Shown near the bottom; empty for none.
    public var title = ""

    public init() {}
}

/// A sound and a picture (or a gradient) into a video whose bars or wave
/// move with the sound: for sharing music, podcasts and voice notes where
/// only videos go.
public enum Visualizer {
    public static let framesPerSecond = 30
    static let bandCount = 48
    static let wavePoints = 96
    static let windowSize = 2048

    /// The levels of each video frame.
    struct Frames {
        /// 0...1, low pitches first.
        var bands: [[Float]] = []
        /// -1...1, the wave around the frame's moment.
        var waves: [[Float]] = []
    }

    // MARK: - The job

    static func render(
        _ file: SourceFile, spec: VisualizerSpec, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var sound = file.url
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        if file.needsFFmpegToRead {
            // OGG, Opus, WMA…: ffmpeg makes a copy macOS can read.
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            sound = work.appendingPathComponent("sound.wav")
            try await FFmpeg.convert(ffmpeg: ffmpeg, input: file.url, output: sound, arguments: ["-vn", "-c:a", "pcm_s16le"], duration: nil) { progress($0 * 0.1) }
        }
        let asset = AVURLAsset(url: sound)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("\(file.url.lastPathComponent) has no sound.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.1 else { throw NothingToDo(reason: "It's too short to make a video of.") }
        let channels = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map { min(max(Int($0), 1), 2) } ?? 2
        let background = try backdrop(spec)
        let source = SoundTrack(asset: asset, track: track, channels: channels)
        try await Blocking.run { isCancelled in
            let frames = try analyze(source, duration: duration, isCancelled: isCancelled) { progress(0.1 + $0 * 0.2) }
            try write(source, frames: frames, spec: spec, background: background, to: destination, isCancelled: isCancelled) {
                progress(0.3 + $0 * 0.7)
            }
        }
    }

    /// The sound, read on the thread that does the work.
    struct SoundTrack: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let channels: Int
    }

    // MARK: - Listening

    /// Each frame's bars (from a Fourier transform of the sound around it)
    /// and wave, scaled so the loud moments reach the top.
    static func analyze(_ sound: SoundTrack, duration: Double, isCancelled: () -> Bool, progress: (Double) -> Void) throws -> Frames {
        let rate = 44_100.0
        let reader = try AVAssetReader(asset: sound.asset)
        let output = AVAssetReaderTrackOutput(track: sound.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the sound.") }

        let count = max(Int((duration * Double(framesPerSecond)).rounded(.up)), 1)
        let spectrum = Spectrum(size: windowSize, rate: rate, bands: bandCount)
        var frames = Frames()
        frames.bands.reserveCapacity(count)
        frames.waves.reserveCapacity(count)
        // The samples read so far that later frames still need, and where they start.
        var pending: [Float] = []
        var pendingStart = 0
        var finished = false
        func window(for frame: Int) -> Range<Int> {
            let middle = Int(Double(frame) / Double(framesPerSecond) * rate)
            return (middle - windowSize / 2)..<(middle + windowSize / 2)
        }
        while frames.bands.count < count {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            let needed = window(for: frames.bands.count)
            if needed.upperBound > pendingStart + pending.count, !finished {
                if let buffer = output.copyNextSampleBuffer() {
                    pending += samples(in: buffer)
                } else {
                    finished = true
                }
                continue
            }
            // Before the start and after the end there's silence.
            let slice = needed.map { index -> Float in
                let at = index - pendingStart
                return at >= 0 && at < pending.count ? pending[at] : 0
            }
            frames.bands.append(spectrum.levels(slice))
            frames.waves.append(stride(from: 0, to: windowSize, by: windowSize / wavePoints).map { start in
                slice[start..<min(start + windowSize / wavePoints, windowSize)].reduce(0, +) / Float(windowSize / wavePoints)
            })
            // Keep only what the next frame's window needs.
            let unneeded = min(max(window(for: frames.bands.count).lowerBound - pendingStart, 0), pending.count)
            pending.removeFirst(unneeded)
            pendingStart += unneeded
            if frames.bands.count % 200 == 0 { progress(Double(frames.bands.count) / Double(count)) }
        }
        if reader.status == .failed { throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the sound.") }
        return smoothed(frames)
    }

    private static func samples(in buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var result = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        result.withUnsafeMutableBytes { bytes in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        return result
    }

    /// Bars rise at once and fall back slowly (as on a stereo), and the
    /// loudest moments reach the top, so quiet recordings move too.
    static func smoothed(_ frames: Frames) -> Frames {
        var result = frames
        var previous = [Float](repeating: 0, count: bandCount)
        for index in result.bands.indices {
            let bands = zip(result.bands[index], previous).map { max($0, $1 * 0.82) }
            result.bands[index] = bands
            previous = bands
        }
        let all = result.bands.flatMap { $0 }.sorted()
        let top = all.isEmpty ? 1 : max(all[min(Int(Double(all.count) * 0.995), all.count - 1)], 0.05)
        result.bands = result.bands.map { $0.map { min($0 / top, 1) } }
        let peaks = result.waves.flatMap { $0.map(abs) }.sorted()
        let loudest = peaks.isEmpty ? 1 : max(peaks[min(Int(Double(peaks.count) * 0.995), peaks.count - 1)], 0.02)
        result.waves = result.waves.map { $0.map { max(min($0 / loudest, 1), -1) } }
        return result
    }

    /// A Fourier transform into bands spaced like we hear (by octaves).
    final class Spectrum {
        private let size: Int
        private let setup: FFTSetup
        private let window: [Float]
        /// Each band's first and last bin.
        private let ranges: [ClosedRange<Int>]
        /// Decibels added to each band: music is quieter the higher it
        /// goes (about 3 dB an octave), so the high bars would hardly move.
        private let tilt: [Float]

        init(size: Int, rate: Double, bands: Int) {
            self.size = size
            setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(size))), FFTRadix(kFFTRadix2))!
            var window = [Float](repeating: 0, count: size)
            vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
            self.window = window
            let low = 50.0, high = 12_000.0, binWidth = rate / Double(size)
            ranges = (0..<bands).map { band in
                let from = low * pow(high / low, Double(band) / Double(bands))
                let to = low * pow(high / low, Double(band + 1) / Double(bands))
                let first = max(Int(from / binWidth), 1)
                return first...max(Int(to / binWidth), first)
            }
            tilt = (0..<bands).map { band in
                let middle = low * pow(high / low, (Double(band) + 0.5) / Double(bands))
                return Float(max(0, 3 * log2(middle / 200)))
            }
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Each band's level, 0...1 (−60 to 0 dB of a full-scale tone).
        func levels(_ samples: [Float]) -> [Float] {
            let half = size / 2
            var windowed = [Float](repeating: 0, count: size)
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
            var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
            var magnitudes = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { pointer in
                        pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(size))), FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            let fullScale = Float(size) / 2
            return zip(ranges, tilt).map { range, tilt in
                let peak = magnitudes[range.clamped(to: 0...(half - 1))].max() ?? 0
                guard peak > 0 else { return 0 }
                let decibels = 20 * log10(max(peak / fullScale, 1e-6)) + tilt
                return min(max((decibels + 60) / 60, 0), 1)
            }
        }
    }

    // MARK: - Drawing

    /// What stays the same in every frame: the picture or gradient, darkened
    /// a little so the bars stand out, and the title.
    static func backdrop(_ spec: VisualizerSpec, size: CGSize? = nil) throws -> CGImage {
        let size = size ?? spec.shape.size
        guard let ctx = context(size) else { throw ConversionError.failed("Not enough memory to draw the video.") }
        let full = CGRect(origin: .zero, size: size)
        if let path = spec.picture, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 1.5),
           ] as CFDictionary) {
            // Filled, from the middle.
            let scale = max(size.width / CGFloat(picture.width), size.height / CGFloat(picture.height))
            let drawn = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
            ctx.fill(full)
        } else {
            let colors = spec.gradient.colors.map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
            }
        }
        let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            let height = min(size.width, size.height) * 0.05
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, height, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, height, nil)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, title as CFString, attributes as CFDictionary)!)
            let shown = CTLineCreateTruncatedLine(line, Double(size.width * 0.86), .end, CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, "…" as CFString, attributes as CFDictionary)!
            )) ?? line
            let width = CTLineGetTypographicBounds(shown, nil, nil, nil)
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: height * 0.3, color: CGColor(gray: 0, alpha: 0.5))
            ctx.textPosition = CGPoint(x: (size.width - width) / 2, y: size.height * 0.1)
            CTLineDraw(shown, ctx)
        }
        guard let image = ctx.makeImage() else { throw ConversionError.failed("Couldn't draw the video.") }
        return image
    }

    /// One frame: the backdrop, then the bars or the wave across the middle.
    static func draw(_ ctx: CGContext, size: CGSize, spec: VisualizerSpec, background: CGImage, bands: [Float], wave: [Float]) {
        ctx.draw(background, in: CGRect(origin: .zero, size: size))
        let width = size.width * 0.8, left = (size.width - width) / 2
        let middle = size.height * (spec.title.isEmpty ? 0.5 : 0.53)
        let reach = min(size.height * 0.28, size.width * 0.3)
        ctx.setShadow(offset: .zero, blur: min(size.width, size.height) * 0.015, color: spec.color.cgColor.copy(alpha: 0.6))
        ctx.setFillColor(spec.color.cgColor)
        ctx.setStrokeColor(spec.color.cgColor)
        switch spec.style {
        case .bars:
            let step = width / CGFloat(max(bands.count, 1))
            let barWidth = step * 0.62
            for (index, level) in bands.enumerated() {
                let height = max(CGFloat(level) * reach, barWidth * 0.5)
                let bar = CGRect(x: left + CGFloat(index) * step + (step - barWidth) / 2, y: middle - height, width: barWidth, height: height * 2)
                ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
            }
            ctx.fillPath()
        case .wave:
            guard wave.count > 1 else { return }
            let step = width / CGFloat(wave.count - 1)
            let points = wave.enumerated().map { CGPoint(x: left + CGFloat($0.offset) * step, y: middle + CGFloat($0.element) * reach) }
            ctx.move(to: points[0])
            for (a, b) in zip(points, points.dropFirst()) {
                ctx.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
            }
            ctx.addLine(to: points[points.count - 1])
            ctx.setLineWidth(max(min(size.width, size.height) * 0.006, 2))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// A small picture of how it will look (with made-up levels), for the window.
    public static func preview(_ spec: VisualizerSpec, longerSide: CGFloat = 480) -> CGImage? {
        let full = spec.shape.size
        let scale = longerSide / max(full.width, full.height)
        let size = CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())
        guard let background = try? backdrop(spec, size: size), let ctx = context(size) else { return nil }
        let bands = (0..<bandCount).map(previewBand)
        let wave = (0..<wavePoints).map(previewWave)
        draw(ctx, size: size, spec: spec, background: background, bands: bands, wave: wave)
        return ctx.makeImage()
    }

    /// Made-up levels for the preview: higher low down, lower up high.
    private static func previewBand(_ index: Int) -> Float {
        let position = Double(index)
        let shape: Double = abs(sin(position * 0.42))
        let fall: Double = 1 - position / Double(bandCount) * 0.6
        return Float(0.25 + 0.65 * shape * fall)
    }

    private static func previewWave(_ index: Int) -> Float {
        let position = Double(index)
        let slow: Double = sin(position * 0.3) * 0.5
        let quick: Double = sin(position * 0.11) * 0.3
        return Float(slow + quick)
    }

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    // MARK: - Writing

    /// The frames as H.264 and the sound as AAC, side by side in one MP4.
    static func write(
        _ sound: SoundTrack, frames: Frames, spec: VisualizerSpec, background: CGImage, to destination: URL,
        isCancelled: () -> Bool, progress: (Double) -> Void
    ) throws {
        let size = spec.shape.size
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoExpectedSourceFrameRateKey: framesPerSecond],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(video)

        let channels = sound.channels
        let reader = try AVAssetReader(asset: sound.asset)
        let pcm = AVAssetReaderTrackOutput(track: sound.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(pcm)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(audio)

        guard reader.startReading(), writer.startWriting() else {
            throw ConversionError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Couldn't make the video.")
        }
        writer.startSession(atSourceTime: .zero)
        var frame = 0
        var videoDone = frames.bands.isEmpty, audioDone = false
        if videoDone { video.markAsFinished() }
        // Each input takes more when it's ready; the writer keeps them in step.
        while !(videoDone && audioDone) {
            if isCancelled() {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            var progressed = false
            if !audioDone && audio.isReadyForMoreMediaData {
                if let buffer = pcm.copyNextSampleBuffer() {
                    audio.append(buffer)
                } else {
                    audio.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }
            if !videoDone && video.isReadyForMoreMediaData {
                guard let pool = adaptor.pixelBufferPool else { throw ConversionError.failed("Couldn't make the video.") }
                var made: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                guard let buffer = made else { throw ConversionError.failed("Not enough memory to draw the video.") }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ) {
                    draw(ctx, size: size, spec: spec, background: background, bands: frames.bands[frame], wave: frames.waves[frame])
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
                frame += 1
                if frame >= frames.bands.count {
                    video.markAsFinished()
                    videoDone = true
                }
                if frame % 30 == 0 { progress(Double(frame) / Double(frames.bands.count)) }
                progressed = true
            }
            if writer.status == .failed { break }
            if !progressed { usleep(2000) }
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't make the video.")
        }
        progress(1)
    }
}
