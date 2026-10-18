import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PinwheelCore

// MARK: - Rename rules

/// Applies rules to a name the way the Rename window does.
private func renamed(
    _ name: String, _ rules: [RenameRule], index: Int = 0, info: RenameFileInfo = RenameFileInfo(folder: "Trip")
) -> String {
    let ext = (name as NSString).pathExtension
    let original = FileName(base: ext.isEmpty ? name : String(name.dropLast(ext.count + 1)), ext: ext)
    let context = RenameContext(index: index, original: original, info: info, now: Date(timeIntervalSince1970: 1_790_000_000))
    var result = original
    for rule in rules { rule.apply(to: &result, context: context) }
    return result.full
}

private func rule(_ kind: RenameRule.Kind, _ change: (inout RenameRule) -> Void = { _ in }) -> RenameRule {
    var rule = RenameRule(kind)
    change(&rule)
    return rule
}

struct RenameRuleTests {
    @Test func replaceFindsTextAnyCaseOrExactly() {
        let photo = rule(.replace) { $0.text = "img"; $0.text2 = "Photo" }
        #expect(renamed("IMG_001 img.JPG", [photo]) == "Photo_001 Photo.JPG")
        let exact = rule(.replace) { $0.text = "img"; $0.text2 = "Photo"; $0.matchCase = true }
        #expect(renamed("IMG_001 img.JPG", [exact]) == "IMG_001 Photo.JPG")
        let first = rule(.replace) { $0.text = "a"; $0.text2 = "_"; $0.occurrence = .first }
        let last = rule(.replace) { $0.text = "a"; $0.text2 = "_"; $0.occurrence = .last }
        #expect(renamed("banana.txt", [first]) == "b_nana.txt")
        #expect(renamed("banana.txt", [last]) == "banan_.txt")
        // The extension only changes when asked.
        let ext = rule(.replace) { $0.text = "jpeg"; $0.text2 = "jpg"; $0.includeExtension = true }
        #expect(renamed("my jpeg.jpeg", [ext]) == "my jpg.jpg")
    }

