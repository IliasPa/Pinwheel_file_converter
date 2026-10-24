import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// File sizes as Finder shows them (1 MB = 1,000,000 bytes).
public enum SizeLimit {
    public static func bytes(megabytes: Double) -> Int64 {
        Int64((megabytes * 1_000_000).rounded())
    }

    /// "10 MB", "2.5 MB", "500 KB".
    public static func title(megabytes: Double) -> String {
        title(bytes: bytes(megabytes: megabytes))
    }

    public static func title(bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 1 { return "\(Int((Double(bytes) / 1000).rounded())) KB" }
        return megabytes.rounded() == megabytes ? "\(Int(megabytes)) MB" : String(format: "%.1f MB", megabytes)
    }

    /// Common limits, with where they come from.
    public static let presets: [(megabytes: Double, hint: String)] = [
        (1, "Web forms"), (2, "Profile pictures"), (5, "Small attachments"), (8, "Chat apps"),
        (10, "Discord, many forms"), (20, "Outlook"), (25, "Gmail"), (50, "Large uploads"),
    ]
}

/// "Size Limit": a file made smaller until it's under a chosen size. Unlike
/// Compress, which uses one quality setting, this works out the quality
/// (and, if needed, the picture size) that fits, then checks the result.
enum SizeLimiter {
    static func run(
        _ file: SourceFile, limit: Int64, format: OutputFormat?, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        guard limit > 0 else { throw ConversionError.failed("Choose a size first.") }
        let size = FileSize.of(file.url) ?? 0
        guard size > limit else {
            throw NothingToDo(reason: "Already under \(SizeLimit.title(bytes: limit)), so nothing was saved.")
        }
        switch file.kind {
        case .image:
            let target = format ?? .jpeg
            return try await Blocking.run { _ in try image(file.url, limit: limit, format: target, destination: destination, background: options.jpegBackground, progress: progress) }
        case .pdf:
            return try await Blocking.run { isCancelled in try pdf(file.url, limit: limit, destination: destination, isCancelled: isCancelled, progress: progress) }
        case .video:
            return try await video(file, limit: limit, destination: destination, options: options, progress: progress)
        case .audio:
            return try await audio(file, limit: limit, destination: destination, options: options, progress: progress)
        case .archive, .document, .spreadsheet, .presentation, .subtitle, nil:
            throw ConversionError.unsupported(file.url.lastPathComponent)
        }
    }

    // MARK: - Pictures

