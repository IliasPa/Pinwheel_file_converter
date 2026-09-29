import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

struct ImageToolTests {
    /// A photo-like JPEG with camera, date and GPS info, turned sideways (EXIF 6).
    private func makeCameraPhoto(at url: URL, quality: Double = 1) throws {
        try Fixtures.makeImage(at: url, width: 400, height: 300, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "PinwheelCam", kCGImagePropertyTIFFModel: "One",
                kCGImagePropertyTIFFOrientation: 6,
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:01 10:00:00"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.98, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 23.72, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ])
    }

    @Test func compressKeepsJPEGAndMakesItSmaller() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.jpg")
        try makeCameraPhoto(at: source)
        let output = try await runConversion(source, .tool(.compress))
        #expect(output.lastPathComponent == "photo (compressed).jpg")
        let before = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        #expect(after < before)
        let tiff = Fixtures.readImage(output)?.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "PinwheelCam")  // compress keeps metadata
    }

    @Test func compressPicksJPEGOrHEICForPNGs() async throws {
        let folder = try TempFolder()
        let transparent = folder.file("logo.png")
        try Fixtures.makeImage(at: transparent)
        let flattened = folder.file("flat.jpg")
        try Fixtures.makeImage(at: flattened, type: .jpeg)
        let opaquePNG = folder.file("opaque.png")
        try ImageConverter.convert(flattened, to: .png, destination: opaquePNG, options: ConversionOptions())

        let fromTransparent = try await runConversion(transparent, .tool(.compress))
        #expect(fromTransparent.pathExtension == "heic")  // keeps the see-through parts
        let fromOpaque = try await runConversion(opaquePNG, .tool(.compress))
        #expect(fromOpaque.pathExtension == "jpg")
    }

    @Test func resizeHalvesAndTurnsUpright() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.jpg")
        try makeCameraPhoto(at: source)  // 400×300 stored, shown as 300×400
        let output = try await runConversion(source, .tool(.resizeHalf))
        #expect(output.lastPathComponent == "photo (50%).jpg")
        let info = try #require(Fixtures.readImage(output))
        #expect(info.width == 150 && info.height == 200)
        #expect((info.properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func resizeKeepsPNGAsPNG() async throws {
        let folder = try TempFolder()
        let source = folder.file("art.png")
        try Fixtures.makeImage(at: source, width: 100, height: 60)
        let output = try await runConversion(source, .tool(.resizeHalf))
        let info = try #require(Fixtures.readImage(output))
        #expect(output.pathExtension == "png" && info.width == 50 && info.height == 30)
    }

    @Test(arguments: ["jpg", "heic", "png"])
    func stripRemovesPrivateInfoButKeepsOrientation(ext: String) async throws {
        let folder = try TempFolder()
        let camera = folder.file("camera.jpg")
        try makeCameraPhoto(at: camera, quality: 0.9)
        var source = camera
        if ext != "jpg" {
            source = folder.file("camera.\(ext)")
            try ImageConverter.convert(camera, to: ext == "png" ? .png : .heic, destination: source, options: ConversionOptions())
            #expect(ImageTools.containsPrivateInfo(source), "fixture should start with private info")
        }
        let output = try await runConversion(source, .tool(.stripMetadata))
        #expect(output.lastPathComponent == "camera (no metadata).\(ext)")
        #expect(!ImageTools.containsPrivateInfo(output))
        let info = try #require(Fixtures.readImage(output))
        #expect(info.properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(info.width == 400 && info.height == 300)
    }

    @Test func animatedGIFsAreRefusedClearly() async throws {
        let folder = try TempFolder()
        let gif = folder.file("anim.gif")
        let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        let frame = try #require(Fixtures.readImage(try {
            let png = folder.file("frame.png")
            try Fixtures.makeImage(at: png)
            return png
        }())?.image)
        CGImageDestinationAddImage(dest, frame, nil)
        CGImageDestinationAddImage(dest, frame, nil)
        #expect(CGImageDestinationFinalize(dest))
        await #expect(throws: ConversionError.self) { try await runConversion(gif, .tool(.resizeHalf)) }
    }
}

struct MediaToolTests {
    private func metadataIdentifiers(_ url: URL) async throws -> [AVMetadataIdentifier] {
        try await AVURLAsset(url: url).load(.metadata).compactMap(\.identifier)
    }

