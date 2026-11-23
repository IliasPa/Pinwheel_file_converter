import AppKit
import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

struct ScreenshotNamingTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func fileIsNamedAfterTheAppAndTheMinute() {
        let name = ScreenshotController.fileName(app: "Safari", date: date(2026, 11, 23, 14, 5), extension: "png") { _ in false }
        #expect(name == "Safari_20261123_1405.png")
        let none = ScreenshotController.fileName(app: "", date: date(2026, 1, 2, 9, 30), extension: "jpg") { _ in false }
        #expect(none == "Screenshot_20260102_0930.jpg")
    }

    @Test func slashesAndColonsAreKeptOutOfNames() {
        let name = ScreenshotController.fileName(app: "A/B: C", date: date(2026, 11, 23, 14, 5), extension: "png") { _ in false }
        #expect(name == "A-B- C_20261123_1405.png")
    }

    @Test func twoInTheSameMinuteDontClash() {
        var taken: Set<String> = ["Mail_20261123_1405.png", "Mail_20261123_1405_2.png"]
        let name = ScreenshotController.fileName(app: "Mail", date: date(2026, 11, 23, 14, 5), extension: "png") { taken.contains($0) }
        #expect(name == "Mail_20261123_1405_3.png")
        taken.insert(name)
    }
}

struct ScreenshotCodeTests {
    @Test func aCodeIsCopiedWithOrWithoutWords() {
        #expect(ScreenshotController.copied(text: "", codes: []) == nil)
        #expect(ScreenshotController.copied(text: "  \n", codes: []) == nil)
        let words = ScreenshotController.copied(text: "Hello\nworld", codes: [])
        #expect(words?.text == "Hello\nworld")
        #expect(words?.title == "Copied 11 characters")
        let qr = ReadCode(text: "https://example.com", kind: "QR code")
        let code = ScreenshotController.copied(text: "", codes: [qr])
        #expect(code?.text == "https://example.com")
        #expect(code?.title == "Copied a QR code")
        let both = ScreenshotController.copied(text: "Scan me", codes: [qr, qr])
        #expect(both?.text == "Scan me\n\nhttps://example.com", "the same code twice is copied once")
        #expect(both?.title == "Copied the text and a QR code")
        let two = ScreenshotController.copied(text: "", codes: [qr, ReadCode(text: "123", kind: "EAN-13 barcode")])
        #expect(two?.text == "https://example.com\n123")
        #expect(two?.title == "Copied 2 codes")
    }
}

struct ScreenshotScaleTests {
    @Test func aRetinaPictureShrinksToItsOnScreenSize() throws {
        let context = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let image = try #require(context.makeImage())
        let small = try #require(ScreenshotController.reduced(image, by: 2))
        #expect(small.width == 200 && small.height == 100)
        #expect(ScreenshotController.reduced(image, by: 3)?.width == 133)
    }

    @Test func aFileIsShrunkInPlace() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("r.png")
        let context = CGContext(
            data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        #expect(ScreenshotController.writePNG(context.makeImage()!, to: file))
        #expect(ScreenshotController.reduce(file, by: 2))
        let size = NSImage(contentsOf: file)?.representations.first
        #expect(size?.pixelsWide == 150 && size?.pixelsHigh == 50)
        #expect(!ScreenshotController.reduce(file, by: 1), "1× leaves it alone")
    }

    @Test func settingsHaveTheNewSwitches() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = SettingsStore(defaults: defaults)
        #expect(!store.screenshotCursor)
        #expect(store.screenshotFullResolution)
        store.screenshotCursor = true
        store.screenshotFullResolution = false
        let again = SettingsStore(defaults: defaults)
        #expect(again.screenshotCursor)
        #expect(!again.screenshotFullResolution)
    }
}

struct ScreenshotHistoryTests {
    private func file(_ scratch: Scratch, _ name: String) -> URL {
        let url = scratch.url.appendingPathComponent(name)
        try? Data([1]).write(to: url)
        return url
    }

