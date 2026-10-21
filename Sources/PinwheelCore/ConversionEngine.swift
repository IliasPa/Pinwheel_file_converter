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
        case (_, .open):
            false  // the window says what it can do; Info works without ffmpeg
        case (_, .recipe), (_, .file):
            false  // each step is checked on its own (see `availability`); file actions need nothing
        case (.video, .convert(.gif)):
            true
        case (.video, .convert(let format)) where format.needsFFmpeg, (.audio, .convert(let format)) where format.needsFFmpeg:
            true
        case (.video, .tool(let tool)), (.audio, .tool(let tool)):
            ToolConverter.usesFFmpeg(tool, for: file)
        case (.video, _), (.audio, _):
            file.needsFFmpegToRead
        default:
            false
        }
    }

    /// The Apple app a conversion takes (Pages, Keynote, Numbers), if any.
    public static func app(for action: WheelAction, file: SourceFile) -> ExternalTool? {
        guard case .convert(let format) = action else { return nil }
        if let app = format.app { return app }
        switch file.url.pathExtension.lowercased() {
        case "pages": return .pages
        case "key", "ppt", "pptx": return .keynote
        case "numbers", "xls": return .numbers
        default: return nil
        }
    }

    /// Whether a wedge can be used right now (it's grayed out otherwise).
    public static func availability(
        of action: WheelAction, for files: [SourceFile], ffmpegAvailable: Bool, cwebpAvailable: Bool = true
    ) -> Availability {
        if case .file = action { return .available }  // any files and folders
        if action == .tool(.archive) { return files.isEmpty ? .unavailable("Nothing to put in it") : .available }
        if action == .convert(.webp) && !cwebpAvailable {
            return .unavailable("Needs cwebp (\(ExternalTool.cwebp.installCommand))")
        }
        if action == .tool(.merge) && files.count < 2 {
            return .unavailable("Drop two or more PDFs to merge them")
        }
        if action == .open(.collage) && files.count < 2 {
            return .unavailable("Drop two or more pictures")
        }
        if case .recipe(let recipe) = action {
            return recipeAvailability(recipe, for: files, ffmpegAvailable: ffmpegAvailable)
        }
        for file in files {
            guard file.kind != nil else {
                return .unavailable("Pinwheel can't convert this kind of file")
            }
            if action == .open(.trim) && file.needsFFmpegToRead {
                return .unavailable("macOS can't play this file, so it can't be edited here")
            }
            if action == .tool(.normalize) && file.needsFFmpegToRead {
                return .unavailable("macOS can't read this file")
            }
            if usesFFmpeg(action, for: file) && !ffmpegAvailable {
                return .unavailable("Needs ffmpeg (brew install ffmpeg)")
            }
            if let app = app(for: action, file: file), app.locate() == nil {
                return .unavailable("Needs \(app.name), free on the App Store")
            }
        }
        return .available
    }

    /// A custom action works when every step does, on what the step before made.
    static func recipeAvailability(_ recipe: Recipe, for files: [SourceFile], ffmpegAvailable: Bool) -> Availability {
        if let problem = recipe.problem { return .unavailable(problem) }
        for file in files {
            guard file.kind == recipe.kind else { return .unavailable("Made for \(recipe.kind.pluralTitle.lowercased())") }
            var current = file
            for step in recipe.steps {
                let action = step.job.action
                if case .unavailable(let reason) = availability(of: action, for: [current], ffmpegAvailable: ffmpegAvailable) {
                    return .unavailable("\(step.title): \(reason)")
                }
                // The next step gets what this one makes (as far as can be told beforehand).
                let single = Recipe(name: step.title, kind: recipe.kind, steps: [step])
                guard let ext = OutputPlanner.recipeOutput(single, for: current, options: ConversionOptions()).1 else { break }
                current = SourceFile(url: file.url.deletingLastPathComponent().appendingPathComponent("pinwheel-step.\(ext)"))
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
        // A ZIP takes anything, folders too; everything else needs files Pinwheel knows.
        guard !request.files.isEmpty, request.action == .tool(.archive) || request.files.allSatisfy({ $0.kind != nil }) else {
            throw ConversionError.unsupported(request.files.first?.url.lastPathComponent ?? "This file")
        }
        if case .open(let editor) = request.action {
            // Editors open a window, which then starts a `.tool` job.
            throw ConversionError.unsupported("\(editor.title) as a job")
        }
        if case .file(let action) = request.action {
            throw ConversionError.unsupported("\(action.title) as a job")
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
            var outputs = [destination]
            switch (file.kind, request.action) {
            case (.image, .convert) where request.isCombinedPDF:
                try ImageConverter.combineIntoPDF(request.files.map(\.url), destination: destination, progress: progress)
            case (.image, .convert(.webp)):
                progress(0.1)
                try await ImageConverter.writeWebP(file.url, destination: destination, options: options)
            case (.image, .convert(.icns)):
                progress(0.1)
                try await IconWriter.writeICNS(file.url, destination: destination)
            case (.image, .convert(let format)):
                progress(0.1)
                try ImageConverter.convert(file.url, to: format, destination: destination, options: options)
            case (.pdf, .convert(let format)) where format.kind == .image:
                try await PDFConverter.renderPages(file.url, to: format, destination: destination, options: options, progress: progress)
            case (.pdf, .convert(let format)), (.document, .convert(let format)), (.spreadsheet, .convert(let format)),
                 (.presentation, .convert(let format)), (.subtitle, .convert(let format)):
                notes.append(try await DocumentConverter.convert(file, to: format, destination: destination, options: options, progress: progress))
            case (.video, .convert(let format)), (.audio, .convert(let format)):
                notes.append(try await MediaConverter.convert(
                    file, to: format, destination: destination, options: options, part: request.mediaEdit, progress: progress
                ))
            case (.archive, .convert(let format)):
                progress(0.05)
                try await ArchiveTools.convert(file.url, to: format, destination: destination)
            case (_, .tool(let tool)):
                notes.append(try await ToolConverter.run(tool, request: request, plan: plan, destination: destination, options: options, progress: progress))
            case (_, .recipe(let recipe)):
                let result = try await RecipeRunner.run(
                    recipe, file: file, destination: destination, baseName: plan.baseName, suffix: plan.suffix,
                    options: options, progress: progress
                )
                outputs = [result.output]
                notes.append(result.note)
            case (_, .open(let editor)):
                throw ConversionError.unsupported("\(editor.title) as a job")
            case (_, .file(let action)):
                throw ConversionError.unsupported("\(action.title) as a job")
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
            return ConversionResult(outputs: outputs, note: note.isEmpty ? nil : note)
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
