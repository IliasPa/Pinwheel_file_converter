import AVFoundation
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PinwheelCore

/// Text drawn as a picture or into a PDF, for Get Text.
enum TextFixtures {
    static func draw(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    static func picture(_ lines: [String]) -> CGImage {
        let ctx = CGContext(
            data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        for (index, line) in lines.enumerated() {
            draw(line, in: ctx, at: CGPoint(x: 60, y: 300 - index * 120), size: 72)
        }
        return ctx.makeImage()!
    }

    /// Page 1 has real text; page 2 is a picture of text (like a scan).
    static func pdf(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 300)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        draw("Real text on page one", in: ctx, at: CGPoint(x: 40, y: 150), size: 30)
        ctx.endPDFPage()
        ctx.beginPDFPage(nil)
        ctx.draw(picture(["Scanned words"]), in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

struct GetTextTests {
    @Test func readsTheTextInAPicture() async throws {
        let folder = try TempFolder()
        let source = folder.file("sign.png")
        try StudioFixtures.save(TextFixtures.picture(["Hello Pinwheel", "Second line 2026"]), to: source)
        let output = try await runConversion(source, .tool(.extractText))
        #expect(output.lastPathComponent == "sign (text).txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("Hello Pinwheel"))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2 && lines[1].contains("2026"), "top to bottom: \(text)")
    }

    @Test func readsPDFsAndTheirScannedPages() async throws {
        let folder = try TempFolder()
        let source = folder.file("mixed.pdf")
        try TextFixtures.pdf(at: source)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .tool(.extractText)))
        let output = try #require(result.outputs.first)
        #expect(output.pathExtension == "txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("Real text on page one"))
        #expect(text.contains("Scanned words"))
        #expect(result.note?.contains("1 scanned page") == true)
    }

    @Test func noTextMeansNothingSaved() async throws {
        let folder = try TempFolder()
        let source = folder.file("blank.png")
        try StudioFixtures.save(StudioFixtures.solid(1), to: source)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .tool(.extractText)))
        #expect(result.skipped)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["blank.png"])
    }
}

struct PDFPageToolTests {
    @Test func mergeJoinsPDFsInNameOrder() async throws {
        let folder = try TempFolder()
        let b = folder.file("b.pdf"), a = folder.file("a.pdf")
        try MediaFixtures.makePDF(at: b, pages: 3)
        try MediaFixtures.makePDF(at: a, pages: 2)
        let request = ConversionRequest(files: [b, a].map(SourceFile.init), action: .tool(.merge))
        #expect(request.isMerge)
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "a (merged).pdf")
        #expect(PDFDocument(url: output)?.pageCount == 5)
    }

    @Test func mergeNeedsTwoPDFs() {
        let one = [SourceFile(url: URL(fileURLWithPath: "/tmp/a.pdf"))]
        #expect(ConversionEngine.availability(of: .tool(.merge), for: one, ffmpegAvailable: true) != .available)
        #expect(ConversionEngine.availability(of: .tool(.merge), for: one + one, ffmpegAvailable: true) == .available)
    }

    @Test func splitMakesAPDFPerPage() async throws {
        let folder = try TempFolder()
        let source = folder.file("report.pdf")
        try MediaFixtures.makePDF(at: source, pages: 3)
        let output = try await runConversion(source, .tool(.split))
        #expect(output.lastPathComponent == "report (pages)")
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names == ["report page 1.pdf", "report page 2.pdf", "report page 3.pdf"])
        #expect(PDFDocument(url: output.appendingPathComponent(names[1]))?.pageCount == 1)

        let single = folder.file("one.pdf")
        try MediaFixtures.makePDF(at: single, pages: 1)
        #expect(try await runRequest(ConversionRequest(file: SourceFile(url: single), action: .tool(.split))).skipped)
    }

    @Test func passwordLocksThePDF() async throws {
        let folder = try TempFolder()
        let source = folder.file("secret.pdf")
        try MediaFixtures.makePDF(at: source, pages: 2)
        let request = ConversionRequest(file: SourceFile(url: source), action: .tool(.protect), parameters: .password("open sesame"))
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "secret (protected).pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.isLocked)
        #expect(!document.unlock(withPassword: "wrong"))
        #expect(document.unlock(withPassword: "open sesame"))
        #expect(document.pageCount == 2)
    }
}

