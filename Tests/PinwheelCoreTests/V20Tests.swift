import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

/// v2.0: what the bench (scripts/bench) found on hard files.
struct V20Tests {
    private func legacy(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// Greek (Windows-1253 and ISO-8859-7), Cyrillic and Japanese files used
    /// to be read as Western: "ÃåéÜ óïõ".
    @Test func oldEncodingsAreRecognized() throws {
        let samples: [(String, String.Encoding)] = [
            ("Γειά σου κόσμε! Τιμή: 12,50 €", legacy(.windowsGreek)),
            ("Καλημέρα, ISO-8859-7 κείμενο.", legacy(.isoLatinGreek)),
            ("Привет, мир! Кириллица.", .windowsCP1251),
            ("名前,価格\n東京,1000", .shiftJIS),
            ("Größe: 5 €, naïve café", .windowsCP1252),
        ]
        for (text, encoding) in samples {
            let data = try #require(text.data(using: encoding))
            #expect(TextFile.decode(data) == text, "\(encoding)")
        }
    }

    @Test func greekSubtitlesAndCSVInWindows1253() async throws {
        let folder = try TempFolder()
        let srt = folder.file("greek.srt")
        try #require("1\n00:00:01,000 --> 00:00:02,000\nΓειά σου, τι κάνεις;\n".data(using: legacy(.windowsGreek))).write(to: srt)
        let text = try String(contentsOf: try await runConversion(srt, .convert(.txt)), encoding: .utf8)
        #expect(text == "Γειά σου, τι κάνεις;\n")

        let csv = folder.file("prices.csv")
        try #require("Όνομα;Τιμή\nΚαφές;3,50\n".data(using: legacy(.windowsGreek))).write(to: csv)
        let workbook = try ExcelWorkbook.read(try await runConversion(csv, .convert(.xlsx)))
        #expect(workbook.sheets[0].rows[1][0] == .text("Καφές"))
    }

    // MARK: - Excel

    private func workbook(_ sheet: String, workbookPr: String = "", styles: String? = nil, at url: URL) throws {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        zip.add("xl/workbook.xml", """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        \(workbookPr)<sheets><sheet name="One" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
        zip.add("xl/worksheets/sheet1.xml", sheet)
        zip.add("xl/styles.xml", styles ?? """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="166" formatCode="[h]:mm:ss"/></numFmts>\
        <cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="166"/></cellXfs></styleSheet>
        """)
        try zip.write(to: url)
    }

    /// Workbooks from old Mac Excel count days from 1904: the same number is
    /// four years later. Times and lengths of time aren't dates.
    @Test func datesFrom1904AndTimes() throws {
        let folder = try TempFolder()
        let url = folder.file("mac.xlsx")
        let sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1"><c r="A1" s="1"><v>44857</v></c><c r="B1" s="2"><v>1.5</v></c></row></sheetData></worksheet>
        """
        try workbook(sheet, workbookPr: "<workbookPr date1904=\"1\"/>", at: url)
        let row = try ExcelWorkbook.read(url).sheets[0].rows[0]
        #expect(row == [.text("2026-10-24"), .text("36:00:00")])

        try workbook(sheet, at: url)
        #expect(try ExcelWorkbook.read(url).sheets[0].rows[0][0] == .text("2022-10-23"), "the usual 1900 system")
    }

    /// The quick reader and XMLParser read the same; names with a prefix
    /// ("x:c", as some apps write them) are read too, and Excel's _x000D_.
    @Test func quickSheetReaderMatchesXMLParser() throws {
        let folder = try TempFolder()
        let url = folder.file("quick.xlsx")
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><!-- a comment --><x:sheetData>\
        <x:row r="1" spans="1:4"><x:c r="A1" t="inlineStr"><x:is><x:t>Tom &amp; &quot;Jerry&quot; &#233;</x:t></x:is></x:c>\
        <x:c r="C1" s="1"><x:v>46319</x:v></x:c><x:c r="D1" t="b"><x:v>1</x:v></x:c></x:row>\
        <x:row r="3"><x:c r="B3"><x:f>A1*2</x:f><x:v>-2.5</x:v></x:c><x:c r="C3" t="str"><x:f>"a"</x:f><x:v>Line1_x000D_
        Line2</x:v></x:c><x:c r="D3" t="inlineStr"><x:is><x:r><x:t>Rich </x:t></x:r><x:r><x:t>text</x:t></x:r><x:rPh><x:t>ふりがな</x:t></x:rPh></x:is></x:c><x:c r="E3"/></x:row>\
        </x:sheetData></x:worksheet>
        """
        try workbook(sheet, at: url)
        let rows = try ExcelWorkbook.read(url).sheets[0].rows
        #expect(rows[0] == [.text("Tom & \"Jerry\" é"), .empty, .text("2026-10-24"), .bool(true)])
        #expect(rows[1].isEmpty)
        #expect(rows[2] == [.empty, .number(-2.5), .text("Line1\nLine2"), .text("Rich text")])

        // Without the quick reader, the same.
        let data = try #require(try ZipReader(url: url).data("xl/worksheets/sheet1.xml"))
        let maker = ExcelWorkbook.CellMaker(strings: [], dates: ExcelWorkbook.DateStyles(dates: [1]), from1904: false)
        #expect(SheetScanner.rows(data, maker: maker).map { Workbook.Sheet(name: "", rows: $0).trimmed.rows } == rows)
    }

    /// Dates are worked out by hand now (a formatter per cell took twelve
    /// seconds for 100,000 dates): the same as the formatter wrote them.
    @Test func datesWorkedOutByHand() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for serial in Array(stride(from: -700.0, through: 80_000, by: 37.25)) + [1, 59, 60, 61, 25_569, 46_319, 46_319.75, 2_958_465] {
            let minutes = (serial * 1_440).rounded()
            formatter.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            #expect(ExcelWorkbook.dateText(serial) == formatter.string(from: Date(timeIntervalSince1970: (minutes / 1_440 - 25_569) * 86_400)), "\(serial)")
        }
    }

    @Test func aHundredThousandRowsQuickly() throws {
        let folder = try TempFolder()
        let url = folder.file("big.xlsx")
        var rows = ""
        for row in 1...100_000 {
            rows += "<row r=\"\(row)\"><c r=\"A\(row)\"><v>\(row)</v></c><c r=\"B\(row)\" t=\"inlineStr\"><is><t>Name \(row)</t></is></c><c r=\"C\(row)\" s=\"1\"><v>46000</v></c></row>"
        }
        try workbook("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>", at: url)
        let sheet = try ExcelWorkbook.read(url).sheets[0]
        #expect(sheet.rows.count == 100_000)
        #expect(sheet.rows[99_999] == [.number(100_000), .text("Name 100000"), .text("2025-12-09")])
        // What made it slow: a date formatter for every date (12 s for these).
        let start = Date()
        for serial in 0..<100_000 { _ = ExcelWorkbook.dateText(Double(40_000 + serial % 9_000)) }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    // MARK: - Subtitles

    @Test func webVTTEscapesBothWays() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        &lt;not a tag&gt; &amp; <i>done</i> <ruby>漢<rt>kan</rt></ruby>
        """
        let cues = Subtitles.parse(vtt)
        #expect(cues[0].text == "<not a tag> & <i>done</i> <ruby>漢</ruby>")
        #expect(Subtitles.plainText(cues) == "<not a tag> & done 漢\n")
        // Back into VTT, "&" and "<" that aren't tags are written as VTT wants them.
        #expect(Subtitles.vttText(cues[0].text) == "&lt;not a tag&gt; &amp; <i>done</i> <ruby>漢</ruby>")
        let srt = Subtitles.parse("1\n00:00:01,000 --> 00:00:02,000\nTom & Jerry <u>x</u>\n")
        #expect(Subtitles.vttText(srt[0].text) == "Tom &amp; Jerry <u>x</u>")
    }

    @Test func cuesInTheOrderShown() {
        let cues = Subtitles.parse("2\n00:00:05,000 --> 00:00:06,000\nSecond\n\n1\n00:00:01,000 --> 00:00:02,000\nFirst\n")
        #expect(cues.map(\.text) == ["First", "Second"])
    }

    // MARK: - Archives

    /// A name that would land outside the folder is left out; the rest opens.
    @Test func unsafeNamesAreLeftOut() async throws {
        let folder = try TempFolder()
        let inner = folder.url.appendingPathComponent("work/x", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("escaped".utf8).write(to: folder.file("work/evil.txt"))
        try Data("fine".utf8).write(to: inner.appendingPathComponent("good.txt"))
        let zip = folder.file("mixed.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", zip.path, "../evil.txt", "good.txt"]
        process.currentDirectoryURL = inner
        try process.run()
        process.waitUntilExit()

        let result = try await runRequest(ConversionRequest(file: SourceFile(url: zip), action: .tool(.extract)))
        let out = try #require(result.outputs.first)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("good.txt").path))
        #expect(!FileManager.default.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        #expect(result.note?.contains("1 file was left out") == true)
    }

    @Test func damagedArchiveSaysSoPlainly() async throws {
        let folder = try TempFolder()
        let source = folder.file("a.txt")
        try Data(repeating: 65, count: 100_000).write(to: source)
        let tgz = folder.file("a.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tgz.path, "-C", folder.url.path, "a.txt"]
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: tgz)
        try data.prefix(data.count / 2).write(to: tgz)
        await #expect(throws: ConversionError.failed("a.tar.gz is incomplete or damaged. If it was downloaded, try downloading it again.")) {
            try await runRequest(ConversionRequest(file: SourceFile(url: tgz), action: .tool(.extract)))
        }
    }

    // MARK: - Moving pictures

    private func animatedGIF(at url: URL, frames: Int = 6) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            let ctx = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: index * 30, y: 20, width: 40, height: 60))
            CGImageDestinationAddImage(destination, try #require(ctx.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Resize and Strip Info used to say "doesn't work on animated GIFs yet".
    @Test func toolsKeepAnimationsMoving() async throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try animatedGIF(at: gif)

        let resized = try await runConversion(gif, .tool(.resize))
        let src = try #require(CGImageSourceCreateWithURL(resized as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 6)
        #expect(Fixtures.readImage(resized)?.width == 100)
        #expect(AnimatedPicture.delay(src, at: 3) == 0.2)

        let stripped = try await runConversion(gif, .tool(.stripMetadata))
        #expect(CGImageSourceCreateWithURL(stripped as CFURL, nil).map(CGImageSourceGetCount) == 6)
    }