    @Test func regularExpressionsWithGroups() {
        let swapDate = rule(.replace) { $0.regex = true; $0.text = #"(\d{2})-(\d{2})-(\d{4})"#; $0.text2 = "$3-$2-$1" }
        #expect(renamed("scan 18-10-2026.pdf", [swapDate]) == "scan 2026-10-18.pdf")
        let broken = rule(.replace) { $0.regex = true; $0.text = "(" }
        #expect(broken.problem != nil)
        #expect(renamed("a(b.txt", [broken]) == "a(b.txt", "a broken expression changes nothing")
    }

    @Test func removeCharacters() {
        func remove(_ part: RenameRule.RemovePart, count: Int = 3, position: Int = 1, text: String = "", text2: String = "") -> RenameRule {
            rule(.remove) { $0.removePart = part; $0.count = count; $0.position = position; $0.text = text; $0.text2 = text2 }
        }
        #expect(renamed("IMG_1234.jpg", [remove(.first, count: 4)]) == "1234.jpg")
        #expect(renamed("report final.pdf", [remove(.last, count: 6)]) == "report.pdf", "the last 3 characters, and more")
        #expect(renamed("abcdef.txt", [remove(.range, count: 2, position: 3)]) == "abef.txt")
        #expect(renamed("abcdef.txt", [remove(.keepFirst, count: 2)]) == "ab.txt")
        #expect(renamed("abcdef.txt", [remove(.keepLast, count: 2)]) == "ef.txt")
        #expect(renamed("01 - Song.mp3", [remove(.upTo, text: " - ")]) == "Song.mp3")
        #expect(renamed("Song - Remastered 2011.mp3", [remove(.from, text: " - ")]) == "Song.mp3")
        #expect(renamed("a [1] b [2].txt", [remove(.between, text: "[", text2: "]")]) == "a  b .txt")
        #expect(renamed("ab.txt", [remove(.first, count: 10)]) == ".txt", "more than there is leaves nothing")
    }

    @Test func removeKindsOfText() {
        func remove(_ kinds: RenameRule.RemoveKind...) -> RenameRule { rule(.removeKinds) { $0.removeKinds = kinds } }
        #expect(renamed("photo 2026 (1).jpg", [remove(.digits)]) == "photo  ().jpg")
        #expect(renamed("Report (final) [v2].pdf", [remove(.brackets)]) == "Report.pdf")
        #expect(renamed("Notes copy 2.txt", [remove(.copyMarks)]) == "Notes.txt")
        #expect(renamed("Notes (3).txt", [remove(.copyMarks)]) == "Notes.txt")
        #expect(renamed("Café Ελλάδα.txt", [remove(.accents)]) == "Cafe Ελλαδα.txt")
        #expect(renamed("party 🎉 time.jpg", [remove(.emoji)]) == "party  time.jpg")
        #expect(renamed("a&b@c#d-e_f.txt", [remove(.special)]) == "abcd-e_f.txt")
        #expect(renamed("Αθήνα Athens.jpg", [remove(.greek)]) == " Athens.jpg")
    }

    @Test func addText() {
        func insert(_ place: RenameRule.InsertPlace, _ text: String, position: Int = 0, near: String = "") -> RenameRule {
            rule(.insert) { $0.text = text; $0.insertPlace = place; $0.position = position; $0.text2 = near }
        }
        #expect(renamed("photo.jpg", [insert(.start, "2026 ")]) == "2026 photo.jpg")
        #expect(renamed("photo.jpg", [insert(.end, " edited")]) == "photo edited.jpg")
        #expect(renamed("photo.jpg", [insert(.position, "-", position: 2)]) == "ph-oto.jpg")
        #expect(renamed("photo.jpg", [insert(.positionFromEnd, "-", position: 1)]) == "phot-o.jpg")
        #expect(renamed("Smith John.txt", [insert(.after, ",", near: "Smith")]) == "Smith, John.txt")
        #expect(renamed("Smith John.txt", [insert(.before, "Mr ", near: "smith")]) == "Mr Smith John.txt")
    }

    @Test func changeCase() {
        func style(_ style: RenameRule.CaseStyle) -> RenameRule { rule(.changeCase) { $0.caseStyle = style } }
        #expect(renamed("my holiday PHOTO.JPG", [style(.lower)]) == "my holiday photo.JPG")
        #expect(renamed("my holiday photo.jpg", [style(.upper)]) == "MY HOLIDAY PHOTO.jpg")
        #expect(renamed("my holiday photo.jpg", [style(.title)]) == "My Holiday Photo.jpg")
        #expect(renamed("MY HOLIDAY photo.jpg", [style(.sentence)]) == "My holiday photo.jpg")
        #expect(renamed("my holiday-photo.jpg", [style(.camel)]) == "myHolidayPhoto.jpg")
        #expect(renamed("my holiday photo.jpg", [style(.pascal)]) == "MyHolidayPhoto.jpg")
        #expect(renamed("myHoliday Photo.jpg", [style(.snake)]) == "my_holiday_photo.jpg")
        #expect(renamed("My Holiday_Photo.jpg", [style(.kebab)]) == "my-holiday-photo.jpg")
        // Greek capitals drop their accents, as Greek spelling does.
        #expect(renamed("Καλημέρα Αθήνα.txt", [style(.upper)]) == "ΚΑΛΗΜΕΡΑ ΑΘΗΝΑ.txt")
        var withExtension = style(.lower)
        withExtension.includeExtension = true
        #expect(renamed("PHOTO.JPG", [withExtension]) == "photo.jpg")
    }

    @Test func spacesAndSeparators() {
        func style(_ style: RenameRule.SeparatorStyle) -> RenameRule { rule(.separators) { $0.separatorStyle = style } }
        #expect(renamed("my holiday photo.jpg", [style(.spacesToUnderscores)]) == "my_holiday_photo.jpg")
        #expect(renamed("my holiday photo.jpg", [style(.spacesToDashes)]) == "my-holiday-photo.jpg")
        #expect(renamed("my_holiday_photo.jpg", [style(.underscoresToSpaces)]) == "my holiday photo.jpg")
        #expect(renamed("  my   holiday__photo- .jpg", [style(.tidy)]) == "my holiday_photo.jpg")
    }

    @Test func numbering() {
        let numbers = rule(.numbering) { $0.start = 1; $0.digits = 3; $0.place = .start; $0.separator = " - " }
        #expect(renamed("Beach.jpg", [numbers], index: 0) == "001 - Beach.jpg")
        #expect(renamed("Beach.jpg", [numbers], index: 41) == "042 - Beach.jpg")
        let stepped = rule(.numbering) { $0.start = 10; $0.step = 10; $0.digits = 0; $0.place = .end; $0.separator = "_" }
        #expect(renamed("a.txt", [stepped], index: 2) == "a_30.txt")
        let letters = rule(.numbering) { $0.numberStyle = .upperLetters; $0.place = .replace }
        #expect(renamed("x.txt", [letters], index: 27) == "AB.txt")
        let roman = rule(.numbering) { $0.numberStyle = .roman; $0.place = .end }
        #expect(renamed("Chapter.pdf", [roman], index: 13) == "Chapter XIV.pdf")
    }

    @Test func patternsWithTokens() {
        var info = RenameFileInfo(folder: "Crete")
        info.taken = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 7, day: 14).date
        info.width = 4032
        info.height = 3024
        info.camera = "iPhone"
        let pattern = rule(.pattern) { $0.text = "{folder}_{date}_{n} ({width}x{height}, {camera})"; $0.digits = 2 }
        #expect(renamed("IMG_7.HEIC", [pattern], index: 4, info: info) == "Crete_2026-07-14_05 (4032x3024, iPhone).HEIC")
        let keep = rule(.pattern) { $0.text = "{name}-{original}" }
        #expect(renamed("a.txt", [rule(.insert) { $0.text = "b" }, keep]) == "ab-a.txt")
    }

