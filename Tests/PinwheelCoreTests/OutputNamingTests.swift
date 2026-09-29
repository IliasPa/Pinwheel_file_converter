import Foundation
import Testing
@testable import PinwheelCore

struct OutputNamingTests {
    @Test func firstNameIsConverted() throws {
        let folder = try TempFolder()
        let source = try folder.touch("holiday photo.jpeg")
        let naming = OutputNaming()
        let url = naming.reserve(for: source, suffix: "converted", fileExtension: "png")
        #expect(url.lastPathComponent == "holiday photo (converted).png")
        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
    }

    @Test func neverOverwritesExistingFiles() throws {
        let folder = try TempFolder()
        let source = try folder.touch("a.jpg")
        _ = try folder.touch("a (converted).png")
        _ = try folder.touch("A (CONVERTED 2).PNG")  // different case is still the same file on macOS
        let url = OutputNaming().reserve(for: source, suffix: "converted", fileExtension: "png")
        #expect(url.lastPathComponent == "a (converted 3).png")
    }

    @Test func reservedNamesAreNotHandedOutTwice() throws {
        let folder = try TempFolder()
        let source = try folder.touch("a.jpg")
        let naming = OutputNaming()
        let first = naming.reserve(for: source, suffix: "converted", fileExtension: "png")
        let second = naming.reserve(for: source, suffix: "converted", fileExtension: "png")
        #expect(first.lastPathComponent == "a (converted).png")
        #expect(second.lastPathComponent == "a (converted 2).png")
        naming.release(first)
        #expect(naming.reserve(for: source, suffix: "converted", fileExtension: "png") == first)
    }

    @Test func foldersAndToolSuffixes() throws {
        let folder = try TempFolder()
        let source = try folder.touch("doc.pdf")
        let naming = OutputNaming()
        #expect(naming.reserve(for: source, suffix: "converted", fileExtension: nil).lastPathComponent == "doc (converted)")
        #expect(naming.reserve(for: source, suffix: "compressed", fileExtension: "pdf").lastPathComponent == "doc (compressed).pdf")
    }
}