    @Test(.enabled(if: ffmpegInstalled)) func compressedGIFStillMoves() async throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try animatedGIF(at: gif, frames: 20)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: gif), action: .tool(.compress)))
        // Either smaller and still moving, or kept as it was (already small).
        if let output = result.outputs.first {
            #expect(CGImageSourceCreateWithURL(output as CFURL, nil).map(CGImageSourceGetCount) == 20)
            #expect((FileSize.of(output) ?? 0) < (FileSize.of(gif) ?? 0))
        } else {
            #expect(result.note != nil)
        }
    }
}

/// v2.0: documents the bench found coming out wrong.
struct V20DocumentTests {
    /// macOS's ODT writer closed lists inside lists wrongly (LibreOffice
    /// couldn't open the file) and left the pictures out.
    @Test func odtWithNestedListsOpensAndKeepsPictures() throws {
        let folder = try TempFolder()
        let png = folder.file("p.png")
        try Fixtures.makeImage(at: png)
        let picture = try #require(Document.Picture.from(try Data(contentsOf: png)))
        let document = Document(title: "Λίστες", blocks: [
            .heading(1, [Document.Run("Τίτλος")]),
            .listItem(ordered: false, level: 0, [Document.Run("One")]),
            .listItem(ordered: false, level: 1, [Document.Run("One, inside")]),
            .listItem(ordered: true, level: 2, [Document.Run("Deepest")]),
            .listItem(ordered: false, level: 0, [Document.Run("Two", bold: true)]),
            .table([["A", "B"], ["1", "2  spaces"]]),
            .image(picture),
            .code("let x  =  1\n\tindented"),
            .paragraph([Document.Run("A link", link: "https://example.com")]),
        ])
        let url = folder.file("lists.odt")
        try OpenDocumentText.write(document, to: url)
        let zip = try ZipReader(url: url)
        let content = try #require(zip.data("content.xml"))
        #expect(XMLParser(data: content).parse(), "well-formed XML")
        #expect(zip.contains("Pictures/1.png") && zip.text("META-INF/manifest.xml")?.contains("Pictures/1.png") == true)
        let text = try #require(String(data: content, encoding: .utf8))
        #expect(text.contains("<text:list-item><text:p text:style-name=\"List_20_Contents\">One</text:p><text:list><text:list-item>"))
        #expect(text.contains("let x <text:s text:c=\"1\"/>= <text:s text:c=\"1\"/>1"))
        // Read back by macOS too (TextEdit's reader).
        let read = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        for words in ["Τίτλος", "One, inside", "Deepest", "Two", "2  spaces", "A link"] { #expect(read.contains(words), "\(words)") }
    }

    private func word(_ body: String, footnotes: String? = nil, at url: URL) throws {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        zip.add("word/document.xml", """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:v="urn:schemas-microsoft-com:vml" \
        xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><w:body>\(body)</w:body></w:document>
        """)
        if let footnotes { zip.add("word/footnotes.xml", "<w:footnotes xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(footnotes)</w:footnotes>") }
        try zip.write(to: url)
    }

    @Test func wordFootnotesTextBoxesAndEquations() throws {
        let folder = try TempFolder()
        let url = folder.file("notes.docx")
        let box = "<w:txbxContent><w:p><w:r><w:t>In the box</w:t></w:r></w:p></w:txbxContent>"
        try word("""
        <w:p><w:r><w:t>Before</w:t></w:r><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wps:txbx>\(box)</wps:txbx></w:drawing></mc:Choice>\
        <mc:Fallback><w:pict><v:textbox>\(box)</v:textbox></w:pict></mc:Fallback></mc:AlternateContent></w:r><w:r><w:t xml:space="preserve"> after.</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Noted</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>\
        <w:p><m:oMathPara><m:oMath><m:r><m:t>a+b=c</m:t></m:r></m:oMath></m:oMathPara></w:p>
        """, footnotes: """
        <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>\
        <w:footnote w:id="2"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> The note itself.</w:t></w:r></w:p></w:footnote>
        """, at: url)
        let text = try WordDocument.read(url).plainText
        #expect(text.components(separatedBy: "In the box").count == 2, "once, not twice")
        #expect(text.contains("Before after.\n\nIn the box"), "the box after the paragraph it sits in")
        #expect(text.contains("Noted[1]") && text.hasSuffix("1. The note itself.\n"))
        #expect(text.contains("a+b=c"))
    }

    @Test func markdownFootnotesTasksBreaksAndQuotes() {
        let document = Document(markdown: """
        Line one  
        line two and <kbd>Ctrl</kbd>.

        - [x] Done
        - [ ] To do

        > Outer
        >> Inner

        A claim[^src].

        [^src]: The source.
        """)
        let text = document.plainText
        #expect(text.contains("Line one\nline two and Ctrl."))
        #expect(text.contains("• ☑ Done") && text.contains("• ☐ To do"))
        #expect(text.contains("Outer Inner") && !text.contains(">"))
        #expect(text.contains("A claim[1].") && text.contains("1. The source.") && !text.contains("[^src]"))
    }
}

/// v2.0: pictures, PDFs and sound the bench found coming out wrong.
struct V20MediaTests {
    /// AVIF doesn't keep "which way is up": phone photos came out sideways.
    @Test func avifIsUpright() async throws {
        let folder = try TempFolder()
        let jpeg = folder.file("phone.jpg")
        try Fixtures.makeImage(at: jpeg, width: 120, height: 80, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let avif = try await runConversion(jpeg, .convert(.avif))
        let info = try #require(Fixtures.readImage(avif))
        #expect(info.width == 80 && info.height == 120)
        #expect((info.properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    /// A palette PNG became a BMP with no header at all (unreadable).
    @Test func bmpFromAPalettePNG() async throws {
        let folder = try TempFolder()
        let png = folder.file("palette.png")
        let table: [UInt8] = [255, 0, 0, 0, 0, 255]
        let space = try #require(CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!, last: 1, colorTable: table))
        let pixels = Data((0..<(40 * 30)).map { UInt8($0 % 40 < 20 ? 0 : 1) })
        let image = try #require(CGImage(width: 40, height: 30, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 40, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: pixels as CFData)!,
                                         decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        let bmp = try await runConversion(png, .convert(.bmp))
        let read = try #require(Fixtures.readImage(bmp))
        #expect(read.type == "com.microsoft.bmp" && read.width == 40)
        #expect(Fixtures.pixel(read.image, x: 30, y: 10).b > 200)
    }

    @Test func cutShortPictureSaysSo() async throws {
        let folder = try TempFolder()
        let whole = folder.file("whole.jpg")
        try Fixtures.makePhoto(at: whole, type: .jpeg)
        let data = try Data(contentsOf: whole)
        let cut = folder.file("cut.jpg")
        try data.prefix(data.count / 2).write(to: cut)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: cut), action: .convert(.png)))
        #expect(result.note?.contains("cut short") == true)
        let fine = try await runRequest(ConversionRequest(file: SourceFile(url: whole), action: .convert(.png)))
        #expect(fine.note == nil)
    }

