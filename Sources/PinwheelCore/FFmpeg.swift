import AVFoundation
import CoreServices
import Foundation

/// Optional command-line helpers from Homebrew.
public enum ExternalTool: String, Sendable {
    /// MP3, GIFs from video, and files macOS can't open (MKV, WebM…).
    case ffmpeg
    /// Smaller PNGs that stay PNG.
    case pngquant
    /// Text recognition for languages Apple's Vision can't read (Greek).
    case tesseract
    /// WebP pictures (macOS reads them but can't write them).
    case cwebp
    /// Apple's free apps, for what only they can read or write.
    case pages, keynote, numbers

    public var isApp: Bool { [.pages, .keynote, .numbers].contains(self) }

    /// "ffmpeg", "Pages"
    public var name: String { isApp ? rawValue.capitalized : rawValue }

    /// cwebp comes in Homebrew's "webp"; the apps are on the App Store.
    public var installCommand: String {
        if isApp { return "free on the App Store" }
        return "brew install \(self == .cwebp ? "webp" : rawValue)"
    }

    /// The tool to use: `customPath` if it works, else the usual Homebrew
    /// places (apps: wherever macOS knows them). nil when it isn't installed.
    public func locate(customPath: String? = nil) -> URL? {
        if isApp {
            let id = "com.apple.iWork.\(name)" as CFString
            let urls = LSCopyApplicationURLsForBundleIdentifier(id, nil)?.takeRetainedValue() as? [URL]
            return urls?.first { $0.path.hasPrefix("/Applications") } ?? urls?.first
        }
        var candidates = ["/opt/homebrew/bin/\(rawValue)", "/usr/local/bin/\(rawValue)"]
        if let customPath, !customPath.isEmpty {
            candidates.insert((customPath as NSString).expandingTildeInPath, at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Runs ffmpeg, used only for what Apple's frameworks can't do:
/// MP3 encoding, GIFs from video, and reading MKV/WebM/OGG and similar files.
public enum FFmpeg {
    public static let installCommand = ExternalTool.ffmpeg.installCommand

    /// The ffmpeg to use, or nil when none is installed.
    public static func locate(customPath: String? = nil) -> URL? {
        ExternalTool.ffmpeg.locate(customPath: customPath)
    }

    /// Converts `input` into `output`, reporting progress 0...1.
    /// `arguments` go between the input and the output path;
    /// `inputArguments` before the input (e.g. a fast seek).
    static func convert(
        ffmpeg: URL,
        input: URL,
        output: URL,
        inputArguments: [String] = [],
        arguments: [String],
        duration: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fullArguments = [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-progress", "pipe:1",
            "-n",  // never overwrite; Pinwheel always picks a new name anyway
        ] + inputArguments + ["-i", input.path] + arguments + [output.path]

        let result = try await ProcessRunner.run(ffmpeg, fullArguments) { line in
            // ffmpeg writes "key=value" lines; out_time_us is how far it got.
            if line == "progress=end" {
                progress(1)
            } else if line.hasPrefix("out_time_us="), let duration, duration > 0,
                      let micros = Double(line.dropFirst("out_time_us=".count)) {
                progress(min(max(micros / 1_000_000 / duration, 0), 1))
            }
        }
        guard result.status == 0 else {
            if let plain = plainWords(result.stderr, input: input) { throw ConversionError.failed(plain) }
            let reason = result.stderr
                .split(whereSeparator: \.isNewline)
                .suffix(2)
                .joined(separator: " ")
            throw ConversionError.failed(reason.isEmpty ? "ffmpeg stopped with an error." : "ffmpeg: \(reason)")
        }
    }

    /// ffmpeg's complaints that have a plain meaning.
    static func plainWords(_ stderr: String, input: URL) -> String? {
        let lower = stderr.lowercased()
        if lower.contains("invalid data found when processing input") || lower.contains("moov atom not found")
            || lower.contains("end of file") && lower.contains("error opening input") {
            return "\(input.lastPathComponent) seems damaged or incomplete (maybe a download that stopped), so it can't be read."
        }
        if lower.contains("output file is empty, nothing was encoded") || lower.contains("output file does not contain any stream") {
            return "There was nothing to save from \(input.lastPathComponent) there."
        }
        return nil
    }

    /// Length in seconds, from AVFoundation when it can read the file, else ffprobe.
    static func duration(of url: URL, ffmpeg: URL?) async -> Double? {
        if let ffmpeg { return await duration(of: SourceFile(url: url), ffmpeg: ffmpeg) }
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    /// Length in seconds, from AVFoundation when it can read the file, else ffprobe.
    static func duration(of file: SourceFile, ffmpeg: URL) async -> Double? {
        if !file.needsFFmpegToRead,
           let time = try? await AVURLAsset(url: file.url).load(.duration), time.isNumeric {
            return time.seconds
        }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path),
              let result = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error", "-show_entries", "format=duration",
                  "-of", "default=noprint_wrappers=1:nokey=1", file.url.path,
              ]) else { return nil }
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A file's sound: how it's coded and its bit rate.
    struct AudioStream: Equatable {
        var codec: String?
        /// Bits per second; nil when unknown.
        var bitRate: Int?

        /// Coded to be small: some of the sound was already left out.
        var isLossy: Bool {
            ["mp3", "mp2", "aac", "vorbis", "opus", "wmav1", "wmav2", "wmapro", "ac3", "eac3"].contains(codec ?? "")
        }

        /// ffprobe's "key=value" lines: the stream's, then the whole file's
        /// bit rate (used when the stream's isn't known, as with most MP3s).
        init(probe output: String) {
            for line in output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "codec_name", codec == nil { codec = parts[1] }
                if parts[0] == "bit_rate", bitRate == nil, let rate = Int(parts[1]), rate > 0 { bitRate = rate }
            }
        }
    }

    /// What's inside a video or sound file, as ffprobe sees it.
    struct Streams: Equatable {
        /// A picture that moves (not an album cover).
        var video = false
        /// The picture has see-through parts (ProRes 4444, animation codecs).
        var alpha = false
        /// The album cover (an attached picture), by its stream number.
        var cover: Int?
        /// The first sound's channels, rate and layout ("5.1(side)"); nil without sound.
        var channels: Int?
        var sampleRate: Int?
        var layout: String?
        var audioTracks = 0
        /// Subtitles: stream number and codec ("subrip", "mov_text", "hdmv_pgs_subtitle").
        var subtitles: [(index: Int, codec: String)] = []
        /// The title and such are kept with the sound, not the file (Ogg, Opus).
        var tagsOnSound = false

        static func == (a: Streams, b: Streams) -> Bool {
            a.video == b.video && a.alpha == b.alpha && a.cover == b.cover && a.channels == b.channels && a.sampleRate == b.sampleRate && a.layout == b.layout
                && a.audioTracks == b.audioTracks && a.subtitles.map(\.index) == b.subtitles.map(\.index) && a.tagsOnSound == b.tagsOnSound
        }

        /// Subtitles written as text (they can become MP4's or another text kind).
        static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]

        init() {}

        init?(json data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let formatTags = (json["format"] as? [String: Any])?["tags"] as? [String: Any] ?? [:]
            for stream in json["streams"] as? [[String: Any]] ?? [] {
                let index = stream["index"] as? Int ?? 0
                let disposition = stream["disposition"] as? [String: Int] ?? [:]
                switch stream["codec_type"] as? String {
                case "video" where disposition["attached_pic"] == 1:
                    if cover == nil { cover = index }
                case "video":
                    video = true
                    // (VP9 in WebM keeps its see-through plane apart, which
                    // ffmpeg's usual decoder doesn't read: those aren't counted.)
                    let format = stream["pix_fmt"] as? String ?? ""
                    alpha = alpha || format.hasPrefix("yuva") || format.hasPrefix("gbra")
                        || ["rgba", "bgra", "argb", "abgr", "ya8", "ya16le", "rgba64le", "bgra64le"].contains(format)
                case "audio":
                    audioTracks += 1
                    guard channels == nil else { continue }
                    channels = stream["channels"] as? Int
                    sampleRate = (stream["sample_rate"] as? String).flatMap { Int($0) }
                    layout = stream["channel_layout"] as? String
                    let tags = stream["tags"] as? [String: Any] ?? [:]
                    tagsOnSound = !formatTags.keys.contains { $0.lowercased() == "title" } && tags.keys.contains { $0.lowercased() == "title" }
                case "subtitle":
                    subtitles.append((index, stream["codec_name"] as? String ?? ""))
                default:
                    break
                }
            }
        }
    }

    static func streams(of url: URL, ffmpeg: URL) async -> Streams? {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path),
              let result = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path]),
              result.status == 0 else { return nil }
        return Streams(json: Data(result.stdout.utf8))
    }

    static func audioStream(of file: SourceFile, ffmpeg: URL) async -> AudioStream? {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path),
              let result = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,bit_rate:format=bit_rate",
                  "-of", "default=noprint_wrappers=1", file.url.path,
              ]) else { return nil }
        let stream = AudioStream(probe: result.stdout)
        return stream.codec == nil ? nil : stream
    }
}