    @Test func datesAndGreeklish() {
        var info = RenameFileInfo(folder: "x")
        info.modified = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5).date
        let date = rule(.date) { $0.dateSource = .modified; $0.dateFormat = "yyyyMMdd_HHmmss"; $0.place = .start; $0.separator = " " }
        #expect(renamed("scan.pdf", [date], info: info) == "20250102_030405 scan.pdf")
        let greeklish = rule(.transliterate)
        #expect(renamed("Γκρέκα στην Αθήνα.jpg", [greeklish]) == "Greka stin Athina.jpg")
        #expect(renamed("Ευχαριστώ Θεσσαλονίκη.txt", [greeklish]) == "Efcharisto Thessaloniki.txt")
        #expect(renamed("ΕΚΠΑΙΔΕΥΣΗ.pdf", [greeklish]) == "EKPAIDEFSI.pdf")
        let classical = rule(.transliterate) { $0.transliteration = .classical }
        #expect(renamed("Αθήνα.jpg", [classical]) == "Athena.jpg")
    }

    @Test func padSwapExtensionAndOrder() {
        #expect(renamed("photo 7 of 12.jpg", [rule(.padNumbers) { $0.digits = 3 }]) == "photo 007 of 012.jpg")
        #expect(renamed("Artist - Title.mp3", [rule(.swap)]) == "Title - Artist.mp3")
        #expect(renamed("a.JPG", [rule(.ext) { $0.extensionChange = .lower }]) == "a.jpg")
        #expect(renamed("a.jpg", [rule(.ext) { $0.extensionChange = .upper }]) == "a.JPG")
        #expect(renamed("a.jpeg", [rule(.ext) { $0.extensionChange = .change; $0.text = ".jpg" }]) == "a.jpg")
        #expect(renamed("a.tmp", [rule(.ext) { $0.extensionChange = .remove }]) == "a")
        // Rules run in order, and a switched-off rule does nothing.
        var off = rule(.insert) { $0.text = "X" }
        off.isOn = false
        let steps = [rule(.replace) { $0.text = " "; $0.text2 = "_" }, rule(.changeCase) { $0.caseStyle = .upper }, off]
        #expect(renamed("my file.txt", steps) == "MY_FILE.txt")
    }
}

struct RenamePlannerTests {
    @Test func problemsAreFoundBeforeRenaming() throws {
        let folder = try TempFolder()
        let a = try folder.touch("a.txt"), b = try folder.touch("b.txt"), c = try folder.touch("c.txt")
        _ = try folder.touch("taken.txt")
        // Everything becomes "same.txt": a clash.
        let same = rule(.pattern) { $0.text = "same" }
        let clash = RenamePlanner.preview([a, b], rules: [same], infos: [:])
        #expect(clash.allSatisfy { $0.problem == .duplicate })
        // A name of a file that stays: taken. A name freed by another rename: fine.
        let toTaken = rule(.replace) { $0.text = "a"; $0.text2 = "taken" }
        #expect(RenamePlanner.preview([a], rules: [toTaken], infos: [:]).first?.problem == .exists)
        let shift = RenamePlanner.preview([a, b], rules: [rule(.replace) { $0.regex = true; $0.text = "^a$"; $0.text2 = "b" }, rule(.replace) { $0.regex = true; $0.text = "^b$"; $0.text2 = "c" }], infos: [:])
        #expect(shift.map(\.newName) == ["c.txt", "c.txt"], "rules run in order on each name")
        let swap = RenamePlanner.preview([a, b], rules: [rule(.pattern) { $0.text = "{n}"; $0.start = 2; $0.digits = 0 }], infos: [:])
        #expect(swap.map(\.newName) == ["2.txt", "3.txt"])
        // Bad characters and empty names.
        #expect(RenamePlanner.preview([c], rules: [rule(.insert) { $0.text = "/" }], infos: [:]).first?.problem == .invalidCharacters)
        #expect(RenamePlanner.preview([c], rules: [rule(.remove) { $0.removePart = .first; $0.count = 9 }, rule(.ext) { $0.extensionChange = .remove }], infos: [:]).first?.problem == .empty)
        // Only the case changing is not a clash with itself.
        let upper = RenamePlanner.preview([c], rules: [rule(.changeCase) { $0.caseStyle = .upper }], infos: [:])
        #expect(upper.first?.newName == "C.txt" && upper.first?.problem == nil)
    }