    @Test func newestFirstSavedAndForgottenWhenTheFileIsGone() throws {
        let scratch = try Scratch()
        let list = scratch.url.appendingPathComponent("history.json")
        let history = ScreenshotHistory(file: list)
        let a = file(scratch, "a.png"), b = file(scratch, "b.png")
        history.add(a, app: "Safari")
        history.add(b, app: "")
        #expect(history.entries.map(\.path) == [b.path, a.path])
        history.add(a, app: "Safari")  // again: moves to the front, once
        #expect(history.entries.map(\.path) == [a.path, b.path])

        let back = ScreenshotHistory(file: list)
        #expect(back.entries.map(\.path) == [a.path, b.path])
        #expect(back.entries.first?.app == "Safari")
        try FileManager.default.removeItem(at: b)
        #expect(ScreenshotHistory(file: list).entries.map(\.path) == [a.path])

        let kept = ScreenshotHistory(file: list)
        let c = file(scratch, "c.png")
        kept.add(c, app: "")
        kept.remove(kept.entries[0])
        #expect(ScreenshotHistory(file: list).entries.map(\.path) == [a.path])
        kept.removeAll()
        #expect(ScreenshotHistory(file: list).entries.isEmpty)
    }

    @Test func keepsOnlyTheLastFew() throws {
        let scratch = try Scratch()
        let history = ScreenshotHistory(file: scratch.url.appendingPathComponent("h.json"))
        for number in 0..<(ScreenshotHistory.limit + 5) {
            history.add(file(scratch, "\(number).png"), app: "")
        }
        #expect(history.entries.count == ScreenshotHistory.limit)
        #expect(history.entries.first?.url.lastPathComponent == "\(ScreenshotHistory.limit + 4).png")
    }
}

struct EditorZoomTests {
    private func model() async throws -> (StudioModel, Scratch) {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("z.png")
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let model = StudioModel(files: [SourceFile(url: file)], tab: .markup)
        for _ in 0..<500 where model.preview == nil || model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        model.canvasSize = CGSize(width: 400, height: 400)
        return (model, scratch)
    }

    @Test func fitsAtFirstAndZoomsAroundAPoint() async throws {
        let (model, scratch) = try await model()
        _ = scratch
        let fit = model.imageRect(in: model.canvasSize)
        #expect(fit.width == 400 && fit.height == 200 && fit.midX == 200 && fit.midY == 200)
        #expect(model.zoomText == "100%" && !model.isZoomed)

        // Zooming around the left of the picture keeps that spot in place.
        let spot = CGPoint(x: 100, y: 200)
        let before = (spot.x - fit.minX) / fit.width
        model.setZoom(2, around: spot)
        let zoomed = model.imageRect(in: model.canvasSize)
        #expect(zoomed.width == 800 && model.zoomText == "200%")
        #expect(abs((spot.x - zoomed.minX) / zoomed.width - before) < 0.001)
        #expect(zoomed.minX <= 0 && zoomed.maxX >= 400, "no gap at the sides")
    }

    @Test func panStopsAtTheEdgesAndFitResets() async throws {
        let (model, scratch) = try await model()
        _ = scratch
        model.panBy(CGSize(width: 50, height: 50))
        #expect(model.pan == .zero, "nothing to move at 100%")
        model.setZoom(2)
        model.panBy(CGSize(width: 10_000, height: 10_000))
        let rect = model.imageRect(in: model.canvasSize)
        #expect(rect.minX == 0, "the picture's left edge stops at the window's")
        #expect(rect.height == 400 && rect.minY == 0, "400 tall just fits: it can't move up or down")
        model.zoomToFit()
        #expect(model.zoom == 1 && model.pan == .zero)
        model.setZoom(50)
        #expect(model.zoom == StudioModel.zoomRange.upperBound)
        model.zoomOut()
        #expect(model.zoom < StudioModel.zoomRange.upperBound)
    }
}

struct AutoBlurTests {
    private func kinds(_ text: String, _ wanted: Set<PrivacyBlur.Kind> = [.emails, .numbers]) -> [(PrivacyBlur.Kind, String)] {
        PrivacyBlur.matches(in: text, kinds: wanted).map { ($0.0, String(text[$0.1])) }
    }

    @Test func findsAddressesAndNumbers() {
        let found = kinds("Write to ann.lee+x@mail.example.org or call +30 210 123 4567 today")
        #expect(found.contains { $0.0 == .emails && $0.1 == "ann.lee+x@mail.example.org" })
        #expect(found.contains { $0.0 == .numbers && $0.1.contains("210 123 4567") })
        #expect(found.count == 2)
    }

