import AppKit
import Foundation
import Testing
@testable import PinwheelCore

struct FormatCatalogTests {
    private func files(_ names: String...) -> [SourceFile] {
        names.map { SourceFile(url: URL(fileURLWithPath: "/tmp/pinwheel-catalog/\($0)")) }
    }

    @Test func fileKinds() {
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.png")) == .image)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.HEIC")) == .image)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.webp")) == .image)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.mov")) == .video)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.mp4")) == .video)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.mkv")) == .video)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.m4a")) == .audio)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.mp3")) == .audio)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.flac")) == .audio)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.ogg")) == .audio)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.pdf")) == .pdf)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.svg")) == nil)
        #expect(FileKind.of(URL(fileURLWithPath: "/tmp/a.txt")) == nil)
        #expect(FileKind.of(FileManager.default.temporaryDirectory) == nil)  // folders
    }

    @Test func singleImageHidesItsOwnFormat() {
        let actions = FormatCatalog.actions(for: files("a.png"), mode: .convert)
        #expect(actions == [.convert(.jpeg), .convert(.heic), .convert(.tiff), .convert(.gif), .convert(.pdf)])
    }

    @Test func mixedImageFormatsKeepEveryWedge() {
        let actions = FormatCatalog.actions(for: files("a.png", "b.jpg"), mode: .convert)
        #expect(actions == FormatCatalog.actions(for: .image, mode: .convert))
    }

    @Test func mixedKindsShowOnlyWhatAllShare() {
        #expect(FormatCatalog.actions(for: files("a.png", "b.mov"), mode: .convert) == [.convert(.gif)])
        #expect(FormatCatalog.actions(for: files("a.mov", "b.wav"), mode: .convert) == [.convert(.m4a), .convert(.mp3)])
        #expect(FormatCatalog.actions(for: files("a.png", "b.pdf"), mode: .convert)
                == [.convert(.png), .convert(.jpeg), .convert(.heic), .convert(.tiff)])
        #expect(FormatCatalog.actions(for: files("a.png", "b.mov"), mode: .tools)
                == [.tool(.compress), .tool(.stripMetadata)])
    }

    @Test func unsupportedFilesLeaveNothing() {
        #expect(FormatCatalog.actions(for: files("a.png", "notes.txt"), mode: .convert).isEmpty)
        #expect(FormatCatalog.actions(for: [], mode: .convert).isEmpty)
    }

    @Test func pdfWheel() {
        #expect(FormatCatalog.actions(for: files("a.pdf"), mode: .convert)
                == [.convert(.png), .convert(.jpeg), .convert(.heic), .convert(.tiff), .tool(.compress)])
        #expect(WheelAction.tool(.compress).title(in: .convert) == "Smaller PDF")
        #expect(WheelAction.tool(.compress).title(in: .tools) == "Compress")
    }

    @Test func summaries() {
        #expect(FormatCatalog.summary(for: files("a.png")) == "1 image")
        #expect(FormatCatalog.summary(for: files("a.png", "b.jpg")) == "2 images")
        #expect(FormatCatalog.summary(for: files("a.png", "b.mov")) == "2 files")
        #expect(FormatCatalog.symbolName(for: files("a.png", "b.mov")) == "doc.on.doc")
    }

    @Test func ffmpegOnlyInputsAreDetected() {
        #expect(files("a.mkv")[0].needsFFmpegToRead)
        #expect(files("a.webm")[0].needsFFmpegToRead)
        #expect(!files("a.mov")[0].needsFFmpegToRead)
        #expect(!files("a.mp3")[0].needsFFmpegToRead)
        #expect(!files("a.png")[0].needsFFmpegToRead)
    }

    @Test func everySymbolExists() {
        var names = Set<String>()
        for format in OutputFormat.allCases { names.insert(format.symbolName) }
        for tool in ToolAction.allCases { names.insert(tool.symbolName) }
        for kind in FileKind.allCases { names.insert(kind.symbolName) }
        names.formUnion([
            WheelAction.tool(.compress).symbolName(in: .convert), "doc.on.doc",
            // Used by the app's hub and onboarding.
            "nosign", "xmark", "hand.draw", "circle.dashed", "arrow.down.circle", "checkmark.circle.fill", "clock",
        ])
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }
}
