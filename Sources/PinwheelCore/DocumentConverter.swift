import Foundation

/// Documents, spreadsheets, slides and subtitles, from one format to another
/// (and PDFs into documents). Each is read into Pinwheel's own model and
/// written out of it; Pages, Keynote and Numbers do what only they can.
enum DocumentConverter {
    /// Returns a note for the progress window, if any.
    static func convert(
        _ file: SourceFile, to format: OutputFormat, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        switch file.kind {
        case .pdf: return try await fromPDF(file, to: format, destination: destination, options: options, progress: progress)
        case .document: try await fromDocument(file.url, to: format, destination: destination, progress: progress)
        case .spreadsheet: return try await fromSpreadsheet(file.url, to: format, destination: destination, progress: progress)
        case .presentation: try await fromSlides(file.url, to: format, destination: destination, options: options, progress: progress)
        case .subtitle: try Subtitles.convert(file.url, to: format, destination: destination)
        default: throw ConversionError.unsupported("\(format.title) from \(file.url.lastPathComponent)")
        }
        return nil
    }

    // MARK: - PDFs

    private static func fromPDF(
        _ file: SourceFile, to format: OutputFormat, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        switch format {
        case .txt:
            return try await TextExtractor.write(file, to: destination, recognition: options.textRecognition, progress: progress)
        case .xlsx:
            let workbook = try await PDFStructure.workbook(file.url, recognition: options.textRecognition, progress: progress)
            guard !workbook.sheets.isEmpty else { throw NothingToDo(reason: "No text was found, so nothing was saved.") }
            try ExcelWorkbook.write(workbook, to: destination)
            return nil
        case .pptx:
            let pages = try await Blocking.run { _ in try PDFStructure.pagePictures(file.url, progress: progress) }
            try SlideDeck.write(pages.map { SlideDeck.Slide(data: $0.data, isJPEG: true, size: $0.size) }, to: destination)
            return nil
        default:
            var note: String?
            let document: Document
            if options.pdfPagesAsPictures && format != .md {
                // Exactly as it looks: a picture of each page.
                let pages = try await Blocking.run { _ in try PDFStructure.pagePictures(file.url, progress: progress) }
                var blocks: [Document.Block] = []
                for (index, page) in pages.enumerated() {
                    if index > 0 { blocks.append(.pageBreak) }
                    let width = min(page.size.width, 451)
                    blocks.append(.image(Document.Picture(data: page.data, isJPEG: true, width: width, height: page.size.height * width / page.size.width)))
                }
                document = Document(title: file.url.deletingPathExtension().lastPathComponent, blocks: blocks)
            } else {
                let (read, scanned) = try await PDFStructure.document(file.url, recognition: options.textRecognition, progress: progress)
                guard !read.isEmpty else { throw NothingToDo(reason: "No text was found, so nothing was saved.") }
                document = read
                if scanned > 0 {
                    note = scanned == 1 ? "1 scanned page was read with text recognition." : "\(scanned) scanned pages were read with text recognition."
                }
            }
            try await write(document, as: format, to: destination)
            return note
        }
    }

    // MARK: - Documents

    private static func fromDocument(
        _ url: URL, to format: OutputFormat, destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ext = url.pathExtension.lowercased()
        // Pages files: Pages itself exports what it can, exactly.
        if ext == "pages" {
            let direct: [OutputFormat: IWork.Export] = [.pdf: .pdf, .docx: .word, .epub: .epub, .txt: .text, .rtf: .richText]
            if let export = direct[format] {
                try await IWork.export(url, with: .pages, as: export, to: destination)
                return
            }
            try await withTemporaryFile("docx") { word in
                try await IWork.export(url, with: .pages, as: .word, to: word)
                try await write(try WordDocument.read(word), as: format, to: destination)
            }
            return
        }
        progress(0.1)
        let document = try read(url)
        progress(0.5)
        try await write(document, as: format, to: destination)
    }

    /// Any document format Pinwheel reads, into its model.
    static func read(_ url: URL) throws -> Document {
        switch url.pathExtension.lowercased() {
        case "docx", "docm", "dotx": return try WordDocument.read(url)
        case "md", "markdown", "mdown": return Document(markdown: try TextFile.read(url), folder: url.deletingLastPathComponent())
        case "txt", "text": return Document(plainText: try TextFile.read(url), title: url.deletingPathExtension().lastPathComponent)
        case "html", "htm", "xhtml":
            let folder = url.deletingLastPathComponent()
            return Document(html: try TextFile.read(url)) { source in
                source.contains("://") ? nil : try? Data(contentsOf: folder.appendingPathComponent(source))
            }
        case "epub": return try EPUBBook.read(url)
        default: return try AttributedDocument.read(url)
        }
    }

