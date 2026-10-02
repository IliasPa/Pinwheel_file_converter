import AVFoundation
import Foundation

/// Optional command-line helpers from Homebrew.
public enum ExternalTool: String, Sendable {
    /// MP3, GIFs from video, and files macOS can't open (MKV, WebM…).
    case ffmpeg
    /// Smaller PNGs that stay PNG.
    case pngquant

    public var installCommand: String { "brew install \(rawValue)" }

    /// The tool to use: `customPath` if it works, else the usual Homebrew
    /// places. nil when it isn't installed.
    public func locate(customPath: String? = nil) -> URL? {
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
    /// `arguments` go between the input and the output path.
    static func convert(
        ffmpeg: URL,
        input: URL,
        output: URL,
        arguments: [String],
        duration: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fullArguments = [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-progress", "pipe:1",
            "-n",  // never overwrite; Pinwheel always picks a new name anyway
            "-i", input.path,
        ] + arguments + [output.path]

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
            let reason = result.stderr
                .split(whereSeparator: \.isNewline)
                .suffix(2)
                .joined(separator: " ")
            throw ConversionError.failed(reason.isEmpty ? "ffmpeg stopped with an error." : "ffmpeg: \(reason)")
        }
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
}

/// Runs a command-line tool and collects its output. Cancelling the Swift
/// task stops the tool.
enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(onStdoutLine: onStdoutLine)
        outPipe.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }

        let handle = ProcessHandle(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ConversionError.failed("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            handle.stop()
        }
        try Task.checkCancellation()
        return Result(status: status, stdout: collector.stdout, stderr: collector.stderr)
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
