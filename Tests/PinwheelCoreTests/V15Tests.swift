import Foundation
import PDFKit
import Testing
@testable import PinwheelCore

/// A document with one of everything.
private let sample = Document(title: "Trip Notes", blocks: [
    .heading(1, [.init("Trip to Crete")]),
    .paragraph([.init("We stayed in "), .init("Chania", bold: true), .init(" for a "), .init("week", italic: true), .init(". See "),
                .init("the map", link: "https://example.com/map"), .init(".")]),
    .heading(2, [.init("Packing")]),
    .listItem(ordered: false, level: 0, [.init("Sun cream")]),
    .listItem(ordered: false, level: 0, [.init("Hats")]),
    .listItem(ordered: true, level: 0, [.init("Book flights")]),
    .listItem(ordered: true, level: 0, [.init("Rent a car")]),
    .quote([.init("Slow down.")]),
    .code("let days = 7"),
    .table([["Day", "Place", "Km"], ["1", "Chania", "0"], ["2", "Balos", "56"]]),
    .rule,
    .paragraph([.init("The end.")]),
])

private func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func redDot() -> Document.Picture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-dot-\(UUID().uuidString).png")
    try? Fixtures.makeImage(at: url, width: 40, height: 20)
    defer { try? FileManager.default.removeItem(at: url) }
    return Document.Picture.from(try! Data(contentsOf: url), description: "A red dot")!
}

private func headings(_ document: Document) -> [String] {
    document.blocks.compactMap { if case .heading(let level, let runs) = $0 { "\(level) \(runs.text)" } else { nil } }
}

// MARK: - ZIP

struct ZipTests {
    @Test func roundTripAndMacOSAgrees() throws {
        let folder = try TempFolder()
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("a/long.txt", String(repeating: "Pinwheel ", count: 1000))
        zip.add("ελληνικά.txt", "Γεια σου")
        let url = folder.file("test.zip")
        try zip.write(to: url)

        let reader = try ZipReader(url: url)
        #expect(reader.names == ["mimetype", "a/long.txt", "ελληνικά.txt"])
        #expect(reader.text("a/long.txt") == String(repeating: "Pinwheel ", count: 1000))
        #expect(reader.text("ελληνικά.txt") == "Γεια σου")
        #expect(reader.data("missing") == nil)
        #expect(try run("/usr/bin/unzip", ["-tq", url.path]).status == 0)
        // EPUB's rule: "mimetype" first, stored as it is.
        let bytes = try Data(contentsOf: url)
        #expect(String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype" && bytes[8] == 0)

        // And a zip made by macOS.
        try "Hello".write(to: folder.file("hello.txt"), atomically: true, encoding: .utf8)
        _ = try run("/usr/bin/zip", ["-jq", folder.file("mac.zip").path, folder.file("hello.txt").path])
        #expect(try ZipReader(url: folder.file("mac.zip")).text("hello.txt") == "Hello")
    }
}

// MARK: - Text formats