/// Runs a command-line tool and collects its output. Cancelling the Swift
/// task stops the tool.
enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// `input` is sent to the tool's standard input; `environment` adds to
    /// (or replaces) the variables it inherits.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let inPipe = input == nil ? nil : Pipe()
        if let inPipe {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(onStdoutLine: onStdoutLine)
        // Finished means: the tool quit *and* both outputs were read to the
        // end, in order (so its last line is never lost or out of place).
        let finished = DispatchGroup()
        let exitStatus = Locked<Int32>(0)

        let handle = ProcessHandle(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                finished.enter()
                process.terminationHandler = { ended in
                    exitStatus.value = ended.terminationStatus
                    finished.leave()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ConversionError.failed("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                read(outPipe, into: finished) { collector.appendOut($0) }
                read(errPipe, into: finished) { collector.appendErr($0) }
                finished.notify(queue: .global()) {
                    continuation.resume(returning: exitStatus.value)
                }
                if let input, let writer = inPipe?.fileHandleForWriting {
                    // If the tool quits without reading, fail the write
                    // instead of macOS stopping Pinwheel (SIGPIPE).
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
            }
        } onCancel: {
            handle.stop()
        }
        try Task.checkCancellation()
        return Result(status: status, stdout: collector.stdout, stderr: collector.stderr)
    }

    /// Passes on everything the pipe delivers, chunk by chunk in order, and
    /// leaves `group` at the end of the output.
    private static func read(_ pipe: Pipe, into group: DispatchGroup, _ append: @escaping @Sendable (Data) -> Void) {
        group.enter()
        let ended = Locked(false)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                // Leave exactly once, even if a last call was already on its way.
                if !ended.exchange(true) { group.leave() }
            } else {
                append(data)
            }
        }
    }
}

