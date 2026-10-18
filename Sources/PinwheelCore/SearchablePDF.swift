import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// "Searchable": scanned pages get an invisible layer with the text that's
/// on them (what a scanner's "OCR" option does), so the PDF can be searched
/// and its text selected and copied. The page looks exactly as before.
/// Pages that already have text are left as they are.
enum SearchablePDF {
    static func make(
        _ source: URL, destination: URL, recognition: TextRecognition,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        let document = try PDFConverter.open(source)
        let count = document.pageCount
        let scans = (0..<count).filter {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !scans.isEmpty else {
            throw NothingToDo(reason: "Every page already has text you can search and copy, so nothing was saved.")
        }
        let texts = try await ScannedPages.read(source, pages: scans, recognition: recognition) { done in
            progress(Double(done) / Double(scans.count) * 0.9)
        }
        try Task.checkCancellation()

        var layered = 0
        for index in scans {
            guard let text = texts[index], !text.isEmpty, let page = document.page(at: index),
                  let replacement = withText(page, text: text) else { continue }
            document.removePage(at: index)
            document.insert(replacement, at: index)
            layered += 1
        }
        guard layered > 0 else {
            throw NothingToDo(reason: "No text was found on the scanned pages, so nothing was saved.")
        }
        guard document.write(to: destination) else { throw ConversionError.cannotWrite(destination.lastPathComponent) }
        progress(1)
        return layered == 1 ? "1 scanned page can now be searched." : "\(layered) scanned pages can now be searched."
    }

    /// The page drawn as it is, with the recognized words on top in
    /// invisible ink. The page's own rotation is drawn in (it stays upright).
    static func withText(_ page: PDFPage, text: RecognizedText) -> PDFPage? {
        guard let original = page.pageRef else { return nil }
        let box = page.bounds(for: .cropBox)
        let turned = abs(page.rotation) % 180 == 90
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        var mediaBox = CGRect(origin: .zero, size: size)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.concatenate(original.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(original)
        ctx.restoreGState()
        drawInvisible(text, in: ctx, size: size)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Each word sized and stretched to cover the word in the picture, so a
    /// search highlights the right spot. A space follows each word but the
    /// last in a line, so copied text has its spaces.
    static func drawInvisible(_ text: RecognizedText, in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in text.lines {
            for (number, word) in line.words.enumerated() {
                let rect = CGRect(
                    x: word.box.minX * size.width, y: (1 - word.box.maxY) * size.height,
                    width: word.box.width * size.width, height: word.box.height * size.height
                )
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                let font = CTFontCreateWithName("Helvetica" as CFString, rect.height, nil)
                let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
                let measured = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: attributes))
                let width = CTLineGetTypographicBounds(measured, nil, nil, nil)
                guard width > 0 else { continue }
                let spoken = number < line.words.count - 1 ? word.text + " " : word.text
                let drawn = CTLineCreateWithAttributedString(NSAttributedString(string: spoken, attributes: attributes))
                ctx.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
                ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22)
                CTLineDraw(drawn, ctx)
            }
        }
        ctx.restoreGState()
    }
}