    @Test func renamingSwapsAndRollsBack() throws {
        let folder = try TempFolder()
        let a = try folder.touch("a.txt"), b = try folder.touch("b.txt")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)
        // Swapping two names needs the in-between step.
        try Renamer.apply([.init(from: a, to: b), .init(from: b, to: a)])
        #expect(try String(contentsOf: a, encoding: .utf8) == "B")
        #expect(try String(contentsOf: b, encoding: .utf8) == "A")
        // A change of case only.
        let upper = folder.file("A.TXT")
        try Renamer.apply([.init(from: a, to: upper)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).contains("A.TXT"))
        // Into a folder that doesn't exist: fails, and the first rename is undone too.
        let c = try folder.touch("c.txt")
        #expect(throws: (any Error).self) {
            try Renamer.apply([.init(from: c, to: folder.file("d.txt")), .init(from: b, to: folder.file("missing/b.txt"))])
        }
        #expect(FileManager.default.fileExists(atPath: c.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(!FileManager.default.fileExists(atPath: folder.file("d.txt").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix(".pinwheel-rename") }
        #expect(leftovers.isEmpty)
    }

    @Test func dateTakenComesFromThePhoto() throws {
        let folder = try TempFolder()
        let photo = folder.file("p.jpg")
        try Fixtures.makePhoto(at: photo, width: 40, height: 30, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
        ])
        let info = RenameFileInfo.read(photo)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try #require(info.taken))
        #expect(parts.year == 2024 && parts.month == 5 && parts.day == 6 && parts.hour == 7)
        #expect(info.width == 40 && info.height == 30)
        #expect(info.camera == "Test Camera")
        #expect(info.folder == folder.url.lastPathComponent)

        // Ordering by size and by date.
        let small = try folder.touch("z.txt")
        let big = folder.file("a.txt")
        try Data(repeating: 1, count: 5000).write(to: big)
        let infos = [small: RenameFileInfo.read(small), big: RenameFileInfo.read(big)]
        #expect(RenameOrder.size.sorted([big, small], infos: infos, reversed: false) == [small, big])
        #expect(RenameOrder.name.sorted([small, big], infos: infos, reversed: true) == [small, big])
    }
}

// MARK: - Size limit

struct SizeLimitTests {
    @Test func sizesReadLikeFinder() {
        #expect(SizeLimit.title(megabytes: 10) == "10 MB")
        #expect(SizeLimit.title(megabytes: 2.5) == "2.5 MB")
        #expect(SizeLimit.title(bytes: 500_000) == "500 KB")
        #expect(SizeLimit.bytes(megabytes: 1.5) == 1_500_000)
    }

    @Test func picturesFitByQualityThenBySize() async throws {
        let folder = try TempFolder()
        let photo = folder.file("big.png")
        try Fixtures.makePhoto(at: photo, width: 1600, height: 1200)
        let original = try #require(FileSize.of(photo))

        // Some room: quality alone does it, at the full size.
        let roomy: Int64 = 400_000
        let request = ConversionRequest(file: SourceFile(url: photo), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: roomy))
        let result = try await runRequest(request)
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "big (under 400 KB).jpg")
        #expect(try #require(FileSize.of(output)) <= roomy)
        #expect(Fixtures.readImage(output)?.width == 1600)
        #expect(result.note?.contains("quality") == true)

        // Very little room: the picture gets smaller too.
        let tight: Int64 = 25_000
        let small = try await runRequest(ConversionRequest(file: SourceFile(url: photo), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: tight)))
        let smallOutput = try #require(small.outputs.first)
        #expect(try #require(FileSize.of(smallOutput)) <= tight)
        #expect(try #require(Fixtures.readImage(smallOutput)?.width) < 1600)
        #expect(original > roomy)

        // Already under: nothing to do.
        let skip = try await runRequest(ConversionRequest(file: SourceFile(url: photo), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: original + 1)))
        #expect(skip.skipped)
        #expect(skip.note?.contains("Already under") == true)
    }

    @Test func seeThroughPicturesStaySeeThrough() async throws {
        let folder = try TempFolder()
        // A transparency channel, but every pixel opaque (like most screenshots): JPEG.
        let opaque = folder.file("screenshot.png")
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(MediaFixtures.noiseImage(width: 400, height: 300), in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let dest = CGImageDestinationCreateWithURL(opaque as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        #expect(ImageConverter.hasAlpha(opaque) && !ImageConverter.hasTransparentPixels(opaque))
        let limit = (FileSize.of(opaque) ?? 0) / 3
        let flat = try await runConversion(opaque, .tool(.sizeLimit), parameters: .sizeLimit(bytes: limit))
        #expect(flat.pathExtension == "jpg")

        // Really see-through: HEIC, which keeps it.
        let cutout = folder.file("cutout.png")
        try Fixtures.makePhoto(at: cutout, width: 600, height: 400, alpha: true)
        #expect(ImageConverter.hasTransparentPixels(cutout))
        let kept = try await runConversion(cutout, .tool(.sizeLimit), parameters: .sizeLimit(bytes: (FileSize.of(cutout) ?? 0) / 3))
        #expect(kept.pathExtension == "heic")
        #expect(Fixtures.readImage(kept)?.properties[kCGImagePropertyHasAlpha] as? Bool == true)
    }

    @Test func pdfPicturesShrinkUntilItFits() async throws {
        let folder = try TempFolder()
        let pdf = folder.file("scan.pdf")
        try MediaFixtures.makePDF(at: pdf, pages: 2, withPhoto: true)
        let original = try #require(FileSize.of(pdf))
        let limit = original / 3
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: pdf), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: limit)))
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        #expect(try #require(FileSize.of(output)) <= limit)
        #expect(PDFDocument(url: output)?.pageCount == 2)

        // Text and shapes only can't go below a point: said, nothing saved.
        let plain = folder.file("plain.pdf")
        try MediaFixtures.makePDF(at: plain, pages: 1)
        let tooSmall = try await runRequest(ConversionRequest(file: SourceFile(url: plain), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: 100)))
        #expect(tooSmall.skipped)
        #expect(tooSmall.note?.contains("Couldn't get it under") == true)
    }

    @Test func audioPicksABitRateThatFits() async throws {
        let folder = try TempFolder()
        let wav = folder.file("talk.wav")
        try SoundFixtures.tone(at: wav, seconds: 20, peak: 0.3)
        // 20 s in 100 KB leaves about 38 kbit/s: mono, at 32 kbit/s.
        let limit: Int64 = 100_000
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: wav), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: limit)))
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        #expect(output.pathExtension == "m4a")
        #expect(try #require(FileSize.of(output)) <= limit)
        #expect(result.note?.contains("mono") == true)
        #expect(abs(try await SoundFixtures.duration(output) - 20) < 0.3)

        // Far too little room for 20 seconds.
        let impossible = try await runRequest(ConversionRequest(file: SourceFile(url: wav), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: 5_000)))
        #expect(impossible.skipped)
        #expect(impossible.note?.contains("Too long") == true)
    }

    @Test func videoAimsUnderTheLimit() async throws {
        let folder = try TempFolder()
        let movie = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: movie, seconds: 4, width: 640, height: 480, noisy: true)
        let original = try #require(FileSize.of(movie))
        let limit = original / 2
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: movie), action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: limit)))
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        #expect(output.pathExtension == "mp4")
        #expect(try #require(FileSize.of(output)) <= limit)
        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.contains { $0.mediaType == .audio })
    }

    @Test func pictureSizeShrinksWhenBitsRunShort() {
        let probe = VideoCompressor.Probe(size: CGSize(width: 3840, height: 2160), fps: 30, duration: 60, hasSound: true)
        #expect(SizeLimiter.longSide(for: probe, bitRate: 40_000_000) == nil, "plenty: the original size")
        let side = SizeLimiter.longSide(for: probe, bitRate: 1_000_000)
        #expect(side != nil && side! <= 1280)
        #expect(SizeLimiter.audioRate(forTotal: 5_000_000) == 128_000)
        #expect(SizeLimiter.audioRate(forTotal: 500_000) == 64_000)
    }
}