struct DocumentTextTests {
    @Test func markdownBothWays() {
        let markdown = sample.markdown
        #expect(markdown.contains("# Trip to Crete"))
        #expect(markdown.contains("**Chania**") && markdown.contains("*week*") && markdown.contains("[the map](https://example.com/map)"))
        #expect(markdown.contains("- Sun cream\n- Hats") && markdown.contains("1. Book flights\n2. Rent a car"))
        #expect(markdown.contains("| Day | Place | Km |"))
        let back = Document(markdown: markdown)
        #expect(back.blocks == sample.blocks.map { block in
            if case .rule = block { return .rule }
            return block
        })
    }

    @Test func paragraphsThatLookLikeMoreStayParagraphs() {
        let document = Document(blocks: [
            .paragraph([.init("1. General.")]), .paragraph([.init("# not a heading")]), .paragraph([.init("- not a list")]),
            .paragraph([.init("> not a quote")]), .paragraph([.init("12) twelve")]),
        ])
        #expect(document.markdown.hasPrefix("1\\. General.\n\n\\# not a heading\n\n\\- not a list"))
        #expect(Document(markdown: document.markdown).blocks == document.blocks)
    }

    @Test func markdownExtras() {
        let document = Document(markdown: """
        Title
        =====

        A line
        that goes on.

        * one
          * nested

        ```
        code here
        ```
        """)
        #expect(document.blocks == [
            .heading(1, [.init("Title")]), .paragraph([.init("A line that goes on.")]),
            .listItem(ordered: false, level: 0, [.init("one")]), .listItem(ordered: false, level: 1, [.init("nested")]),
            .code("code here"),
        ])
    }

    @Test func htmlBothWays() {
        let html = sample.html
        #expect(html.contains("<h1>Trip to Crete</h1>") && html.contains("<strong>Chania</strong>") && html.contains("<ol>"))
        let back = Document(html: html)
        #expect(back.title == "Trip Notes")
        #expect(headings(back) == ["1 Trip to Crete", "2 Packing"])
        #expect(back.blocks.contains(.table([["Day", "Place", "Km"], ["1", "Chania", "0"], ["2", "Balos", "56"]])))
        #expect(back.blocks.contains(.listItem(ordered: true, level: 0, [.init("Rent a car")])))
        #expect(back.blocks.contains(.code("let days = 7")))
    }

    @Test func forgivingHTML() {
        let document = Document(html: """
        <html><head><style>p { color: red }</style><script>alert(1)</script></head>
        <body><p>Fish &amp; chips &mdash; <B>tasty</B><br>really</p><ul><li>One<li>Two</ul><img src="nowhere.png"></body></html>
        """)
        #expect(document.blocks == [
            .paragraph([.init("Fish & chips — "), .init("tasty", bold: true), .init("\nreally")]),
            .listItem(ordered: false, level: 0, [.init("One")]), .listItem(ordered: false, level: 0, [.init("Two")]),
        ])
    }

    @Test func plainText() {
        let text = sample.plainText
        #expect(text.contains("Trip to Crete\n\nWe stayed in Chania for a week."))
        #expect(text.contains("• Sun cream\n• Hats") && text.contains("1. Book flights\n2. Rent a car"))
        let back = Document(plainText: "One\ntwo\n\nThree\r\n\r\nFour\u{0C}Five")
        #expect(back.blocks == [
            .paragraph([.init("One\ntwo")]), .paragraph([.init("Three")]), .paragraph([.init("Four")]), .pageBreak, .paragraph([.init("Five")]),
        ])
    }
}

// MARK: - Word, EPUB, RTF, ODT and PDF

