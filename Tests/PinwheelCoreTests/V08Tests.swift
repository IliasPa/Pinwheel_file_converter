import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PinwheelCore

struct StraightenTests {
    @Test func straighteningKeepsTheSizeAndLeavesNoEmptyCorners() throws {
        let source = StudioSource(image: StudioFixtures.quarters(width: 300, height: 200))
        for angle in [-30.0, -4.5, 7.25, 45] {
            var edit = ImageEdit()
            edit.straighten = angle
            let image = try StudioRenderer.render(source, mask: nil, edit: edit)
            #expect((image.width, image.height) == (300, 200), "angle \(angle)")
            for (x, y) in [(0, 0), (299, 0), (0, 199), (299, 199)] {
                #expect(Fixtures.pixel(image, x: x, y: y).a == 255, "corner (\(x), \(y)) at \(angle)°")
            }
        }
        // A small turn keeps each quarter roughly where it was.
        var edit = ImageEdit()
        edit.straighten = 3
        #expect(StudioFixtures.corners(try StudioRenderer.render(source, mask: nil, edit: edit)) == ["red", "green", "white", "blue"])
        #expect(!edit.isEmpty)
    }
}

struct WatermarkTests {
    private let plain = StudioSource(image: StudioFixtures.solid(0.2, width: 600, height: 400))

    private func darkness(_ image: CGImage, in rect: CGRect) -> Int {
        var bright = 0
        for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
            for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) where Fixtures.pixel(image, x: x, y: y).r > 120 {
                bright += 1
            }
        }
        return bright
    }

    @Test func textGoesWhereItsPut() throws {
        var mark = Watermark()
        mark.text = "© Pinwheel"
        mark.size = 0.06
        mark.opacity = 1
        var edit = ImageEdit()
        edit.watermark = mark
        let image = try StudioRenderer.render(plain, mask: nil, edit: edit)
        #expect(darkness(image, in: CGRect(x: 380, y: 330, width: 210, height: 60)) > 20, "white text in the bottom right")
        #expect(darkness(image, in: CGRect(x: 0, y: 0, width: 200, height: 100)) == 0, "nothing in the top left")

        edit.watermark?.placement = .topLeft
        let moved = try StudioRenderer.render(plain, mask: nil, edit: edit)
        #expect(darkness(moved, in: CGRect(x: 0, y: 0, width: 260, height: 80)) > 20)
    }

    @Test func tilingCoversThePicture() throws {
        var mark = Watermark()
        mark.text = "DRAFT"
        mark.placement = .tiled
        mark.opacity = 1
        var edit = ImageEdit()
        edit.watermark = mark
        let image = try StudioRenderer.render(plain, mask: nil, edit: edit)
        for quarter in [CGRect(x: 0, y: 0, width: 300, height: 200), CGRect(x: 300, y: 200, width: 300, height: 200)] {
            #expect(darkness(image, in: quarter) > 10)
        }
    }

    @Test func logosAndBlankWatermarks() throws {
        let folder = try TempFolder()
        let logo = folder.file("logo.png")
        try StudioFixtures.save(StudioFixtures.solid(1, width: 80, height: 40), to: logo)
        var mark = Watermark()
        mark.kind = .logo
        mark.logoPath = logo.path
        mark.placement = .center
        mark.opacity = 1
        mark.shadow = false
        var edit = ImageEdit()
        edit.watermark = mark
        let image = try StudioRenderer.render(plain, mask: nil, edit: edit)
        #expect(Fixtures.pixel(image, x: 300, y: 200).r > 240, "the white logo is in the middle")

        // An empty watermark is no change at all.
        var blank = ImageEdit()
        blank.watermark = Watermark()
        blank.watermark?.text = "  "
        #expect(blank.isEmpty)
    }
}