    /// PDFs macOS writes (Smaller PDF, Organize, Merge, Split, and documents
    /// into PDF) had Greek μ as the micro sign µ in Times: searching for the
    /// word found nothing.
    @Test func greekMuSurvivesOrganize() async throws {
        let folder = try TempFolder()
        let url = folder.file("greek.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("Αποτελέσματα μέτρησης" as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [.font: NSFont(name: "Times New Roman", size: 20)!])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let arrangement = PageArrangement(pages: [.init(file: 0, page: 1), .init(file: 0, page: 0, turns: 1)])
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: url), action: .tool(.organize), parameters: .pages(arrangement)))
        let organized = try #require(result.outputs.first)
        let text = try #require(PDFDocument(url: organized)?.string)
        #expect(text.contains("Αποτελέσματα μέτρησης") && !text.contains("\u{00B5}"))
        #expect(PDFDocument(url: result.outputs[0])?.page(at: 1)?.rotation == 90)
    }

    /// Text macOS draws itself in Times: μ goes in a Mac Roman font with no
    /// letter map, and reads as µ. The map is added.
    @Test func greekMuInTextMacOSDraws() throws {
        let folder = try TempFolder()
        let url = folder.file("drawn.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Αποτελέσματα μέτρησης, 5 kg" as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [.font: NSFont(name: "Times New Roman", size: 20)!])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        #expect(PDFDocument(url: url)?.string?.contains("\u{00B5}") == true, "macOS still writes it wrong")
        PDFTextRepair.fixGreekMu(in: url)
        let text = try #require(PDFDocument(url: url)?.string)
        #expect(text.contains("Αποτελέσματα μέτρησης, 5 kg"))
        #expect(!PDFTextRepair.hasGreekMicro(text))
    }

    /// Apple's AAC encoder takes only some bit rates at each sample rate:
    /// editing an 8 kHz phone recording failed with "couldn't save".
    @Test func lowSampleRateSoundCanBeEdited() async throws {
        let folder = try TempFolder()
        let m4a = folder.file("phone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.3) * 0.3) }
        do {
            let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000])
            try file.write(from: buffer)
        }
        var trim = MediaEdit()
        trim.start = 0.2
        trim.end = 1.5
        let edited = try await runConversion(m4a, .tool(.editMedia), parameters: .media(trim))
        let length = try await AVURLAsset(url: edited).load(.duration).seconds
        #expect(abs(length - 1.3) < 0.1)
        #expect(AACBitRate.allowed(256_000, sampleRate: 8_000, channels: 1) == 24_000)
        #expect(AACBitRate.allowed(256_000, sampleRate: 44_100, channels: 2) == 256_000)
        #expect(AACBitRate.allowed(8_000, sampleRate: 48_000, channels: 2) == 64_000)
    }
}