// MARK: - Custom actions

struct RecipeTests {
    @Test func stepsRunInOrderOnWhatTheLastOneMade() async throws {
        let folder = try TempFolder()
        let photo = folder.file("beach.png")
        try Fixtures.makePhoto(at: photo, width: 2000, height: 1500)
        let recipe = Recipe(name: "Square", kind: .image, steps: [.crop(.square), .resize(.fit1080), .convert(.jpeg)])
        #expect(recipe.problem == nil)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: photo), action: .recipe(recipe)))
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        #expect(output.lastPathComponent == "beach (Square).jpg")
        let image = try #require(Fixtures.readImage(output))
        #expect(image.width == 1080 && image.height == 1080)
        #expect(image.type == "public.jpeg")
        // The steps' own files are gone; only the result is left beside the original.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(names == ["beach (Square).jpg", "beach.png"])
    }

    @Test func aStepWithNothingToDoIsPassedOver() async throws {
        let folder = try TempFolder()
        let photo = folder.file("small.png")
        try Fixtures.makePhoto(at: photo, width: 300, height: 200)
        let recipe = Recipe(name: "Web", kind: .image, steps: [.resize(.fit1920), .convert(.heic)])
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: photo), action: .recipe(recipe)))
        let output = try #require(result.outputs.first)
        #expect(output.pathExtension == "heic")
        #expect(result.note?.contains("Fit 1920 px") == true)

        // When no step changes anything, nothing is saved.
        let idle = Recipe(name: "Idle", kind: .image, steps: [.resize(.fit3840)])
        let skipped = try await runRequest(ConversionRequest(file: SourceFile(url: photo), action: .recipe(idle)))
        #expect(skipped.skipped)
    }

    @Test func kindsChangeAlongTheWay() async throws {
        let folder = try TempFolder()
        let movie = folder.file("talk.mov")
        try await MediaFixtures.makeVideo(at: movie, seconds: 2)
        let recipe = Recipe(name: "Podcast", kind: .video, steps: [.extractAudio, .fade(inSeconds: 0.5, outSeconds: 0.5)])
        #expect(recipe.kindsBeforeSteps == [.video, .audio])
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: movie), action: .recipe(recipe)))
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        #expect(output.lastPathComponent == "talk (Podcast).m4a")
        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.map(\.mediaType) == [.audio])
    }

    @Test func problemsAndAvailability() throws {
        #expect(Recipe(name: "", kind: .image, steps: [.compress]).problem == "Give it a name.")
        #expect(Recipe(name: "x", kind: .image).problem == "Add at least one step.")
        let afterText = Recipe(name: "x", kind: .image, steps: [.extractText, .compress])
        #expect(afterText.problem?.contains("can't be changed further") == true)
        let wrongKind = Recipe(name: "x", kind: .audio, steps: [.crop(.square)])
        #expect(wrongKind.problem?.contains("doesn't work on audio") == true)
        #expect(!afterText.replacesOriginal)

        let folder = try TempFolder()
        let movie = try folder.touch("clip.mov")
        let photo = try folder.touch("photo.jpg")
        let mp3 = Recipe(name: "MP3", kind: .video, steps: [.extractAudio, .convert(.mp3)])
        let video = SourceFile(url: movie)
        #expect(ConversionEngine.availability(of: .recipe(mp3), for: [video], ffmpegAvailable: false)
                == .unavailable("To MP3: Needs ffmpeg (brew install ffmpeg)"))
        #expect(ConversionEngine.availability(of: .recipe(mp3), for: [video], ffmpegAvailable: true) == .available)
        #expect(ConversionEngine.availability(of: .recipe(mp3), for: [SourceFile(url: photo)], ffmpegAvailable: true)
                == .unavailable("Made for videos"))

        // A custom action travels to the worker process and back intact.
        let job = ConversionRequest(file: video, action: .recipe(mp3))
        let decoded = try JSONDecoder().decode(ConversionRequest.self, from: try JSONEncoder().encode(job))
        #expect(decoded == job)
    }

    @Test func customActionsSitAfterTheToolsOnTheirKindsWheel() throws {
        let folder = try TempFolder()
        let photo = SourceFile(url: try folder.touch("a.jpg"))
        let pdf = SourceFile(url: try folder.touch("a.pdf"))
        let mine = Recipe(name: "Mine", kind: .image, steps: [.compress])
        var hidden = FormatCatalog.defaultHidden
        let wheel = FormatCatalog.actions(for: [photo], mode: .tools, hidden: hidden, recipes: [mine])
        #expect(wheel.count == FormatCatalog.maxWedges, "the image wheel is full already")
        hidden.insert(FormatCatalog.hiddenKey(.image, .open(.rename)))
        #expect(FormatCatalog.actions(for: [photo], mode: .tools, hidden: hidden, recipes: [mine]).last == .recipe(mine))
        #expect(!FormatCatalog.actions(for: [pdf], mode: .tools, recipes: [mine]).contains(.recipe(mine)))
        #expect(!FormatCatalog.actions(for: [photo], mode: .convert, recipes: [mine]).contains(.recipe(mine)))
    }
}

