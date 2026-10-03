import Foundation

public enum Availability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// A job with everything about its output decided: the plan, and the exact
/// name to write, already reserved. It can be done in this process or sent
/// to a worker process.
public struct PlannedJob: Sendable, Equatable, Codable {
    public var request: ConversionRequest
    public var options: ConversionOptions
    var plan: OutputPlan
    /// The file (or, for a multi-page PDF, the folder) to write.
    public var destination: URL
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

    /// Runs one job in this process, off the main thread. (The app runs jobs
    /// in a worker process instead; see `ConversionRunner`.) On failure or
    /// cancellation, anything half-written is deleted. A result with no
    /// outputs means there was nothing useful to do, and its note says why.
    @concurrent
    public static func run(
        _ request: ConversionRequest,
        options: ConversionOptions,
        naming: OutputNaming = .shared,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        let job = try prepare(request, options: options, naming: naming)
        defer { naming.release(job.destination) }
        return try await perform(job, progress: progress)
    }

    /// Decides what the job makes and where, and reserves that name so no
    /// other job picks it. Call `naming.release(job.destination)` when done.
    public static func prepare(
        _ request: ConversionRequest,
        options: ConversionOptions,
        naming: OutputNaming = .shared
    ) throws -> PlannedJob {
        guard !request.files.isEmpty, request.files.allSatisfy({ $0.kind != nil }) else {
            throw ConversionError.unsupported(request.files.first?.url.lastPathComponent ?? "This file")
        }
        let plan = OutputPlanner.plan(request, options: options)
        let destination = naming.reserve(
            in: plan.folder, baseName: plan.baseName, suffix: plan.suffix, fileExtension: plan.fileExtension
        )
        return PlannedJob(request: request, options: options, plan: plan, destination: destination)
    }

    /// Does a prepared job: sends it to the right converter and checks the result.
    @concurrent
    public static func perform(
        _ job: PlannedJob,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        let (request, options, plan, destination) = (job.request, job.options, job.plan, job.destination)
        let file = request.files[0]
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
                try await PDFConverter.renderPages(file.url, to: format, destination: destination, options: options, progress: progress)
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