/// v2.0: video and sound conversions that need ffmpeg (the bench's hard files, small).
@Suite(.enabled(if: ffmpegInstalled))
struct V20FFmpegTests {
    private func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = try #require(FFmpeg.locate())
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "ffmpeg \(arguments.joined(separator: " "))")
    }

    private func probe(_ url: URL) throws -> [String: Any] {
        let process = Process()
        process.executableURL = try #require(FFmpeg.locate()).deletingLastPathComponent().appendingPathComponent("ffprobe")
        process.arguments = ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func streams(_ url: URL, _ type: String) throws -> [[String: Any]] {
        (try probe(url)["streams"] as? [[String: Any]] ?? []).filter { $0["codec_type"] as? String == type }
    }

    private func title(_ url: URL) throws -> String? {
        let json = try probe(url)
        let format = (json["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:]
        let stream = (json["streams"] as? [[String: Any]])?.first?["tags"] as? [String: String] ?? [:]
        return (format.merging(stream) { $0 + $1 }).first { $0.key.lowercased().hasSuffix("title") }?.value
    }

    /// Music kept its title and cover only sometimes (MP3 → M4A or FLAC lost both).
    @Test func musicKeepsTitleAndCover() async throws {
        let folder = try TempFolder()
        let cover = folder.file("cover.jpg"), mp3 = folder.file("song.mp3")
        try Fixtures.makePhoto(at: cover, width: 300, height: 300, type: .jpeg)
        try ffmpeg(["-f", "lavfi", "-i", "sine=f=440:d=2", "-i", cover.path, "-map", "0", "-map", "1", "-c:a", "libmp3lame", "-c:v", "copy",
                    "-disposition:v", "attached_pic", "-id3v2_version", "3", "-metadata", "title=Καλημέρα", "-metadata", "artist=Η Μπάντα", mp3.path])
        for format in [OutputFormat.m4a, .flac, .wav] {
            let made = try await runConversion(mp3, .convert(format))
            #expect(try title(made) == "Καλημέρα", "\(format)")
            if format != .wav {
                #expect(try streams(made, "video").contains { ($0["disposition"] as? [String: Int])?["attached_pic"] == 1 }, "cover in \(format)")
            }
        }
        let compressed = try await runRequest(ConversionRequest(file: SourceFile(url: mp3), action: .tool(.compress)))
        if let made = compressed.outputs.first { #expect(try title(made) == "Καλημέρα") }
    }

    /// Opus and Ogg keep their tags with the sound: MP3s made from them had none.
    @Test func opusTagsGoAlong() async throws {
        let folder = try TempFolder()
        let opus = folder.file("voice.opus")
        try ffmpeg(["-f", "lavfi", "-i", "sine=f=300:d=2", "-c:a", "libopus", "-metadata", "title=Φωνή", opus.path])
        #expect(try title(try await runConversion(opus, .convert(.mp3))) == "Φωνή")
        // And Info changes it there too.
        let edit = MetadataEdit(changes: [.title: "Νέος"])
        #expect(try title(try await runConversion(opus, .tool(.editInfo), parameters: .metadata(edit))) == "Νέος")
    }

    @Test func infoTitleSticksInMP4AndMOV() async throws {
        let folder = try TempFolder()
        for type in [AVFileType.mp4, .mov] {
            let video = folder.file("clip.\(type == .mp4 ? "mp4" : "mov")")
            try await MediaFixtures.makeVideo(at: video, fileType: type)
            let made = try await runConversion(video, .tool(.editInfo), parameters: .metadata(MetadataEdit(changes: [.title: "Bench Τίτλος"])))
            let titles = try await AVURLAsset(url: made).load(.commonMetadata).filter { $0.commonKey == .commonKeyTitle }
            #expect(try await titles.first?.load(.stringValue) == "Bench Τίτλος", "\(type)")
        }
    }

    /// 5.1 sound broke WMA ("Invalid argument") and Opus ("Invalid channel layout 5.1(side)").
    @Test func surroundSoundIntoWMAAndOpus() async throws {
        let folder = try TempFolder()
        let ac3 = folder.file("movie.ac3")
        try ffmpeg(["-f", "lavfi", "-i", "aevalsrc=sin(400*t)|sin(500*t)|sin(600*t)|0|sin(700*t)|sin(800*t):d=2:s=48000:c=5.1(side)", "-c:a", "ac3", ac3.path])
        #expect(try streams(try await runConversion(ac3, .convert(.wma)), "audio").first?["channels"] as? Int == 2)
        #expect(try streams(try await runConversion(ac3, .convert(.opus)), "audio").first?["channels"] as? Int == 6)
    }

    @Test func subtitlesStayInside() async throws {
        let folder = try TempFolder()
        let srt = folder.file("subs.srt"), mkv = folder.file("film.mkv")
        try Data("1\n00:00:00,200 --> 00:00:01,500\nΓεια σου\n".utf8).write(to: srt)
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x240:d=2", "-f", "lavfi", "-i", "sine=d=2", "-i", srt.path,
                    "-map", "0", "-map", "1", "-map", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "srt", mkv.path])
        let mp4 = try await runConversion(mkv, .convert(.mp4))
        #expect(try streams(mp4, "subtitle").first?["codec_name"] as? String == "mov_text")
        let back = try await runConversion(mp4, .convert(.mkv))
        #expect(try streams(back, "subtitle").count == 1)
    }

    /// A camcorder clip (MPEG-TS that doesn't start at zero): a GIF of a part had no frames.
    @Test func gifOfPartOfACamcorderClip() async throws {
        let folder = try TempFolder()
        let mts = folder.file("clip.mts")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=3", "-vf", "interlace", "-c:v", "libx264", "-flags", "+ilme+ildct",
                    "-x264opts", "tff=1", "-pix_fmt", "yuv420p", "-f", "mpegts", mts.path])
        var part = MediaEdit()
        part.start = 0.5
        part.end = 2
        let gif = try await runConversion(mts, .convert(.gif), parameters: .media(part))
        #expect((CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0) > 5)
        // A part after the end says so.
        part.start = 10
        part.end = 12
        let after = try await runRequest(ConversionRequest(file: SourceFile(url: mts), action: .convert(.gif), parameters: .media(part)))
        #expect(after.skipped && after.note?.contains("after the video ends") == true)
    }

    @Test func soundOnlyAndPictureOnlySaySo() async throws {
        let folder = try TempFolder()
        let sound = folder.file("sound.mp4"), silent = folder.file("silent.mp4")
        try ffmpeg(["-f", "lavfi", "-i", "sine=d=1", "-c:a", "aac", sound.path])
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=160x120:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", silent.path])
        await #expect(throws: ConversionError.failed("sound.mp4 is only sound, with no picture. Choose M4A or MP3 instead.")) {
            try await runRequest(ConversionRequest(file: SourceFile(url: sound), action: .convert(.webm)))
        }
        let mp3 = try await runRequest(ConversionRequest(file: SourceFile(url: silent), action: .convert(.mp3)))
        #expect(mp3.skipped && mp3.note == "silent.mp4 has no sound, so there's nothing to save.")
    }

    /// HEVC tagged "hev1" opens in macOS but doesn't decode: the frame comes from a copy ffmpeg makes.
    @Test func undecodableVideoStillGivesAFrame() async throws {
        let folder = try TempFolder()
        let hev1 = folder.file("hev1.mp4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x240:d=2", "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hev1",
                    "-pix_fmt", "yuv420p", hev1.path])
        let frame = try await runConversion(hev1, .tool(.saveFrame), parameters: .frame(seconds: 1))
        #expect(Fixtures.readImage(frame)?.width == 320)
        // A file that isn't a video says so plainly.
        let junk = folder.file("junk.mp4")
        try Data((0..<4000).map { UInt8($0 % 251) }).write(to: junk)
        do {
            _ = try await runRequest(ConversionRequest(file: SourceFile(url: junk), action: .convert(.mov)))
            Issue.record("a file of noise converted")
        } catch {
            #expect(error.localizedDescription.contains("seems damaged or incomplete"))
        }
    }
}