struct MediaEditTests {
    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test func muteRemovesTheSoundOnly() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source, metadata: MediaFixtures.privateMetadata())
        let output = try await runConversion(source, .tool(.mute))
        #expect(output.lastPathComponent == "clip (muted).mov")
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.load(.metadata).contains { $0.identifier == .quickTimeMetadataTitle }, "tags are kept")

        let silent = folder.file("silent.mov")
        try await MediaFixtures.makeVideo(at: silent, withAudio: false)
        #expect(try await runRequest(ConversionRequest(file: SourceFile(url: silent), action: .tool(.mute))).skipped)
    }

    @Test(arguments: ["mov", "wav", "m4a"])
    func trimKeepsJustThePartChosen(ext: String) async throws {
        let folder = try TempFolder()
        let source = folder.file("long.\(ext)")
        switch ext {
        case "wav": try MediaFixtures.makeWAV(at: source, seconds: 3)
        case "m4a": try await MediaFixtures.makeVideo(at: source, seconds: 3, withVideo: false, fileType: .m4a)
        default: try await MediaFixtures.makeVideo(at: source, seconds: 3)
        }
        let request = ConversionRequest(file: SourceFile(url: source), action: .tool(.trim), parameters: .timeRange(start: 1, end: 2))
        let output = try #require(try await runRequest(request, findTools: false).outputs.first)
        #expect(output.lastPathComponent == "long (trimmed).\(ext)")
        #expect(abs(try await duration(output) - 1) < 0.15)
    }

    @Test(.enabled(if: ffmpegInstalled))
    func trimKeepsMP3AsMP3WithFFmpeg() async throws {
        let folder = try TempFolder()
        let wav = folder.file("tone.wav"), mp3 = folder.file("song.mp3")
        try MediaFixtures.makeWAV(at: wav, seconds: 3)
        try await MediaFixtures.ffmpegTranscode(wav, to: mp3, arguments: ["-c:a", "libmp3lame", "-q:a", "4"])
        let request = ConversionRequest(file: SourceFile(url: mp3), action: .tool(.trim), parameters: .timeRange(start: 0.5, end: 2))
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.pathExtension == "mp3")
        #expect(abs(try await duration(output) - 1.5) < 0.15)

        // Without ffmpeg, the part becomes M4A instead.
        var noFFmpeg = ConversionOptions()
        noFFmpeg.ffmpegURL = nil
        #expect(OutputPlanner.trimOutput(for: SourceFile(url: mp3), options: noFFmpeg).1 == "m4a")
    }

    @Test func saveFrameMakesAnUprightJPEG() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source, seconds: 2, width: 320, height: 240)
        let request = ConversionRequest(file: SourceFile(url: source), action: .tool(.saveFrame), parameters: .frame(seconds: 1))
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "clip (frame).jpg")
        let info = try #require(Fixtures.readImage(output))
        #expect((info.width, info.height) == (320, 240))
    }

    @Test func trimNeedsAFileMacOSCanPlay() {
        let mkv = SourceFile(url: URL(fileURLWithPath: "/tmp/a.mkv"))
        #expect(ConversionEngine.availability(of: .open(.trim), for: [mkv], ffmpegAvailable: true) != .available)
        let mov = SourceFile(url: URL(fileURLWithPath: "/tmp/a.mov"))
        #expect(ConversionEngine.availability(of: .open(.trim), for: [mov], ffmpegAvailable: false) == .available)
    }
}

struct MetadataTests {
    private func edit(_ file: URL, _ changes: [MetadataField: String], removeLocation: Bool = false, findTools: Bool = true) async throws -> URL {
        let request = ConversionRequest(
            file: SourceFile(url: file), action: .tool(.editInfo),
            parameters: .metadata(MetadataEdit(changes: changes, removeLocation: removeLocation))
        )
        let result = try await runRequest(request, findTools: findTools)
        return try #require(result.outputs.first, "expected an output, got: \(result.note ?? "nothing")")
    }

    private func details(_ url: URL) async -> FileDetails {
        await FileInspector.details(of: SourceFile(url: url), ffmpegURL: FFmpeg.locate())
    }

    @Test(arguments: ["jpg", "png", "heic"])
    func photoDetailsRoundTrip(ext: String) async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.\(ext)")
        let type = ["jpg": "public.jpeg", "png": "public.png", "heic": "public.heic"][ext]!
        try StudioFixtures.save(StudioFixtures.quarters(), to: source, type: type, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PinwheelCam", kCGImagePropertyTIFFModel: "One"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.98, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 23.72, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ])
        let before = await details(source)
        #expect(before.readOnlyReason == nil)
        #expect(before.location?.latitude == 37.98)
        #expect(before.sections.flatMap(\.rows).contains { $0.label == "Camera" && $0.value == "PinwheelCam One" })

        let output = try await edit(source, [
            .title: "Sunset", .description: "At the beach", .author: "Ilias", .copyright: "© 2026", .keywords: "sea, sun ,summer",
        ], removeLocation: true)
        #expect(output.lastPathComponent == "photo (edited).\(ext)")
        let after = await details(output)
        #expect(after.values[.title] == "Sunset")
        #expect(after.values[.description] == "At the beach")
        #expect(after.values[.author] == "Ilias")
        #expect(after.values[.copyright] == "© 2026")
        #expect(after.values[.keywords] == "sea, sun, summer")
        #expect(after.location == nil)
        #expect(after.sections.flatMap(\.rows).contains { $0.label == "Camera" }, "camera details are kept")

        // An empty value removes the detail.
        let cleared = await details(try await edit(output, [.title: "", .keywords: ""]))
        #expect(cleared.values[.title] == nil)
        #expect(cleared.values[.keywords] == nil)
        #expect(cleared.values[.author] == "Ilias")
    }