// MARK: - The wheel's new tools

struct V09CatalogTests {
    @Test func newToolsAndTheirDefaults() throws {
        let folder = try TempFolder()
        let photo = SourceFile(url: try folder.touch("a.jpg"))
        let pdf = SourceFile(url: try folder.touch("a.pdf"))
        let text = SourceFile(url: try folder.touch("notes.txt"))
        let images = FormatCatalog.actions(for: [photo], mode: .tools, hidden: FormatCatalog.defaultHidden)
        #expect(images == [
            .tool(.compress), .open(.sizeLimit), .tool(.resize), .tool(.removeBackground), .open(.crop),
            .open(.adjust), .open(.watermark), .open(.info), .open(.rename),
        ])
        let pdfs = FormatCatalog.actions(for: [pdf], mode: .tools, hidden: FormatCatalog.defaultHidden)
        #expect(pdfs.contains(.tool(.makeSearchable)) && pdfs.count == FormatCatalog.maxWedges)
        // Any file can be renamed, even ones Pinwheel can't convert.
        #expect(FormatCatalog.actions(for: [text], mode: .tools) == [.open(.rename)])
        #expect(FormatCatalog.actions(for: [text], mode: .convert).isEmpty)
        #expect(FormatCatalog.actions(for: [photo, pdf], mode: .tools, hidden: FormatCatalog.defaultHidden).contains(.open(.rename)))
    }

    @Test func outputsAreNamedAfterTheLimit() {
        let file = SourceFile(url: URL(fileURLWithPath: "/tmp/movie.mov"))
        let plan = OutputPlanner.plan(ConversionRequest(file: file, action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: 25_000_000)), options: ConversionOptions())
        #expect(plan.suffix == "under 25 MB" && plan.fileExtension == "mp4")
        let scan = SourceFile(url: URL(fileURLWithPath: "/tmp/scan.pdf"))
        let searchable = OutputPlanner.plan(ConversionRequest(file: scan, action: .tool(.makeSearchable)), options: ConversionOptions())
        #expect(searchable.suffix == "searchable" && searchable.fileExtension == "pdf")
        let recipe = Recipe(name: "Share", kind: .image, steps: [.convert(.pdf), .compress])
        let photo = SourceFile(url: URL(fileURLWithPath: "/tmp/photo.png"))
        let planned = OutputPlanner.plan(ConversionRequest(file: photo, action: .recipe(recipe)), options: ConversionOptions())
        #expect(planned.suffix == "Share" && planned.fileExtension == "pdf")
    }
}