extension V20Tests {
    /// ZIPs made from an app started from the Dock (no locale) had names
    /// without the UTF-8 mark: Windows showed "╬æ╧ü╧ç…" for Greek.
    @Test func zipNamesAreMarkedUTF8() async throws {
        let folder = try TempFolder()
        let file = folder.file("Αρχείο ένα.txt")
        try Data("γεια".utf8).write(to: file)
        let result = try await runRequest(ConversionRequest(files: [SourceFile(url: file)], action: .tool(.archive)))
        let zip = try Data(contentsOf: try #require(result.outputs.first))
        // The central directory entry's flags: bit 11 is "names are UTF-8".
        let entry = try #require(zip.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])))
        let flags = UInt16(zip[entry.lowerBound + 8]) | UInt16(zip[entry.lowerBound + 9]) << 8
        #expect(flags & 0x800 != 0)
    }
}

extension V20FFmpegTests {
    /// A podcast in an .mp4 has no picture: it gets the sound wheel.
    @Test func soundOnlyMP4IsSound() async throws {
        let folder = try TempFolder()
        let sound = folder.file("podcast.mp4"), video = folder.file("clip.mp4")
        try await MediaFixtures.makeVideo(at: sound, withVideo: false, fileType: .mp4)
        try await MediaFixtures.makeVideo(at: video, fileType: .mp4)
        #expect(SourceFile(url: sound).kind == .audio)
        #expect(SourceFile(url: video).kind == .video)
        #expect(MovieTracks.handlers(of: video)?.contains("vide") == true)
    }

