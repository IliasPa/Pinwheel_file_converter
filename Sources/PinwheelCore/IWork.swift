import Foundation

/// Pages, Keynote and Numbers (free from Apple), asked with AppleScript to
/// open a file and export it: what only they can read or write (.pages,
/// .key, .numbers, old .ppt and .xls), and slides drawn exactly.
/// macOS asks once whether Pinwheel may control each of them.
enum IWork {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"

        var bundleID: String { "com.apple.iWork.\(rawValue)" }
        var tool: ExternalTool {
            switch self {
            case .pages: .pages
            case .keynote: .keynote
            case .numbers: .numbers
            }
        }
    }

    /// The app's export formats (written into the script, never typed in).
    enum Export: String {
        case native
        case pdf = "PDF"
        case word = "Microsoft Word"
        case epub = "EPUB"
        case text = "unformatted text"
        case richText = "formatted text"
        case powerPoint = "Microsoft PowerPoint"
        case excel = "Microsoft Excel"
        case csv = "CSV"
    }

    /// Opens `input` in the app and exports it (or saves it in the app's
    /// own format) to `output`. One file at a time per app; the app quits
    /// afterwards if Pinwheel started it.
    static func export(_ input: URL, with app: App, as format: Export, to output: URL) async throws {
        guard app.tool.locate() != nil else {
            throw ConversionError.failed("This needs \(app.rawValue), free on the App Store.")
        }
        let action = format == .native ? "save theDocument in outputFile" : "export theDocument to outputFile as \(format.rawValue)"
        // The script itself asks whether the app was running (it knows
        // better than this process). On an error too, the document is
        // closed and the app quits if Pinwheel started it; quitting takes a
        // moment, and the next job mustn't take the app for one that's open.
        let script = """
        on run argv
            set inputFile to POSIX file (item 1 of argv)
            set outputFile to POSIX file (item 2 of argv)
            set wasRunning to application id "\(app.bundleID)" is running
            set failure to missing value
            with timeout of 600 seconds
                tell application id "\(app.bundleID)"
                    try
                        set theDocument to open inputFile
                        \(action)
                    on error message number code
                        set failure to {message, code}
                    end try
                    try
                        close theDocument saving no
                    end try
                    if not wasRunning then quit
                end tell
            end timeout
            if not wasRunning then
                repeat 60 times
                    if application id "\(app.bundleID)" is not running then exit repeat
                    delay 0.25
                end repeat
            end if
            if failure is not missing value then error (item 1 of failure) number (item 2 of failure)
        end run
        """
        let lock = try await Lock.take(app.rawValue)
        defer { lock.release() }
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"), ["-", input.path, output.path], input: Data(script.utf8)
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.failed(problem(result.stderr, app: app))
        }
    }

    static func problem(_ stderr: String, app: App) -> String {
        if stderr.contains("-1743") || stderr.lowercased().contains("not authorized") {
            return "Pinwheel isn't allowed to use \(app.rawValue). Allow it in System Settings › Privacy & Security › Automation."
        }
        if stderr.contains("-1712") { return "\(app.rawValue) took too long to answer." }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "it stopped with an error"
        let reason = line.replacing(#/^.*execution error: /#, with: "").replacingOccurrences(of: "\(app.rawValue) got an error: ", with: "")
        return "\(app.rawValue) couldn't do it: \(reason)"
    }

    /// One job per app at a time, across Pinwheel's workers too.
    final class Lock: @unchecked Sendable {
        private let descriptor: Int32

        private init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        static func take(_ name: String) async throws -> Lock {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(name).lock").path
            let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else { throw ConversionError.failed("Couldn't wait for \(name).") }
            try await Blocking.run { _ in _ = flock(descriptor, LOCK_EX) }
            return Lock(descriptor: descriptor)
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
