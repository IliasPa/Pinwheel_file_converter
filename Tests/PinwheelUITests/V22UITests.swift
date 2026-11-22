import AppKit
import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

struct ScreenshotSettingsTests {
    private func freshStore(_ name: String = "PinwheelTests-\(UUID().uuidString)") -> (SettingsStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (SettingsStore(defaults: defaults), defaults)
    }

    @Test func defaultsAreSensible() {
        let (store, _) = freshStore()
        #expect(store.screenshotsEnabled)
        #expect(store.screenshotAfter == .edit)
        #expect(store.screenshotCopy)
        #expect(store.screenshotFormat == .png)
        #expect(store.screenshotDelay == 0)
        #expect(store.lastScreenshotArea == nil)
        for mode in ScreenshotMode.allCases {
            #expect(store.screenshotShortcuts[mode] == mode.defaultShortcut)
            #expect(mode.defaultShortcut.isUsable && !mode.defaultShortcut.isReserved)
        }
        // No two ways share keys, and none takes macOS's ⇧⌘3/4/5.
        let titles = ScreenshotMode.allCases.map { $0.defaultShortcut.title }
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.contains("⇧") })
    }

    @Test func choicesAreKept() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let (store, defaults) = freshStore(name)
        store.screenshotAfter = .pin
        store.screenshotDelay = 5
        store.screenshotFormat = .heic
        store.screenshotCopy = false
        store.screenshotFolderPath = "/tmp/shots"
        store.screenshotShortcuts[.area] = KeyShortcut(keyCode: 0, modifiers: [.control, .option], key: "A")
        store.lastScreenshotArea = NSRect(x: 10, y: 20, width: 300, height: 200)
        let again = SettingsStore(defaults: defaults)
        #expect(again.screenshotAfter == .pin)
        #expect(again.screenshotDelay == 5)
        #expect(again.screenshotFormat == .heic)
        #expect(!again.screenshotCopy)
        #expect(again.screenshotFolder.path == "/tmp/shots")
        #expect(again.screenshotShortcuts[.area]?.title == "⌃⌥A")
        #expect(again.screenshotShortcuts[.window] == ScreenshotMode.window.defaultShortcut)
        #expect(again.lastScreenshotArea == NSRect(x: 10, y: 20, width: 300, height: 200))
        again.resetToDefaults()
        #expect(again.screenshotAfter == .edit)
        #expect(again.screenshotFormat == .png)
        #expect(again.screenshotShortcuts[.area] == ScreenshotMode.area.defaultShortcut)
    }

    @Test func formatsMapToFilesAndEachExplainsItself() {
        #expect(ScreenshotFormat.allCases.map(\.outputFormat.fileExtension) == ["png", "jpg", "heic"])
        for format in ScreenshotFormat.allCases {
            #expect(!format.bestFor.isEmpty && !format.watchOut.isEmpty && !format.tagline.isEmpty)
        }
        #expect(ScreenshotMode.allCases.contains(.text))
        #expect(ScreenshotMode.text.defaultShortcut.title == "⌥⌘7")
    }

    @Test func theTabIsFoundBySearch() {
        func found(_ text: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(text) } }
        #expect(found("screenshot") == [.screenshots])
        #expect(found("Shottr") == [.screenshots])
        #expect(found("eyedropper") == [.screenshots])
    }

    @Test func theEditorOffersTheNewTools() {
        let kinds = Set(Annotation.Kind.allCases)
        #expect(kinds.isSuperset(of: [.line, .blur, .spotlight, .measure]))
    }
}

struct ScreenshotCornerCaseTests {
    @Test func aSelectionNeedsRoom() {
        let selector = AreaSelector()
        var result: NSRect? = NSRect(x: 1, y: 1, width: 1, height: 1)
        var called = false
        selector.completion = { chosen in
            result = chosen
            called = true
        }
        selector.begin(at: NSPoint(x: 100, y: 100))
        selector.drag(to: NSPoint(x: 101, y: 101))  // a click, not a box
        selector.end()
        #expect(called && result == nil)

        let again = AreaSelector()
        again.completion = { result = $0 }
        again.begin(at: NSPoint(x: 300, y: 200))
        again.drag(to: NSPoint(x: 100, y: 50))
        again.end()
        #expect(result == NSRect(x: 100, y: 50, width: 200, height: 150))
    }
}