    @Test func videoCompressMakesAPlayableMP4() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source, width: 320, height: 240)
        let output = try await runConversion(source, .tool(.compress))
        #expect(output.lastPathComponent == "clip (compressed).mp4")
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func videoStripRemovesTitleAndLocation() async throws {
        let folder = try TempFolder()
        let source = folder.file("trip.mov")
        try await MediaFixtures.makeVideo(at: source, metadata: MediaFixtures.privateMetadata())
        let before = try await metadataIdentifiers(source)
        #expect(before.contains(.quickTimeMetadataLocationISO6709), "fixture should have a location")

        #expect(!ConversionEngine.usesFFmpeg(.tool(.stripMetadata), for: SourceFile(url: source)))
        let output = try await runConversion(source, .tool(.stripMetadata))
        #expect(output.lastPathComponent == "trip (no metadata).mov")
        let after = try await metadataIdentifiers(output)
        #expect(!after.contains(.quickTimeMetadataLocationISO6709))
        #expect(!after.contains(.quickTimeMetadataTitle))
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).count == 1)
    }

    @Test func getAudioSavesTheSoundtrack() async throws {
        let folder = try TempFolder()
        let source = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: source)
        let output = try await runConversion(source, .tool(.extractAudio))
        #expect(output.lastPathComponent == "clip (audio).m4a")
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func audioCompressMakesASmallerAACFile() async throws {
        let folder = try TempFolder()
        let source = folder.file("tone.wav")
        try MediaFixtures.makeWAV(at: source, seconds: 3)
        let recorder = ProgressRecorder()
        let output = try await runConversion(source, .tool(.compress), progress: recorder.record)
        #expect(output.lastPathComponent == "tone (compressed).m4a")
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 3) < 0.15)
        let before = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        #expect(after * 5 < before)
        #expect(recorder.values.last == 1)
    }

    @Test func audioStripRemovesTagsFromM4A() async throws {
        let folder = try TempFolder()
        let source = folder.file("song.m4a")
        try await MediaFixtures.makeVideo(at: source, withVideo: false, fileType: .m4a, metadata: MediaFixtures.titleTag())
        #expect(try await metadataIdentifiers(source).contains(.iTunesMetadataSongName), "fixture should have a title")

        let output = try await runConversion(source, .tool(.stripMetadata))
        #expect(output.lastPathComponent == "song (no metadata).m4a")
        #expect(!(try await metadataIdentifiers(output)).contains(.iTunesMetadataSongName))
    }

    @Test(.enabled(if: ffmpegInstalled))
    func audioStripRemovesTagsFromMP3() async throws {
        let folder = try TempFolder()
        let wav = folder.file("tone.wav")
        let mp3 = folder.file("song.mp3")
        try MediaFixtures.makeWAV(at: wav)
        try await MediaFixtures.ffmpegTranscode(wav, to: mp3, arguments: ["-c:a", "libmp3lame", "-q:a", "4", "-metadata", "title=Secret song"])
        let titleBefore = try await AVURLAsset(url: mp3).load(.metadata).first { $0.commonKey == .commonKeyTitle }
        #expect(titleBefore != nil, "fixture should have a title")

        #expect(ConversionEngine.usesFFmpeg(.tool(.stripMetadata), for: SourceFile(url: mp3)))
        let output = try await runConversion(mp3, .tool(.stripMetadata))
        let titleAfter = try await AVURLAsset(url: output).load(.metadata).first { $0.commonKey == .commonKeyTitle }
        #expect(titleAfter == nil)
        #expect(abs(try await AVURLAsset(url: output).load(.duration).seconds - 1) < 0.15)
    }
}

struct PDFToolTests {
    @Test func stripRemovesTheAuthor() async throws {
        let folder = try TempFolder()
        let source = folder.file("letter.pdf")
        try MediaFixtures.makePDF(at: source, pages: 2)
        #expect(PDFDocument(url: source)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Pinwheel Tests")
        let output = try await runConversion(source, .tool(.stripMetadata))
        #expect(output.lastPathComponent == "letter (no metadata).pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
    }
}

struct ToolAvailabilityTests {
    @Test func everyToolWorksWithoutFFmpegForCommonFiles() {
        for name in ["a.jpg", "a.png", "a.heic", "a.pdf", "a.mov", "a.mp4", "a.m4a", "a.wav"] {
            let file = SourceFile(url: URL(fileURLWithPath: "/tmp/\(name)"))
            for action in FormatCatalog.actions(for: [file], mode: .tools) {
                #expect(
                    ConversionEngine.availability(of: action, for: [file], ffmpegAvailable: false) == .available,
                    "\(action.id) on \(name)"
                )
            }
        }
    }

    @Test func mp3AndFlacStripNeedFFmpeg() {
        for name in ["a.mp3", "a.flac"] {
            let file = SourceFile(url: URL(fileURLWithPath: "/tmp/\(name)"))
            #expect(ConversionEngine.availability(of: .tool(.stripMetadata), for: [file], ffmpegAvailable: false) != .available)
            #expect(ConversionEngine.availability(of: .tool(.compress), for: [file], ffmpegAvailable: false) == .available)
        }
    }

    @Test func outputNames() {
        func plan(_ name: String, _ tool: ToolAction) -> String? {
            ConversionEngine.plan(for: SourceFile(url: URL(fileURLWithPath: "/tmp/\(name)")), action: .tool(tool)).fileExtension
        }
        #expect(plan("a.mov", .compress) == "mp4")
        #expect(plan("a.mov", .extractAudio) == "m4a")
        #expect(plan("a.mov", .stripMetadata) == "mov")
        #expect(plan("a.wav", .compress) == "m4a")
        #expect(plan("a.mp3", .stripMetadata) == "mp3")
        #expect(plan("a.pdf", .compress) == "pdf")
        #expect(plan("a.bmp", .resizeHalf) == "png")
        #expect(plan("a.JPEG", .resizeHalf) == "jpeg")
        #expect(ToolAction.resizeHalf.nameSuffix == "50%")
    }
}