    @Test func shortNumbersAndWordsAreLeftAlone() {
        #expect(kinds("Page 12 of 30, 2 items").isEmpty)
        #expect(kinds("Card 4111 1111 1111 1111").first?.1.hasSuffix("1111") == true)
        #expect(kinds("PIN 4821").count == 1)
        #expect(kinds("a@b.c").isEmpty, "needs a real domain")
        #expect(kinds("x@y.org", [.numbers]).isEmpty, "only what was asked for")
    }

    @Test func aDigitsInsideAnAddressAreNotAlsoANumber() {
        let found = kinds("user12345@example.com")
        #expect(found.count == 1 && found[0].0 == .emails)
    }

    @Test func oldEditsHaveNoAutoTag() throws {
        let json = #"{"id":"6F6E1D6A-1B0F-4C5C-9E52-0F3A5A5C2B11","kind":"redact","points":[{"x":0,"y":0},{"x":1,"y":1}],"color":{"red":0,"green":0,"blue":0,"alpha":1},"size":0.01,"text":""}"#
        let note = try? JSONDecoder().decode(Annotation.self, from: Data(json.utf8))
        if let note { #expect(note.auto == "") }
        let tagged = Annotation(kind: .redact, points: [], color: .black, size: 0.01, auto: "faces")
        let back = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(tagged))
        #expect(back.auto == "faces")
    }

    @Test func switchingOffTakesAwayOnlyThatKind() async throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("p.png")
        let context = CGContext(
            data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let model = StudioModel(files: [SourceFile(url: file)], tab: .markup)
        model.undoManager.groupsByEvent = false
        for _ in 0..<500 where model.preview == nil || model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        let box = [RelativePoint(x: 0.1, y: 0.1), RelativePoint(x: 0.3, y: 0.3)]
        let found = PrivacyBlur.annotations(for: [PrivacyBlur.Found(kind: .faces, rect: RelativeRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))])
        #expect(found.first?.auto == "faces")
        _ = box
        model.beginMarkupForTesting(found + [Annotation(kind: .rectangle, points: box, color: .black, size: 0.01)])
        #expect(model.isAutoBlurOn(.faces) && !model.isAutoBlurOn(.emails))
        model.setAutoBlur(.faces, on: false)
        #expect(!model.isAutoBlurOn(.faces))
        #expect(model.edit.markup.count == 1 && model.edit.markup[0].kind == .rectangle, "drawn marks stay")
    }
}