struct PlainBackgroundTests {
    /// A red ring with a white hole on white: a "logo".
    private func logo() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 100, y: 50, width: 200, height: 200))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 160, y: 110, width: 80, height: 80))
        return ctx.makeImage()!
    }

    @Test func removesThePlainColorAndItsHoles() throws {
        let picture = logo()
        let mask = try #require(PlainBackground.mask(for: picture))
        var edit = ImageEdit()
        edit.removeBackground = true
        let image = try StudioRenderer.render(StudioSource(image: picture), mask: mask, edit: edit)
        #expect(Fixtures.pixel(image, x: 5, y: 5).a == 0, "the corner is gone")
        #expect(Fixtures.pixel(image, x: 200, y: 150).a == 0, "so is the hole")
        #expect(Fixtures.pixel(image, x: 130, y: 150).a == 255, "the ring stays")
    }

    @Test func busyOrEmptyPicturesHaveNoPlainBackground() {
        #expect(PlainBackground.mask(for: StudioFixtures.quarters()) == nil)
        #expect(PlainBackground.mask(for: StudioFixtures.solid(0.5)) == nil)
    }
}

struct CollageTests {
    private let wide = CGSize(width: 400, height: 300), tall = CGSize(width: 300, height: 400)

    @Test func gridCentersTheLastRow() {
        var spec = CollageSpec()
        spec.width = 1000
        spec.margin = 0
        spec.spacing = 0
        let layout = CollageLayout.make(for: Array(repeating: wide, count: 5), spec: spec)
        #expect(layout.cells.count == 5)
        #expect(layout.cells[0].size == CGSize(width: 1000.0 / 3, height: 1000.0 / 3))  // 3 across, square cells
        #expect(layout.canvas == CGSize(width: 1000, height: 667))
        #expect(abs(layout.cells[3].minX - 1000.0 / 6) < 0.5, "two in the last row, centered")
    }

    @Test func rowsKeepEveryShapeAndFillTheWidth() {
        var spec = CollageSpec()
        spec.layout = .rows
        spec.width = 1200
        spec.margin = 0.02
        let layout = CollageLayout.make(for: [wide, tall, wide, wide, tall], spec: spec)
        for (cell, size) in zip(layout.cells, [wide, tall, wide, wide, tall]) {
            #expect(abs(cell.width / cell.height - size.width / size.height) < 0.01)
        }
        let firstRow = layout.cells.filter { abs($0.minY - layout.cells[0].minY) < 0.5 }
        #expect(abs(firstRow.map(\.maxX).max()! - (1200 - 24)) < 1, "a full row reaches the right margin")
    }

    @Test func contactSheetsHaveNamesAndATitle() {
        var spec = CollageSpec()
        spec.layout = .contactSheet
        spec.title = "Trip"
        let layout = CollageLayout.make(for: [wide, tall, wide], spec: spec)
        #expect(layout.captions.count == 3)
        #expect(layout.titleRect != nil)
        #expect(!layout.fills)
    }

    @Test func collageJobUsesTheChosenOrder() async throws {
        let folder = try TempFolder()
        let b = folder.file("b.png"), a = folder.file("a.png")
        try StudioFixtures.save(StudioFixtures.quarters(width: 400, height: 300), to: b)
        try StudioFixtures.save(StudioFixtures.solid(0.3, width: 300, height: 400), to: a)
        var spec = CollageSpec()
        spec.width = 800
        spec.layout = .contactSheet
        let request = ConversionRequest(files: [b, a].map(SourceFile.init), action: .tool(.collage), parameters: .collage(spec))
        #expect(request.isCombined)
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "b (collage).jpg")
        let info = try #require(Fixtures.readImage(output))
        #expect(info.width == 800)
        #expect(!request.replacesOriginal, "a collage never sends its photos to the Trash")
    }
}

