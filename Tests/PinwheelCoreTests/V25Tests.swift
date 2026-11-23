import Foundation
import Testing
@testable import PinwheelCore

struct NewFileMakerTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-newfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFreeNameIsFoundLikeWindowsDoes() {
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        var taken: Set<String> = []
        let first = NewFileMaker.freeURL(in: folder, baseName: "New Word Document", fileExtension: "docx") { taken.contains($0.lastPathComponent) }
        #expect(first.lastPathComponent == "New Word Document.docx")
        taken = ["New Word Document.docx", "New Word Document 2.docx"]
        let third = NewFileMaker.freeURL(in: folder, baseName: "New Word Document", fileExtension: "docx") { taken.contains($0.lastPathComponent) }
        #expect(third.lastPathComponent == "New Word Document 3.docx")
        #expect(NewFileMaker.freeURL(in: folder, baseName: "Notes", fileExtension: "") { _ in false }.lastPathComponent == "Notes")
    }

    @Test func everyKindPinwheelMakesIsWritten() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for kind in NewFileKind.allCases where !kind.needsApp {
            let url = folder.appendingPathComponent("\(kind.baseName).\(kind.fileExtension)")
            try NewFileMaker.write(kind, to: url)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(kind)")
            #expect(throws: (any Error).self, "never replaces a file") { try NewFileMaker.write(kind, to: url) }
        }
        let script = folder.appendingPathComponent("New Shell Script.sh")
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755, "a shell script can be run")
        #expect(throws: (any Error).self) { try NewFileMaker.write(.pages, to: folder.appendingPathComponent("x.pages")) }
    }

    @Test func officeFilesHoldWellFormedParts() throws {
        func parts(_ data: Data) throws -> ZipReader { try ZipReader(data: data) }
        let word = try parts(NewFileMaker.emptyWord())
        let excel = try parts(NewFileMaker.emptyExcel())
        let slides = try parts(NewFileMaker.emptyPowerPoint())
        let text = try parts(NewFileMaker.emptyOpenDocumentText())
        let expected: [(ZipReader, [String])] = [
            (word, ["[Content_Types].xml", "_rels/.rels", "word/document.xml"]),
            (excel, ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/styles.xml"]),
            (slides, ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels",
                      "ppt/slideMasters/slideMaster1.xml", "ppt/slideLayouts/slideLayout1.xml", "ppt/slides/slide1.xml", "ppt/theme/theme1.xml"]),
            (text, ["mimetype", "META-INF/manifest.xml", "content.xml"]),
        ]
        for (zip, names) in expected {
            for name in names {
                #expect(zip.contains(name), "\(name)")
                guard name != "mimetype", let data = zip.data(name) else { continue }
                let parser = XMLParser(data: data)
                #expect(parser.parse(), "\(name) is well-formed XML")
            }
        }
        #expect(text.text("mimetype") == "application/vnd.oasis.opendocument.text")
    }

    @Test func macOSReadsTheWordAndOpenDocumentFiles() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for kind in [NewFileKind.word, .openDocumentText, .richText, .html] {
            let url = folder.appendingPathComponent("blank.\(kind.fileExtension)")
            try NewFileMaker.write(kind, to: url)
            // Apple's own reader (TextEdit's) opens it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-info", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(kind)")
        }
    }

    @Test func theStartingMenuIsOfficeIWorkThenText() {
        #expect(NewFileKind.startingMenu.prefix(6) == [.word, .excel, .powerpoint, .pages, .numbers, .keynote])
        #expect(Set(NewFileKind.allCases.map(\.fileExtension)).count == NewFileKind.allCases.count, "one extension each")
        #expect(NewFileKind.pages.needsApp && !NewFileKind.word.needsApp)
        #expect(NewFileKind.pages.makingApps.first == "com.apple.Pages")
    }
}