/// One Blur tool (blocks or smooth) with the switches in its settings, Pixel
/// Zoom as a tool, and no Erase tool, Erase Selection or Clear All buttons.
@MainActor
struct BlurAndZoomToolTests {
    /// White, with a black bar from x = 40 to 60.
    private func model() async throws -> (StudioModel, Scratch) {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("bar.png")
        let ctx = CGContext(
            data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 0, width: 20, height: 60))
        let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let model = StudioModel(files: [SourceFile(url: file)], tab: .markup)
        model.undoManager.groupsByEvent = false
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("PinwheelTest-\(UUID().uuidString)"))
        for _ in 0..<500 where model.preview == nil || model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.preview != nil)
        return (model, scratch)
    }

    @Test func theGridHasOneBlurAndPixelZoomAsATool() {
        let titles = MarkupPanel.tools.map(\.1)
        #expect(titles.filter { $0 == "Blur" }.count == 1)
        #expect(!titles.contains("Blur Out") && !titles.contains("Soft Blur"))
        #expect(titles.contains("Pixel Zoom") && !titles.contains("Erase"))
        #expect(!MarkupPanel.tools.contains { $0.0 == .mark(.erase) }, "Backspace deletes; there's no Erase tool")
        #expect(Set(titles).count == titles.count, "each once")
    }

    @Test func blurIsOneToolInBlocksOrSmoothAndRemembersWhich() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        #expect(!model.showsBlurSettings)
        MarkupPanel.choose(.blur, in: model)
        #expect(model.tool == .redact && model.isBlurTool && model.showsBlurSettings, "blocks at first")
        #expect(MarkupPanel.isOn(.blur, in: model) && !MarkupPanel.isOn(.mark(nil), in: model))
        model.setBlurStyle(.blur)
        #expect(model.tool == .blur && MarkupPanel.isOn(.blur, in: model))
        MarkupPanel.choose(.mark(.arrow), in: model)
        #expect(!model.showsBlurSettings, "the switches show only with Blur")
        MarkupPanel.choose(.blur, in: model)
        #expect(model.tool == .blur, "smooth, as chosen last")
    }

    @Test func blurPicksUpABlurThatsThereAndAStyleChangeChangesIt() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        let box = PrivacyBlur.annotations(for: [PrivacyBlur.Found(kind: .faces, rect: RelativeRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))])
        model.beginMarkupForTesting(box)
        MarkupPanel.choose(.blur, in: model)
        model.beginMarkup(at: RelativePoint(x: 0.3, y: 0.3))
        model.continueMarkup(to: RelativePoint(x: 0.35, y: 0.3))
        model.endMarkup()
        #expect(model.edit.markup.count == 1, "no new blur drawn")
        #expect(model.selection == box[0].id)
        #expect(abs(model.edit.markup[0].points[0].x - 0.25) < 0.001, "moved")
        model.setBlurStyle(.blur)
        #expect(model.edit.markup[0].kind == .blur, "the selected blur turns smooth")
        model.deleteKey()
        #expect(model.edit.markup.isEmpty, "Backspace deletes it")

        // Elsewhere, a drag draws a new one.
        model.beginMarkup(at: RelativePoint(x: 0.6, y: 0.6))
        model.continueMarkup(to: RelativePoint(x: 0.9, y: 0.9))
        model.endMarkup()
        #expect(model.edit.markup.count == 1 && model.edit.markup[0].kind == .blur)
    }

    @Test func blursFoundByThemselvesGetTheStyleAndAllTextIsASwitchLikeTheOthers() {
        #expect(PrivacyBlur.Kind.allCases == [.faces, .emails, .numbers, .text])
        #expect(PrivacyBlur.Kind.allCases.map(\.title) == ["Faces", "E-mail addresses", "Numbers", "All text"])
        let found = [PrivacyBlur.Found(kind: .text, rect: RelativeRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1))]
        #expect(PrivacyBlur.annotations(for: found).first?.kind == .redact)
        let smooth = PrivacyBlur.annotations(for: found, style: .blur)
        #expect(smooth.first?.kind == .blur && smooth.first?.auto == "text")
    }

    @Test func allTextSwitchesOffLikeTheOthers() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        let lines = PrivacyBlur.annotations(for: [PrivacyBlur.Found(kind: .text, rect: RelativeRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1))])
        let face = PrivacyBlur.annotations(for: [PrivacyBlur.Found(kind: .faces, rect: RelativeRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))])
        model.beginMarkupForTesting(lines + face)
        #expect(model.isAutoBlurOn(.text) && model.isAutoBlurOn(.faces))
        model.setAutoBlur(.text, on: false)
        #expect(!model.isAutoBlurOn(.text) && model.isAutoBlurOn(.faces))
    }

    @Test func pixelZoomIsAToolAndAClickCopiesTheColor() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        MarkupPanel.choose(.pixelZoom, in: model)
        #expect(model.isPixelZoomTool && MarkupPanel.isOn(.pixelZoom, in: model) && !MarkupPanel.isOn(.mark(nil), in: model))
        model.hover = CGPoint(x: 0.5, y: 0.5)
        #expect(model.showsZoom)
        model.beginMarkup(at: model.markupPoint(fromShown: CGPoint(x: 0.5, y: 0.5)))
        model.endMarkup()
        #expect(model.pasteboard.string(forType: .string) == "#000000", "the bar is black")
        #expect(model.colorNote == "Copied #000000.")
        #expect(model.edit.markup.isEmpty, "nothing drawn")

        MarkupPanel.choose(.mark(.arrow), in: model)
        #expect(!model.isPixelZoomTool && !model.showsZoom, "another tool ends it")
        MarkupPanel.choose(.pixelZoom, in: model)
        MarkupPanel.choose(.mark(nil), in: model)
        #expect(!model.isPixelZoomTool && MarkupPanel.isOn(.mark(nil), in: model), "Select ends it too")
    }
}

