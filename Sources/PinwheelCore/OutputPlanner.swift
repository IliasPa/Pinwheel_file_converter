import Foundation

/// Everything decided about a job's output before any work starts. The
/// converters follow it instead of working things out again.
struct OutputPlan: Sendable, Equatable {
    var folder: URL
    var baseName: String
    /// Goes in brackets: "photo (converted).png".
    var suffix: String
    /// The format being written (for a folder of PDF pages: the image format).
    /// nil when a tool keeps the original container (e.g. Strip Info on a .mkv).
    var format: OutputFormat?
    /// Extension of the output file; nil when the output is a folder.
    var fileExtension: String?
    /// Why the output isn't where you asked for it, if it isn't.
    var folderNote: String?
}

enum OutputPlanner {
    static func plan(_ request: ConversionRequest, options: ConversionOptions) -> OutputPlan {
        // A combined PDF is named after its first page (first file by name).
        let file = request.isCombinedPDF
            ? request.files.min { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }!
            : request.files[0]
        let (folder, note) = outputFolder(for: file.url, options: options)
        var plan = OutputPlan(
            folder: folder,
            baseName: file.url.deletingPathExtension().lastPathComponent,
            suffix: "converted",
            format: nil,
            fileExtension: nil,
            folderNote: note
        )
        switch request.action {
        case .convert(let format):
            plan.format = format
            if request.isCombinedPDF {
                plan.suffix = "combined"
                plan.fileExtension = OutputFormat.pdf.fileExtension
            } else if file.kind == .pdf, PDFConverter.pageCount(of: file.url) > 1 {
                plan.fileExtension = nil  // a folder with one image per page
            } else {
                plan.fileExtension = format.fileExtension
            }
        case .tool(let tool):
            plan.suffix = tool.nameSuffix(options: options)
            (plan.format, plan.fileExtension) = toolOutput(tool, for: file)
        }
        return plan
    }

    /// What a tool writes. Formats are kept whenever that makes sense.
    static func toolOutput(_ tool: ToolAction, for file: SourceFile) -> (OutputFormat?, String) {
        let ext = file.url.pathExtension.lowercased()
        switch (file.kind, tool) {
        case (.image, .compress):
            // JPEG, HEIC and PNG stay what they are. Formats that can't get
            // smaller themselves (TIFF, BMP, camera RAW…) become HEIC.
            if let format = file.format, [.jpeg, .heic, .png].contains(format) { return (format, ext) }
            return (.heic, OutputFormat.heic.fileExtension)
        case (.image, _):
            if let format = file.format, [.png, .jpeg, .heic, .tiff, .gif].contains(format) { return (format, ext) }
            return (.png, OutputFormat.png.fileExtension)
        case (.video, .compress):
            return (.mp4, OutputFormat.mp4.fileExtension)
        case (.video, .extractAudio), (.audio, .compress):
            return (.m4a, OutputFormat.m4a.fileExtension)
        case (.pdf, _):
            return (.pdf, OutputFormat.pdf.fileExtension)
        default:
            return (nil, ext)  // Strip Info keeps the original container
        }
    }

    /// The chosen place, or the fallback folder (Downloads) with a note when
    /// that place can't be written to, e.g. a disk image or a read-only share.
    static func outputFolder(for source: URL, options: ConversionOptions) -> (URL, String?) {
        let preferred: URL = switch options.saveLocation {
        case .nextToOriginal: source.deletingLastPathComponent()
        case .downloads: options.fallbackFolder
        case .folder(let folder): folder
        }
        if isWritableFolder(preferred) { return (preferred, nil) }
        let fallback = options.fallbackFolder.lastPathComponent
        let note = options.saveLocation == .nextToOriginal
            ? "Saved in \(fallback): the original's folder is read-only."
            : "Saved in \(fallback): the chosen folder can't be written to."
        return (options.fallbackFolder, note)
    }

    static func isWritableFolder(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: folder.path)
    }
}
