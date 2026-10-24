import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

let webpToolsInstalled = ExternalTool.cwebp.locate().map {
    FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("img2webp").path)
} ?? false

/// v1.9: animations that keep moving (and become videos), animated WebP
/// from videos.
struct AnimationTests {
    /// Four frames of a box moving right, 0.2 s each; the left edge see-through.
    static func animatedGIF(at url: URL, frames: Int = 4) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 8, y: 0, width: 56, height: 48))
            ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 8 + index * 10, y: 12, width: 20, height: 24))
            let image = try #require(ctx.makeImage())
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(dest))
    }

    private func frameCount(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
    }

    @Test func animatedPicturesAreSeen() throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try Self.animatedGIF(at: gif)
        let still = folder.file("still.gif")
        try Self.animatedGIF(at: still, frames: 1)
        #expect(SourceFile(url: gif).isAnimated && !SourceFile(url: still).isAnimated)
        // The wheel: videos only for what moves.
        let moving = FormatCatalog.actions(for: [SourceFile(url: gif)], mode: .convert)
        #expect(moving.contains(.convert(.mp4)) && moving.contains(.convert(.webm)) && !moving.contains(.convert(.gif)))
        #expect(moving.count <= FormatCatalog.maxFormats)
        #expect(!FormatCatalog.actions(for: [SourceFile(url: still)], mode: .convert).contains(.convert(.mp4)))
        let frames = try AnimatedPicture.frames(of: gif)
        #expect(frames.count == 4)
        #expect(try abs(frames.frame(1).delay - 0.2) < 0.001)
    }

    @Test func animationsKeepMoving() async throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try Self.animatedGIF(at: gif)
        let png = try await runConversion(gif, .convert(.png))
        #expect(frameCount(png) == 4, "an animated PNG")
        let heic = try await runConversion(gif, .convert(.heic))
        #expect(frameCount(heic) == 4, "a HEIC sequence")
        // Back into a GIF, still moving, from the PNG.
        let again = try await runConversion(png, .convert(.gif))
        #expect(frameCount(again) == 4)
        // A format that can't move: the first frame.
        let jpeg = try await runConversion(gif, .convert(.jpeg))
        #expect(frameCount(jpeg) == 1)
    }

    @Test(.enabled(if: webpToolsInstalled, "needs Homebrew's webp tools")) func animatedWebP() async throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try Self.animatedGIF(at: gif)
        let webp = try await runConversion(gif, .convert(.webp))
        #expect(frameCount(webp) == 4)
        let src = try #require(CGImageSourceCreateWithURL(webp as CFURL, nil))
        #expect(abs((AnimatedPicture.delay(src, at: 0) ?? 0) - 0.2) < 0.01)
    }

    @Test func gifIntoMP4() async throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try Self.animatedGIF(at: gif)
        let mp4 = try await runConversion(gif, .convert(.mp4))
        #expect(mp4.pathExtension == "mp4")
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(duration - 0.8) < 0.05 && size == CGSize(width: 64, height: 48))
    }

    @Test(.enabled(if: ffmpegInstalled, "needs ffmpeg")) func gifIntoWebM() async throws {
        let folder = try TempFolder()
        let gif = folder.file("moving.gif")
        try Self.animatedGIF(at: gif)
        let webm = try await runConversion(gif, .convert(.webm))
        let ffmpeg = try #require(FFmpeg.locate())
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let probe = try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of", "csv=p=0", webm.path])
        #expect(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "vp9")
    }

    @Test(.enabled(if: ffmpegInstalled && webpToolsInstalled, "needs ffmpeg and Homebrew's webp tools")) func videoIntoAnimatedWebP() async throws {
        let folder = try TempFolder()
        let video = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: video, seconds: 1, width: 160, height: 120)
        var options = ConversionOptions()
        options.gifFPS = 10
        let webp = try await runConversion(video, .convert(.webp), options: options)
        #expect(webp.pathExtension == "webp" && frameCount(webp) >= 8)
        let first = try #require(CGImageSourceCreateWithURL(webp as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(first.width == 160, "never bigger than the video")
    }
}

