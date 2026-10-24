import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures that move (animated GIF, PNG, WebP and HEIC): they stay moving
/// as GIF, PNG (APNG), HEIC (an image sequence), WebP (with Homebrew's webp
/// tools), MP4 and WebM; other formats get the first frame. Videos become
/// animated WebP here too.
enum AnimatedPicture {
    struct Frame {
        var image: CGImage
        /// Seconds it shows.
        var delay: Double
    }

    /// The formats that keep the motion.
    static let keepsMotion: Set<OutputFormat> = [.gif, .png, .heic, .webp, .mp4, .webm]

    /// More than one frame, each shown for a time.
    static func isAnimated(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 1 else { return false }
        return delay(src, at: 0) != nil
    }

    /// Seconds frame `index` shows; nil when the picture doesn't say (not an animation).
    static func delay(_ src: CGImageSource, at index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return nil }
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictionary, unclamped, clamped) in keys {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            if let seconds = (values[unclamped] as? Double) ?? (values[clamped] as? Double) { return seconds }
        }
        return nil
    }

    /// The picture's frames, one at a time (a long animation can be hundreds).
    struct Frames {
        let count: Int
        let frame: (Int) throws -> Frame
    }

    static func frames(of url: URL) throws -> Frames {
        let src = try ImageConverter.open(url)
        return Frames(count: CGImageSourceGetCount(src)) { index in
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else { throw ConversionError.unreadable(url.lastPathComponent) }
            // Browsers show very short frames (under 0.02 s) for 0.1 s: as the maker saw them.
            let seconds = delay(src, at: index) ?? 0.1
            return Frame(image: image, delay: seconds < 0.02 ? 0.1 : seconds)
        }
    }

    /// An animated picture into `format`, still moving.
    static func convert(_ source: URL, to format: OutputFormat, destination: URL, options: ConversionOptions,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        switch format {
        case .webp:
            try await writeWebP(frames(of: source), to: destination, options: options, progress: progress)
        case .webm:
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            try await webm(source, destination: destination, ffmpeg: ffmpeg, progress: progress)
        case .mp4:
            try await Blocking.run { _ in try writeMP4(try frames(of: source), to: destination, background: options.jpegBackground, progress: progress) }
        default:
            try await Blocking.run { _ in try writeWithImageIO(try frames(of: source), to: destination, as: format, options: options, progress: progress) }
        }
    }

    // MARK: - GIF, APNG and HEIC sequences

    static func writeWithImageIO(_ frames: Frames, to url: URL, as format: OutputFormat, options: ConversionOptions,
                                 progress: (Double) -> Void) throws {
        let type = format == .heic ? "public.heics" : format.utType.identifier
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames.count, nil) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        // Played over and over, as the original.
        let loop: [CFString: Any] = switch format {
        case .gif: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        case .png: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        default: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]]
        }
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        for index in 0..<frames.count {
            try Task.checkCancellation()
            let frame = try frames.frame(index)
            var image = frame.image
            var properties: [CFString: Any]
            switch format {
            case .gif:
                image = GIFPalette.dithered(frame.image) ?? frame.image
                properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay, kCGImagePropertyGIFUnclampedDelayTime: frame.delay]]
            case .png:
                properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: frame.delay, kCGImagePropertyAPNGUnclampedDelayTime: frame.delay]]
            default:
                properties = [
                    kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: frame.delay, kCGImagePropertyHEICSUnclampedDelayTime: frame.delay],
                    kCGImageDestinationLossyCompressionQuality: options.heicQuality,
                ]
            }
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            progress(Double(index + 1) / Double(frames.count) * 0.9)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.cannotWrite(url.lastPathComponent) }
    }

    // MARK: - WebP

    /// img2webp, from the same Homebrew package as cwebp.
    static func img2webp(_ options: ConversionOptions) throws -> URL {
        guard let cwebp = options.cwebpURL else {
            throw ConversionError.failed("WebP needs Homebrew's webp tools. Install them with: \(ExternalTool.cwebp.installCommand)")
        }
        let tool = cwebp.deletingLastPathComponent().appendingPathComponent("img2webp")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw ConversionError.failed("Animated WebP needs img2webp, from Homebrew's webp tools. Install them with: \(ExternalTool.cwebp.installCommand)")
        }
        return tool
    }

    /// Each frame as a lossless PNG, then img2webp puts them together,
    /// choosing lossy or lossless for each (whichever is smaller).
    static func writeWebP(_ frames: Frames, to url: URL, options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void) async throws {
        let tool = try img2webp(options)
        try await withFolder { folder in
            var arguments = ["-loop", "0", "-mixed", "-q", "\(Int((options.webpQuality * 100).rounded()))"]
            for index in 0..<frames.count {
                try Task.checkCancellation()
                let frame = try frames.frame(index)
                let file = folder.appendingPathComponent(String(format: "frame %05d.png", index))
                try ImageConverter.write(frame.image, to: file, format: .png, options: options)
                arguments += ["-d", "\(max(1, Int((frame.delay * 1000).rounded())))", file.path]
                progress(Double(index + 1) / Double(frames.count) * 0.6)
            }
            try await run(tool, arguments + ["-o", url.path])
        }
    }

    /// A video's first seconds as an animated WebP, at the GIF settings
    /// (width, frames per second, length): ffmpeg draws the frames.
    static func webp(fromVideo file: SourceFile, destination: URL, ffmpeg: URL, options: ConversionOptions,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let tool = try img2webp(options)
        var note: String?
        try await withFolder { folder in
            var input: [String] = []
            if let limit = options.gifMaxSeconds {
                input = ["-t", "\(limit)"]
                if let full = await FFmpeg.duration(of: file, ffmpeg: ffmpeg), full > Double(limit) + 0.5 {
                    note = "Only the first \(limit) seconds (you can change this in Settings › Wheels › Formats › GIF)."
                }
            }
            let pattern = folder.appendingPathComponent("frame %05d.png")
            let result = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + input + [
                "-i", file.url.path, "-vf", "fps=\(options.gifFPS),scale='min(\(options.gifWidth),iw)':-2:flags=lanczos",
                "-an", pattern.path,
            ])
            guard result.status == 0 else { throw ConversionError.failed("ffmpeg couldn't read the video: \(result.stderr.split(separator: "\n").last ?? "")") }
            progress(0.5)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }.sorted()
            guard !files.isEmpty else { throw ConversionError.failed("The video has no pictures to make a WebP of.") }
            let milliseconds = max(1, Int((1000 / Double(max(options.gifFPS, 1))).rounded()))
            var arguments = ["-loop", "0", "-mixed", "-q", "\(Int((options.webpQuality * 100).rounded()))"]
            for name in files { arguments += ["-d", "\(milliseconds)", folder.appendingPathComponent(name).path] }
            try await run(tool, arguments + ["-o", destination.path])
        }
        return note
    }

    private static func run(_ tool: URL, _ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(tool, arguments)
        guard result.status == 0 else {
            let reason = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it stopped with an error"
            throw ConversionError.failed("Couldn't make the WebP: \(reason)")
        }
    }

    // MARK: - Videos

    /// H.264, as macOS makes it: no ffmpeg needed. Each frame shows as long
    /// as it did; see-through parts get the JPEG background color (MP4 has
    /// no transparency).
    static func writeMP4(_ frames: Frames, to url: URL, background: String, progress: (Double) -> Void) throws {
        let first = try frames.frame(0)
        // H.264 wants even sizes.
        let width = first.image.width + first.image.width % 2, height = first.image.height + first.image.height % 2
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't make the video.") }
        writer.startSession(atSourceTime: .zero)
        let fill = ImageConverter.color(hex: background) ?? CGColor(gray: 1, alpha: 1)
        var time = 0.0
        for index in 0..<frames.count {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            let frame = index == 0 ? first : try frames.frame(index)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { break }
                usleep(2000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw ConversionError.failed("Couldn't make the video.") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw ConversionError.failed("Not enough memory to draw the video.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.setFillColor(fill)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.draw(frame.image, in: CGRect(x: 0, y: height - frame.image.height, width: frame.image.width, height: frame.image.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            time += frame.delay
            progress(Double(index + 1) / Double(frames.count) * 0.9)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't make the video.")
        }
    }

    /// VP9 with its see-through parts, made by ffmpeg: a GIF as it is, any
    /// other animation from a lossless APNG of its frames.
    static func webm(_ source: URL, destination: URL, ffmpeg: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let arguments = ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-pix_fmt", "yuva420p", "-an"]
        if CGImageSourceCreateWithURL(source as CFURL, nil).flatMap(CGImageSourceGetType) as String? == UTType.gif.identifier {
            try await FFmpeg.convert(ffmpeg: ffmpeg, input: source, output: destination, arguments: arguments, duration: nil, progress: progress)
            return
        }
        try await withFolder { folder in
            let apng = folder.appendingPathComponent("frames.png")
            try await Blocking.run { _ in try writeWithImageIO(try frames(of: source), to: apng, as: .png, options: ConversionOptions()) { progress($0 / 2) } }
            try await FFmpeg.convert(ffmpeg: ffmpeg, input: apng, output: destination, arguments: arguments, duration: nil) { progress(0.5 + $0 / 2) }
        }
    }

    /// A folder of its own in the temporary folder, removed afterwards.
    private static func withFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await body(folder)
    }
}