/// The editor's second round of 2.3: one slider for size or strength, the
/// snapping ruler, and the pixel zoom.
struct StudioSliderAndRulerTests {
    private func model(width: Int = 100, height: Int = 60) async throws -> (StudioModel, Scratch) {
        let scratch = try Scratch()
        // White, with a black bar from x = 40 to 60.
        let file = scratch.url.appendingPathComponent("bar.png")
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 0, width: 20, height: height))
        let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let model = StudioModel(files: [SourceFile(url: file)], tab: .markup)
        model.undoManager.groupsByEvent = false
        for _ in 0..<500 where model.preview == nil || model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.preview != nil)
        return (model, scratch)
    }

    @Test func oneSliderMeansSizeOrStrengthByTool() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        model.tool = .arrow
        #expect(!model.sliderIsStrength && model.sliderValue == 0.5)
        model.beginSliding(); model.setSliderValue(0.75); model.endSliding()
        let large = model.size(for: .arrow)
        model.beginSliding(); model.setSliderValue(0.25); model.endSliding()
        #expect(large > model.size(for: .arrow) * 2, "Large is much thicker than Small")
        // The three notches are exactly the old Small, Medium and Large.
        #expect(StudioModel.SizeScale.share(level: 0.25, for: .arrow) == 0.004)
        #expect(StudioModel.SizeScale.share(level: 0.5, for: .arrow) == 0.007)
        #expect(StudioModel.SizeScale.share(level: 0.75, for: .arrow) == 0.012)
        #expect(abs(StudioModel.SizeScale.level(share: 0.009, for: .arrow) - 0.5 - 0.25 * (0.002 / 0.005)) < 1e-9)
        // Blur tools use the same slider as a strength, kept apart from the size.
        model.tool = .blur
        #expect(model.sliderIsStrength && model.sliderValue == 0.5)
        model.beginSliding(); model.setSliderValue(0.9); model.endSliding()
        model.tool = .arrow
        #expect(model.sliderValue == 0.25, "the size is where it was left")
        model.tool = .blur
        #expect(model.sliderValue == 0.9)
    }

    @Test func theSliderEditsWhatIsSelected() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        model.tool = .spotlight
        model.beginMarkup(at: RelativePoint(x: 0.1, y: 0.1))
        model.continueMarkup(to: RelativePoint(x: 0.4, y: 0.4))
        model.endMarkup()
        let spot = try #require(model.edit.markup.first)
        model.tool = nil
        model.selection = spot.id
        #expect(model.sliderIsStrength && model.sliderValue == 0.5)
        model.beginSliding(); model.setSliderValue(0.8); model.endSliding()
        #expect(model.edit.markup[0].strength == 0.8)
        model.undo()
        #expect(model.edit.markup[0].strength == 0.5, "a slider drag is one undo step")
    }

    @Test func aClickWithTheRulerMeasuresBetweenEdges() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        model.tool = .measure
        model.beginMarkup(at: RelativePoint(x: 0.5, y: 0.5))  // inside the bar
        model.endMarkup()
        let ruler = try #require(model.edit.markup.first)
        #expect(ruler.kind == .measure)
        #expect(abs(ruler.points[0].x - 0.4) < 0.011 && abs(ruler.points[1].x - 0.6) < 0.011)
        #expect(ruler.points[0].y == ruler.points[1].y, "it runs straight across")
    }

    @Test func aDraggedRulerSnapsItsEndsToEdges() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        model.tool = .measure
        model.beginMarkup(at: RelativePoint(x: 0.43, y: 0.5))  // 3 px inside the bar's left edge
        model.continueMarkup(to: RelativePoint(x: 0.9, y: 0.52))  // almost level, past the right edge
        model.endMarkup()
        let ruler = try #require(model.edit.markup.first)
        #expect(abs(ruler.points[0].x - 0.4) < 0.011, "the start jumped to the edge")
        #expect(ruler.points[0].y == ruler.points[1].y, "and the ruler is level")
    }

    @Test func theZoomShowsPixelsAndTheirColor() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        #expect(!model.showsZoom)
        model.hover = CGPoint(x: 0.5, y: 0.5)
        #expect(model.zoomPatch?.hex == "#000000", "the bar is black")
        model.tool = .measure
        #expect(model.showsZoom, "Measure shows it by itself")
        model.tool = .arrow
        #expect(!model.showsZoom)
        model.pixelZoom = true
        #expect(model.showsZoom)
        model.hover = CGPoint(x: 0.05, y: 0.5)
        #expect(model.zoomPatch?.hex == "#FFFFFF")
        let patch = try #require(model.zoomPatch)
        #expect(patch.image.width == StudioModel.zoomPixels)
    }

    @Test func eraseWaitsForBackspace() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        model.tool = .erase
        #expect(!model.sliderIsStrength && model.sliderKind == nil, "no slider for erasing")
        model.beginMarkup(at: RelativePoint(x: 0.4, y: 0.4))
        model.continueMarkup(to: RelativePoint(x: 0.6, y: 0.6))
        model.endMarkup()
        #expect(model.edit.markup.isEmpty, "choosing a box changes nothing yet")
        #expect(model.eraseArea != nil && model.canDeleteByKey)
        model.deleteKey()  // Backspace
        #expect(model.edit.markup.map(\.kind) == [.erase] && model.eraseArea == nil)
        model.undo()
        #expect(model.edit.markup.isEmpty)
        // A click chooses nothing; switching tools drops the box.
        model.beginMarkup(at: RelativePoint(x: 0.4, y: 0.4)); model.endMarkup()
        #expect(model.eraseArea == nil)
        model.beginMarkup(at: RelativePoint(x: 0.1, y: 0.1)); model.continueMarkup(to: RelativePoint(x: 0.3, y: 0.3)); model.endMarkup()
        model.tool = .arrow
        #expect(model.eraseArea == nil && !model.canDeleteByKey)
    }

    @Test func backspaceDeletesTheSelectedMark() async throws {
        let (model, _scratch) = try await model()
        _ = _scratch
        model.tool = .arrow
        model.beginMarkup(at: RelativePoint(x: 0.1, y: 0.1)); model.continueMarkup(to: RelativePoint(x: 0.5, y: 0.5)); model.endMarkup()
        #expect(!model.canDeleteByKey, "nothing is selected")
        model.tool = nil
        model.selection = model.edit.markup[0].id
        #expect(model.canDeleteByKey)
        model.deleteKey()
        #expect(model.edit.markup.isEmpty)
    }

    @Test func thePictureFillsTheWindow() {
        #expect(StudioCanvas.margin(for: .markup) == 0 && StudioCanvas.margin(for: .adjust) == 0)
        #expect(StudioCanvas.margin(for: .crop) > 0, "the crop box needs room for its handles")
    }

    @Test func sliderNotchesPullTheThumbIn() {
        #expect(EditSlider.attract(0.52, toAny: [0.25, 0.5, 0.75], within: 0.035) == 0.5)
        #expect(EditSlider.attract(0.6, toAny: [0.25, 0.5, 0.75], within: 0.035) == 0.6)
        #expect(EditSlider.attract(0.74, toAny: [0.25, 0.5, 0.75], within: 0.035) == 0.75)
    }
}

struct FrozenScreenTests {
    @Test func aBoxIsCutFromTheFrozenPictureInItsOwnPixels() throws {
        // A 200 × 100 point screen photographed at 2×: left half white, right half black.
        let ctx = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let shot = AreaSelector.FrozenScreen(frame: NSRect(x: 100, y: 50, width: 200, height: 100), image: ctx.makeImage()!)
        let framed = AreaSelector()
        framed.setFrozenForTesting([shot])
        let cut = try #require(framed.picture(of: NSRect(x: 150, y: 70, width: 40, height: 20)))
        #expect(cut.width == 80 && cut.height == 40, "points become pixels at 2×")
        // A box hanging off the screen is cut to what's on it.
        let edge = try #require(framed.picture(of: NSRect(x: 280, y: 130, width: 100, height: 100)))
        #expect(edge.width == 40 && edge.height == 40)
        #expect(framed.picture(of: NSRect(x: 900, y: 900, width: 10, height: 10)) == nil)
    }
}