struct DocumentFileTests {
    @Test func wordBothWays() throws {
        let folder = try TempFolder()
        var document = sample
        document.blocks.append(.image(redDot()))
        document.blocks.append(.pageBreak)
        document.blocks.append(.paragraph([.init("After the break")]))
        let url = folder.file("trip.docx")
        try WordDocument.write(document, to: url)

        // macOS reads it…
        let text = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        #expect(text.status == 0 && text.output.contains("Trip to Crete") && text.output.contains("Balos"))
        // …and so does Pinwheel, with everything in its place.
        let back = try WordDocument.read(url)
        #expect(back.title == "Trip Notes")
        #expect(headings(back) == ["1 Trip to Crete", "2 Packing"])
        #expect(back.blocks.contains(.paragraph([.init("We stayed in "), .init("Chania", bold: true), .init(" for a "),
                                                 .init("week", italic: true), .init(". See "),
                                                 .init("the map", link: "https://example.com/map"), .init(".")])))
        #expect(back.blocks.contains(.listItem(ordered: false, level: 0, [.init("Hats")])))
        #expect(back.blocks.contains(.listItem(ordered: true, level: 0, [.init("Rent a car")])))
        #expect(back.blocks.contains(.quote([.init("Slow down.")])))
        #expect(back.blocks.contains(.code("let days = 7")))
        #expect(back.blocks.contains(.table([["Day", "Place", "Km"], ["1", "Chania", "0"], ["2", "Balos", "56"]])))
        #expect(back.blocks.contains(.pageBreak))
        let pictures = back.blocks.compactMap { if case .image(let picture) = $0 { picture } else { nil } }
        #expect(pictures.count == 1 && pictures.first?.width == 40)
    }

    @Test func epubBothWays() throws {
        let folder = try TempFolder()
        var document = sample
        document.blocks += [.heading(1, [.init("Second Chapter")]), .image(redDot()), .paragraph([.init("More.")])]
        let url = folder.file("trip.epub")
        try EPUBBook.write(document, to: url)
        let zip = try ZipReader(url: url)
        #expect(zip.names.first == "mimetype")
        #expect(zip.contains("OEBPS/chapter1.xhtml") && zip.contains("OEBPS/chapter2.xhtml") && zip.contains("OEBPS/images/image1.png"))
        // Every chapter is well-formed XML (EPUB readers insist).
        for name in zip.names where name.hasSuffix(".xhtml") || name.hasSuffix(".opf") {
            #expect(XMLParser(data: zip.data(name)!).parse(), "\(name)")
        }
        let back = try EPUBBook.read(url)
        #expect(back.title == "Trip Notes")
        #expect(headings(back) == ["1 Trip to Crete", "2 Packing", "1 Second Chapter"])
        #expect(back.blocks.contains { if case .image = $0 { true } else { false } })
    }

    @Test func rtfAndODTThroughMacOS() throws {
        let folder = try TempFolder()
        for (ext, type) in [("rtf", NSAttributedString.DocumentType.rtf), ("odt", .openDocument)] {
            let url = folder.file("trip.\(ext)")
            try AttributedDocument.write(sample, to: url, type: type)
            let back = try AttributedDocument.read(url)
            #expect(headings(back) == ["1 Trip to Crete", "2 Packing"], "\(ext)")
            #expect(back.blocks.contains { if case .table(let rows) = $0 { rows.last == ["2", "Balos", "56"] } else { false } }, "\(ext)")
            #expect(back.blocks.contains(.listItem(ordered: false, level: 0, [.init("Hats")])), "\(ext)")
            #expect(back.blocks.contains(.listItem(ordered: true, level: 0, [.init("Rent a car")])), "\(ext)")
        }
    }

    @Test func documentsBecomePDFs() throws {
        let folder = try TempFolder()
        var document = sample
        // Long enough for several pages, and a page break.
        for number in 1...60 { document.blocks.append(.paragraph([.init("Paragraph \(number): " + String(repeating: "words go on and on ", count: 8))])) }
        document.blocks.append(.pageBreak)
        document.blocks.append(.paragraph([.init("On its own page")]))
        let url = folder.file("trip.pdf")
        try AttributedDocument.writePDF(document, to: url)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount >= 3)
        #expect(pdf.page(at: pdf.pageCount - 1)?.string?.contains("On its own page") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Trip to Crete") == true)
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Trip Notes")
    }
}

// MARK: - Reading PDFs

struct PDFReadingTests {
    /// A PDF made from `document` (by Pinwheel's own layout).
    private func pdf(of document: Document, in folder: TempFolder) throws -> URL {
        let url = folder.file("source.pdf")
        try AttributedDocument.writePDF(document, to: url)
        return url
    }

    @Test func headingsParagraphsAndLists() async throws {
        let folder = try TempFolder()
        let long = "This sentence is long enough to wrap onto the next line of the page, so the reader has to join lines back into one paragraph again."
        let wrappedItem = "Costs went down in every single region we work in, which is long enough to wrap onto a second line"
        let source = Document(blocks: [
            .heading(1, [.init("Annual Report")]),
            .paragraph([.init(long)]),
            .paragraph([.init("A second paragraph, also quite long, which keeps going and going until it wraps onto a second line as well.")]),
            .heading(2, [.init("Results")]),
            .listItem(ordered: false, level: 0, [.init("Sales went up")]),
            .listItem(ordered: false, level: 0, [.init(wrappedItem)]),
            .paragraph([.init("The end.")]),
        ])
        let url = try pdf(of: source, in: folder)
        let (document, scanned) = try await PDFStructure.document(url, recognition: TextRecognition()) { _ in }
        #expect(scanned == 0)
        #expect(headings(document) == ["1 Annual Report", "2 Results"])
        let paragraphs = document.blocks.compactMap { if case .paragraph(let runs) = $0 { runs.text } else { nil } }
        #expect(paragraphs.first == long, "wrapped lines join into one paragraph")
        #expect(paragraphs.count == 3)
        let items = document.blocks.compactMap { if case .listItem(_, _, let runs) = $0 { runs.text } else { nil } }
        #expect(items == ["Sales went up", wrappedItem])
    }

