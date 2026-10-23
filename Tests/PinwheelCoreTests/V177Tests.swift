import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

/// v1.7.7: yellow ticks for conversions that lose something, and the reader
/// that does Vision's work in a helper stopped a minute after its last use.
struct ConversionLimitTests {
    private func limit(_ from: String, _ to: OutputFormat) throws -> String? {
        let source = try #require(Compatibility.sources.first { $0.title == from })
        return Compatibility.limitation(from: source, to: to)
    }

    @Test func whatEachConversionLoses() throws {
        #expect(try limit("PNG", .jpeg) == "see-through parts become white")
        #expect(try limit("JPEG", .png) == nil, "nothing lost")
        #expect(try limit("JPEG", .gif) == "only 256 colors")
        #expect(try limit("GIF", .png) == "only the first frame of an animated GIF")
        #expect(try limit("PNG", .ico) != nil && limit("PNG", .icns) == nil)
        #expect(try limit("PDF", .png) == nil && limit("PDF", .docx) != nil && limit("PDF", .txt) == "text only")
        #expect(try limit("MP4", .gif) != nil && limit("MP4", .mov) == nil && limit("MP4", .mp3) == nil)
        #expect(try limit("MP3", .m4a) != nil, "lossy again")
        #expect(try limit("MP3", .flac) != nil && limit("WAV", .mp3) == nil && limit("FLAC", .wav) == nil)
        #expect(try limit("DOCX", .txt) != nil && limit("TXT", .docx) == nil && limit("MD", .docx) == nil)
        #expect(try limit("XLSX", .csv) == "only the first sheet, as plain values" && limit("CSV", .tsv) == nil)
        #expect(try limit("SRT", .vtt) == nil && limit("VTT", .srt) != nil && limit("SRT", .txt) != nil)
        #expect(try limit("ZIP", .tar) == nil)
        // Every limit is for a conversion the table has.
        for section in Compatibility.sections {
            for row in section.rows {
                for (target, cell) in zip(section.targets, row.cells) where Compatibility.limitation(from: row.source, to: target) != nil {
                    if case .converts = cell {} else { Issue.record("\(row.source.title) → \(target.title) has a limit but doesn't convert") }
                }
            }
        }
    }
}

@Suite(.serialized)
struct PictureReaderTests {
    private func png(_ image: CGImage, at url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func qr(_ text: String, at url: URL) throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(text.utf8), "inputCorrectionLevel": "M"]))
        let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = code.transformed(by: CGAffineTransform(translationX: 48, y: 48))
            .composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -48, dy: -48).offsetBy(dx: 48, dy: 48)))
        try CIContext().writePNGRepresentation(of: padded, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// The real helper: it reads text, codes and where text is, then quits
    /// once it's been idle, and starts again for the next question.
    @Test func theHelperReadsThenGoes() async throws {
        let folder = try TempFolder()
        let words = folder.file("words.png")
        try png(textPicture("Pinwheel reads this"), at: words)
        let code = folder.file("code.png")
        try qr("Hello from the reader", at: code)

        let reader = PictureReader(worker: try builtWorker(), keepAlive: .milliseconds(800))
        #expect(await reader.processID == nil)
        // (The first time a newly built helper reads text, macOS takes about
        // 40 seconds to get it ready; after that it's quick.)
        let text = try await reader.text(in: words, recognition: TextRecognition())
        #expect(text.contains("Pinwheel reads this"))
        let pid = try #require(await reader.processID)
        #expect(await reader.isRunning)
        #expect(try await reader.codes(in: code).map(\.text) == ["Hello from the reader"])
        #expect(await reader.processID == pid, "the same helper answers while it's in use")
        let regions = try await reader.regions(in: words, faces: true, text: true)
        #expect(!regions.isEmpty && regions.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.width <= 1 && $0.height <= 1 })

        // Idle: it quits, and its memory goes with it.
        var gone = false
        for _ in 0..<60 where !gone {
            try await Task.sleep(for: .milliseconds(100))
            gone = kill(pid, 0) != 0
        }
        let running = await reader.isRunning
        #expect(gone && !running)

        // Asked again: a new one.
        #expect(try await reader.codes(in: code).count == 1)
        let again = await reader.processID
        #expect(again != nil && again != pid)
    }

    /// A picture that can't be read is an error, not a crash; the helper goes on.
    @Test func aBadPicture() async throws {
        let folder = try TempFolder()
        let broken = folder.file("broken.png")
        try Data("not a picture".utf8).write(to: broken)
        let reader = PictureReader(worker: try builtWorker(), keepAlive: .milliseconds(500))
        await #expect(throws: (any Error).self) { try await reader.codes(in: broken) }
        let code = folder.file("code.png")
        try qr("Still here", at: code)
        #expect(try await reader.codes(in: code).map(\.text) == ["Still here"])
    }

    @Test func withoutAHelperItsDoneHere() async throws {
        let folder = try TempFolder()
        let code = folder.file("code.png")
        try qr("In this process", at: code)
        let reader = PictureReader(worker: nil)
        #expect(try await reader.codes(in: code).map(\.text) == ["In this process"])
        #expect(await reader.processID == nil)
    }
}