struct AutoBlurVisionTests {
    @Test func findsTheAddressAndTheNumberInADrawnLine() throws {
        let size = CGSize(width: 900, height: 200)
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        NSAttributedString(string: "Mail ann.lee@example.org", attributes: attributes).draw(at: CGPoint(x: 20, y: 120))
        NSAttributedString(string: "Phone 210 123 4567", attributes: attributes).draw(at: CGPoint(x: 20, y: 40))
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())

        let found = try PrivacyBlur.find(kinds: [.emails, .numbers], in: image)
        let email = try #require(found.first { $0.kind == .emails })
        let number = try #require(found.first { $0.kind == .numbers })
        // The address is on the top line, to the right of the word "Mail": the box starts after it.
        // The boxes cover the address and the number (Vision's box for part of a
        // line is approximate at the start, so only what must be covered is checked).
        #expect(email.rect.y < 0.5 && email.rect.x < 0.2 && email.rect.x + email.rect.width > 0.55)
        #expect(number.rect.y > 0.5 && number.rect.x < 0.25 && number.rect.x + number.rect.width > 0.45)
        #expect(email.rect.x + email.rect.width < 0.8, "not the whole width of the picture")
        #expect(try PrivacyBlur.find(kinds: [], in: image).isEmpty)

        // All text: a box for each line, from its first word.
        let lines = try PrivacyBlur.find(kinds: [.text], in: image)
        #expect(lines.count == 2 && lines.allSatisfy { $0.kind == .text })
        #expect(lines.allSatisfy { $0.rect.x < 0.05 }, "the words before the address and the number too")
    }
}

/// Builds Pinwheel's menu-bar menu for tests (the controller lives as long as the menu).
@MainActor
enum MenuBarTesting {
    final class Calls {
        var used: [ScreenshotEntry] = []
        var edited: [ScreenshotEntry] = []
    }

    nonisolated(unsafe) private static var ownerKey: UInt8 = 0

    /// A real little picture, so it has a thumbnail.
    static func picture(_ scratch: Scratch, _ name: String, width: Int = 320, height: Int = 200) throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let url = scratch.url.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    static func menu(history: ScreenshotHistory?, screenshotsOn: Bool = true, calls: Calls = Calls()) -> NSMenu {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "PinwheelMenuTest-\(UUID().uuidString)")!)
        let controller = MenuBarController(
            actions: .init(
                showSettings: {}, showProgress: {}, showFFmpegHelp: {}, showFeedback: {}, toggleShelf: {},
                useScreenshot: { calls.used.append($0) },
                editScreenshot: { calls.edited.append($0) },
                quit: {}
            ),
            clipboardShortcut: { settings.clipboardShortcut },
            screenshotShortcuts: { screenshotsOn ? settings.screenshotShortcuts : nil },
            screenshotHistory: { history },
            recents: RecentsStore(defaults: UserDefaults(suiteName: "PinwheelMenuTest-\(UUID().uuidString)")!),
            history: UndoHistory(),
            launch: LaunchAtLogin(),
            isTrusted: { true },
            hasFFmpeg: { true }
        )
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        // Menu items hold their target weakly: the menu keeps the controller.
        objc_setAssociatedObject(menu, &ownerKey, controller, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }
}

/// The menu-bar icon › Screenshot History, right under Clipboard History.
@MainActor
struct MenuBarScreenshotHistoryTests {
    private typealias Calls = MenuBarTesting.Calls

    @Test func itIsRightUnderClipboardHistory() throws {
        let scratch = try Scratch()
        let history = ScreenshotHistory(file: scratch.url.appendingPathComponent("history.json"))
        history.add(try MenuBarTesting.picture(scratch, "Safari_20261123_1405.png"), app: "Safari")
        let titles = MenuBarTesting.menu(history: history).items.map(\.title)
        let clipboard = try #require(titles.firstIndex(of: "Clipboard History"))
        #expect(titles[clipboard + 1] == "Screenshot History")
        #expect(titles[clipboard + 2] == "Screenshot")
    }

