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
            if file.kind == .pdf, PDFConverter.pageCount(of: file.url) > 1 {
                return OutputPlan(suffix: "converted", fileExtension: nil)
            }
            return OutputPlan(suffix: "converted", fileExtension: format.fileExtension)
        case .tool(let tool):
            return OutputPlan(suffix: tool.nameSuffix, fileExtension: ToolConverter.outputExtension(for: tool, file: file))
        }
    }

    /// Whether ffmpeg is needed for this action on this file.
    public static func usesFFmpeg(_ action: WheelAction, for file: SourceFile) -> Bool {
        switch (file.kind, action) {
        case (.video, .convert(.gif)), (.video, .convert(.mp3)), (.audio, .convert(.mp3)):
            true
        case (.video, .tool(let tool)), (.audio, .tool(let tool)):
            ToolConverter.usesFFmpeg(tool, for: file)
        case (.video, _), (.audio, _):
            file.needsFFmpegToRead
        default:
            false
        }
    }

    /// Whether a wedge can be used right now (it's grayed out otherwise).
    public static func availability(of action: WheelAction, for files: [SourceFile], ffmpegAvailable: Bool) -> Availability {
        for file in files {
            guard file.kind != nil else {
                return .unavailable("Pinwheel can't convert this kind of file")
            }
            if usesFFmpeg(action, for: file) && !ffmpegAvailable {
                return .unavailable("Needs ffmpeg (brew install ffmpeg)")
            }
        }
        return .available
    }

    /// Runs one conversion off the main thread. Returns what it wrote (a file,
    /// or a folder for multi-page PDFs). On failure or cancellation, anything
    /// half-written is deleted.
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
            switch (kind, action) {
            case (.image, .convert(let format)):
                progress(0.1)
                try ImageConverter.convert(file.url, to: format, destination: destination, options: options)
            case (.pdf, .convert(let format)):
                _ = try PDFConverter.renderPages(file.url, to: format, destination: destination, options: options, progress: progress)
            case (.video, .convert(let format)), (.audio, .convert(let format)):
                try await MediaConverter.convert(file, to: format, destination: destination, options: options, progress: progress)
            case (_, .tool(let tool)):
                try await ToolConverter.run(tool, file: file, destination: destination, options: options, progress: progress)
            }
            try Task.checkCancellation()
            progress(1)
            return [destination]
        } catch {
            // The destination was a fresh, unused name, so removing it can't
            // touch anything that existed before.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
