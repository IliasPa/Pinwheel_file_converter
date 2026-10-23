import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.7: quick buttons that know more links, pictures from browsers,
/// Straighten's magnet, and a quicker Settings.
@MainActor
struct V177Tests {
    @Test func moreTrackingIsCleaned() {
        let clean = ClipActions.cleanLinks
        // The LinkedIn link that showed no button.
        #expect(clean("https://www.linkedin.com/in/someone/?isSelfProfile=true") == "https://www.linkedin.com/in/someone/")
        #expect(clean("https://www.linkedin.com/posts/x?trk=public_post&lipi=abc") == "https://www.linkedin.com/posts/x")
        // Any Amazon, any Google: what the page needs stays.
        #expect(clean("https://www.amazon.de/dp/B000?ref=sr_1&tag=aff-21&th=1") == "https://www.amazon.de/dp/B000?th=1")
        #expect(clean("https://www.google.com/search?q=pinwheel&ved=0ah&ei=xyz&sca_esv=1") == "https://www.google.com/search?q=pinwheel")
        #expect(clean("https://www.tiktok.com/@a/video/1?_r=1&_t=8x&is_from_webapp=1") == "https://www.tiktok.com/@a/video/1")
        #expect(clean("https://m.facebook.com/story.php?id=5&mibextid=Zx") == "https://m.facebook.com/story.php?id=5")
        #expect(clean("https://example.com/a?pk_campaign=x&mtm_source=y&page=2") == "https://example.com/a?page=2")
        // Not a tracker anywhere: kept ("ref" only counts on some sites).
        #expect(clean("https://github.com/a/b/blob/x?ref=main") == "https://github.com/a/b/blob/x?ref=main")
        #expect(clean("https://amazonaws.com/x?ref=1") == "https://amazonaws.com/x?ref=1")
    }

