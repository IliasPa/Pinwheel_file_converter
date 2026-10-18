import Foundation
import PDFKit

/// The PDF tools: Compress, Strip Info, Merge, Split Pages and Add Password.
enum PDFTools {
    static func run(
        _ tool: ToolAction,
        request: ConversionRequest,
        destination: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let source = request.files[0].url
        switch tool {
        case .compress:
            try PDFConverter.compress(source, destination: destination, quality: options.compressQuality, dpi: options.pdfImageDPI)
        case .stripMetadata:
            try PDFConverter.stripMetadata(source, destination: destination)
        case .merge:
            guard request.files.count > 1 else {
                throw NothingToDo(reason: "Merge needs two or more PDFs, so nothing was saved.")
            }
            let ordered = request.files.map(\.url).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            try merge(ordered, destination: destination, progress: progress)
        case .split:
            try split(source, folder: destination, progress: progress)
        case .protect:
            guard case .password(let password)? = request.parameters else {
                throw ConversionError.failed("Choose a password first.")
            }
            try protect(source, password: password, destination: destination)
        default:
            throw ConversionError.unsupported("\(tool.title) for PDFs")
        }
    }

    /// All pages of all PDFs, in the given order, in one PDF.
    static func merge(_ sources: [URL], destination: URL, progress: @Sendable (Double) -> Void) throws {
        let merged = PDFDocument()
        for (number, url) in sources.enumerated() {
            try Task.checkCancellation()
            let document = try PDFConverter.open(url)
            for index in 0..<document.pageCount {
                // A page belongs to one document, so the merged one gets copies.
                if let page = document.page(at: index)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
            progress(Double(number + 1) / Double(sources.count) * 0.9)
        }
        guard merged.write(to: destination) else { throw ConversionError.cannotWrite(destination.lastPathComponent) }
    }

    /// One PDF per page in a new folder: "report page 01.pdf", "report page 02.pdf"…
    static func split(_ source: URL, folder: URL, progress: @Sendable (Double) -> Void) throws {
        let document = try PDFConverter.open(source)
        let count = document.pageCount
        guard count > 1 else {
            throw NothingToDo(reason: "It has only one page, so there's nothing to split.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let base = source.deletingPathExtension().lastPathComponent
        let digits = String(count).count
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(index + 1)
            let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
            let file = folder.appendingPathComponent("\(base) page \(padded).pdf")
            guard single.write(to: file) else { throw ConversionError.cannotWrite(file.lastPathComponent) }
            progress(Double(index + 1) / Double(count))
        }
    }

    /// The same PDF, opening only with the password (which also guards
    /// printing and changes).
    static func protect(_ source: URL, password: String, destination: URL) throws {
        guard !password.isEmpty else { throw ConversionError.failed("The password can't be empty.") }
        let document = try PDFConverter.open(source)
        let written = document.write(to: destination, withOptions: [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ])
        guard written else { throw ConversionError.cannotWrite(destination.lastPathComponent) }
    }
}