struct OrganizeTests {
    @Test func pagesFromSeveralPDFsInAnyOrderAndTurn() async throws {
        let folder = try TempFolder()
        let first = folder.file("first.pdf"), second = folder.file("second.pdf")
        try MediaFixtures.makePDF(at: first, pages: 2)
        try MediaFixtures.makePDF(at: second, pages: 3)
        let arrangement = PageArrangement(pages: [
            .init(file: 1, page: 2, turns: 1),
            .init(file: 0, page: 0),
            .init(file: 1, page: 0, turns: -1),
        ])
        let request = ConversionRequest(files: [first, second].map(SourceFile.init), action: .tool(.organize), parameters: .pages(arrangement))
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "first (organized).pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.rotation == 90)
        #expect(document.page(at: 1)?.rotation == 0)
        #expect(document.page(at: 2)?.rotation == 270)
        #expect(PageArrangement.all(pageCounts: [2, 3]).pages.count == 5)
    }
}

/// Sound made for the loudness tests.
enum SoundFixtures {
    /// A stereo 1 kHz tone with this peak (0...1), and maybe one loud click in the middle.
    static func tone(at url: URL, seconds: Double = 3, peak: Float = 0.1, click: Float? = nil, sampleRate: Double = 48_000) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = peak * Float(sin(Double(i) * 2 * .pi * 1000 / sampleRate))
            }
            if let click { buffer.floatChannelData![channel][Int(frames) / 2] = click }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }
}

struct LoudnessTests {
    @Test func aToneMeasuresAsTheStandardSays() async throws {
        // BS.1770: a stereo 1 kHz sine peaking at −20 dBFS reads −20 LUFS.
        let folder = try TempFolder()
        let tone = folder.file("tone.wav")
        try SoundFixtures.tone(at: tone, peak: 0.1)
        let loudness = try #require(try await AudioProcessor.measure(tone).loudness)
        #expect(abs(loudness - -20) < 0.2, "measured \(loudness)")
    }

    @Test func normalizeBringsItToMinus16AndThenLeavesItAlone() async throws {
        let folder = try TempFolder()
        let tone = folder.file("quiet.wav")
        try SoundFixtures.tone(at: tone, peak: 0.05)  // about −26 LUFS
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: tone), action: .tool(.normalize)))
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "quiet (normalized).wav")
        #expect(result.note?.contains("-16.0 LUFS") == true, "\(result.note ?? "")")
        let after = try #require(try await AudioProcessor.measure(output).loudness)
        #expect(abs(after - -16) < 0.3, "measured \(after)")

        let again = try await runRequest(ConversionRequest(file: SourceFile(url: output), action: .tool(.normalize)))
        #expect(again.skipped)
    }

    @Test func peaksLimitHowLoudItGets() async throws {
        let folder = try TempFolder()
        // Quiet (about −34 LUFS) but with one loud click: the click limits the boost.
        let clicky = folder.file("clicky.wav")
        try SoundFixtures.tone(at: clicky, peak: 0.02, click: 0.8)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: clicky), action: .tool(.normalize)))
        #expect(result.note?.contains("peaks") == true, "\(result.note ?? "")")
        let measured = try await AudioProcessor.measure(try #require(result.outputs.first))
        #expect(measured.peak < 0.9 && measured.peak > 0.85, "peak \(measured.peak)")
    }
}

struct MediaEditorTests {
    @Test func audioFadesAndSpeed() async throws {
        let folder = try TempFolder()
        let tone = folder.file("tone.wav")
        try SoundFixtures.tone(at: tone, seconds: 4, peak: 0.5)
        var edit = MediaEdit()
        edit.speed = 2
        edit.fadeIn = 0.5
        edit.fadeOut = 0.5
        edit.volume = -6
        let output = try await runConversion(tone, .tool(.editMedia), parameters: .media(edit))
        #expect(output.lastPathComponent == "tone (edited).wav")
        #expect(abs(try await SoundFixtures.duration(output) - 2) < 0.15)
        let file = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let rate = file.processingFormat.sampleRate
        func level(at seconds: Double) -> Float {
            let start = Int(seconds * rate)
            return (start..<(start + 200)).map { abs(samples[min($0, Int(buffer.frameLength) - 1)]) }.max() ?? 0
        }
        #expect(level(at: 0.01) < 0.05, "fading in")
        #expect(abs(level(at: 1) - 0.25) < 0.04, "−6 dB of 0.5 is about 0.25")
        #expect(level(at: 1.99) < 0.05, "fading out")
    }