    /// A sound file that ends early (a download that stopped) converts what's there, and says so.
    @Test func cutShortSoundSaysSo() async throws {
        let folder = try TempFolder()
        let whole = folder.file("whole.flac"), cut = folder.file("cut.flac")
        let process = Process()
        process.executableURL = try #require(FFmpeg.locate())
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=f=440:d=6", "-c:a", "flac", whole.path]
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: whole)
        try data.prefix(data.count / 3).write(to: cut)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: cut), action: .convert(.m4a)))
        #expect(result.note?.contains("seems cut short") == true, "\(result.note ?? "no note")")
        let fine = try await runRequest(ConversionRequest(file: SourceFile(url: whole), action: .convert(.m4a)))
        #expect(fine.note == nil)
    }

    /// See-through ProRes into MP4: black behind it, not the colors hidden there.
    @Test func seeThroughVideoGetsBlackBehind() async throws {
        let folder = try TempFolder()
        let prores = folder.file("overlay.mov")
        let process = Process()
        process.executableURL = try #require(FFmpeg.locate())
        // Red everywhere, but only the left half shows.
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=red:s=320x240:d=1",
                             "-vf", "format=rgba,geq=r='255':g='0':b='0':a='if(lt(X,W/2),255,0)'", "-c:v", "prores_ks", "-profile:v", "4444",
                             "-pix_fmt", "yuva444p10le", prores.path]
        try process.run()
        process.waitUntilExit()
        let mp4 = try await runConversion(prores, .convert(.mp4))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mp4))
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let right = Fixtures.pixel(frame, x: frame.width * 3 / 4, y: frame.height / 2)
        let left = Fixtures.pixel(frame, x: frame.width / 4, y: frame.height / 2)
        #expect(right.r < 40 && left.r > 200, "right \(right), left \(left)")
    }
}

extension V20FFmpegTests {
    /// Compress kept the picture but not its see-through part (HEVC with alpha now).
    @Test func compressedSeeThroughVideoStaysSeeThrough() async throws {
        let folder = try TempFolder()
        let prores = folder.file("overlay.mov")
        let process = Process()
        process.executableURL = try #require(FFmpeg.locate())
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=red:s=320x240:d=1",
                             "-vf", "format=rgba,geq=r='255':g='0':b='0':a='if(lt(X,W/2),255,0)'", "-c:v", "prores_ks", "-profile:v", "4444",
                             "-pix_fmt", "yuva444p10le", prores.path]
        try process.run()
        process.waitUntilExit()
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: prores), action: .tool(.compress)))
        let made = try #require(result.outputs.first)
        let track = try #require(try await AVURLAsset(url: made).loadTracks(withMediaType: .video).first)
        #expect(try await VideoCompressor.hasAlpha(track))
    }
}