    @Test func bareLink() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        func link(_ text: String) throws -> ClipItem {
            try #require(store.add([[(type: UTType.utf8PlainText.identifier, data: Data(text.utf8))]], appID: nil, appName: nil))
        }
        // Extras no list knows: Bare Link takes everything after "?" and "#".
        let plain = try link("https://example.com/article?id=7#comments")
        #expect(ClipActions.available(for: plain, store: store) == [.bareLink])
        #expect(ClipActions.bareLink("https://example.com/article?id=7#comments") == "https://example.com/article")
        // Only tracking: Clean Links does it all, so no Bare Link too.
        #expect(ClipActions.available(for: try link("https://example.com/?utm_source=x"), store: store) == [.cleanLinks])
        // Nothing extra: no buttons for it.
        #expect(ClipActions.available(for: try link("https://example.com/about"), store: store).isEmpty)
        // Both: the rest remains after Clean Links.
        #expect(ClipActions.available(for: try link("https://example.com/p?id=2&fbclid=z"), store: store) == [.cleanLinks, .bareLink])
    }

    /// A browser's Copy Image puts the picture and its address on the
    /// clipboard: it's a picture (so Text in Image can read it).
    @Test func picturesFromBrowsers() throws {
        let png = NSBitmapImageRep(cgImage: CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!)
            .representation(using: .png, properties: [:])!
        func kind(_ types: [(UTType, Data)]) -> ClipKind? {
            ClipboardStore.describe([types.map { (type: $0.0.identifier, data: $0.1) }])?.kind
        }
        let address = Data("https://example.com/photo.png".utf8)
        #expect(kind([(.tiff, png), (.utf8PlainText, address)]) == .image, "the picture first")
        #expect(kind([(.utf8PlainText, address), (.png, png)]) == .image, "just its address alongside")
        #expect(kind([(.html, Data("<b>Cells</b>".utf8)), (.utf8PlainText, Data("Cells".utf8)), (.png, png)]) == .text, "text with a picture of itself")
        #expect(kind([(.utf8PlainText, Data("Hello".utf8)), (.png, png)]) == .text)
    }

    @Test func straightenSnapsToLevel() {
        #expect(EditSlider.attract(0.8, to: 0, within: 1.5) == 0)
        #expect(EditSlider.attract(-1.4, to: 0, within: 1.5) == 0)
        #expect(EditSlider.attract(1.6, to: 0, within: 1.5) == 1.6)
        #expect(EditSlider.attract(0.8, to: nil, within: 1.5) == 0.8, "no magnet, no pull")
    }

    /// Searching Settings for a format opens its kind on Conversions and Compatibility.
    @Test func searchingShowsTheKind() {
        let state = SettingsViewState()
        state.showKind(for: "webm")
        #expect(state.settingsKind == .video)
        state.showKind(for: "mp3")
        #expect(state.settingsKind == .audio, "MP3 files are audio (videos only become MP3)")
        state.showKind(for: "spread")
        #expect(state.settingsKind == .spreadsheet)
        state.showKind(for: "x")
        #expect(state.settingsKind == .spreadsheet, "one letter changes nothing")
    }

    /// What's installed is looked up once for a page, not once a row.
    @Test func lookupsAreRemembered() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        let first = settings.installed.at
        _ = settings.ffmpegURL
        _ = settings.isInstalled(.pages)
        #expect(settings.installed.at == first)
        // A new ffmpeg path is looked at straight away.
        settings.ffmpegPath = "/nowhere/ffmpeg"
        #expect(settings.installed.at != first && settings.installed.ffmpegPath == "/nowhere/ffmpeg")
        #expect(settings.isInstalled(.cwebp) == (ExternalTool.cwebp.locate() != nil))
    }

    @Test func theHistoryAppearsAtOnce() {
        #expect(ClipboardPanel().animationBehavior == .none)
    }

    /// No limit: a copy shows every button that changes it, side by side.
    @Test func everyButtonThatHelpsShows() async throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let text = "Read  this:\nhttps://example.com/a?utm_source=mail&id=2"
        store.add([[(type: UTType.html.identifier, data: Data("<p>\(text)</p>".utf8)), (type: UTType.utf8PlainText.identifier, data: Data(text.utf8))]],
                  appID: nil, appName: nil)
        let item = try #require(store.items.first)
        let actions = ClipActions.available(for: item, store: store)
        #expect(actions == [.plainText, .cleanLinks, .oneLine, .tidySpaces] + ClipAction.cases)

        // The bar at a row's width (a copy's text column is about 480
        // points), in a window that's never shown, so it's in no other
        // test's way.
        let bar = NSHostingView(rootView: ClipActionBar(item: item, actions: actions, model: ClipboardPanelModel(store: store)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = bar
        var buttons: [ClickAreaView] = []
        for _ in 0..<40 where buttons.count < 5 {
            bar.layoutSubtreeIfNeeded()
            buttons = Self.buttons(in: bar)
            if buttons.count < 5 { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(buttons.map(\.label) == ["Plain Text", "Clean Links", "One Line", "Tidy Spaces", "Aa"])
        let frames = buttons.map { $0.convert($0.bounds, to: bar) }
        #expect(frames.allSatisfy { $0.width > 20 && $0.minX >= 0 && $0.maxX <= bar.bounds.width }, "none squeezed or cut off")
    }

    private static func buttons(in view: NSView) -> [ClickAreaView] {
        let found = view.subviews.flatMap { [$0 as? ClickAreaView].compactMap { $0 } + buttons(in: $0) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// A picture looked at the old way (Tesseract only, so photos showed no
    /// text) is looked at again; one that couldn't be read isn't "no text".
    @Test func picturesAreLookedAtAgain() async throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let photo = scratch.url.appendingPathComponent("photo.png")
        let png = NSBitmapImageRep(cgImage: CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!)
        try #require(png.representation(using: .png, properties: [:])).write(to: photo)
        var item = try #require(store.add([[(type: UTType.fileURL.identifier, data: photo.dataRepresentation)]], appID: nil, appName: nil))
        #expect(ClipActions.needsLook(item, store: store))
        store.setPictureFindings(of: item, text: "", codes: [])
        item = try #require(store.items.first)
        #expect(!ClipActions.needsLook(item, store: store) && item.pictureLook == ClipActions.lookVersion)
        // As 1.7.6 left it: looked at, nothing found, no version.
        item.pictureLook = nil
        #expect(ClipActions.needsLook(item, store: store))

        let broken = scratch.url.appendingPathComponent("broken.png")
        try Data("not a picture".utf8).write(to: broken)
        let unread = await ClipActions.look(at: broken, recognition: TextRecognition())
        #expect(unread == nil, "tried again another time")
        let read = await ClipActions.look(at: photo, recognition: TextRecognition())
        #expect(read?.text == "", "read: no words in it")
    }
}