    @Test func videoTurnsAndSpeedsUpWithoutReencodingThePicture() async throws {
        let folder = try TempFolder()
        let clip = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: clip, seconds: 2, width: 320, height: 240)
        var edit = MediaEdit()
        edit.quarterTurns = 1
        edit.speed = 2
        let output = try await runConversion(clip, .tool(.editMedia), parameters: .media(edit))
        #expect(output.lastPathComponent == "clip (edited).mov")
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let shown = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        #expect((abs(shown.width), abs(shown.height)) == (240, 320))
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.15)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1, "the sound is kept, retimed")
    }

    @Test func videoMuteAndFadedSound() async throws {
        let folder = try TempFolder()
        let clip = folder.file("clip.mp4")
        try await MediaFixtures.makeVideo(at: clip, seconds: 2, fileType: .mp4)
        var muted = MediaEdit()
        muted.mute = true
        muted.quarterTurns = 2
        let silent = try await runConversion(clip, .tool(.editMedia), parameters: .media(muted))
        #expect(try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio).isEmpty)

        var faded = MediaEdit()
        faded.fadeIn = 0.5
        faded.start = 0.5
        let output = try await runConversion(clip, .tool(.editMedia), parameters: .media(faded))
        #expect(output.pathExtension == "mp4")
        #expect(abs(try await SoundFixtures.duration(output) - 1.5) < 0.15)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test(.enabled(if: ffmpegInstalled))
    func gifOfJustThePart() async throws {
        let folder = try TempFolder()
        let clip = folder.file("long.mov")
        try await MediaFixtures.makeVideo(at: clip, seconds: 4)
        var part = MediaEdit()
        (part.start, part.end) = (1, 2)
        part.quarterTurns = 1
        var options = ConversionOptions()
        options.gifFPS = 10
        let request = ConversionRequest(file: SourceFile(url: clip), action: .convert(.gif), parameters: .media(part))
        #expect(!request.replacesOriginal)
        let output = try #require(try await runRequest(request, options: options).outputs.first)
        let src = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let frames = CGImageSourceGetCount(src)
        #expect((8...12).contains(frames), "1 s × 10 fps, got \(frames)")
        let first = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(first.height > first.width, "turned a quarter")
    }

    @Test func framesAreTurnedAsShown() async throws {
        let folder = try TempFolder()
        let clip = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: clip, seconds: 1, width: 320, height: 240)
        let request = ConversionRequest(file: SourceFile(url: clip), action: .tool(.saveFrame), parameters: .frame(seconds: 0.5, quarterTurns: 3))
        let output = try #require(try await runRequest(request).outputs.first)
        let info = try #require(Fixtures.readImage(output))
        #expect((info.width, info.height) == (240, 320))
    }

    @Test func emptyEditsSaveNothing() async throws {
        let folder = try TempFolder()
        let tone = folder.file("tone.wav")
        try SoundFixtures.tone(at: tone, seconds: 1)
        #expect(try await runRequest(ConversionRequest(file: SourceFile(url: tone), action: .tool(.editMedia), parameters: .media(MediaEdit()))).skipped)
        #expect(MediaEdit().isEmpty(duration: 10))
        var part = MediaEdit()
        part.end = 5
        #expect(!part.isEmpty(duration: 10))
        #expect(part.range(duration: 3) == (0, 3))
    }
}

/// Runs one job with parameters and returns its output.
func runConversion(_ source: URL, _ action: WheelAction, parameters: JobParameters) async throws -> URL {
    let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: action, parameters: parameters))
    return try #require(result.outputs.first, "expected an output, got: \(result.note ?? "nothing")")
}
