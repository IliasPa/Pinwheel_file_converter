import Foundation

/// How a job's output will be named.
public struct OutputPlan: Sendable, Equatable {
    /// Goes in brackets: "photo (converted).png".
    public var suffix: String
    /// nil means the output is a folder (e.g. one image per PDF page).
    public var fileExtension: String?

    public init(suffix: String, fileExtension: String?) {
        self.suffix = suffix
        self.fileExtension = fileExtension
    }
}

public enum Availability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Sends each job to the right converter.
public enum ConversionEngine {
    public static func plan(for file: SourceFile, action: WheelAction) -> OutputPlan {
        switch action {
        case .convert(let format):
            OutputPlan(suffix: "converted", fileExtension: format.fileExtension)
        case .tool(let tool):
            OutputPlan(suffix: tool.nameSuffix, fileExtension: file.url.pathExtension.lowercased())
        }
    }

    /// Whether a wedge can be used right now (it's grayed out otherwise).
    public static func availability(of action: WheelAction, for files: [SourceFile], ffmpegAvailable: Bool) -> Availability {
        for file in files {
            guard let kind = file.kind else {
                return .unavailable("Pinwheel can't convert this kind of file")
            }
            switch (kind, action) {
            case (.image, .convert):
                continue
            default:
                return .unavailable("Coming in the next update")
            }
        }
        return .available
    }

    /// Runs one conversion off the main thread. Returns the files it wrote.
    /// On failure or cancellation, anything half-written is deleted.
    @concurrent
    public static func run(
        file: SourceFile,
        action: WheelAction,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        guard let kind = file.kind else {
            throw ConversionError.unsupported(file.url.lastPathComponent)
        }
        do {
            try Task.checkCancellation()
            let outputs: [URL]
            switch (kind, action) {
            case (.image, .convert(let format)):
                progress(0.1)
                try ImageConverter.convert(file.url, to: format, destination: destination, options: options)
                outputs = [destination]
            default:
                throw ConversionError.unsupported("\(action.title(in: .convert)) for \(file.url.lastPathComponent)")
            }
            try Task.checkCancellation()
            progress(1)
            return outputs
        } catch {
            // The destination was a fresh, unused name, so removing it can't
            // touch anything that existed before.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
