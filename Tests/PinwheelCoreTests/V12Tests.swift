import Foundation
import Testing
@testable import PinwheelCore

// MARK: - The compatibility tables

struct CompatibilityTests {
    private func cell(_ from: String, _ to: OutputFormat) throws -> Compatibility.Cell {
        for section in Compatibility.sections {
            guard let row = section.rows.first(where: { $0.source.title == from }) else { continue }
            guard let column = section.targets.firstIndex(of: to) else { return .no }
            return row.cells[column]
        }
        throw CancellationError()
    }

    @Test func everyRowIsAKindOfFilePinwheelReads() {
        for source in Compatibility.sources {
            #expect(source.sample.kind != nil, "\(source.title)")
        }
        #expect(Set(Compatibility.sources.map(\.id)).count == Compatibility.sources.count)
        // One table per kind, every row in its kind's table.
        #expect(Compatibility.sections.map(\.kind) == [.image, .pdf, .video, .audio, .archive, .document, .spreadsheet, .presentation, .subtitle])
        #expect(Compatibility.sections.flatMap(\.rows).count == Compatibility.sources.count)
        for section in Compatibility.sections {
            #expect(section.rows.allSatisfy { $0.source.kind == section.kind && $0.cells.count == section.targets.count })
        }
    }

    @Test func columnsKeepOneOrderWithMP3BeforeM4A() throws {
        #expect(Set(Compatibility.order) == Set(OutputFormat.allCases) && Compatibility.order.count == OutputFormat.allCases.count)
        #expect(try #require(Compatibility.order.firstIndex(of: .mp3)) < #require(Compatibility.order.firstIndex(of: .m4a)))
        for section in Compatibility.sections {
            #expect(section.targets == Compatibility.order.filter(section.targets.contains), "\(section.kind)")
        }
        // Each kind's own formats line up with its rows, so the dashes run down the middle.
        for section in Compatibility.sections {
            let dashColumns = section.rows.compactMap { $0.cells.firstIndex(of: .same) }
            #expect(dashColumns == dashColumns.sorted(), "\(section.kind)")
        }
    }

    @Test func aFormatAgainstItselfIsADash() {
        var dashes: [String] = []
        for section in Compatibility.sections {
            for row in section.rows {
                for (column, target) in section.targets.enumerated() where row.cells[column] == .same {
                    dashes.append("\(row.source.title) \(target.title)")
                }
            }
        }
        #expect(dashes.sorted() == [
            "7Z 7Z", "AIFF AIFF", "AVI AVI", "AVIF AVIF", "BMP BMP", "CSV CSV", "DOCX DOCX", "EPUB EPUB", "FLAC FLAC", "GIF GIF",
            "HEIC HEIC", "HTML HTML", "JPEG JPEG", "M4A M4A", "MD MD", "MKV MKV", "MOV MOV", "MP3 MP3", "MP4 MP4", "ODS ODS",
            "ODT ODT", "OGG OGG", "Opus Opus", "PDF PDF", "PNG PNG", "PPTX PPTX", "Pages Pages", "RTF RTF", "SRT SRT", "TAR TAR",
            "TAR.GZ TAR.GZ", "TIFF TIFF", "TSV TSV", "TXT TXT", "VTT VTT", "WAV WAV", "WMA WMA", "WMV WMV", "WebM WebM",
            "WebP WebP", "XLSX XLSX", "ZIP ZIP",
        ])
    }

    @Test func ticksAreWhatTheFormatWheelOffers() {
        for section in Compatibility.sections {
            for row in section.rows {
                let wheel = FormatCatalog.actions(for: [row.source.sample], mode: .convert)
                for (column, target) in section.targets.enumerated() {
                    let converts = if case .converts = row.cells[column] { true } else { false }
                    #expect(converts == wheel.contains(.convert(target)), "\(row.source.title) → \(target.title)")
                }
                // Nothing the wheel offers is missing from the table.
                for case .convert(let format) in wheel {
                    #expect(section.targets.contains(format), "\(row.source.title) → \(format.title) has no column")
                }
            }
        }
    }

    @Test func wellKnownBoxes() throws {
        #expect(try cell("HEIC", .jpeg) == .converts(needs: nil))
        #expect(try cell("RAW", .png) == .converts(needs: nil))
        #expect(try cell("WebP", .pdf) == .converts(needs: nil))
        #expect(try cell("SVG", .png) == .converts(needs: nil))
        #expect(try cell("PNG", .avif) == .converts(needs: nil))
        #expect(try cell("PNG", .webp) == .converts(needs: .cwebp))
        #expect(try cell("PDF", .png) == .converts(needs: nil))
        #expect(try cell("MOV", .m4a) == .converts(needs: nil))
        #expect(try cell("MOV", .gif) == .converts(needs: .ffmpeg))
        #expect(try cell("MOV", .webm) == .converts(needs: .ffmpeg))
        #expect(try cell("WAV", .mp3) == .converts(needs: .ffmpeg))
        #expect(try cell("WAV", .opus) == .converts(needs: .ffmpeg))
        #expect(try cell("MKV", .mp4) == .converts(needs: .ffmpeg))  // macOS can't read MKV…
        #expect(try cell("AVI", .mov) == .converts(needs: .ffmpeg))  // …nor AVI
        #expect(try cell("RAR", .zip) == .converts(needs: nil))
        #expect(try cell("ZIP", .sevenZip) == .converts(needs: nil))
        #expect(try cell("PDF", .gif) == .no)
        #expect(try cell("PNG", .mp4) == .no)
        #expect(try cell("MP3", .mov) == .no)
        #expect(try cell("WAV", .gif) == .no)
    }

    @Test func extraToolsForEveryFileOfAKind() {
        #expect(Compatibility.tool(for: .convert(.mp3), kind: .audio) == .ffmpeg)
        #expect(Compatibility.tool(for: .convert(.mp3), kind: .video) == .ffmpeg)
        #expect(Compatibility.tool(for: .convert(.gif), kind: .video) == .ffmpeg)
        #expect(Compatibility.tool(for: .convert(.webp), kind: .image) == .cwebp)
        #expect(Compatibility.tool(for: .convert(.gif), kind: .image) == nil)
        #expect(Compatibility.tool(for: .convert(.m4a), kind: .video) == nil)
        #expect(Compatibility.tool(for: .convert(.flac), kind: .audio) == nil)
        #expect(Compatibility.tool(for: .tool(.compress), kind: .pdf) == nil)
        #expect(Compatibility.tool(for: .open(.collage), kind: .image) == nil)
        #expect(Compatibility.tool(for: .tool(.extract), kind: .archive) == nil)
    }
}