// MARK: - Text recognition

/// A picture of some lines of text, as a scanner would make it.
func textPicture(_ text: String, width: Int = 1600, height: Int = 500, fontSize: CGFloat = 54) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    (text as NSString).draw(in: NSRect(x: 40, y: 20, width: width - 80, height: height - 40), withAttributes: [
        .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black,
    ])
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

/// A PDF whose one page is only a picture (a scan), with no text in it.
func scannedPDF(at url: URL, _ text: String) throws {
    let picture = textPicture(text)
    var box = CGRect(x: 0, y: 0, width: 576, height: 180)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    ctx.draw(picture, in: box)
    ctx.endPDFPage()
    ctx.closePDF()
}

/// Tesseract with Greek, when this Mac has it (Settings downloads it).
enum TesseractSetup {
    static var greek: TextRecognition? {
        guard let program = ExternalTool.tesseract.locate() else { return nil }
        var recognition = TextRecognition()
        recognition.engine = .tesseract
        recognition.tesseractURL = program
        recognition.languages = ["ell", "eng"]
        if TesseractData.languages(in: TesseractData.ownFolder).contains("ell") {
            try? TesseractData.linkBuiltIn(TesseractData.builtInFolder(for: program), into: TesseractData.ownFolder)
            recognition.dataFolder = TesseractData.ownFolder
        } else if !TesseractData.languages(in: TesseractData.builtInFolder(for: program)).contains("ell") {
            return nil
        }
        return recognition
    }
}

struct TextRecognitionTests {
    @Test func visionGivesWordsAndWhereTheyAre() async throws {
        let text = try await TextRecognizer.recognize(textPicture("Pinwheel reads text\nSecond line here"), settings: TextRecognition())
        #expect(text.string.contains("Pinwheel reads text"))
        #expect(text.lines.count == 2)
        let first = try #require(text.lines.first?.words.first)
        #expect(first.text == "Pinwheel")
        #expect(first.box.minX < 0.2 && first.box.minY < 0.5, "top left, from the top")
        #expect(text.lines.flatMap(\.words).allSatisfy { $0.box.width > 0 && $0.box.maxX <= 1.01 })
    }

    @Test func tesseractTablesBecomeLinesAndParagraphs() {
        let table = """
            level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
            1\t1\t0\t0\t0\t0\t0\t0\t1000\t500\t-1\t
            5\t1\t1\t1\t1\t1\t10\t10\t100\t40\t95\tΚαλημέρα
            5\t1\t1\t1\t1\t2\t120\t10\t80\t40\t95\tκόσµε
            5\t1\t1\t1\t2\t1\t10\t60\t100\t40\t90\tline
            5\t1\t2\t1\t1\t1\t10\t200\t100\t40\t90\tNew
            """
        let text = TextRecognizer.parseTSV(table, width: 1000, height: 500)
        #expect(text.string == "Καλημέρα κόσμε\nline\n\nNew", "µ inside Greek is μ, and a new block is a new paragraph")
        #expect(text.lines[0].words[1].box == CGRect(x: 0.12, y: 0.02, width: 0.08, height: 0.08))
    }

    @Test(.enabled(if: TesseractSetup.greek != nil, "needs Tesseract with Greek"))
    func greekIsReadWithTesseract() async throws {
        let recognition = try #require(TesseractSetup.greek)
        let picture = textPicture("Καλημέρα κόσμε από την Αθήνα\nGood morning from Athens")
        let text = try await TextRecognizer.recognize(picture, settings: recognition).string
        #expect(text.contains("Καλημέρα"))
        #expect(text.contains("Αθήνα"))
        #expect(text.contains("Athens"))
    }

    @Test func missingLanguagesAreExplained() async throws {
        guard let program = ExternalTool.tesseract.locate() else { return }
        var recognition = TextRecognition()
        recognition.engine = .tesseract
        recognition.tesseractURL = program
        recognition.languages = ["xyz"]
        await #expect(throws: ConversionError.self) {
            _ = try await TextRecognizer.recognize(textPicture("abc"), settings: recognition)
        }
    }
}