    @Test func numberedLinesOnTheirOwnKeepTheirNumbers() async throws {
        let folder = try TempFolder()
        let source = Document(blocks: [
            .paragraph([.init("1. General.")]),
            .paragraph([.init("The software is licensed, not sold.")]),
            .paragraph([.init("2. Permitted uses.")]),
            .paragraph([.init("You may use it on one Mac.")]),
            .listItem(ordered: true, level: 0, [.init("First step")]),
            .listItem(ordered: true, level: 0, [.init("Second step")]),
        ])
        let (document, _) = try await PDFStructure.document(try pdf(of: source, in: folder), recognition: TextRecognition()) { _ in }
        #expect(document.blocks.contains(.paragraph([.init("1. General.")])))
        #expect(document.blocks.contains(.paragraph([.init("2. Permitted uses.")])))
        #expect(document.blocks.contains(.listItem(ordered: true, level: 0, [.init("Second step")])))
    }

    @Test func codeAndBoldComeBack() async throws {
        let folder = try TempFolder()
        let source = Document(blocks: [
            .paragraph([.init("Run "), .init("this", bold: true), .init(" once:")]), .code("let days = 7\nprint(days)"), .paragraph([.init("Done.")]),
        ])
        let (document, _) = try await PDFStructure.document(try pdf(of: source, in: folder), recognition: TextRecognition()) { _ in }
        #expect(document.blocks == source.blocks)
    }

    @Test func nestedLists() async throws {
        let folder = try TempFolder()
        let items: [Document.Block] = [
            .listItem(ordered: false, level: 0, [.init("Fruit")]), .listItem(ordered: false, level: 1, [.init("Apples")]),
            .listItem(ordered: false, level: 1, [.init("Pears")]), .listItem(ordered: false, level: 0, [.init("Bread")]),
        ]
        let source = Document(blocks: [.paragraph([.init("Shopping:")])] + items)
        let (document, _) = try await PDFStructure.document(try pdf(of: source, in: folder), recognition: TextRecognition()) { _ in }
        #expect(Array(document.blocks.dropFirst()) == items)
    }