    /// First the highest quality that fits; when even a low quality is too
    /// big, a smaller picture at a good quality.
    static func image(
        _ source: URL, limit: Int64, format: OutputFormat, destination: URL, background: String = "#FFFFFF",
        progress: @Sendable (Double) -> Void
    ) throws -> String? {
        let src = try ImageConverter.open(source)
        if CGImageSourceGetCount(src) > 1, CGImageSourceGetType(src) as String? == OutputFormat.gif.utType.identifier {
            throw ConversionError.failed("Size Limit doesn't work on animated GIFs yet.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let properties = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false

        // Same pixels, lower quality: the metadata and orientation stay as they are.
        let sameSize: (Double) throws -> Data = { quality in
            try encode(format: format) { dest in
                let settings: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
                if format == .jpeg && hasAlpha, let image = CGImageSourceCreateImageAtIndex(src, index, nil) {
                    let flat = try ImageConverter.flatten(image, onto: background)
                    CGImageDestinationAddImage(dest, flat, ImageConverter.metadata(from: properties).merging(settings) { $1 } as CFDictionary)
                } else {
                    CGImageDestinationAddImageFromSource(dest, src, index, settings as CFDictionary)
                }
            }
        }
        progress(0.1)
        if let (data, quality) = try bestQuality(limit: limit, range: 0.3...0.92, encode: sameSize) {
            try write(data, to: destination)
            return "Saved at \(Int((quality * 100).rounded()))% quality."
        }

        // Smaller pictures, until one fits at a decent quality.
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let metadata = ImageConverter.uprightMetadata(from: properties)
        // The file shrinks about with the area, so with the square of the side.
        let estimate = Double(try sameSize(0.75).count)
        var longSide = Double(max(width, height, 1)) * min(0.9, (Double(limit) / max(estimate, 1)).squareRoot() * 0.95)
        for round in 0..<10 {
            progress(0.3 + Double(round) * 0.06)
            if round > 0 { longSide *= 0.85 }
            longSide = max(longSide.rounded(), 16)
            let image = try ImageConverter.orientedImage(src, index: index, maxPixelSize: Int(longSide))
            let flat = format == .jpeg && hasAlpha ? try ImageConverter.flatten(image, onto: background) : image
            let smaller: (Double) throws -> Data = { quality in
                try encode(format: format) { dest in
                    let settings = metadata.merging([kCGImageDestinationLossyCompressionQuality: quality]) { $1 }
                    CGImageDestinationAddImage(dest, flat, settings as CFDictionary)
                }
            }
            if let (data, quality) = try bestQuality(limit: limit, range: 0.6...0.9, encode: smaller) {
                try write(data, to: destination)
                return "Made \(flat.width) × \(flat.height) px at \(Int((quality * 100).rounded()))% quality to fit."
            }
            if longSide <= 16 { break }
        }
        throw NothingToDo(reason: "Couldn't get it under \(SizeLimit.title(bytes: limit)), so nothing was saved.")
    }

    /// The highest quality in `range` whose result fits, found by halving.
    static func bestQuality(limit: Int64, range: ClosedRange<Double>, encode: (Double) throws -> Data) throws -> (Data, Double)? {
        let top = try encode(range.upperBound)
        if top.count <= limit { return (top, range.upperBound) }
        var low = range.lowerBound, high = range.upperBound
        let floor = try encode(low)
        guard floor.count <= limit else { return nil }
        var best = (floor, low)
        for _ in 0..<6 {
            let middle = (low + high) / 2
            let data = try encode(middle)
            if data.count <= limit {
                best = (data, middle)
                low = middle
            } else {
                high = middle
            }
        }
        return best
    }

    private static func encode(format: OutputFormat, _ add: (CGImageDestination) throws -> Void) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("macOS can't write \(format.title) pictures.")
        }
        try add(dest)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Couldn't make the smaller picture.") }
        return data as Data
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .withoutOverwriting) } catch { throw ConversionError.cannotWrite(url.lastPathComponent) }
    }

    // MARK: - PDFs

    /// The pictures inside at lower and lower resolution and quality, until
    /// the PDF fits. Text and drawings stay sharp at every step.
    static func pdf(
        _ source: URL, limit: Int64, destination: URL, isCancelled: () -> Bool,
        progress: @Sendable (Double) -> Void
    ) throws -> String? {
        let steps: [(dpi: Double, quality: Double)] = [(150, 0.7), (120, 0.6), (100, 0.5), (85, 0.45), (72, 0.4), (60, 0.35), (50, 0.3)]
        let attempt = destination.deletingLastPathComponent()
            .appendingPathComponent(".pinwheel-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: attempt) }
        var smallest: Int64?
        for (number, step) in steps.enumerated() {
            if isCancelled() { throw CancellationError() }
            try? FileManager.default.removeItem(at: attempt)
            try PDFConverter.compress(source, destination: attempt, quality: step.quality, dpi: step.dpi)
            let size = FileSize.of(attempt) ?? .max
            smallest = min(smallest ?? size, size)
            progress(Double(number + 1) / Double(steps.count))
            if size <= limit {
                try FileManager.default.moveItem(at: attempt, to: destination)
                return "Pictures inside saved at \(Int(step.dpi)) DPI to fit."
            }
        }
        let best = smallest.map { " (the smallest was \(SizeLimit.title(bytes: $0)): it's mostly text or drawings)" } ?? ""
        throw NothingToDo(reason: "Couldn't get it under \(SizeLimit.title(bytes: limit))\(best), so nothing was saved.")
    }

    // MARK: - Video and audio

    /// Bits per second available for the whole file, keeping a little for
    /// the container.
    static func budget(limit: Int64, duration: Double) -> Double {
        Double(limit) * 8 * 0.95 / max(duration, 0.1)
    }

    /// Sound for a total budget: good when there's room, smaller when not.
    static func audioRate(forTotal total: Double) -> Int {
        total > 2_000_000 ? 128_000 : (total > 700_000 ? 96_000 : 64_000)
    }

    /// The largest picture (long side) that still gets enough bits per pixel
    /// to look clean at this bit rate.
    static func longSide(for video: VideoCompressor.Probe, bitRate: Double) -> Int? {
        let original = max(video.size.width, video.size.height)
        let shorter = min(video.size.width, video.size.height) / max(original, 1)
        for side in [nil, 3840, 2560, 1920, 1280, 960, 854, 640, 480, 320] as [Int?] {
            let long = side.map { min(CGFloat($0), original) } ?? original
            if let side, CGFloat(side) >= original { continue }
            let pixels = Double(long * long * shorter)
            if bitRate / (pixels * video.fps) >= 0.04 { return side }
        }
        return 320
    }

    static func video(
        _ file: SourceFile, limit: Int64, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        if file.needsFFmpegToRead {
            return try await ffmpegVideo(file, limit: limit, destination: destination, options: options, progress: progress)
        }
        let probe = try await VideoCompressor.probe(file.url)
        let total = budget(limit: limit, duration: probe.duration)
        let sound = probe.hasSound ? audioRate(forTotal: total) : 0
        var videoRate = total - Double(sound)
        guard videoRate >= 80_000 else { throw tooLong(limit: limit, duration: probe.duration) }
        var side = longSide(for: probe, bitRate: videoRate)
        let attempts = 5
        /// Bit rates tried at the current picture size, and the sizes they made.
        var tried: [(rate: Double, size: Double)] = []

        for attempt in 0..<attempts {
            try? FileManager.default.removeItem(at: destination)
            let rate = Int(videoRate)
            // No second may take much more than its share (a little more at first).
            let peak = Int(Double(rate) / 8 * (attempt == 0 ? 1.2 : 1))
            try await VideoCompressor.encode(
                file.url, destination: destination, longSide: side, audioBitRate: sound, peakBytesPerSecond: peak,
                // Most fit the first time; a second go fills in the rest of the bar.
                progress: { value in progress(attempt == 0 ? value * 0.8 : min(0.8 + 0.04 * Double(attempt - 1) + value * 0.04, 0.99)) },
                bitRate: { _, _, _ in rate }
            )
            let size = FileSize.of(destination) ?? .max
            if size <= limit {
                let picture = side.map { "\($0) px, " } ?? ""
                return "Made at \(picture)\(String(format: "%.1f", Double(rate) / 1_000_000)) Mbit/s to fit."
            }
            // The encoder aims, it doesn't promise. Busy pictures have a floor
            // it can't go under, so a lower bit rate saves less and less: after
            // two tries, aim with how much the last change saved.
            let over = Double(size) / Double(limit)
            tried.append((Double(rate), Double(size)))
            let target = Double(limit) * 0.96
            if tried.count >= 2 {
                let (a, b) = (tried[tried.count - 2], tried[tried.count - 1])
                let slope = (b.size - a.size) / (b.rate - a.rate)
                videoRate = slope > 0 ? b.rate + (target - b.size) / slope : b.rate * 0.92 / over
                if videoRate >= b.rate || videoRate < 20_000 { videoRate = b.rate * 0.85 / over }
            } else {
                videoRate *= 0.92 / over
            }
            // Far off: a smaller picture too (then the tries start over).
            if over > 1.15 {
                let current = side.map(Double.init) ?? Double(max(probe.size.width, probe.size.height))
                side = max(Int(current * 0.8), 160)
                tried.removeAll()
            }
        }
        try? FileManager.default.removeItem(at: destination)
        throw NothingToDo(reason: "Couldn't get it under \(SizeLimit.title(bytes: limit)), so nothing was saved.")
    }

    static func ffmpegVideo(
        _ file: SourceFile, limit: Int64, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
        guard let duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg), duration > 0 else {
            throw ConversionError.failed("Couldn't tell how long \(file.url.lastPathComponent) is.")
        }
        let total = budget(limit: limit, duration: duration)
        let sound = audioRate(forTotal: total)
        var videoRate = total - Double(sound)
        guard videoRate >= 80_000 else { throw tooLong(limit: limit, duration: duration) }
        for attempt in 0..<4 {
            try? FileManager.default.removeItem(at: destination)
            let rate = Int(videoRate)
            let arguments = [
                "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "medium",
                "-b:v", "\(rate)", "-maxrate", "\(Int(Double(rate) * 1.4))", "-bufsize", "\(rate * 2)", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "\(sound)", "-movflags", "+faststart",
            ]
            try await FFmpeg.convert(
                ffmpeg: ffmpeg, input: file.url, output: destination, arguments: arguments, duration: duration,
                progress: { progress((Double(attempt) + $0) / 4) }
            )
            let size = FileSize.of(destination) ?? .max
            if size <= limit { return "Made at \(String(format: "%.1f", Double(rate) / 1_000_000)) Mbit/s to fit." }
            videoRate *= 0.92 * Double(limit) / Double(size)
        }
        try? FileManager.default.removeItem(at: destination)
        throw NothingToDo(reason: "Couldn't get it under \(SizeLimit.title(bytes: limit)), so nothing was saved.")
    }

    /// Audio bit rates to choose from, highest first.
    static let audioRates = [256, 192, 160, 128, 112, 96, 80, 64, 56, 48, 40, 32, 24, 16].map { $0 * 1000 }

    static func audio(
        _ file: SourceFile, limit: Int64, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        let duration: Double
        if file.needsFFmpegToRead {
            guard let ffmpeg = options.ffmpegURL else { throw ConversionError.needsFFmpeg }
            duration = await FFmpeg.duration(of: file, ffmpeg: ffmpeg) ?? 0
        } else {
            duration = try await AVURLAsset(url: file.url).load(.duration).seconds
        }
        guard duration > 0 else { throw ConversionError.failed("Couldn't tell how long \(file.url.lastPathComponent) is.") }
        let total = budget(limit: limit, duration: duration)
        guard let rate = audioRates.first(where: { Double($0) <= total }) else {
            throw tooLong(limit: limit, duration: duration)
        }
        // Low bit rates sound better in mono (and, lowest of all, at a lower sample rate).
        let channels = rate < 64_000 ? 1 : nil
        let sampleRate: Double? = rate < 32_000 ? 22_050 : nil
        if file.needsFFmpegToRead, let ffmpeg = options.ffmpegURL {
            var arguments = ["-vn", "-c:a", "aac", "-b:a", "\(rate)"]
            if let channels { arguments += ["-ac", "\(channels)"] }
            if let sampleRate { arguments += ["-ar", "\(Int(sampleRate))"] }
            try await FFmpeg.convert(ffmpeg: ffmpeg, input: file.url, output: destination, arguments: arguments, duration: duration, progress: progress)
        } else {
            try await AudioCompressor.compress(
                file.url, destination: destination, bitRate: rate, channels: channels, sampleRate: sampleRate, progress: progress
            )
        }
        guard (FileSize.of(destination) ?? .max) <= limit else {
            try? FileManager.default.removeItem(at: destination)
            throw NothingToDo(reason: "Couldn't get it under \(SizeLimit.title(bytes: limit)), so nothing was saved.")
        }
        return "Saved at \(rate / 1000) kbit/s\(channels == 1 ? " (mono)" : "") to fit."
    }

    /// How much room this length needs at the lowest usable quality.
    private static func tooLong(limit: Int64, duration: Double) -> NothingToDo {
        let needed = SizeLimit.title(bytes: Int64(duration * 100_000 / 8 / 0.95) + 1)
        return NothingToDo(reason: "Too long to fit in \(SizeLimit.title(bytes: limit)): it needs at least about \(needed). Nothing was saved.")
    }
}
