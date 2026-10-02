import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PinwheelCore

/// Compress must actually help; otherwise nothing is saved.
struct CompressCheckTests {
    @Test func compressThatWouldNotHelpIsSkipped() async throws {
        let folder = try TempFolder()
        let source = folder.file("tiny.jpg")
        // Already saved at a lower quality than Compress uses.
        try Fixtures.makePhoto(at: source, width: 300, height: 200, type: .jpeg)
        try ImageConverter.convert(source, to: .jpeg, destination: folder.file("low.jpg"), options: {
            var options = ConversionOptions()
            options.jpegQuality = 0.3
            return options
        }())
        let low = folder.file("low.jpg")
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: low), action: .tool(.compress)))
        #expect(result.skipped)
        #expect(result.note?.contains("Already as small") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == ["low.jpg", "tiny.jpg"])
    }
}

struct ResizeOptionTests {
    private func resize(_ source: URL, _ option: ResizeOption) async throws -> ConversionResult {
        var options = ConversionOptions()
        options.resize = option
        return try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .tool(.resize)), options: options)
    }

    @Test func fitShrinksBigImages() async throws {
        let folder = try TempFolder()
        let source = folder.file("big.jpg")
        try Fixtures.makePhoto(at: source, width: 4000, height: 3000, type: .jpeg)
        let result = try await resize(source, .fit1920)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "big (1920px).jpg")
        let info = try #require(Fixtures.readImage(output))
        #expect(info.width == 1920 && info.height == 1440)
    }

    @Test func fitLeavesSmallImagesAlone() async throws {
        let folder = try TempFolder()
        let source = folder.file("small.png")
        try Fixtures.makePhoto(at: source, width: 800, height: 600)
        let result = try await resize(source, .fit1920)
        #expect(result.skipped)
        #expect(result.note?.contains("1920") == true)
    }

    @Test func percentagesScaleBothSides() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makePhoto(at: source, width: 800, height: 600)
        let output = try #require(try await resize(source, .quarter).outputs.first)
        #expect(output.lastPathComponent == "photo (25%).png")
        let info = try #require(Fixtures.readImage(output))
        #expect(info.width == 200 && info.height == 150)
    }

    @Test func wedgeTitleFollowsTheSetting() {
        var options = ConversionOptions()
        options.resize = .fit2560
        #expect(WheelAction.tool(.resize).title(in: .tools, options: options) == "Fit 2560 px")
        #expect(ToolAction.resize.nameSuffix(options: options) == "2560px")
    }
}

struct VideoCompressTests {
    @Test func compressKeepsTheSizeAndShrinksTheFile() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source, width: 640, height: 360, noisy: true)
        let output = try await runConversion(source, .tool(.compress))
        #expect(output.lastPathComponent == "clip (compressed).mp4")
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 640 && size.height == 360)
        let subtype = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(subtype == kCMVideoCodecType_HEVC)
        #expect(try #require(FileSize.of(output)) < (try #require(FileSize.of(source))))
    }

    @Test func sizeLimitKeepsTheShape() {
        #expect(VideoCompressor.targetSize(CGSize(width: 3840, height: 2160), longSide: 1920) == (1920, 1080))
        #expect(VideoCompressor.targetSize(CGSize(width: 1080, height: 1920), longSide: 1280) == (720, 1280))
        #expect(VideoCompressor.targetSize(CGSize(width: 640, height: 360), longSide: 1920) == (640, 360))
        #expect(VideoCompressor.targetSize(CGSize(width: 1919, height: 1081), longSide: nil) == (1920, 1082))
    }

    @Test func bitRateNeverAimsAboveTheOriginal() {
        let rate = VideoCompressor.targetBitRate(width: 1920, height: 1080, fps: 30, quality: .best, sourceBitRate: 2_000_000)
        #expect(rate <= 1_600_000)
        let smaller = VideoCompressor.targetBitRate(width: 1920, height: 1080, fps: 30, quality: .smaller, sourceBitRate: 0)
        let best = VideoCompressor.targetBitRate(width: 1920, height: 1080, fps: 30, quality: .best, sourceBitRate: 0)
        #expect(smaller < best)
    }
}

struct GIFLimitTests {
    @Test(.enabled(if: ffmpegInstalled))
    func onlyTheFirstSecondsBecomeAGIF() async throws {
        let folder = try TempFolder()
        let source = folder.file("long.mov")
        try await MediaFixtures.makeVideo(at: source, seconds: 4)
        var options = ConversionOptions()
        options.gifMaxSeconds = 2
        options.gifFPS = 10
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .convert(.gif)), options: options)
        let output = try #require(result.outputs.first)
        let frames = CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(output as CFURL, nil)))
        #expect((17...23).contains(frames), "about 2 s × 10 fps, got \(frames)")
        #expect(result.note?.contains("first 2 seconds") == true)
    }
}

struct CombinedPDFTests {
    @Test func severalImagesBecomeOnePDFInNameOrder() async throws {
        let folder = try TempFolder()
        let c = folder.file("c.png"), a = folder.file("a.png"), b = folder.file("b.png")
        try Fixtures.makeImage(at: c, width: 300, height: 200)
        try Fixtures.makeImage(at: a, width: 100, height: 100)
        try Fixtures.makeImage(at: b, width: 200, height: 100)
        let request = ConversionRequest(files: [c, a, b].map(SourceFile.init), action: .convert(.pdf))
        #expect(request.isCombinedPDF)
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "a (combined).pdf")
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount == 3)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 100, height: 100))
        #expect(pdf.page(at: 2)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 200))
    }

    @Test func mixedFilesAreNotCombined() {
        let files = ["a.png", "b.pdf"].map { SourceFile(url: URL(fileURLWithPath: "/tmp/\($0)")) }
        #expect(!ConversionRequest(files: files, action: .convert(.pdf)).isCombinedPDF)
    }
}

struct SaveLocationTests {
    @Test func readOnlyFolderFallsBackToDownloads() async throws {
        let folder = try TempFolder()
        let fallback = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makeImage(at: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }

        var options = ConversionOptions()
        options.fallbackFolder = fallback.url
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .convert(.jpeg)), options: options)
        let output = try #require(result.outputs.first)
        #expect(output.deletingLastPathComponent().standardizedFileURL == fallback.url.standardizedFileURL)
        #expect(result.note?.contains("read-only") == true)
    }

    @Test func chosenFolderIsUsed() async throws {
        let folder = try TempFolder()
        let chosen = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makeImage(at: source)
        var options = ConversionOptions()
        options.saveLocation = .folder(chosen.url)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .convert(.heic)), options: options)
        let output = try #require(result.outputs.first)
        #expect(output.deletingLastPathComponent().standardizedFileURL == chosen.url.standardizedFileURL)
        #expect(result.note == nil)
    }
}

struct ProgressThrottleTests {
    @Test func passesOnFewUpdatesButAlwaysTheLast() {
        let throttle = ProgressThrottle()
        var reported = 0
        for step in 0...1000 where throttle.shouldReport(Double(step) / 1000) {
            reported += 1
        }
        #expect(reported <= 3)
        #expect(throttle.shouldReport(1))
    }
}