    @Test func tablesInDocuments() async throws {
        let folder = try TempFolder()
        let rows = [["Region", "Sales", "Growth"], ["North", "1,200", "4%"], ["South", "3,450", "18%"]]
        let source = Document(blocks: [
            .heading(1, [.init("Numbers")]), .paragraph([.init("Before the table.")]), .table(rows), .paragraph([.init("After the table.")]),
        ])
        let (document, _) = try await PDFStructure.document(try pdf(of: source, in: folder), recognition: TextRecognition()) { _ in }
        #expect(document.blocks == [
            .heading(1, [.init("Numbers")]), .paragraph([.init("Before the table.")]), .table(rows), .paragraph([.init("After the table.")]),
        ])
    }

    /// A line as PDFKit finds it.
    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 14) -> PDFStructure.Line {
        PDFStructure.Line(runs: [.init(text)], size: size, bold: false, mono: false,
                          frame: CGRect(x: x, y: y, width: width, height: size * 1.2), page: 0, pageSize: CGSize(width: 600, height: 800))
    }

    @Test func piecesOfOneLineAndTheirOrder() {
        // "1." drawn apart from its text, a line split in two, and a column beside.
        let lines = [
            line("1.", x: 57, y: 400, width: 15), line("2.", x: 57, y: 370, width: 15),
            line("How to add", x: 86, y: 400, width: 100), line("How to edit", x: 86, y: 370, width: 100),
            line("The Bitrate bigger.", x: 57, y: 300, width: 150), line("Best keep it.", x: 215, y: 300, width: 100),
            line("source video.", x: 57, y: 280, width: 90), line("Far away", x: 400, y: 280, width: 60),
        ]
        let joined = PDFStructure.joiningPieces(lines).map(\.text)
        #expect(joined == ["1. How to add", "2. How to edit", "The Bitrate bigger. Best keep it.", "source video.", "Far away"])

        let shuffled = [line("second", x: 57, y: 300, width: 90), line("first", x: 57, y: 320, width: 90)]
        #expect(PDFStructure.inReadingOrder(shuffled).map(\.text) == ["first", "second"])
        let columns = [line("right", x: 300, y: 320, width: 90), line("left", x: 57, y: 320, width: 90)]
        #expect(PDFStructure.inReadingOrder(columns).map(\.text) == ["right", "left"], "side by side: the PDF's order")

        #expect(PDFStructure.withoutLigatures("Oﬃce ﬁles ﬂow") == "Office files flow")
        #expect(PDFStructure.isMarker("12.") && PDFStructure.isMarker("b)") && PDFStructure.isMarker(" • ") && !PDFStructure.isMarker("1999"))
    }

    @Test func pageNumbersAndRepeatedFootersGo() {
        let size = CGSize(width: 600, height: 800)
        func line(_ text: String, page: Int, y: CGFloat) -> PDFStructure.Line {
            PDFStructure.Line(runs: [.init(text)], size: 11, bold: false, mono: false, frame: CGRect(x: 60, y: y, width: 300, height: 13), page: page, pageSize: size)
        }
        var lines: [PDFStructure.Line] = []
        for page in 0..<4 {
            lines += [line("Body text on page \(page)", page: page, y: 400), line("Company Ltd · Confidential", page: page, y: 30), line("\(page + 1)", page: page, y: 50)]
        }
        let kept = PDFStructure.withoutFurniture(lines).map(\.text)
        #expect(kept == (0..<4).map { "Body text on page \($0)" })
        #expect(PDFStructure.listMarker("• Milk")! == (false, "Milk"))
        #expect(PDFStructure.listMarker("12) Eggs")! == (true, "Eggs"))
        #expect(PDFStructure.listMarker("Plain text") == nil)
    }

    @Test func tablesBecomeSheets() async throws {
        let folder = try TempFolder()
        let rows: [[Workbook.Cell]] = [
            [.text("Product"), .text("Units"), .text("Price")],
            [.text("Apples"), .number(120), .number(0.5)],
            [.text("Pears"), .number(80), .number(0.75)],
        ]
        let url = folder.file("table.pdf")
        try AttributedDocument.writePDF(Workbook(sheets: [Workbook.Sheet(name: "Fruit", rows: rows)]), to: url)
        let workbook = try await PDFStructure.workbook(url, recognition: TextRecognition()) { _ in }
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.name == "Page 1")
        #expect(sheet.rows == rows)
    }

    @Test func sheetsKeepJustTheTablesWhenThereAreSome() throws {
        func words(_ line: [(String, CGFloat)], y: CGFloat) -> [PDFStructure.Word] {
            line.map { PDFStructure.Word(text: $0.0, frame: CGRect(x: $0.1, y: y, width: CGFloat($0.0.count) * 6, height: 12)) }
        }
        let title = words([("Quarterly", 60), ("report", 118)], y: 700)
        let bullet = words([("•", 60), ("Sales", 80), ("went", 114), ("up", 142)], y: 680)
        let table = words([("Region", 60), ("Sales", 200)], y: 650) + words([("North", 60), ("1,200", 200)], y: 635)
            + words([("South", 60), ("3,450", 200)], y: 620)
        #expect(PDFStructure.grid(title + bullet + table) == [
            [.text("Region"), .text("Sales")], [.text("North"), .number(1200)], [.text("South"), .number(3450)],
        ])
        #expect(PDFStructure.grid(title + bullet) == [[.text("Quarterly report")], [.text("•"), .text("Sales went up")]])
    }

    @Test func pagesAsPictures() throws {
        let folder = try TempFolder()
        let url = try pdf(of: sample, in: folder)
        let pages = try PDFStructure.pagePictures(url) { _ in }
        #expect(pages.count == 1)
        #expect(pages[0].size == PaperSize.current)
        #expect(Document.Picture.from(pages[0].data)?.isJPEG == true)
    }
}

// MARK: - Spreadsheets