// MARK: - The format wheel

struct V12FormatWheelTests {
    private func files(_ names: String...) -> [SourceFile] {
        names.map { SourceFile(url: URL(fileURLWithPath: "/tmp/pinwheel-v12/\($0)")) }
    }

    @Test func m4aFilesAreNotOfferedM4A() async throws {
        #expect(files("a.m4a")[0].format == .m4a)
        #expect(!FormatCatalog.actions(for: files("a.m4a"), mode: .convert).contains(.convert(.m4a)))
        // A real one: its type comes from the file ("com.apple.m4a-audio").
        let folder = try TempFolder()
        let wav = folder.file("tone.wav")
        try MediaFixtures.makeWAV(at: wav)
        let m4a = try await runConversion(wav, .convert(.m4a))
        let file = SourceFile(url: m4a)
        #expect(file.format == .m4a)
        #expect(FormatCatalog.actions(for: [file], mode: .convert)
                == [.convert(.mp3), .convert(.wav), .convert(.aiff), .convert(.flac), .convert(.ogg), .convert(.opus), .convert(.wma)])
    }

    @Test func aviGoesThroughFFmpeg() {
        let avi = files("clip.avi")[0]
        #expect(avi.kind == .video)
        #expect(avi.needsFFmpegToRead)
        #expect(ConversionEngine.availability(of: .convert(.mp4), for: [avi], ffmpegAvailable: false)
                == .unavailable("Needs ffmpeg (brew install ffmpeg)"))
        #expect(ConversionEngine.availability(of: .convert(.mp4), for: [avi], ffmpegAvailable: true) == .available)
        #expect(!files("clip.mov")[0].needsFFmpegToRead)
    }

    @Test(.enabled(if: ffmpegInstalled)) func anAVIBecomesAnMP4() async throws {
        let folder = try TempFolder()
        let mov = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: mov)
        let avi = folder.file("clip.avi")
        try await MediaFixtures.ffmpegTranscode(mov, to: avi, arguments: ["-c:v", "mpeg4", "-c:a", "libmp3lame"])
        let mp4 = try await runConversion(avi, .convert(.mp4))
        #expect(mp4.pathExtension == "mp4")
        #expect(SourceFile(url: mp4).format == .mp4)
    }

    @Test func switchedOffFormatsLeaveTheWheel() {
        let hidden: Set = [FormatCatalog.hiddenKey(.image, .convert(.tiff)), FormatCatalog.hiddenKey(.image, .open(.collage))]
        #expect(FormatCatalog.actions(for: files("a.png"), mode: .convert, hidden: hidden)
                == [.convert(.jpeg), .convert(.heic), .convert(.webp), .convert(.avif), .convert(.gif), .convert(.bmp), .convert(.ico), .convert(.icns), .convert(.pdf)])
        // Collage too, which shows only for several pictures.
        #expect(FormatCatalog.actions(for: files("a.png", "b.jpg"), mode: .convert).last == .open(.collage))
        #expect(!FormatCatalog.actions(for: files("a.png", "b.jpg"), mode: .convert, hidden: hidden).contains(.open(.collage)))
        // Other kinds keep theirs.
        #expect(FormatCatalog.actions(for: files("a.pdf"), mode: .convert, hidden: hidden).contains(.convert(.tiff)))
    }

    @Test func settingsListCollageWithTheImageFormats() {
        #expect(FormatCatalog.choices(for: .image, mode: .convert) == FormatCatalog.actions(for: .image, mode: .convert) + [.open(.collage)])
        for kind in [FileKind.video, .audio, .pdf] {
            #expect(FormatCatalog.choices(for: kind, mode: .convert) == FormatCatalog.actions(for: kind, mode: .convert))
        }
        for kind in FileKind.allCases {
            #expect(FormatCatalog.choices(for: kind, mode: .tools) == FormatCatalog.actions(for: kind, mode: .tools))
        }
    }
}