    /// The model, written as `format`.
    static func write(_ document: Document, as format: OutputFormat, to url: URL) async throws {
        switch format {
        case .pdf: try AttributedDocument.writePDF(document, to: url)
        case .docx: try WordDocument.write(document, to: url)
        case .pages:
            try await withTemporaryFile("docx") { word in
                try WordDocument.write(document, to: word)
                try await IWork.export(word, with: .pages, as: .native, to: url)
            }
        case .rtf: try AttributedDocument.write(document, to: url, type: .rtf)
        case .odt: try AttributedDocument.write(document, to: url, type: .openDocument)
        case .epub: try EPUBBook.write(document, to: url)
        case .md: try writeText(document.markdown, to: url)
        case .txt: try writeText(document.plainText, to: url)
        case .html: try writeText(document.html, to: url)
        default: throw ConversionError.unsupported("\(format.title) from a document")
        }
    }

    // MARK: - Spreadsheets

    private static func fromSpreadsheet(
        _ url: URL, to format: OutputFormat, destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        let ext = url.pathExtension.lowercased()
        // Numbers files and old Excel files: Numbers reads them.
        if ext == "numbers" || ext == "xls" {
            if format == .pdf {
                try await IWork.export(url, with: .numbers, as: .pdf, to: destination)
                return nil
            }
            return try await withTemporaryFile("xlsx") { excel in
                try await IWork.export(url, with: .numbers, as: .excel, to: excel)
                return try write(try ExcelWorkbook.read(excel), as: format, to: destination)
            }
        }
        progress(0.1)
        let workbook: Workbook
        switch ext {
        case "xlsx", "xlsm": workbook = try ExcelWorkbook.read(url)
        case "ods": workbook = try OpenDocumentSheet.read(url)
        case "tsv", "tab": workbook = try DelimitedText.read(url, tabs: true)
        default: workbook = try DelimitedText.read(url, tabs: false)
        }
        progress(0.5)
        return try write(workbook, as: format, to: destination)
    }

    /// Returns a note when only the first sheet could be kept.
    static func write(_ workbook: Workbook, as format: OutputFormat, to url: URL) throws -> String? {
        switch format {
        case .xlsx: try ExcelWorkbook.write(workbook, to: url)
        case .ods: try OpenDocumentSheet.write(workbook, to: url)
        case .pdf: try AttributedDocument.writePDF(workbook, to: url)
        case .csv, .tsv:
            guard let sheet = workbook.firstSheet else { throw NothingToDo(reason: "The spreadsheet is empty, so nothing was saved.") }
            try DelimitedText.write(sheet, to: url, tabs: format == .tsv)
            let others = workbook.sheets.filter { !$0.trimmed.rows.isEmpty }.count - 1
            if others > 0 {
                return "Only the sheet “\(sheet.name)” was saved: \(format.title) holds one sheet (\(others) more in the original)."
            }
        default: throw ConversionError.unsupported("\(format.title) from a spreadsheet")
        }
        return nil
    }

    // MARK: - Slides

    private static func fromSlides(
        _ url: URL, to format: OutputFormat, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch format {
        case .pdf:
            try await IWork.export(url, with: .keynote, as: .pdf, to: destination)
        case .pptx:
            try await IWork.export(url, with: .keynote, as: .powerPoint, to: destination)
        case .png, .jpeg:
            // Keynote draws the slides into a PDF; each page becomes a picture.
            try await withTemporaryFile("pdf") { pdf in
                try await IWork.export(url, with: .keynote, as: .pdf, to: pdf)
                progress(0.5)
                var pictureOptions = options
                pictureOptions.pdfDPI = 144
                try await PDFConverter.renderPages(
                    pdf, to: format, destination: destination, options: pictureOptions, slidesOf: url.deletingPathExtension().lastPathComponent
                ) { progress(0.5 + $0 / 2) }
            }
        default:
            throw ConversionError.unsupported("\(format.title) from slides")
        }
    }

    // MARK: - Helpers

    private static func writeText(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }

    /// A file of its own in the temporary folder, removed afterwards.
    private static func withTemporaryFile<T>(_ ext: String, _ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await body(folder.appendingPathComponent("document.\(ext)"))
    }
}
