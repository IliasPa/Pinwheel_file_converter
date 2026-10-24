import Foundation

/// Documents, spreadsheets, slides and subtitles, from one format to another
/// (and PDFs into documents). Each is read into Pinwheel's own model and
/// written out of it; Pages, Keynote and Numbers do what only they can.
enum DocumentConverter {
    /// What a conversion wrote: a note for the progress window, and the
    /// files when they aren't just `destination` (a folder of CSV files, or
    /// a Markdown file and the folder of its pictures).
    struct Written: Sendable {
        var note: String?
        var outputs: [URL]?
    }

    static func convert(
        _ file: SourceFile, to format: OutputFormat, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Written {
        switch file.kind {
        case .pdf: return try await fromPDF(file, to: format, destination: destination, options: options, progress: progress)
        case .document: return try await fromDocument(file.url, to: format, destination: destination, progress: progress)
        case .spreadsheet: return try await fromSpreadsheet(file.url, to: format, destination: destination, progress: progress)
        case .presentation: try await fromSlides(file.url, to: format, destination: destination, options: options, progress: progress)
        case .subtitle: try Subtitles.convert(file.url, to: format, destination: destination, options: options)
        default: throw ConversionError.unsupported("\(format.title) from \(file.url.lastPathComponent)")
        }
        return Written()
    }

    // MARK: - PDFs

    private static func fromPDF(
        _ file: SourceFile, to format: OutputFormat, destination: URL, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Written {
        switch format {
        case .txt:
            return Written(note: try await TextExtractor.write(file, to: destination, recognition: options.textRecognition, progress: progress))
        case .xlsx:
            let workbook = try await PDFStructure.workbook(file.url, recognition: options.textRecognition, progress: progress)
            guard !workbook.sheets.isEmpty else { throw NothingToDo(reason: "No text was found, so nothing was saved.") }
            try ExcelWorkbook.write(workbook, to: destination)
            return Written()
        case .pptx:
            let pages = try await Blocking.run { _ in try PDFStructure.pagePictures(file.url, progress: progress) }
            try SlideDeck.write(pages.map { SlideDeck.Slide(data: $0.data, isJPEG: true, size: $0.size) }, to: destination)
            return Written()
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
            var written = try await write(document, as: format, to: destination)
            written.note = note
            return written
        }
    }

    // MARK: - Documents

    private static func fromDocument(
        _ url: URL, to format: OutputFormat, destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Written {
        let ext = url.pathExtension.lowercased()
        // Pages files: Pages itself exports what it can, exactly.
        if ext == "pages" {
            let direct: [OutputFormat: IWork.Export] = [.pdf: .pdf, .docx: .word, .epub: .epub, .txt: .text, .rtf: .richText]
            if let export = direct[format] {
                try await IWork.export(url, with: .pages, as: export, to: destination)
                return Written()
            }
            return try await withTemporaryFile("docx") { word in
                try await IWork.export(url, with: .pages, as: .word, to: word)
                return try await write(try WordDocument.read(word), as: format, to: destination)
            }
        }
        progress(0.1)
        let document = try read(url)
        progress(0.5)
        return try await write(document, as: format, to: destination)
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
    @discardableResult
    static func write(_ document: Document, as format: OutputFormat, to url: URL) async throws -> Written {
        switch format {
        case .pdf: try AttributedDocument.writePDF(document, to: url)
        case .docx: try WordDocument.write(document, to: url)
        case .pages:
            try await withTemporaryFile("docx") { word in
                try WordDocument.write(document, to: word)
                try await IWork.export(word, with: .pages, as: .native, to: url)
            }
        case .rtf: try AttributedDocument.writeRTF(document, to: url)
        case .odt: try AttributedDocument.write(document, to: url, type: .openDocument)
        case .epub: try EPUBBook.write(document, to: url)
        case .md: return try writeMarkdown(document, to: url)
        case .txt: try writeText(document.plainText, to: url)
        case .html: try writeText(document.html, to: url)
        default: throw ConversionError.unsupported("\(format.title) from a document")
        }
        return Written()
    }

    /// Markdown, with its pictures as files in a folder beside it ("Notes
    /// pictures"), linked from the text: most Markdown apps don't show
    /// pictures kept inside the text itself.
    static func writeMarkdown(_ document: Document, to url: URL) throws -> Written {
        let pictures = document.blocks.compactMap { block -> Document.Picture? in
            if case .image(let picture) = block { return picture }
            return nil
        }
        guard !pictures.isEmpty else {
            try writeText(document.markdown, to: url)
            return Written()
        }
        let folder = uniqueURL(url.deletingPathExtension(), suffix: " pictures")
        let names = pictures.indices.map { "picture \($0 + 1).\(pictures[$0].fileExtension)" }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for (picture, name) in zip(pictures, names) {
                try picture.data.write(to: folder.appendingPathComponent(name))
            }
            try writeText(document.markdown(picturesIn: folder.lastPathComponent, named: names), to: url)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        return Written(outputs: [url, folder])
    }

    /// `base` + `suffix`, or with " 2", " 3"… when that's taken.
    static func uniqueURL(_ base: URL, suffix: String, fileExtension: String? = nil) -> URL {
        let folder = base.deletingLastPathComponent()
        let name = base.lastPathComponent + suffix
        var attempt = 1
        while true {
            var candidate = folder.appendingPathComponent(attempt == 1 ? name : "\(name) \(attempt)")
            if let fileExtension { candidate.appendPathExtension(fileExtension) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            attempt += 1
        }
    }

    // MARK: - Spreadsheets

    private static func fromSpreadsheet(
        _ url: URL, to format: OutputFormat, destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Written {
        let ext = url.pathExtension.lowercased()
        // Numbers files and old Excel files: Numbers reads them.
        if ext == "numbers" || ext == "xls" {
            if format == .pdf {
                try await IWork.export(url, with: .numbers, as: .pdf, to: destination)
                return Written()
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

    /// CSV and TSV hold one sheet: a workbook with several becomes a folder
    /// with a file for each (named after the sheet).
    static func write(_ workbook: Workbook, as format: OutputFormat, to url: URL) throws -> Written {
        switch format {
        case .xlsx: try ExcelWorkbook.write(workbook, to: url)
        case .ods: try OpenDocumentSheet.write(workbook, to: url)
        case .pdf: try AttributedDocument.writePDF(workbook, to: url)
        case .csv, .tsv:
            let sheets = workbook.sheets.filter { !$0.trimmed.rows.isEmpty }
            guard let first = sheets.first ?? workbook.sheets.first else {
                throw NothingToDo(reason: "The spreadsheet is empty, so nothing was saved.")
            }
            guard sheets.count > 1 else {
                try DelimitedText.write(first, to: url, tabs: format == .tsv)
                return Written()
            }
            let folder = uniqueURL(url.deletingPathExtension(), suffix: "")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                var used: Set<String> = []
                for (index, sheet) in sheets.enumerated() {
                    var name = OutputNaming.safeFileName(sheet.name.isEmpty ? "Sheet \(index + 1)" : sheet.name)
                    while !used.insert(name.lowercased()).inserted { name += " \(index + 1)" }
                    try DelimitedText.write(sheet, to: folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension), tabs: format == .tsv)
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            return Written(note: "\(format.title) holds one sheet, so each of the \(sheets.count) sheets is a file of its own, in a folder.", outputs: [folder])
        default: throw ConversionError.unsupported("\(format.title) from a spreadsheet")
        }
        return Written()
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