/// A value shared between threads, behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Changes the value in one step and returns what `body` returns.
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }

    /// Sets a new value and returns the old one, in one step.
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let old = stored
            stored = newValue
            return old
        }
    }
}

/// Lets the cancellation handler (which may run on any thread) stop the process.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func stop() {
        if process.isRunning { process.terminate() }
    }
}

/// Gathers a process's output from background threads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pendingLine = ""
    private let onStdoutLine: (@Sendable (String) -> Void)?

    init(onStdoutLine: (@Sendable (String) -> Void)?) {
        self.onStdoutLine = onStdoutLine
    }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        out.append(data)
        pendingLine += String(decoding: data, as: UTF8.self)
        while let newline = pendingLine.firstIndex(of: "\n") {
            lines.append(String(pendingLine[..<newline]).trimmingCharacters(in: .whitespaces))
            pendingLine = String(pendingLine[pendingLine.index(after: newline)...])
        }
        lock.unlock()
        lines.forEach { onStdoutLine?($0) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        err.append(data)
        lock.unlock()
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}

/// Apple objects that aren't marked Sendable (an asset reader and its
/// writer), handed to the one thread that uses them until it's done.
struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs blocking work (a decoding loop, Vision, offline audio rendering) on
/// a thread of its own instead of Swift's small shared thread pool. Apple's
/// frameworks use that pool themselves, so filling it with waiting work can
/// freeze them. `isCancelled` becomes true when the task is cancelled.
public enum Blocking {
    public static func run<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let cancelled = Locked(false)
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try work { cancelled.value } })
                }
            }
        } onCancel: {
            cancelled.value = true
        }
        try Task.checkCancellation()
        return result
    }
}

/// How long a sound or video file says it is.
enum MediaLength {
    static func of(_ url: URL, ffmpeg: URL?) async -> Double? {
        await FFmpeg.duration(of: url, ffmpeg: ffmpeg).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}