    @Test func eachScreenshotIsListedNewestFirstWithAPictureAndAnEditLineUnderOption() async throws {
        let scratch = try Scratch()
        let history = ScreenshotHistory(file: scratch.url.appendingPathComponent("history.json"))
        let older = try MenuBarTesting.picture(scratch, "Screenshot_20261123_1751.png")
        let newer = try MenuBarTesting.picture(scratch, "Preview_20261123_1754.png", width: 200, height: 400)
        history.add(older, app: "")
        history.add(newer, app: "Preview")
        let calls = Calls()
        let menu = MenuBarTesting.menu(history: history, calls: calls)
        let list = try #require(menu.items.first { $0.title == "Screenshot History" }?.submenu)

        let first = list.items[0], firstEdit = list.items[1], second = list.items[2]
        #expect(first.title == "Preview_20261123_1754.png")
        #expect(first.subtitle?.hasSuffix("· Preview") == true)
        #expect(!first.isAlternate)
        #expect(firstEdit.title == "Edit Preview_20261123_1754.png…")
        #expect(firstEdit.isAlternate && firstEdit.keyEquivalentModifierMask == .option)
        #expect(second.title == "Screenshot_20261123_1751.png")
        #expect(second.subtitle?.contains("·") == false)  // no app: just when

        // Thumbnails fit the menu and keep their shape.
        let tall = try #require(first.image?.size), wide = try #require(second.image?.size)
        #expect(tall.width <= 48 && tall.height <= 30 && wide.width <= 48 && wide.height <= 30)
        #expect(abs(tall.width / tall.height - 0.5) < 0.05)
        #expect(abs(wide.width / wide.height - 1.6) < 0.05)

        list.performActionForItem(at: 1)  // ⌥: edit
        #expect(calls.edited.map(\.path) == [newer.path])
        list.performActionForItem(at: 2)  // click: paste or copy (after the menu closes)
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.used.map(\.path) == [older.path])

        let clear = try #require(list.items.firstIndex { $0.title == "Clear Screenshot History" })
        list.performActionForItem(at: clear)
        #expect(history.entries.isEmpty)
    }

    @Test func atMostTenAreListedAndTheRestAreOneClickAway() throws {
        let scratch = try Scratch()
        let history = ScreenshotHistory(file: scratch.url.appendingPathComponent("history.json"))
        for index in 0..<12 { history.add(try MenuBarTesting.picture(scratch, "shot\(index).png", width: 8, height: 8), app: "") }
        let list = try #require(MenuBarTesting.menu(history: history).items.first { $0.title == "Screenshot History" }?.submenu)
        #expect(list.items.filter { $0.action != nil && !$0.isAlternate && $0.title.hasPrefix("shot") }.count == MenuBarController.screenshotsListed)
        #expect(list.items.contains { $0.title == "Show All 12 in Clipboard History" })
    }

    @Test func noneYetSaysHowToStartAndOffWithNoneHidesIt() throws {
        let scratch = try Scratch()
        let empty = ScreenshotHistory(file: scratch.url.appendingPathComponent("history.json"))
        let list = try #require(MenuBarTesting.menu(history: empty).items.first { $0.title == "Screenshot History" }?.submenu)
        #expect(list.items.count == 1)
        #expect(list.items[0].title.hasPrefix("No screenshots yet") && !list.items[0].isEnabled)

        #expect(!MenuBarTesting.menu(history: empty, screenshotsOn: false).items.contains { $0.title == "Screenshot History" })
        // Screenshots switched off, but some were taken before: still listed.
        empty.add(try MenuBarTesting.picture(scratch, "kept.png", width: 8, height: 8), app: "")
        #expect(MenuBarTesting.menu(history: empty, screenshotsOn: false).items.contains { $0.title == "Screenshot History" })
    }

    @Test func aScreenshotThatWasDeletedIsLeftOut() throws {
        let scratch = try Scratch()
        let history = ScreenshotHistory(file: scratch.url.appendingPathComponent("history.json"))
        let gone = try MenuBarTesting.picture(scratch, "gone.png", width: 8, height: 8)
        history.add(try MenuBarTesting.picture(scratch, "here.png", width: 8, height: 8), app: "")
        history.add(gone, app: "")
        try FileManager.default.removeItem(at: gone)
        let list = try #require(MenuBarTesting.menu(history: history).items.first { $0.title == "Screenshot History" }?.submenu)
        #expect(!list.items.contains { $0.title.contains("gone.png") })
        #expect(list.items.first?.title == "here.png")
    }
}