struct SearchablePDFTests {
    @Test func scannedPagesGetInvisibleText() async throws {
        let folder = try TempFolder()
        let scan = folder.file("letter.pdf")
        try scannedPDF(at: scan, "Invoice number 4521\nPaid in full")
        #expect((PDFDocument(url: scan)?.page(at: 0)?.string ?? "").isEmpty, "a scan has no text to start with")

        let result = try await runRequest(ConversionRequest(file: SourceFile(url: scan), action: .tool(.makeSearchable)))
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        #expect(output.lastPathComponent == "letter (searchable).pdf")
        let document = try #require(PDFDocument(url: output))
        let text = document.page(at: 0)?.string ?? ""
        #expect(text.contains("Invoice"))
        #expect(text.contains("4521"))
        #expect(!document.findString("Paid", withOptions: .caseInsensitive).isEmpty, "search finds it")

        // The page looks the same: the text is there, but not drawn.
        let before = try PDFConverter.render(try #require(CGPDFDocument(scan as CFURL)?.page(at: 1)), dpi: 72)
        let after = try PDFConverter.render(try #require(CGPDFDocument(output as CFURL)?.page(at: 1)), dpi: 72)
        #expect(before.width == after.width && before.height == after.height)
        var different = 0
        for x in stride(from: 0, to: before.width, by: 7) {
            for y in stride(from: 0, to: before.height, by: 7) {
                let a = Fixtures.pixel(before, x: x, y: y), b = Fixtures.pixel(after, x: x, y: y)
                if abs(Int(a.r) - Int(b.r)) > 40 { different += 1 }
            }
        }
        #expect(different < 5, "\(different) spots look different")

        // Run again on the result: every page has text now.
        let again = try await runRequest(ConversionRequest(file: SourceFile(url: output), action: .tool(.makeSearchable)))
        #expect(again.skipped)
    }

    @Test(.enabled(if: TesseractSetup.greek != nil, "needs Tesseract with Greek"))
    func greekScansBecomeSearchable() async throws {
        let folder = try TempFolder()
        let scan = folder.file("greek.pdf")
        try scannedPDF(at: scan, "Βεβαίωση σπουδών\nΘεσσαλονίκη 2026")
        var options = ConversionOptions()
        options.textRecognition = try #require(TesseractSetup.greek)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: scan), action: .tool(.makeSearchable)), options: options)
        let output = try #require(result.outputs.first, "\(result.note ?? "")")
        let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(text.contains("Βεβαίωση"))
        #expect(text.contains("2026"))

        // Get Text reads Greek too.
        let textResult = try await runRequest(ConversionRequest(file: SourceFile(url: scan), action: .tool(.extractText)), options: options)
        let file = try #require(textResult.outputs.first)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Θεσσαλονίκη"))
    }
}

struct TesseractDataTests {
    @Test func aDownloadedLanguageSitsBesideTesseractsOwn() throws {
        let folder = try TempFolder()
        let builtIn = folder.url.appendingPathComponent("share/tessdata", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 300_000).write(to: builtIn.appendingPathComponent("eng.traineddata"))
        let own = folder.url.appendingPathComponent("Pinwheel/tessdata", isDirectory: true)

        // An error page instead of the file is refused.
        let broken = folder.file("broken.download")
        try Data("Not Found".utf8).write(to: broken)
        #expect(throws: ConversionError.self) { try TesseractData.install(broken, code: "ell", into: own, linking: builtIn) }

        let download = folder.file("ell.download")
        try Data(repeating: 2, count: 300_000).write(to: download)
        try TesseractData.install(download, code: "ell", into: own, linking: builtIn)
        #expect(TesseractData.languages(in: own) == ["ell", "eng"])
        #expect(!FileManager.default.fileExists(atPath: download.path), "moved, not copied")
        // Doing it again (a newer Tesseract) is fine.
        try TesseractData.linkBuiltIn(builtIn, into: own)
        #expect(TesseractData.languages(in: own) == ["ell", "eng"])

        let program = URL(fileURLWithPath: "/opt/homebrew/bin/tesseract")
        #expect(TesseractData.builtInFolder(for: program).path.hasSuffix("share/tessdata"))
    }
}

// MARK: - Phone videos (filmed upright, stored sideways)

struct PortraitVideoTests {
    /// How a phone stores a video held upright: landscape pixels, turned a quarter.
    static let upright = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)

    @Test func turningStartsFromHowItIsShown() async throws {
        let folder = try TempFolder()
        let movie = folder.file("phone.mov")
        try await MediaFixtures.makeVideo(at: movie, seconds: 2, width: 320, height: 180, noisy: true, transform: Self.upright)
        let shown = try await VideoCompressor.probe(movie).size
        #expect(shown == CGSize(width: 180, height: 320))

        var edit = MediaEdit()
        edit.quarterTurns = 1
        let turned = try await runConversion(movie, .tool(.editMedia), parameters: .media(edit))
        #expect(try await VideoCompressor.probe(turned).size == CGSize(width: 320, height: 180))

        // A frame is saved upright, as shown, and turned when asked.
        let frame = try await runConversion(movie, .tool(.saveFrame), parameters: .frame(seconds: 0.5, quarterTurns: 0))
        let picture = try #require(Fixtures.readImage(frame))
        #expect(picture.width == 180 && picture.height == 320)

        // A size limit keeps it upright too (smaller, if that's what fits).
        let limit = (FileSize.of(movie) ?? 0) * 7 / 10
        let limited = try await runConversion(movie, .tool(.sizeLimit), parameters: .sizeLimit(bytes: limit))
        let limitedSize = try await VideoCompressor.probe(limited).size
        #expect(limitedSize.height > limitedSize.width)
        #expect(try #require(FileSize.of(limited)) <= limit)
    }
}
