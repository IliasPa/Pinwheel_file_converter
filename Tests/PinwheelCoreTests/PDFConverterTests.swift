import Foundation
import PDFKit
import Testing
@testable import PinwheelCore

struct PDFConverterTests {
    @Test func onePagePDFBecomesOneImage() async throws {
        let folder = try TempFolder()
        let source = folder.file("flyer.pdf")
        try MediaFixtures.makePDF(at: source, pages: 1)
        let output = try await runConversion(source, .convert(.png))
        #expect(output.lastPathComponent == "flyer (converted).png")
        let info = try #require(Fixtures.readImage(output))
        // 200 × 100 points at 150 DPI.
        #expect(info.width == 417 && info.height == 208)
    }

    @Test func multiPagePDFBecomesAFolderOfImages() async throws {
        let folder = try TempFolder()
        let source = folder.file("report.pdf")
        try MediaFixtures.makePDF(at: source, pages: 12)
        let output = try await runConversion(source, .convert(.jpeg))
        #expect(output.lastPathComponent == "report (converted)")
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names.count == 12)
        #expect(names.first == "report page 01.jpg")
        #expect(names.last == "report page 12.jpg")
        #expect(Fixtures.readImage(output.appendingPathComponent("report page 05.jpg"))?.type == "public.jpeg")
    }

    @Test func pagesDrawnSideBySideLandInTheRightFiles() async throws {
        let folder = try TempFolder()
        let source = folder.file("sizes.pdf")
        // Page n is 100 + 10n points wide, so each image shows which page it is.
        let ctx = try #require(CGContext(source as CFURL, mediaBox: nil, nil))
        for page in 0..<20 {
            var box = CGRect(x: 0, y: 0, width: 100 + 10 * page, height: 50)
            ctx.beginPage(mediaBox: &box)
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(box)
            ctx.endPage()
        }
        ctx.closePDF()

        var options = ConversionOptions()
        options.pdfDPI = 72
        let progress = Locked<[Double]>([])
        let output = try await runConversion(source, .convert(.png), options: options) { value in
            progress.value += [value]
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names.count == 20)
        for (index, name) in names.enumerated() {
            #expect(name == "sizes page \(String(format: "%02d", index + 1)).png")
            #expect(Fixtures.readImage(output.appendingPathComponent(name))?.width == 100 + 10 * index)
        }
        #expect(progress.value.max() == 1)
    }

    @Test func rotatedPagesComeOutUpright() async throws {
        let folder = try TempFolder()
        let plain = folder.file("plain.pdf")
        try MediaFixtures.makePDF(at: plain, pages: 1)
        let document = try #require(PDFDocument(url: plain))
        document.page(at: 0)?.rotation = 90
        let rotated = folder.file("rotated.pdf")
        #expect(document.write(to: rotated))

        let output = try await runConversion(rotated, .convert(.png))
        let info = try #require(Fixtures.readImage(output))
        #expect(info.width == 208 && info.height == 417)
    }

    @Test func smallerPDFKeepsEveryPageAndShrinksPhotos() async throws {
        let folder = try TempFolder()
        let source = folder.file("photos.pdf")
        try MediaFixtures.makePDF(at: source, pages: 3, withPhoto: true)
        let output = try await runConversion(source, .tool(.compress))
        #expect(output.lastPathComponent == "photos (compressed).pdf")
        #expect(PDFDocument(url: output)?.pageCount == 3)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let after = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int ?? 0
        #expect(after < before)
    }

    @Test func pdfWheelIsFullyAvailable() {
        let pdf = SourceFile(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        for action in FormatCatalog.actions(for: [pdf], mode: .convert) {
            #expect(ConversionEngine.availability(of: action, for: [pdf], ffmpegAvailable: false) == .available)
        }
    }
}
