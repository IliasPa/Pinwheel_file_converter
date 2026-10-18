import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// "Get Text": the words in a picture or a PDF, saved as a plain .txt file.
/// Text recognition runs on this Mac (Vision), like Live Text.
enum TextExtractor {
    /// Writes the text; returns a note for the progress window, if any.
    static func write(_ file: SourceFile, to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws -> String? {
        var note: String?
        let text: String
        switch file.kind {
        case .image:
            let src = try ImageConverter.open(file.url)
            // Bigger than this doesn't read better, it's just slower.
            let image = try ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxPixelSize: 4096)
            text = try recognize(image)
        case .pdf:
            let (pdfText, scanned) = try pdfText(file.url, progress: progress)
            text = pdfText
            if scanned > 0 {
                note = scanned == 1 ? "1 scanned page was read with text recognition." : "\(scanned) scanned pages were read with text recognition."
            }
        default:
            throw ConversionError.unsupported("Getting text from \(file.url.lastPathComponent)")
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NothingToDo(reason: "No text was found, so nothing was saved.")
        }
        do {
            try Data(text.utf8).write(to: destination)
        } catch {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        return note
    }

    /// The text in a picture, top to bottom, one line per line found.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VisionTurns.take { try VNImageRequestHandler(cgImage: image).perform([request]) }
        } catch {
            throw ConversionError.failed("Couldn't read the text: \(error.localizedDescription)")
        }
        // Vision's y points up; sort into reading order by rows, then left to right.
        let lines = (request.results ?? []).sorted { a, b in
            let rowA = (a.boundingBox.midY * 60).rounded(), rowB = (b.boundingBox.midY * 60).rounded()
            return rowA != rowB ? rowA > rowB : a.boundingBox.minX < b.boundingBox.minX
        }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Each page's own text; pages without any (scans) are read with text
    /// recognition. Returns the text and how many pages were scans.
    static func pdfText(_ url: URL, progress: @Sendable (Double) -> Void) throws -> (String, Int) {
        let document = try PDFConverter.open(url)
        let pages = CGPDFDocument(url as CFURL)
        var parts: [String] = []
        var scanned = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            var text = document.page(at: index)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let page = pages?.page(at: index + 1) {
                text = try recognize(try PDFConverter.render(page, dpi: 200))
                if !text.isEmpty { scanned += 1 }
            }
            parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            progress(Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        // A blank line and a form feed between pages, like `pdftotext`.
        return (parts.joined(separator: "\n\n\u{0C}"), scanned)
    }
}
