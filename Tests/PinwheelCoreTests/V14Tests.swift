import AppKit
import Compression
import CoreImage
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

private let cwebpInstalled = ExternalTool.cwebp.locate() != nil

private func files(_ names: String...) -> [SourceFile] {
    names.map { SourceFile(url: URL(fileURLWithPath: "/tmp/pinwheel-v14/\($0)")) }
}

/// What ImageIO makes of a picture: its type, how many images, the first one's size.
private func picture(_ url: URL) -> (type: String, count: Int, width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) as String?,
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return (type, CGImageSourceGetCount(src), image.width, image.height)
}

// MARK: - Wheels

struct V14WheelTests {
    @Test func theFileActionsWheelIsTheSameForAnything() {
        let folder = SourceFile(url: FileManager.default.temporaryDirectory)
        #expect(folder.kind == nil)
        let expected = FileAction.allCases.map(WheelAction.file) + [.tool(.archive)]
        #expect(FormatCatalog.actions(for: [folder], mode: .actions) == expected)
        #expect(FormatCatalog.actions(for: files("a.png", "b.mov", "c.txt"), mode: .actions) == expected)
        #expect(FormatCatalog.actions(for: [folder], mode: .actions, hidden: [FormatCatalog.actionKey(.file(.airDrop))]).first == .file(.copy))
        for kind in FileKind.allCases {
            #expect(FormatCatalog.actions(for: kind, mode: .actions) == expected)
        }
    }

    @Test func archivesGetTheirOwnWheel() {
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.zip")) == .archive)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.tar.gz")) == .archive)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.rar")) == .archive)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.7z")) == .archive)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.docx")) != .archive, "documents are zips inside, but not archives")
        #expect(FormatCatalog.actions(for: files("a.zip"), mode: .convert)
                == [.tool(.extract), .convert(.tar), .convert(.tgz), .convert(.sevenZip)])
        #expect(FormatCatalog.actions(for: files("a.rar"), mode: .convert)
                == [.tool(.extract), .convert(.zip), .convert(.tar), .convert(.tgz), .convert(.sevenZip)])
        #expect(FormatCatalog.actions(for: files("a.tar.gz"), mode: .convert).contains(.convert(.tgz)) == false)
        #expect(FormatCatalog.actions(for: files("a.zip"), mode: .tools) == [.open(.rename)])
    }

    @Test func formatWheelsHoldUpToTwelve() {
        #expect(FormatCatalog.maxWedges(in: .convert) == 12)
        #expect(FormatCatalog.maxWedges(in: .tools) == 9)
        #expect(FormatCatalog.maxWedges(in: .actions) == 9)
        for kind in FileKind.allCases {
            #expect(FormatCatalog.choices(for: kind, mode: .convert).count <= FormatCatalog.maxFormats, "\(kind)")
        }
        // Several pictures: eleven formats and Collage, all on one wheel.
        #expect(FormatCatalog.actions(for: files("a.png", "b.jpg"), mode: .convert).count == 12)
        #expect(FormatCatalog.actions(for: files("a.mov"), mode: .convert).count == 8)
    }

    @Test func formatsAreKnownByTheirFiles() {
        #expect(files("a.webp")[0].format == .webp)
        #expect(files("a.avif")[0].format == .avif)
        #expect(files("a.bmp")[0].format == .bmp)
        #expect(files("a.mkv")[0].format == .mkv)
        #expect(files("a.webm")[0].format == .webm)
        #expect(files("a.wmv")[0].format == .wmv)
        #expect(files("a.ogg")[0].format == .ogg)
        #expect(files("a.opus")[0].format == .opus, "Opus is Ogg audio too, told apart by name")
        #expect(files("a.wma")[0].format == .wma)
        #expect(files("a.tar.gz")[0].format == .tgz)
        #expect(files("a.tgz")[0].format == .tgz)
        #expect(files("a.7z")[0].format == .sevenZip)
        #expect(files("a.rar")[0].format == nil)
        #expect(files("a.svg")[0].kind == .image && files("a.svg")[0].format == nil)
        #expect(OutputFormat.tgz.fileExtension == "tar.gz" && OutputFormat.sevenZip.fileExtension == "7z")
        for format in OutputFormat.allCases {
            #expect(!format.title.isEmpty && !format.detail(from: format.kind).isEmpty)
        }
    }

    @Test func whatNeedsFFmpegOrCwebp() {
        let mov = files("a.mov")[0], wav = files("a.wav")[0], png = files("a.png")[0]
        for format in [OutputFormat.mkv, .webm, .avi, .wmv] {
            #expect(ConversionEngine.usesFFmpeg(.convert(format), for: mov), "\(format)")
        }
        for format in [OutputFormat.ogg, .opus, .wma, .mp3] {
            #expect(ConversionEngine.usesFFmpeg(.convert(format), for: wav), "\(format)")
        }
        #expect(!ConversionEngine.usesFFmpeg(.convert(.mov), for: mov))
        #expect(!ConversionEngine.usesFFmpeg(.convert(.flac), for: wav))
        #expect(ConversionEngine.availability(of: .convert(.webp), for: [png], ffmpegAvailable: true, cwebpAvailable: false)
                == .unavailable("Needs cwebp (brew install webp)"))
        #expect(ConversionEngine.availability(of: .convert(.webp), for: [png], ffmpegAvailable: false, cwebpAvailable: true) == .available)
        #expect(ExternalTool.cwebp.installCommand == "brew install webp")
    }

    @Test func fileActionsAndZIPTakeFoldersToo() {
        let folder = SourceFile(url: FileManager.default.temporaryDirectory)
        for action in FormatCatalog.fileActions {
            #expect(ConversionEngine.availability(of: action, for: [folder], ffmpegAvailable: false) == .available)
        }
        #expect(ConversionRequest(file: folder, action: .tool(.archive)).isCombined)
        #expect(!ConversionRequest(file: folder, action: .tool(.archive)).replacesOriginal, "zipping never bins the originals")
        #expect(!ConversionRequest(files: files("a.zip"), action: .tool(.extract)).replacesOriginal)
        #expect(throws: ConversionError.self) {
            try ConversionEngine.prepare(ConversionRequest(file: folder, action: .file(.copy)), options: ConversionOptions(), naming: OutputNaming())
        }
    }

    @Test func customActionStepsFollowTheWheels() {
        #expect(RecipeStep.convert(.webp).works(on: .image))
        #expect(RecipeStep.convert(.webm).works(on: .video))
        #expect(!RecipeStep.convert(.webm).works(on: .audio))
        #expect(RecipeStep.convert(.opus).outputKind(from: .video) == .audio)
        #expect(RecipeStep.convert(.png).outputKind(from: .pdf) == nil)
        #expect(RecipeStep.templates(for: .archive).isEmpty)
        #expect(!RecipeStep.compress.works(on: .archive))
    }

    @Test func everyNewSymbolExists() {
        var names = Set(FileAction.allCases.map(\.symbolName))
        names.formUnion(OutputFormat.allCases.map(\.symbolName))
        names.formUnion([FileKind.archive.symbolName, ToolAction.archive.symbolName, ToolAction.extract.symbolName, Editor.codes.symbolName])
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }
}

