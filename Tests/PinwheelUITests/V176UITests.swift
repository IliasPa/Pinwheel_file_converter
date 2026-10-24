import AppKit
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.6: quick buttons that show when they should and work, and a
/// clipboard history that answers faster.
@MainActor
struct QuickButtonTests {
    private func settings() -> (SettingsStore, String) {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (SettingsStore(defaults: defaults), name)
    }

    private func textPicture(_ text: String) -> Data {
        let context = CGContext(data: nil, width: 1400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1400, height: 300))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(in: NSRect(x: 40, y: 40, width: 1320, height: 220), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// A copied screenshot is read once in the background; its button then
    /// shows, and pastes what was read straight away.
    @Test func picturesAreLookedAtOnce() async throws {
        let scratch = try Scratch()
        let (settings, name) = settings()
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        let controller = ClipboardController(settings: settings, store: ClipboardStore(folder: scratch.url), pasteboard: board)
        var pasted = 0
        controller.paste = { pasted += 1 }
        controller.mayPress = { true }

        board.clearContents()
        board.setData(textPicture("Read me quickly"), forType: .png)
        controller.checkClipboard()
        var picture = try #require(controller.store.items.first)
        for _ in 0..<400 where picture.pictureHasText == nil {
            try await Task.sleep(for: .milliseconds(25))
            picture = try #require(controller.store.items.first)
        }
        #expect(picture.pictureHasText == true && picture.pictureHasCode == false)
        #expect(controller.model.actions(for: picture) == [.textInImage], "no Read Code: there's no code in it")
        #expect(controller.store.pictureText(of: picture)?.contains("Read me quickly") == true)

        controller.show()
        controller.model.isPinned = true
        defer {
            controller.model.isPinned = false
            controller.hide()
        }
        let clock = ContinuousClock()
        let started = clock.now
        controller.run(.textInImage, on: picture)
        for _ in 0..<40 where pasted == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pasted == 1 && board.string(forType: .string)?.contains("Read me quickly") == true)
        // Already read: nothing to wait for. (Reading again would take a
        // moment, or 40 s the first time; a Mac busy with other tests can
        // take a second or two even so.)
        #expect(clock.now - started < .seconds(3), "already read: nothing to wait for")

        // With the buttons off, pictures aren't read at all.
        settings.clipboardActions = false
        board.clearContents()
        board.setData(textPicture("Not read"), forType: .png)
        controller.checkClipboard()
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.store.items.first?.pictureHasText == nil)
    }

    @Test func onlyWhenTheyChangeSomething() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        func add(_ text: String) throws -> ClipItem {
            try #require(store.add([[(type: UTType.utf8PlainText.identifier, data: Data(text.utf8))]], appID: nil, appName: nil))
        }
        // A line copied with its line break: nothing to join or tidy.
        #expect(ClipActions.available(for: try add("One line\n"), store: store) == ClipAction.cases)
        // Code keeps its indents; a cell row keeps its tabs.
        #expect(ClipActions.available(for: try add("if a {\n    b()\n}"), store: store) == [.oneLine] + ClipAction.cases)
        #expect(ClipActions.available(for: try add("Name\tCity\tPhone"), store: store) == ClipAction.cases)
        // No letters: no capitals to change.
        #expect(ClipActions.available(for: try add("+30 210 1234567"), store: store).isEmpty)
    }

    @Test func searchingWithoutAccentsOrCapitals() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        store.add([[(type: UTType.utf8PlainText.identifier, data: Data("Καλημέρα από την Αθήνα".utf8))]], appID: "com.apple.Notes", appName: "Notes")
        store.add([[(type: UTType.utf8PlainText.identifier, data: Data("Café menu".utf8))]], appID: nil, appName: nil)
        #expect(store.matching(search: "αθηνα").count == 1)
        #expect(store.matching(search: "CAFE").map(\.preview) == ["Café menu"])
        #expect(store.matching(search: "notes καλημερα").count == 1)
        #expect(store.matching(search: "nothing").isEmpty)
    }

    /// The pointer only marks a copy; the list scrolls for the keyboard.
    @Test func thePointerDoesNotScroll() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        for word in ["alpha", "beta", "gamma"] {
            store.add([[(type: UTType.utf8PlainText.identifier, data: Data(word.utf8))]], appID: nil, appName: nil)
        }
        let model = ClipboardPanelModel(store: store)
        model.prepare()
        #expect(model.scrollTarget == store.items[0].id)
        model.hover(store.items[2])
        #expect(model.selection == store.items[2].id && model.scrollTarget == store.items[0].id)
        model.moveSelection(by: -1)
        #expect(model.selection == store.items[1].id && model.scrollTarget == store.items[1].id)
    }

    /// In the window: each copy shows its buttons, and clicking one pastes.
    @Test func theButtonsInTheWindow() async throws {
        let scratch = try Scratch()
        let (settings, name) = settings()
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        let store = ClipboardStore(folder: scratch.url)
        store.add([[(type: UTType.utf8PlainText.identifier, data: Data("https://example.com/?id=1&utm_source=mail".utf8))]], appID: nil, appName: nil)
        store.add([[(type: UTType.utf8PlainText.identifier, data: Data("Mixed Case words".utf8))]], appID: nil, appName: nil)
        let controller = ClipboardController(settings: settings, store: store, pasteboard: board)
        var pasted = 0
        controller.paste = { pasted += 1 }
        controller.mayPress = { true }
        controller.show()
        controller.model.isPinned = true
        defer {
            controller.model.isPinned = false
            controller.hide()
        }
        let window = controller.panel
        var button: ClickAreaView?
        for _ in 0..<80 where button == nil {
            window.contentView?.layoutSubtreeIfNeeded()
            button = Self.button("Clean Links", in: window)
            if button == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let cleanLinks = try #require(button, "the button is in the window")
        #expect(Self.button("Plain Text", in: window) == nil, "not formatted: no Plain Text")

        // A real click on it: down and up where it is (nothing covers it).
        let center = cleanLinks.convert(NSPoint(x: cleanLinks.bounds.midX, y: cleanLinks.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(center) === cleanLinks)
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
            NSApp.sendEvent(event)
        }
        for _ in 0..<40 where pasted == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(pasted == 1 && board.string(forType: .string) == "https://example.com/?id=1")

        // Aa: a menu of capitals; VoiceOver can press the buttons too.
        let mixed = try #require(store.items.first { $0.preview == "Mixed Case words" })
        let menu = ClipActionBar.caseMenu(for: mixed, model: controller.model)
        #expect(menu.items.map(\.title) == ["UPPERCASE", "lowercase", "Title Case", "Sentence case"])
        _ = menu.items[0].target?.perform(menu.items[0].action)
        for _ in 0..<40 where pasted < 2 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(pasted == 2 && board.string(forType: .string) == "MIXED CASE WORDS")
        let aa = try #require(Self.button("Aa", in: window))
        #expect(aa.accessibilityRole() == .button && aa.accessibilityLabel() == "Aa")

        // Switched off in Settings: gone.
        settings.clipboardActions = false
        for _ in 0..<40 where Self.button("Clean Links", in: window) != nil {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(Self.button("Clean Links", in: window) == nil)
    }

    /// A small button in the window, by its label.
    static func button(_ label: String, in window: NSWindow) -> ClickAreaView? {
        func find(_ view: NSView) -> ClickAreaView? {
            if let button = view as? ClickAreaView, button.label == label, button.window != nil { return button }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }
}
