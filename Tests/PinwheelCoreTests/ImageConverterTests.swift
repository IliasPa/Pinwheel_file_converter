import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

struct ImageConverterTests {
    private func convert(_ source: URL, to format: OutputFormat, in folder: TempFolder) async throws -> URL {
        let file = SourceFile(url: source)
        let plan = ConversionEngine.plan(for: file, action: .convert(format))
        let naming = OutputNaming()
        let destination = naming.reserve(for: source, suffix: plan.suffix, fileExtension: plan.fileExtension)
        let outputs = try await ConversionEngine.run(
            file: file, action: .convert(format), destination: destination, options: ConversionOptions()
        ) { _ in }
        #expect(outputs == [destination])
        return destination
    }

    @Test(arguments: [OutputFormat.jpeg, .heic, .tiff, .gif, .png])
    func convertsToEveryImageFormat(format: OutputFormat) async throws {
        let folder = try TempFolder()
        let source = folder.file("picture.\(format == .png ? "tiff" : "png")")
        try Fixtures.makeImage(at: source, type: format == .png ? .tiff : .png)

        let output = try await convert(source, to: format, in: folder)
        #expect(output.lastPathComponent == "picture (converted).\(format.fileExtension)")
        let info = try #require(Fixtures.readImage(output))
        #expect(info.type == format.utType.identifier)
        #expect(info.width == 100 && info.height == 60)
    }

    @Test func jpegTurnsTransparencyWhiteNotBlack() async throws {
        let folder = try TempFolder()
        let source = folder.file("logo.png")
        try Fixtures.makeImage(at: source)
        let output = try await convert(source, to: .jpeg, in: folder)
        let info = try #require(Fixtures.readImage(output))
        let transparentSide = Fixtures.pixel(info.image, x: 90, y: 30)
        #expect(transparentSide.r > 240 && transparentSide.g > 240 && transparentSide.b > 240)
        let redSide = Fixtures.pixel(info.image, x: 10, y: 30)
        #expect(redSide.r > 200 && redSide.g < 60)
    }

    @Test func keepsMetadata() async throws {
        let folder = try TempFolder()
        let source = folder.file("camera.jpg")
        try Fixtures.makeImage(at: source, type: .jpeg, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PinwheelCam"],
        ])
        let output = try await convert(source, to: .heic, in: folder)
        let info = try #require(Fixtures.readImage(output))
        let tiff = info.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "PinwheelCam")
    }

    @Test func imageToPDFMakesOnePageOfTheRightSize() async throws {
        let folder = try TempFolder()
        let source = folder.file("scan.png")
        try Fixtures.makeImage(at: source, width: 144, height: 72)
        let output = try await convert(source, to: .pdf, in: folder)
        let pdf = try #require(CGPDFDocument(output as CFURL))
        #expect(pdf.numberOfPages == 1)
        let box = try #require(pdf.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(box.width == 144 && box.height == 72)
    }

    @Test func secondConversionGetsANewName() async throws {
        let folder = try TempFolder()
        let source = folder.file("a.png")
        try Fixtures.makeImage(at: source)
        let first = try await convert(source, to: .jpeg, in: folder)
        let second = try await convert(source, to: .jpeg, in: folder)
        #expect(first.lastPathComponent == "a (converted).jpg")
        #expect(second.lastPathComponent == "a (converted 2).jpg")
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func unreadableFilesFailCleanly() async throws {
        let folder = try TempFolder()
        let source = folder.file("broken.png")
        try Data("not an image".utf8).write(to: source)
        let destination = folder.file("broken (converted).jpg")
        await #expect(throws: ConversionError.self) {
            try await ConversionEngine.run(
                file: SourceFile(url: source), action: .convert(.jpeg),
                destination: destination, options: ConversionOptions()
            ) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