// MARK: - Pictures

struct V14PictureTests {
    @Test func avifBmpAndIcons() async throws {
        let folder = try TempFolder()
        let source = folder.file("logo.png")
        try Fixtures.makeImage(at: source, width: 300, height: 200)

        let avif = try await runConversion(source, .convert(.avif))
        #expect(avif.pathExtension == "avif")
        #expect(picture(avif)?.type == "public.avif")
        #expect(picture(avif)?.width == 300)

        let bmp = try await runConversion(source, .convert(.bmp))
        #expect(picture(bmp)?.type == UTType.bmp.identifier)

        // Icons hold every size, square, with the picture fitted inside.
        let ico = try await runConversion(source, .convert(.ico))
        #expect(picture(ico)?.type == UTType.ico.identifier)
        #expect(picture(ico)?.count == IconWriter.icoSizes.count)
        let icns = try await runConversion(source, .convert(.icns))
        #expect(picture(icns)?.type == UTType.icns.identifier)
        #expect((picture(icns)?.count ?? 0) >= 5)
        let largest = try #require(CGImageSourceCreateWithURL(icns as CFURL, nil)).largestImageSize
        #expect(largest == CGSize(width: 1024, height: 1024))
    }

    @Test(.enabled(if: cwebpInstalled)) func webpWithCwebp() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makePhoto(at: source, width: 640, height: 480)
        let webp = try await runConversion(source, .convert(.webp))
        #expect(webp.pathExtension == "webp")
        #expect(picture(webp)?.type == UTType.webP.identifier)
        #expect(picture(webp)?.width == 640 && picture(webp)?.height == 480)
        // Back from WebP too (macOS reads it).
        let png = try await runConversion(webp, .convert(.png))
        #expect(picture(png)?.width == 640)
    }

    @Test func webpWithoutCwebpSaysHow() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makeImage(at: source)
        var options = ConversionOptions()
        options.cwebpURL = nil
        await #expect(throws: ConversionError.failed("WebP needs cwebp. Install it with: brew install webp")) {
            _ = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .convert(.webp)), options: options, findTools: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["photo.png"], "nothing half-made is left")
    }

    @Test func svgBecomesAPictureOrStaysADrawing() async throws {
        let folder = try TempFolder()
        let svg = folder.file("badge.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
        <rect width="120" height="80" fill="#3355ee"/><circle cx="60" cy="40" r="30" fill="#ffcc00"/></svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        #expect(SourceFile(url: svg).kind == .image)

        // Big enough to stay sharp: 2048 pixels across, the shape kept.
        let png = try await runConversion(svg, .convert(.png))
        #expect(picture(png)?.width == 2048 && picture(png)?.height == 1365)
        let jpeg = try await runConversion(svg, .convert(.jpeg))
        #expect(picture(jpeg)?.type == UTType.jpeg.identifier)

        // A PDF the size of the drawing.
        let pdf = try await runConversion(svg, .convert(.pdf))
        let page = try #require(PDFDocument(url: pdf)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 120, height: 80))

        // Tools work on drawings as on any picture.
        let codes = try CodeReader.codes(in: svg)
        #expect(codes.isEmpty)
    }

    @Test func qrCodesAreRead() throws {
        let folder = try TempFolder()
        let url = folder.file("code.png")
        try qrPicture("https://example.com/pinwheel", to: url)
        let codes = try CodeReader.codes(in: url)
        #expect(codes == [ReadCode(text: "https://example.com/pinwheel", kind: "QR code")])
        #expect(codes.first?.link == URL(string: "https://example.com/pinwheel"))
        #expect(ReadCode(text: "Just words", kind: "QR code").link == nil)

        let plain = folder.file("plain.png")
        try Fixtures.makeImage(at: plain)
        #expect(try CodeReader.codes(in: plain).isEmpty)
    }

    /// A big, sharp QR code with a white margin, as a PNG.
    private func qrPicture(_ text: String, to url: URL) throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(text.utf8), "inputCorrectionLevel": "M"]))
        let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = code.transformed(by: CGAffineTransform(translationX: 48, y: 48))
            .composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -48, dy: -48).offsetBy(dx: 48, dy: 48)))
        let context = CIContext()
        try context.writePNGRepresentation(of: padded, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

private extension CGImageSource {
    var largestImageSize: CGSize {
        (0..<CGImageSourceGetCount(self)).compactMap { CGImageSourceCreateImageAtIndex(self, $0, nil) }
            .map { CGSize(width: $0.width, height: $0.height) }
            .max { $0.width < $1.width } ?? .zero
    }
}

// MARK: - Video and audio

struct V14MediaTests {
    @Test(.enabled(if: ffmpegInstalled), arguments: [OutputFormat.mkv, .webm, .avi, .wmv])
    func videoFormats(_ format: OutputFormat) async throws {
        let folder = try TempFolder()
        let mov = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: mov, seconds: 1)
        let output = try await runConversion(mov, .convert(format))
        #expect(output.pathExtension == format.fileExtension)
        let file = SourceFile(url: output)
        #expect(file.kind == .video && file.format == format)
        let seconds = await FFmpeg.duration(of: file, ffmpeg: try #require(FFmpeg.locate()))
        #expect(abs((seconds ?? 0) - 1) < 0.3, "\(format): \(seconds ?? -1) s")
    }

    @Test(.enabled(if: ffmpegInstalled), arguments: [OutputFormat.ogg, .opus, .wma])
    func audioFormats(_ format: OutputFormat) async throws {
        let folder = try TempFolder()
        let wav = folder.file("tone.wav")
        try MediaFixtures.makeWAV(at: wav, seconds: 1)
        let output = try await runConversion(wav, .convert(format))
        let file = SourceFile(url: output)
        #expect(file.kind == .audio && file.format == format)
        let seconds = await FFmpeg.duration(of: file, ffmpeg: try #require(FFmpeg.locate()))
        #expect(abs((seconds ?? 0) - 1) < 0.2, "\(format): \(seconds ?? -1) s")
    }

    @Test(.enabled(if: ffmpegInstalled)) func mkvCopiesWhenItCan() async throws {
        let folder = try TempFolder()
        let mov = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: mov, seconds: 1, noisy: true)
        let mkv = try await runConversion(mov, .convert(.mkv))
        // Copied, not made again: about the same size.
        let before = Double(FileSize.of(mov) ?? 0), after = Double(FileSize.of(mkv) ?? 0)
        #expect(abs(after - before) / before < 0.1, "\(before) → \(after)")
    }
}

// MARK: - Archives

struct V14ArchiveTests {
    /// A file and a folder (with a file inside), to pack.
    private func makeStuff(in folder: TempFolder) throws -> [URL] {
        let note = folder.file("note.txt")
        try "Hello from Pinwheel".write(to: note, atomically: true, encoding: .utf8)
        let photos = folder.file("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Fixtures.makeImage(at: photos.appendingPathComponent("red.png"))
        try Data("mac only".utf8).write(to: photos.appendingPathComponent(".DS_Store"))
        return [note, photos]
    }

    /// Every file under `folder`, as relative paths.
    private func contents(of folder: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            paths.append(String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)))
        }
        return paths.sorted()
    }

    @Test func zipThenExtract() async throws {
        let folder = try TempFolder()
        let stuff = try makeStuff(in: folder)
        let result = try await runRequest(ConversionRequest(files: stuff.map(SourceFile.init), action: .tool(.archive)))
        let zip = try #require(result.outputs.first)
        #expect(zip.lastPathComponent == "Archive (2 items).zip")
        #expect(SourceFile(url: zip).kind == .archive)

        let extracted = try await runConversion(zip, .tool(.extract))
        #expect(extracted.lastPathComponent == "Archive (2 items) (extracted)")
        #expect(contents(of: extracted) == ["Photos/red.png", "note.txt"], "no .DS_Store, no ._ files")
        #expect(try String(contentsOf: extracted.appendingPathComponent("note.txt"), encoding: .utf8) == "Hello from Pinwheel")

        // One item: named after it.
        let single = try await runRequest(ConversionRequest(files: [SourceFile(url: stuff[1])], action: .tool(.archive)))
        #expect(single.outputs.first?.lastPathComponent == "Photos (zipped).zip")
    }

    @Test(arguments: [OutputFormat.sevenZip, .tgz, .tar])
    func repack(_ format: OutputFormat) async throws {
        let folder = try TempFolder()
        let stuff = try makeStuff(in: folder)
        let zip = try #require(try await runRequest(ConversionRequest(files: stuff.map(SourceFile.init), action: .tool(.archive))).outputs.first)
        let repacked = try await runConversion(zip, .convert(format))
        #expect(repacked.lastPathComponent == "Archive (2 items) (converted).\(format.fileExtension)")
        #expect(SourceFile(url: repacked).format == format)
        let extracted = try await runConversion(repacked, .tool(.extract))
        #expect(contents(of: extracted) == ["Photos/red.png", "note.txt"])
    }

    @Test func singleSqueezedFiles() async throws {
        let folder = try TempFolder()
        let text = Data(String(repeating: "Pinwheel ", count: 500).utf8)
        let note = folder.file("note.txt")
        try text.write(to: note)

        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-k", note.path]
        try gzip.run()
        gzip.waitUntilExit()
        let fromGZ = try await runConversion(folder.file("note.txt.gz"), .tool(.extract))
        #expect(try Data(contentsOf: fromGZ.appendingPathComponent("note.txt")) == text)

        // .xz, made with Apple's Compression (macOS has no xz command).
        let xz = folder.file("again.txt.xz")
        var squeezed = Data()
        let filter = try OutputFilter(.compress, using: .lzma) { if let data = $0 { squeezed.append(data) } }
        try filter.write(text)
        try filter.finalize()
        try squeezed.write(to: xz)
        let fromXZ = try await runConversion(xz, .tool(.extract))
        #expect(try Data(contentsOf: fromXZ.appendingPathComponent("again.txt")) == text)
    }

    @Test func passwordsAreExplained() async throws {
        let folder = try TempFolder()
        let note = folder.file("secret.txt")
        try "shh".write(to: note, atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder.url
        zip.arguments = ["-q", "-P", "pinwheel", "locked.zip", "secret.txt"]
        try zip.run()
        zip.waitUntilExit()
        do {
            _ = try await runConversion(folder.file("locked.zip"), .tool(.extract))
            Issue.record("a locked archive opened")
        } catch let error as ConversionError {
            #expect(error.localizedDescription.contains("password"), "\(error.localizedDescription)")
        }
    }

    @Test func archiveNames() {
        #expect(ArchiveTools.baseName(of: URL(fileURLWithPath: "/tmp/photos.tar.gz")) == "photos")
        #expect(ArchiveTools.baseName(of: URL(fileURLWithPath: "/tmp/photos.7z")) == "photos")
        #expect(ArchiveTools.baseName(of: URL(fileURLWithPath: "/tmp/notes.txt.gz")) == "notes.txt")
        #expect(ArchiveTools.baseName(of: URL(fileURLWithPath: "/tmp/.zip")) == ".zip", "a dot file keeps its name")
        #expect(ArchiveTools.singleFileCompression(of: URL(fileURLWithPath: "/tmp/a.tar.gz")) == nil)
        #expect(ArchiveTools.singleFileCompression(of: URL(fileURLWithPath: "/tmp/a.txt.gz")) == "gz")
        #expect(ArchiveTools.singleFileCompression(of: URL(fileURLWithPath: "/tmp/a.txt.xz")) == "xz")
    }
}
