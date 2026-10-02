import Foundation

public enum Availability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Plans each job, sends it to the right converter, and checks the result.
public enum ConversionEngine {
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

    /// Runs one job off the main thread. On failure or cancellation, anything
    /// half-written is deleted. A result with no outputs means there was
    /// nothing useful to do, and its note says why.
    @concurrent
    public static func run(
        _ request: ConversionRequest,
        options: ConversionOptions,
        naming: OutputNaming = .shared,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        guard let file = request.files.first, request.files.allSatisfy({ $0.kind != nil }) else {
            throw ConversionError.unsupported(request.files.first?.url.lastPathComponent ?? "This file")
        }
        let plan = OutputPlanner.plan(request, options: options)
        let destination = naming.reserve(
            in: plan.folder, baseName: plan.baseName, suffix: plan.suffix, fileExtension: plan.fileExtension
        )
        defer { naming.release(destination) }

        do {
            try Task.checkCancellation()
            var notes = [plan.folderNote]
            switch (file.kind, request.action) {
            case (.image, .convert) where request.isCombinedPDF:
                try ImageConverter.combineIntoPDF(request.files.map(\.url), destination: destination, progress: progress)
            case (.image, .convert(let format)):
                progress(0.1)
                try ImageConverter.convert(file.url, to: format, destination: destination, options: options)
            case (.pdf, .convert(let format)):
                try PDFConverter.renderPages(file.url, to: format, destination: destination, options: options, progress: progress)
            case (.video, .convert(let format)), (.audio, .convert(let format)):
                notes.append(try await MediaConverter.convert(file, to: format, destination: destination, options: options, progress: progress))
            case (_, .tool(let tool)):
                try await ToolConverter.run(tool, file: file, plan: plan, destination: destination, options: options, progress: progress)
            case (nil, _):
                throw ConversionError.unsupported(file.url.lastPathComponent)
            }
            try Task.checkCancellation()

            if case .tool(.compress) = request.action, let reason = notSmallerReason(file, output: destination, options: options) {
                try? FileManager.default.removeItem(at: destination)
                return ConversionResult(outputs: [], note: reason)
            }
            progress(1)
            let note = notes.compactMap { $0 }.joined(separator: " ")
            return ConversionResult(outputs: [destination], note: note.isEmpty ? nil : note)
        } catch let skip as NothingToDo {
            try? FileManager.default.removeItem(at: destination)
            return ConversionResult(outputs: [], note: skip.reason)
        } catch {
            // The destination was a fresh, unused name, so removing it can't
            // touch anything that existed before.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Compress has to be worth it: if the result isn't clearly smaller, the
    /// original is the better file. Returns why it was thrown away, or nil.
    static func notSmallerReason(_ file: SourceFile, output: URL, options: ConversionOptions) -> String? {
        guard let before = FileSize.of(file.url), let after = FileSize.of(output), before > 0 else { return nil }
        guard Double(after) > Double(before) * (1 - options.minimumSaving) else { return nil }
        var reason = "Already as small as it gets, so nothing was saved."
        if file.format == .png && options.pngquantURL == nil {
            reason += " For smaller PNGs, install pngquant: brew install pngquant"
        }
        return reason
    }
}