struct SpreadsheetTests {
    private let book = Workbook(sheets: [
        Workbook.Sheet(name: "Sales", rows: [
            [.text("Name"), .text("Amount"), .text("Paid")],
            [.text("Ilias, \"the boss\""), .number(1234.5), .bool(true)],
            [.text("Line\nbreak"), .number(-3), .bool(false)],
            [.text("007"), .empty, .text("x")],
        ]),
        Workbook.Sheet(name: "Notes", rows: [[.text("Second sheet")]]),
    ])

    @Test func excelAndODSBothWays() throws {
        let folder = try TempFolder()
        let excel = folder.file("book.xlsx")
        try ExcelWorkbook.write(book, to: excel)
        #expect(try ExcelWorkbook.read(excel) == book)
        let ods = folder.file("book.ods")
        try OpenDocumentSheet.write(book, to: ods)
        #expect(try OpenDocumentSheet.read(ods) == book)
        #expect(try ZipReader(url: ods).names.first == "mimetype")
    }

    @Test func csvBothWays() throws {
        let folder = try TempFolder()
        let csv = folder.file("sales.csv")
        try DelimitedText.write(book.sheets[0], to: csv, tabs: false)
        let back = try DelimitedText.read(csv, tabs: false)
        #expect(back.sheets[0].rows == book.sheets[0].rows.map { $0.map { $0 == .empty ? .empty : $0 } })
        let tsv = folder.file("sales.tsv")
        try DelimitedText.write(book.sheets[0], to: tsv, tabs: true)
        #expect(try DelimitedText.read(tsv, tabs: true).sheets[0].rows.first == [.text("Name"), .text("Amount"), .text("Paid")])
        // Semicolons and decimal commas, as Excel writes them in much of Europe.
        try "Τιμή;Ποσότητα\n1,5;2\n".write(to: folder.file("eu.csv"), atomically: true, encoding: .utf8)
        #expect(try DelimitedText.read(folder.file("eu.csv"), tabs: false).sheets[0].rows == [[.text("Τιμή"), .text("Ποσότητα")], [.number(1.5), .number(2)]])
    }

    @Test func excelDatesAndColumns() {
        #expect(ExcelWorkbook.columnName(0) == "A" && ExcelWorkbook.columnName(25) == "Z" && ExcelWorkbook.columnName(27) == "AB")
        #expect(ExcelWorkbook.columnIndex("AB12") == 27)
        #expect(ExcelWorkbook.dateText(45951) == "2025-10-21")
        #expect(ExcelWorkbook.sheetNames([.init(name: "a/b", rows: []), .init(name: "A/B", rows: [])]) == ["ab", "AB (2)"])
    }

    @Test func throughTheEngine() async throws {
        let folder = try TempFolder()
        let excel = folder.file("book.xlsx")
        try ExcelWorkbook.write(book, to: excel)
        // Two sheets: a folder with a CSV for each (v1.8; before, only the first).
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: excel), action: .convert(.csv)))
        let csvFolder = try #require(result.outputs.first)
        let files = try FileManager.default.contentsOfDirectory(atPath: csvFolder.path).sorted()
        #expect(result.outputs.count == 1 && files.count == 2 && files.allSatisfy { $0.hasSuffix(".csv") }, "\(files)")
        #expect(files.contains("Sales.csv"))
        let pdf = try await runConversion(excel, .convert(.pdf))
        let text = try #require(PDFDocument(url: pdf)?.string)
        #expect(text.contains("Second sheet") && text.contains("1234.5"))
    }
}

// MARK: - Subtitles

struct SubtitleTests {
    private let srt = """
    1
    00:00:01,000 --> 00:00:02,500
    Hello, <i>world</i>

    2
    00:00:03,000 --> 00:00:04,000
    Goodbye
    """

