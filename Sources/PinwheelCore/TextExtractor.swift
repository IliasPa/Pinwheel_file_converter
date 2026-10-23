import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// "Get Text": the words in a picture or a PDF, saved as a plain .txt file.
/// Text recognition runs on this Mac: Apple's Vision (like Live Text), or
/// Tesseract when Greek (or another language Vision lacks) is wanted.
enum TextExtractor {
    /// Writes the text; returns a note for the progress window, if any.
    static func write(
        _ file: SourceFile, to destination: URL, recognition: TextRecognition,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String? {
        var note: String?
        let text: String
        switch file.kind {
        case .image:
            let image = try await Blocking.run { _ in try picture(file.url) }
            progress(0.2)
            text = try await TextRecognizer.recognizePicture(image, settings: recognition).string
        case .pdf:
            let (pdfText, scanned) = try await pdfText(file.url, recognition: recognition, progress: progress)
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

    /// The picture upright. Bigger than this doesn't read better, just slower.
    static func picture(_ url: URL) throws -> CGImage {
        let src = try ImageConverter.open(url)
        return try ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxPixelSize: 4096)
    }

    /// Each page's own text; pages without any (scans) are read with text
    /// recognition. Returns the text and how many pages were scans.
    static func pdfText(
        _ url: URL, recognition: TextRecognition, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (String, Int) {
        let document = try PDFConverter.open(url)
        let count = document.pageCount
        var parts = (0..<count).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let scans = parts.indices.filter { parts[$0].isEmpty }
        let recognized = try await ScannedPages.read(url, pages: scans, recognition: recognition) { done in
            progress(Double(count - scans.count + done) / Double(max(count, 1)))
        }
        for (index, text) in recognized { parts[index] = text.string.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A blank line and a form feed between pages, like `pdftotext`.
        return (parts.joined(separator: "\n\n\u{0C}"), recognized.values.filter { !$0.isEmpty }.count)
    }
}

/// Reads scanned PDF pages: draws each at 300 DPI and recognizes its text.
/// Tesseract runs on a few pages at once (one per core it can have);
/// Vision takes them one by one (it uses the whole Mac for each).
enum ScannedPages {
    static let dpi = 300.0

    static func read(
        _ url: URL, pages: [Int], recognition: TextRecognition,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [Int: RecognizedText] {
        guard !pages.isEmpty else { return [:] }
        let lanes = recognition.engine == .tesseract ? min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1), 4) : 1
        let done = Locked(0)
        return try await withThrowingTaskGroup(of: (Int, RecognizedText).self) { group in
            var results: [Int: RecognizedText] = [:]
            var queue = pages[...]
            func startNext() {
                guard let index = queue.popFirst() else { return }
                group.addTask {
                    let image = try await Blocking.run { _ in try render(url, page: index) }
                    let text = try await TextRecognizer.recognize(image, settings: recognition)
                    progress(done.withValue { $0 += 1; return $0 })
                    return (index, text)
                }
            }
            for _ in 0..<lanes { startNext() }
            while let (index, text) = try await group.next() {
                results[index] = text
                startNext()
            }
            return results
        }
    }

    /// One page as a picture, upright as it's shown (its own rotation included).
    static func render(_ url: URL, page index: Int) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if !document.isUnlocked { _ = document.unlockWithPassword("") }
        guard let page = document.page(at: index + 1) else { throw ConversionError.unreadable(url.lastPathComponent) }
        return try PDFConverter.render(page, dpi: dpi)
    }
}

/// The words in a picture, for the clipboard history's Text in Image.
public enum PictureText {
    /// In reading order; "" when there are none.
    public static func read(_ url: URL, recognition: TextRecognition) async throws -> String {
        let image = try await Blocking.run { _ in try TextExtractor.picture(url) }
        return try await TextRecognizer.recognizePicture(image, settings: recognition).string
    }
}