/// Automatic: a picture is read by Tesseract and Vision, and the better
/// reading is kept (Vision can't read Greek; Tesseract finds little in photos).
struct BetterReadingTests {
    private func reading(_ lines: [[(String, Double)]]) -> RecognizedText {
        RecognizedText(lines: lines.map { RecognizedLine(words: $0.map { RecognizedWord(text: $0.0, box: .zero, confidence: $0.1) }) })
    }

    @Test func theBetterReadingIsKept() {
        // A photo: Tesseract finds bits it isn't sure of, Vision the words.
        let photo = (tesseract: reading([[("(Ω", 0.2), ("ad", 0.3), ("Ξ", 0.4)], [("Monday", 0.7)]]),
                     vision: reading([[("OPENING", 1), ("HOURS", 1)], [("Monday", 1), ("to", 1), ("Friday", 1)]]))
        #expect(TextRecognizer.better(tesseract: photo.tesseract, vision: photo.vision) == photo.vision)
        // Greek, which Vision reads as look-alike letters.
        let greek = (tesseract: reading([[("Καλημέρα", 0.9), ("κόσμε", 0.85)]]),
                     vision: reading([[("Kalnuépa", 1), ("kóoue", 1), ("and", 1), ("more", 1)]]))
        #expect(TextRecognizer.better(tesseract: greek.tesseract, vision: greek.vision) == greek.tesseract)
        // A clean screenshot: both read it all; Tesseract's order of blocks stays.
        let shot = (tesseract: reading([[("Inbox", 0.95)], [("Meeting", 0.95), ("notes", 0.93)]]),
                    vision: reading([[("Inbox", 1), ("Meeting", 1), ("notes", 1)]]))
        #expect(TextRecognizer.better(tesseract: shot.tesseract, vision: shot.vision) == shot.tesseract)
    }

    /// A sign photographed with a phone: 12 MP, at an angle, in uneven
    /// light, grainy and a little soft. Tesseract finds no text in it.
    private func signPhoto() throws -> CGImage {
        let width = 4032, height = 3024
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.45, green: 0.32, blue: 0.22, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: 0.09)
        ctx.translateBy(x: -1500, y: -1050)
        ctx.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2100))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (index, line) in ["OPENING HOURS", "Monday to Friday 9:00 - 17:00", "Saturday 10:00 - 14:00", "Closed on Sundays"].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 200, y: 1750 - CGFloat(index) * 300), withAttributes: [
                .font: NSFont.systemFont(ofSize: index == 0 ? 190 : 140, weight: index == 0 ? .bold : .regular),
                .foregroundColor: NSColor(white: 0.15, alpha: 1),
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        var image = CIImage(cgImage: try #require(ctx.makeImage()))
        image = image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: 300, y: 2900), "inputTopRight": CIVector(x: 3800, y: 2700),
            "inputBottomLeft": CIVector(x: 150, y: 200), "inputBottomRight": CIVector(x: 3950, y: 450),
        ])
        let shade = try #require(CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 900, y: 2400), "inputRadius0": 300, "inputRadius1": 3600,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.55),
        ])?.outputImage)
        let grain = try #require(CIFilter(name: "CIRandomGenerator")?.outputImage).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.12, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.12, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.12, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
            "inputBiasVector": CIVector(x: -0.06, y: -0.06, z: -0.06, w: 0),
        ])
        image = grain.composited(over: shade.composited(over: image)).applyingGaussianBlur(sigma: 2.2)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(CIContext().createCGImage(image, from: image.extent))
    }

    @Test(.enabled(if: TesseractSetup.greek != nil, "needs Tesseract with Greek"))
    func automaticReadsPhotosAndGreek() async throws {
        var recognition = try #require(TesseractSetup.greek)
        recognition.checksWithVision = true
        let photo = try signPhoto()
        #expect(try await TextRecognizer.recognizePicture(photo, settings: recognition).string.contains("Closed on Sundays"))
        let greek = textPicture("Καλημέρα κόσμε από την Αθήνα")
        #expect(try await TextRecognizer.recognizePicture(greek, settings: recognition).string.contains("Καλημέρα"))
    }
}