    @Test func pdfDetailsRoundTrip() async throws {
        let folder = try TempFolder()
        let source = folder.file("paper.pdf")
        try MediaFixtures.makePDF(at: source, pages: 2)
        let before = await details(source)
        #expect(before.values[.author] == "Pinwheel Tests")
        #expect(before.sections.flatMap(\.rows).contains { $0.label == "Pages" && $0.value == "2" })

        let output = try await edit(source, [.title: "My Paper", .author: "", .keywords: "school, notes"])
        let after = await details(output)
        #expect(after.values[.title] == "My Paper")
        #expect(after.values[.author] == nil)
        #expect(after.values[.keywords] == "school, notes")
        #expect(PDFDocument(url: output)?.pageCount == 2)
    }

    @Test func songTagsRoundTripInM4A() async throws {
        let folder = try TempFolder()
        let source = folder.file("song.m4a")
        try await MediaFixtures.makeVideo(at: source, withVideo: false, fileType: .m4a, metadata: MediaFixtures.titleTag())
        #expect(await details(source).values[.title] == "Secret song")
        let changes: [MetadataField: String] = [
            .title: "New Song", .artist: "Me", .album: "Firsts", .genre: "Jazz", .year: "2026", .comment: "Take 2",
        ]
        let output = try await edit(source, changes, findTools: false)
        let after = await details(output)
        for (field, value) in changes {
            #expect(after.values[field] == value, "\(field)")
        }
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func videoTitleAndLocation() async throws {
        let folder = try TempFolder()
        let source = folder.file("trip.mov")
        try await MediaFixtures.makeVideo(at: source, metadata: MediaFixtures.privateMetadata())
        let before = await details(source)
        #expect(before.values[.title] == "Secret trip")
        #expect(before.location != nil)
        #expect(before.sections.flatMap(\.rows).contains { $0.label == "Duration" })

        let output = try await edit(source, [.title: "Holiday", .artist: "Ilias"], removeLocation: true, findTools: false)
        let after = await details(output)
        #expect(after.values[.title] == "Holiday")
        #expect(after.values[.artist] == "Ilias")
        #expect(after.location == nil)
    }

    @Test(.enabled(if: ffmpegInstalled))
    func mp3TagsGoThroughFFmpeg() async throws {
        let folder = try TempFolder()
        let wav = folder.file("tone.wav"), mp3 = folder.file("song.mp3")
        try MediaFixtures.makeWAV(at: wav)
        try await MediaFixtures.ffmpegTranscode(wav, to: mp3, arguments: ["-c:a", "libmp3lame", "-q:a", "4", "-metadata", "title=Old"])
        #expect(await details(mp3).values[.title] == "Old")
        let output = try await edit(mp3, [.title: "New", .artist: "Band", .year: "1999"])
        #expect(output.pathExtension == "mp3")
        let after = await details(output)
        #expect(after.values[.title] == "New")
        #expect(after.values[.artist] == "Band")
        #expect(after.values[.year] == "1999")
    }

    @Test func mp3NeedsFFmpegToSave() async {
        let details = await FileInspector.details(of: SourceFile(url: URL(fileURLWithPath: "/tmp/missing.mp3")), ffmpegURL: nil)
        #expect(details.readOnlyReason?.contains("ffmpeg") == true)
    }

    @Test func locationsFromVideos() {
        let place = GeoLocation(iso6709: "+37.9838+023.7275+000.000/")
        #expect(place?.latitude == 37.9838 && place?.longitude == 23.7275)
        #expect(GeoLocation(iso6709: "-33.8688+151.2093/")?.description == "33.8688° S, 151.2093° E")
        #expect(GeoLocation(iso6709: "nowhere") == nil)
    }

    @Test func nothingChangedSavesNothing() async throws {
        let folder = try TempFolder()
        let source = folder.file("same.pdf")
        try MediaFixtures.makePDF(at: source, pages: 1)
        let request = ConversionRequest(file: SourceFile(url: source), action: .tool(.editInfo), parameters: .metadata(MetadataEdit()))
        #expect(try await runRequest(request).skipped)
    }
}
