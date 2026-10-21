import Foundation
import Testing
@testable import PinwheelCore

// MARK: - The compatibility table

struct CompatibilityTests {
    private func cell(_ from: String, _ to: OutputFormat) throws -> Compatibility.Cell {
        let row = try #require(Compatibility.rows.first { $0.source.title == from })
        return row.cells[try #require(Compatibility.targets.firstIndex(of: to))]
    }

    @Test func everyRowIsAKindOfFilePinwheelReads() {
        for source in Compatibility.sources {
            #expect(source.sample.kind != nil, "\(source.title)")
        }
        #expect(Set(Compatibility.sources.map(\.id)).count == Compatibility.sources.count)
        // Grouped by kind, in the columns' order (images, PDF, video, audio),
        // so the dashes run down the middle.
        let kinds = Compatibility.sources.map(\.kind)
        let groups = kinds.indices.filter { $0 == 0 || kinds[$0 - 1] != kinds[$0] }.map { kinds[$0] }
        #expect(groups == [.image, .pdf, .video, .audio])
    }

    @Test func everyFormatIsAColumnWithMP3BeforeM4A() throws {
        let targets = Compatibility.targets
        #expect(targets.count == OutputFormat.allCases.count && Set(targets) == Set(OutputFormat.allCases))
        #expect(try #require(targets.firstIndex(of: .mp3)) < #require(targets.firstIndex(of: .m4a)))
        // Each kind's own formats line up with its rows, so the dashes run down the middle.
        var dashColumns: [Int] = []
        for row in Compatibility.rows {
            if let column = row.cells.firstIndex(of: .same) { dashColumns.append(column) }
        }
        #expect(dashColumns == dashColumns.sorted())
    }

    @Test func aFormatAgainstItselfIsADash() {
        var dashes: [String] = []
        for row in Compatibility.rows {
            for (column, target) in Compatibility.targets.enumerated() where row.cells[column] == .same {
                dashes.append("\(row.source.title) \(target.title)")
            }
        }
        #expect(dashes.sorted() == [
            "AIFF AIFF", "FLAC FLAC", "GIF GIF", "HEIC HEIC", "JPEG JPEG", "M4A M4A", "MOV MOV", "MP3 MP3", "MP4 MP4",
            "PDF PDF", "PNG PNG", "TIFF TIFF", "WAV WAV",
        ])
    }

    @Test func ticksAreWhatTheFormatWheelOffers() {
        for row in Compatibility.rows {
            let wheel = FormatCatalog.actions(for: [row.source.sample], mode: .convert)
            for (column, target) in Compatibility.targets.enumerated() {
                let converts = if case .converts = row.cells[column] { true } else { false }
                #expect(converts == wheel.contains(.convert(target)), "\(row.source.title) → \(target.title)")
            }
        }
    }

    @Test func wellKnownBoxes() throws {
        #expect(try cell("HEIC", .jpeg) == .converts(needsFFmpeg: false))
        #expect(try cell("RAW", .png) == .converts(needsFFmpeg: false))
        #expect(try cell("WebP", .pdf) == .converts(needsFFmpeg: false))
        #expect(try cell("PDF", .png) == .converts(needsFFmpeg: false))
        #expect(try cell("MOV", .m4a) == .converts(needsFFmpeg: false))
        #expect(try cell("MOV", .gif) == .converts(needsFFmpeg: true))
        #expect(try cell("WAV", .mp3) == .converts(needsFFmpeg: true))
        #expect(try cell("MKV", .mp4) == .converts(needsFFmpeg: true))  // macOS can't read MKV…
        #expect(try cell("AVI", .mov) == .converts(needsFFmpeg: true))  // …nor AVI
        #expect(try cell("PDF", .gif) == .no)
        #expect(try cell("PNG", .mp4) == .no)
        #expect(try cell("MP3", .mov) == .no)
        #expect(try cell("WAV", .gif) == .no)
    }

    @Test func ffmpegForEveryFileOfAKind() {
        #expect(Compatibility.needsFFmpeg(.convert(.mp3), for: .audio))
        #expect(Compatibility.needsFFmpeg(.convert(.mp3), for: .video))
        #expect(Compatibility.needsFFmpeg(.convert(.gif), for: .video))
        #expect(!Compatibility.needsFFmpeg(.convert(.gif), for: .image))
        #expect(!Compatibility.needsFFmpeg(.convert(.m4a), for: .video))
        #expect(!Compatibility.needsFFmpeg(.convert(.flac), for: .audio))
        #expect(!Compatibility.needsFFmpeg(.tool(.compress), for: .pdf))
        #expect(!Compatibility.needsFFmpeg(.open(.collage), for: .image))
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
        #expect(FormatCatalog.actions(for: [file], mode: .convert) == [.convert(.mp3), .convert(.wav), .convert(.aiff), .convert(.flac)])
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
                == [.convert(.jpeg), .convert(.heic), .convert(.gif), .convert(.pdf)])
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
