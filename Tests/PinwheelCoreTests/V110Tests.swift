import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import PinwheelCore

/// v1.10: PDFs into PowerPoint that can be edited, and into Excel table by
/// table, ruled tables cell by cell, with numbers as numbers.
struct V110Tests {
    /// Pages drawn by `draw`, each 720 × 405 (a slide's shape).
    private func pdf(at url: URL, size: CGSize = CGSize(width: 720, height: 405), _ draw: (CGContext) throws -> Void) throws {
        var box = CGRect(origin: .zero, size: size)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        try draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func write(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
        let font = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)!
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func photo() throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        return try #require(ctx.makeImage())
    }

    @Test func slidesYouCanEdit() async throws {
        let folder = try TempFolder()
        let url = folder.file("talk.pdf")
        let picture = try photo()
        try pdf(at: url) { ctx in
            ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.85, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 405))
            write("Quarterly Results", at: CGPoint(x: 60, y: 330), size: 32, bold: true, color: NSColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1))
            write("Sales grew in every region this year.", at: CGPoint(x: 60, y: 260), size: 18)
            write("Costs stayed where they were.", at: CGPoint(x: 60, y: 236), size: 18)
            ctx.draw(picture, in: CGRect(x: 460, y: 60, width: 200, height: 150))
        }
        let pptx = try await runConversion(url, .convert(.pptx))
        let zip = try ZipReader(url: pptx)
        let slide = try #require(zip.text("ppt/slides/slide1.xml"))
        #expect(slide.contains("<a:t>Quarterly Results</a:t>") && slide.contains("txBox=\"1\""))
        #expect(slide.contains("sz=\"3200\" b=\"1\"") && slide.contains("<a:srgbClr val=\"1A4DB3\"/>"))
        // The two body lines: one box, each line a paragraph, 24 points apart.
        #expect(slide.contains("<a:t>Sales grew in every region this year.</a:t></a:r></a:p><a:p>"))
        #expect(slide.contains("<a:spcPts val=\"2400\"/>"))
        #expect(zip.contains("ppt/media/image1.jpg") && zip.contains("ppt/media/image1-1.jpg"), "the page, and its picture to move")

        // Pages as pictures, if that's what Settings says.
        var options = ConversionOptions()
        options.pdfPagesAsPictures = true
        let pictures = try await runConversion(url, .convert(.pptx), options: options)
        #expect(try ZipReader(url: pictures).text("ppt/slides/slide1.xml")?.contains("txBox") == false)
    }

    @Test func theBackgroundLosesItsWords() throws {
        let folder = try TempFolder()
        let url = folder.file("plain.pdf")
        try pdf(at: url) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 405))
            write("Big white words", at: CGPoint(x: 100, y: 200), size: 40, color: .white)
        }
        let page = try #require(CGPDFDocument(url as CFURL)?.page(at: 1))
        let data = try #require(PDFSlides.background(page, box: page.getBoxRect(.cropBox), covering: [CGRect(x: 100, y: 195, width: 330, height: 50)]))
        let image = try #require(NSBitmapImageRep(data: data))
        // Where the words were: the blue around them, as in a corner.
        let spot = try #require(image.colorAt(x: Int(200 * 150 / 72), y: image.pixelsHigh - Int(215 * 150 / 72))?.usingColorSpace(.sRGB))
        let corner = try #require(image.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        #expect(abs(spot.redComponent - corner.redComponent) < 0.03 && abs(spot.blueComponent - corner.blueComponent) < 0.03, "\(spot) \(corner)")
        #expect(spot.redComponent < 0.5, "not the white of the words")
    }

    /// A ruled table: lines between all rows and columns; one cell's text wraps.
    private func ruledTable(_ ctx: CGContext, top: CGFloat, rows: [[String]]) {
        let columns: [CGFloat] = [60, 200, 330, 460]
        let height: CGFloat = 30
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(0.8)
        for row in 0...rows.count {
            ctx.move(to: CGPoint(x: columns[0], y: top - CGFloat(row) * height))
            ctx.addLine(to: CGPoint(x: columns[3], y: top - CGFloat(row) * height))
        }
        for x in columns {
            ctx.move(to: CGPoint(x: x, y: top))
            ctx.addLine(to: CGPoint(x: x, y: top - CGFloat(rows.count) * height))
        }
        ctx.strokePath()
        for (row, cells) in rows.enumerated() {
            for (column, text) in cells.enumerated() {
                let lines = text.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    write(line, at: CGPoint(x: columns[column] + 6, y: top - CGFloat(row) * height - 13 - CGFloat(index) * 11), size: 9)
                }
            }
        }
    }

    @Test func tablesBecomeSheetsOneEach() async throws {
        let folder = try TempFolder()
        let url = folder.file("invoice.pdf")
        try pdf(at: url, size: CGSize(width: 595, height: 842)) { ctx in
            write("Invoice 2026-118", at: CGPoint(x: 60, y: 780), size: 18)
            ruledTable(ctx, top: 740, rows: [["Item", "Units", "Price"], ["Olive oil\n(5 litres)", "2", "1.250,00 €"], ["Honey", "10", "85,50 €"]])
            write("Thank you.", at: CGPoint(x: 60, y: 600), size: 12)
            ruledTable(ctx, top: 560, rows: [["Paid", "Date", "Left"], ["Yes", "2026-10-24", "(300,00)"], ["No", "-", "0,00"]])
        }
        let workbook = try await PDFStructure.workbook(url, recognition: TextRecognition()) { _ in }
        #expect(workbook.sheets.map(\.name) == ["Page 1, table 1", "Page 1, table 2"])
        #expect(workbook.sheets[0].rows == [
            [.text("Item"), .text("Units"), .text("Price")],
            [.text("Olive oil (5 litres)"), .number(2), .number(1250)],
            [.text("Honey"), .number(10), .number(85.5)],
        ])
        #expect(workbook.sheets[1].rows[1] == [.text("Yes"), .text("2026-10-24"), .number(-300)])
    }

    @Test func numbersAsNumbers() {
        func values(_ rows: [[String]]) -> [[Workbook.Cell]] { PDFTables.cells(rows) }
        #expect(values([["1.250,00", "3,5"]]) == [[.number(1250), .number(3.5)]], "a comma for decimals")
        #expect(values([["1,250.00", "3.5"]]) == [[.number(1250), .number(3.5)]], "a point for decimals")
        #expect(values([["1,250", "2,000"]]) == [[.number(1250), .number(2000)]], "thousands")
        #expect(values([["$ 1 250", "(300)", "−5"]]) == [[.number(1250), .number(-300), .number(-5)]])
        #expect(values([["007", "12%", "N/A"]]) == [[.text("007"), .text("12%"), .text("N/A")]])
    }
}