    @Test func srtAndVTT() throws {
        let cues = Subtitles.parse(srt)
        #expect(cues == [.init(start: 1, end: 2.5, text: "Hello, <i>world</i>"), .init(start: 3, end: 4, text: "Goodbye")])
        let vtt = Subtitles.vtt(cues)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello, <i>world</i>"))
        #expect(Subtitles.parse(vtt) == cues)
        #expect(Subtitles.srt(cues) == srt + "\n")
        #expect(Subtitles.plainText(cues) == "Hello, world\nGoodbye\n")
        // WebVTT's short times, settings, notes and voices.
        let web = Subtitles.parse("WEBVTT\n\nNOTE made by hand\n\n01:02.500 --> 01:04.000 align:start\n<v Maria>Hi there")
        #expect(web == [.init(start: 62.5, end: 64, text: "<v Maria>Hi there", place: .init(column: .left))], "align:start: on the left (v1.8)")
        #expect(Subtitles.srtText(web[0].text) == "Maria: Hi there")
    }
}

// MARK: - Through the engine

struct V15EngineTests {
    @Test(arguments: [OutputFormat.docx, .epub, .md, .txt, .html, .rtf, .odt, .pdf])
    func markdownBecomes(_ format: OutputFormat) async throws {
        let folder = try TempFolder()
        let source = folder.file("notes.md")
        try sample.markdown.write(to: source, atomically: true, encoding: .utf8)
        let output = try await runConversion(source, .convert(format))
        #expect(output.pathExtension == format.fileExtension)
        #expect(SourceFile(url: output).format == format)
        if format != .pdf {
            let back = try DocumentConverter.read(output)
            #expect(back.blocks.contains { block in
                if case .heading(_, let runs) = block { return runs.text == "Trip to Crete" }
                if case .paragraph(let runs) = block { return runs.text.contains("Trip to Crete") }
                return false
            }, "\(format)")
        }
    }

    @Test(arguments: [OutputFormat.docx, .epub, .md, .txt, .xlsx, .pptx])
    func pdfBecomes(_ format: OutputFormat) async throws {
        let folder = try TempFolder()
        let source = folder.file("report.pdf")
        try AttributedDocument.writePDF(sample, to: source)
        let output = try await runConversion(source, .convert(format))
        #expect(output.pathExtension == format.fileExtension)
        switch format {
        case .pptx:
            let zip = try ZipReader(url: output)
            #expect(zip.contains("ppt/slides/slide1.xml") && zip.contains("ppt/media/image1.jpg"))
            for name in zip.names where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                #expect(XMLParser(data: zip.data(name)!).parse(), "\(name)")
            }
        case .xlsx:
            #expect(try ExcelWorkbook.read(output).sheets.first?.rows.contains { $0.contains(.text("Balos")) } == true)
        default:
            #expect(try DocumentConverter.read(output).plainText.contains("Chania"), "\(format)")
        }
    }

    @Test func pdfPagesAsPicturesIntoWord() async throws {
        let folder = try TempFolder()
        let source = folder.file("report.pdf")
        try AttributedDocument.writePDF(sample, to: source)
        var options = ConversionOptions()
        options.pdfPagesAsPictures = true
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .convert(.docx)), options: options)
        let back = try WordDocument.read(try #require(result.outputs.first))
        #expect(back.blocks.count == 1)
        guard case .image(let page)? = back.blocks.first else { Issue.record("no page picture"); return }
        #expect(page.isJPEG && page.width == 451)
    }

    @Test func subtitlesAndSpreadsheets() async throws {
        let folder = try TempFolder()
        let srt = folder.file("film.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try await runConversion(srt, .convert(.vtt))
        #expect(try String(contentsOf: vtt, encoding: .utf8).hasPrefix("WEBVTT"))
        let csv = folder.file("list.csv")
        try "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)
        let ods = try await runConversion(csv, .convert(.ods))
        #expect(try OpenDocumentSheet.read(ods).sheets[0].rows == [[.text("a"), .text("b")], [.number(1), .number(2)]])
    }
}

// MARK: - Wheels