/// v1.9: PDFs into Word, Pages and EPUB keep their pictures, colors, small
/// print and two columns.
struct PDFIntoDocumentTests {
    private func photo(width: Int = 300, height: Int = 200) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 3, y: height / 4, width: width / 3, height: height / 2))
        return try #require(ctx.makeImage())
    }

    /// Pages drawn by `draw`, each on A4.
    private func pdf(at url: URL, pages: Int = 1, _ draw: (CGContext, Int) throws -> Void) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            try draw(ctx, page)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func write(_ text: String, at point: CGPoint, size: CGFloat = 12, color: NSColor = .black) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont(name: "Helvetica", size: size)!, .foregroundColor: color])
    }

    private func images(_ blocks: [Document.Block]) -> Int {
        blocks.count { if case .image = $0 { return true }; return false }
    }

    @Test func picturesStayInTheirPlace() async throws {
        let folder = try TempFolder()
        let url = folder.file("report.pdf")
        let picture = try photo()
        try pdf(at: url) { ctx, _ in
            write("Before the photo, a sentence that is long enough to count as a paragraph.", at: CGPoint(x: 60, y: 760))
            ctx.draw(picture, in: CGRect(x: 60, y: 480, width: 300, height: 200))
            write("After the photo, another sentence that is long enough to count as one.", at: CGPoint(x: 60, y: 440))
            ctx.draw(picture, in: CGRect(x: 60, y: 100, width: 10, height: 10))  // a bullet-sized mark: left out
        }
        let (document, _) = try await PDFStructure.document(url, recognition: TextRecognition()) { _ in }
        let kinds = document.blocks.map { block -> String in
            switch block {
            case .image(let picture): "image \(Int(picture.width))×\(Int(picture.height))"
            case .paragraph(let runs): runs.text.hasPrefix("Before") ? "before" : runs.text.hasPrefix("After") ? "after" : "text"
            default: "other"
            }
        }
        #expect(kinds == ["before", "image 300×200", "after"])
        // And into Word, with the picture in it.
        let word = try await runConversion(url, .convert(.docx))
        #expect(try ZipReader(url: word).contains("word/media/image1.jpg"))
    }

    @Test func picturesInsideFormsAreFound() async throws {
        let folder = try TempFolder()
        let inner = folder.file("inner.pdf")
        let picture = try photo()
        try pdf(at: inner) { ctx, _ in ctx.draw(picture, in: CGRect(x: 100, y: 300, width: 300, height: 200)) }
        // A page drawn into another becomes a form there.
        let outer = folder.file("outer.pdf")
        let page = try #require(CGPDFDocument(inner as CFURL)?.page(at: 1))
        try pdf(at: outer) { ctx, _ in
            ctx.saveGState()
            ctx.translateBy(x: 0, y: -100)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }
        let found = PDFPictures.frames(on: try #require(CGPDFDocument(outer as CFURL)?.page(at: 1)))
        let frame = try #require(found.first)
        #expect(abs(frame.minX - 100) < 1 && abs(frame.minY - 200) < 1 && abs(frame.width - 300) < 1)
    }

    @Test func colorsAndSmallPrint() async throws {
        let folder = try TempFolder()
        let url = folder.file("colors.pdf")
        try pdf(at: url) { _, _ in
            for line in 0..<6 { write("Plain body text on line \(line), set at twelve points as most is.", at: CGPoint(x: 60, y: 760 - CGFloat(line) * 18)) }
            write("Warning in red: mind the step.", at: CGPoint(x: 60, y: 600), color: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            write("Small print at the end, set at eight points.", at: CGPoint(x: 60, y: 560), size: 8)
        }
        let (document, _) = try await PDFStructure.document(url, recognition: TextRecognition()) { _ in }
        let runs = document.blocks.flatMap { block -> [Document.Run] in
            if case .paragraph(let runs) = block { return runs }
            return []
        }
        #expect(runs.first { $0.text.contains("Warning") }?.color == "#E61A1A")
        #expect(runs.first { $0.text.contains("Small print") }?.size == 8)
        #expect(runs.first { $0.text.contains("Plain body") }.map { $0.size == nil && $0.color == nil } == true)
        // Word gets them.
        let word = try await runConversion(url, .convert(.docx))
        let xml = try #require(try ZipReader(url: word).text("word/document.xml"))
        #expect(xml.contains("<w:color w:val=\"E61A1A\"/>") && xml.contains("<w:sz w:val=\"16\"/>"))
    }

    @Test func twoColumnsStayTwoColumns() async throws {
        let folder = try TempFolder()
        let url = folder.file("paper.pdf")
        try pdf(at: url) { _, _ in
            write("A Paper In Two Columns", at: CGPoint(x: 160, y: 790), size: 20)
            for line in 0..<12 {
                write("Left column line \(line) of the text.", at: CGPoint(x: 50, y: 740 - CGFloat(line) * 16), size: 10)
                write("Right column line \(line) of the text.", at: CGPoint(x: 320, y: 740 - CGFloat(line) * 16), size: 10)
            }
        }
        let (document, _) = try await PDFStructure.document(url, recognition: TextRecognition()) { _ in }
        #expect(document.blocks.contains(.columns(2)) && document.blocks.last == .columns(1))
        let text = document.plainText
        let leftEnd = try #require(text.range(of: "Left column line 11"))
        let rightStart = try #require(text.range(of: "Right column line 0"))
        #expect(leftEnd.lowerBound < rightStart.lowerBound, "the left column first, all of it")
        let word = try await runConversion(url, .convert(.docx))
        let xml = try #require(try ZipReader(url: word).text("word/document.xml"))
        #expect(xml.contains("<w:cols w:num=\"2\""))
    }

    @Test func aLogoOnEveryPageIsLeftOut() async throws {
        let folder = try TempFolder()
        let url = folder.file("letters.pdf")
        let logo = try photo(width: 80, height: 40)
        try pdf(at: url, pages: 4) { ctx, page in
            ctx.draw(logo, in: CGRect(x: 40, y: 780, width: 80, height: 40))
            write("Page \(page + 1) has a paragraph of its own that is long enough to keep.", at: CGPoint(x: 60, y: 600))
        }
        let (document, _) = try await PDFStructure.document(url, recognition: TextRecognition()) { _ in }
        #expect(images(document.blocks) == 0)
        #expect(document.plainText.contains("Page 4 has a paragraph"))
    }
}