struct V15WheelTests {
    @Test func kindsAndFormats() {
        func kind(_ name: String) -> FileKind? { FileKind.of(URL(fileURLWithPath: "/tmp/pinwheel-v15/\(name)")) }
        #expect(kind("a.docx") == .document && kind("a.pages") == .document && kind("a.md") == .document && kind("a.epub") == .document)
        #expect(kind("a.xlsx") == .spreadsheet && kind("a.csv") == .spreadsheet && kind("a.numbers") == .spreadsheet)
        #expect(kind("a.pptx") == .presentation && kind("a.key") == .presentation)
        #expect(kind("a.srt") == .subtitle && kind("a.vtt") == .subtitle)
        for (name, format) in [("a.docx", OutputFormat.docx), ("a.markdown", .md), ("a.htm", .html), ("a.text", .txt), ("a.pages", .pages)] {
            #expect(SourceFile(url: URL(fileURLWithPath: "/tmp/\(name)")).format == format, "\(name)")
        }
        // A .pages package (a folder on disk) is still a document.
        let folder = try! TempFolder()
        let package = folder.file("Old.pages")
        try! FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(FileKind.of(package) == .document)
    }

    @Test func appsAreNeededForTheirFormats() {
        func file(_ name: String) -> SourceFile { SourceFile(url: URL(fileURLWithPath: "/tmp/\(name)")) }
        #expect(ConversionEngine.app(for: .convert(.pdf), file: file("a.pages")) == .pages)
        #expect(ConversionEngine.app(for: .convert(.pages), file: file("a.docx")) == .pages)
        #expect(ConversionEngine.app(for: .convert(.pdf), file: file("a.pptx")) == .keynote)
        #expect(ConversionEngine.app(for: .convert(.csv), file: file("a.numbers")) == .numbers)
        #expect(ConversionEngine.app(for: .convert(.pdf), file: file("a.docx")) == nil)
        #expect(ConversionEngine.app(for: .convert(.pptx), file: file("a.pdf")) == nil)
        let pages = ConversionEngine.availability(of: .convert(.pages), for: [file("a.docx")], ffmpegAvailable: true)
        #expect(pages == (ExternalTool.pages.locate() == nil ? .unavailable("Needs Pages, free on the App Store") : .available))
        #expect(ExternalTool.pages.name == "Pages" && ExternalTool.pages.installCommand == "free on the App Store")
    }
}

// MARK: - Pages, Keynote and Numbers

/// They open windows and macOS asks before Pinwheel may use them, so these
/// run only when asked: PINWHEEL_IWORK=1 scripts/test.sh --filter IWorkTests
struct IWorkTests {
    static let enabled = ProcessInfo.processInfo.environment["PINWHEEL_IWORK"] == "1"

    @Test(.enabled(if: enabled)) func pages() async throws {
        let folder = try TempFolder()
        let word = folder.file("trip.docx")
        try WordDocument.write(sample, to: word)
        let pages = try await runConversion(word, .convert(.pages))
        #expect(pages.pathExtension == "pages" && FileKind.of(pages) == .document)
        let pdf = try await runConversion(pages, .convert(.pdf))
        #expect(PDFDocument(url: pdf)?.string?.contains("Trip to Crete") == true)
        let markdown = try await runConversion(pages, .convert(.md))
        let text = try String(contentsOf: markdown, encoding: .utf8)
        #expect(text.contains("Trip to Crete") && text.contains("Balos"))
    }

    @Test(.enabled(if: enabled)) func keynote() async throws {
        let folder = try TempFolder()
        let source = folder.file("deck.pdf")
        try AttributedDocument.writePDF(sample, to: source)
        let deck = try await runConversion(source, .convert(.pptx))
        let pdf = try await runConversion(deck, .convert(.pdf))
        #expect(PDFDocument(url: pdf)?.pageCount == 1)
        let pictures = try await runConversion(deck, .convert(.png))
        let contents = try FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)
        #expect(contents.count == 1 && contents[0].lastPathComponent.hasSuffix("slide 1.png"))
    }

    @Test(.enabled(if: enabled)) func numbers() async throws {
        let folder = try TempFolder()
        let excel = folder.file("book.xlsx")
        try ExcelWorkbook.write(Workbook(sheets: [Workbook.Sheet(name: "Fruit", rows: [[.text("Apples"), .number(3)]])]), to: excel)
        let numbers = folder.file("book.numbers")
        try await IWork.export(excel, with: .numbers, as: .native, to: numbers)
        let csv = try await runConversion(numbers, .convert(.csv))
        #expect(try DelimitedText.read(csv, tabs: false).sheets[0].rows.first == [.text("Apples"), .number(3)])
    }
}
