import AppKit
import Carbon.HIToolbox
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

private func freshDefaults() -> UserDefaults {
    let name = "PinwheelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// A clipboard of the test's own, so the real one is left alone.
private func testPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("PinwheelTests-\(UUID().uuidString)"))
}

private func put(_ values: [(UTType, Data)], on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier)) }
    pasteboard.writeObjects([item])
}

private func text(_ string: String) -> (UTType, Data) { (.utf8PlainText, Data(string.utf8)) }

/// Reads what's on `board` and keeps it, as the watcher does.
@discardableResult
private func keep(_ store: ClipboardStore, from board: NSPasteboard, appID: String? = nil, appName: String? = nil) throws -> ClipItem {
    let contents = try #require(ClipboardStore.read(board))
    return try #require(store.add(contents, appID: appID, appName: appName))
}

// MARK: - The history

struct ClipboardStoreTests {
    @Test func kindsOfCopies() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url.appendingPathComponent("Clipboard"))
        let board = testPasteboard()

        put([text("  Meeting at 10, room B  ")], on: board)
        let note = try keep(store, from: board, appID: "com.apple.Notes", appName: "Notes")
        #expect(note.kind == .text && note.preview == "Meeting at 10, room B" && note.appName == "Notes")

        put([text("https://example.com/a?b=1")], on: board)
        #expect(try keep(store, from: board, appID: "com.apple.Safari", appName: "Safari").kind == .link)
        #expect(!ClipboardStore.isLink("see https://example.com") && ClipboardStore.isLink("mailto:me@example.com"))

        let png = try Data(contentsOf: try scratch.image("shot.png", width: 40, height: 20))
        put([(.png, png)], on: board)
        let picture = try keep(store, from: board)
        #expect(picture.kind == .image && picture.preview == "Image 40 × 20")
        #expect(FileManager.default.fileExists(atPath: try #require(store.thumbnail(of: picture)).path))

        board.clearContents()
        board.writeObjects([try scratch.image("a.png"), try scratch.image("b.png")] as [NSURL])
        let files = try keep(store, from: board, appID: "com.apple.finder", appName: "Finder")
        #expect(files.kind == .file && files.preview == "a.png, b.png" && files.contents.count == 2)
        #expect(store.files(of: files).map(\.lastPathComponent) == ["a.png", "b.png"])

        #expect(store.items.map(\.kind) == [.file, .image, .link, .text], "newest first")
        #expect(store.apps.map(\.name) == ["Finder", "Safari", "Notes"])
        #expect(store.matching(kind: .link).count == 1)
        #expect(store.matching(appID: "com.apple.Notes").map(\.preview) == ["Meeting at 10, room B"])
        #expect(store.matching(search: "room notes").count == 1, "words match the text or the app")
    }

    @Test func privateCopiesAreNeverKept() {
        let board = testPasteboard()
        // As password managers mark what they copy.
        board.clearContents()
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.writeObjects([secret])
        #expect(ClipboardStore.read(board) == nil)
        board.clearContents()
        #expect(ClipboardStore.read(board) == nil)
    }

    @Test func copiedAgainMovesToTheTop() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let board = testPasteboard()
        for word in ["one", "two", "one"] {
            put([text(word)], on: board)
            try keep(store, from: board)
        }
        #expect(store.items.map(\.preview) == ["one", "two"])
    }

    @Test func favoritesStayAndEverythingIsRemembered() throws {
        let scratch = try Scratch()
        let folder = scratch.url.appendingPathComponent("Clipboard")
        let store = ClipboardStore(folder: folder)
        store.limit = 3
        let board = testPasteboard()
        for number in 1...5 {
            put([text("copy \(number)")], on: board)
            let item = try keep(store, from: board, appID: "com.apple.TextEdit", appName: "TextEdit")
            if number == 1 { store.toggleFavorite(item) }
        }
        #expect(store.items.map(\.preview) == ["copy 5", "copy 4", "copy 3", "copy 1"], "3 copies and the favorite")
        // Only the kept ones have files.
        let folders = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "history.json" }
        #expect(folders.count == 4)

        let again = ClipboardStore(folder: folder)
        #expect(again.items.map(\.preview) == store.items.map(\.preview))
        #expect(again.items.last?.isFavorite == true)
        again.clear()
        #expect(again.items.map(\.preview) == ["copy 1"])
        #expect(again.matching(favoritesOnly: true).count == 1)
    }

    @Test func copyingPutsBackEveryFormat() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let board = testPasteboard()
        let rich = try NSAttributedString(string: "Bold words").data(from: NSRange(location: 0, length: 10), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        put([(.rtf, rich), text("Bold words")], on: board)
        let item = try keep(store, from: board)
        board.clearContents()
        store.copy(item, to: board)
        #expect(board.string(forType: .string) == "Bold words")
        #expect(board.data(forType: .rtf) == rich)
        #expect(store.text(of: item) == "Bold words")
    }
}

// MARK: - The shortcut

struct KeyShortcutTests {
    @Test func namesAndKeys() throws {
        #expect(KeyShortcut.clipboard.title == "⌥⌘V")
        #expect(KeyShortcut.clipboard.carbonModifiers == UInt32(cmdKey | optionKey))
        #expect(KeyShortcut.clipboard.isUsable && !KeyShortcut.clipboard.isReserved)
        #expect(!KeyShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.shift], key: "V").isUsable)
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command], key: "V").isReserved)
        #expect(KeyShortcut(stored: KeyShortcut.clipboard.stored) == .clipboard)

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F708}", charactersIgnoringModifiers: "\u{F708}", isARepeat: false, keyCode: UInt16(kVK_F5)
        ))
        #expect(KeyShortcut(event: event)?.title == "⌃⌥F5")
        let letter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "K", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)
        ))
        #expect(KeyShortcut(event: letter)?.title == "⇧⌘K")
    }

    @Test func macOSTakesIt() {
        let hotKey = GlobalHotKey()
        // Keys nobody uses, so the test doesn't collide with another app.
        let rare = KeyShortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .command], key: "F19")
        #expect(hotKey.register(rare) {})
        #expect(hotKey.isRegistered)
        hotKey.unregister()
        #expect(!hotKey.isRegistered)
    }

    @Test func settingsRememberIt() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.clipboardEnabled && store.clipboardShortcut == .clipboard && store.clipboardLimit == 200)
        var changes = 0
        store.onClipboardChange = { changes += 1 }
        store.clipboardShortcut = KeyShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.control, .command], key: "C")
        store.clipboardLimit = 500
        #expect(changes == 2)
        let again = SettingsStore(defaults: defaults)
        #expect(again.clipboardShortcut.title == "⌃⌘C" && again.clipboardLimit == 500)
        again.resetToDefaults()
        #expect(again.clipboardShortcut == .clipboard && again.clipboardLimit == 200 && again.clipboardEnabled)
        #expect(again.clipboardPastes)
        again.clipboardPastes = false
        #expect(!SettingsStore(defaults: defaults).clipboardPastes)

        func found(_ text: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(text) } }
        #expect(found("clipboard") == [.clipboard] && found("pasta") == [.clipboard])
        #expect(NSImage(systemSymbolName: SettingsPane.clipboard.symbolName ?? "", accessibilityDescription: nil) != nil)
        for kind in ClipKind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil)
        }
    }
}

// MARK: - Watching and copying

struct ClipboardControllerTests {
    @Test func keepsCopiesAndCopiesBack() async throws {
        let scratch = try Scratch()
        let settings = SettingsStore(defaults: freshDefaults())
        settings.clipboardShortcut = KeyShortcut(keyCode: UInt16(kVK_F18), modifiers: [.control, .option, .command], key: "F18")
        let board = testPasteboard()
        let controller = ClipboardController(settings: settings, store: ClipboardStore(folder: scratch.url), pasteboard: board)
        // Never press keys for real: they'd go to whatever app is in front.
        var pasted = 0
        controller.paste = { pasted += 1 }
        controller.mayPress = { true }
        controller.apply()
        defer {
            settings.clipboardEnabled = false
            controller.apply()
        }
        #expect(controller.model.shortcutProblem == nil)

        put([text("first")], on: board)
        controller.checkClipboard()
        put([text("second")], on: board)
        controller.checkClipboard()
        controller.checkClipboard()  // nothing new
        #expect(controller.store.items.map(\.preview) == ["second", "first"])

        // Copying from the history: on the clipboard, at the top, not kept
        // twice, and pasted (⌘V) a moment later, once the window is gone.
        controller.copy(controller.store.items[1])
        #expect(board.string(forType: .string) == "first")
        controller.checkClipboard()
        #expect(controller.store.items.map(\.preview) == ["first", "second"])
        #expect(pasted == 0, "not before the app in front has its keyboard back")
        for _ in 0..<40 where pasted == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(pasted == 1)

        // "Just copy it", or no permission to press keys: copied, not pasted.
        settings.clipboardPastes = false
        controller.copy(controller.store.items[1])
        settings.clipboardPastes = true
        controller.mayPress = { false }
        controller.copy(controller.store.items[1])
        try await Task.sleep(for: .milliseconds(300))
        #expect(pasted == 1 && board.string(forType: .string) == "first")

        // Off: nothing is kept.
        settings.clipboardEnabled = false
        controller.apply()
        put([text("third")], on: board)
        controller.checkClipboard()
        #expect(controller.store.items.count == 2)
    }

    @Test func choosingWithTheKeyboard() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let board = testPasteboard()
        for word in ["alpha", "beta", "gamma"] {
            put([text(word)], on: board)
            try keep(store, from: board)
        }
        let model = ClipboardPanelModel(store: store)
        var copied: [String] = []
        model.onCopy = { copied.append($0.preview) }
        model.prepare()
        #expect(model.visible.map(\.preview) == ["gamma", "beta", "alpha"])
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.copySelected()
        #expect(copied == ["alpha"], "stops at the last one")
        model.search = "bet"
        model.copySelected()
        #expect(copied == ["alpha", "beta"])
        model.search = ""  // the newest is chosen again
        model.removeSelected()
        #expect(store.items.map(\.preview) == ["beta", "alpha"] && model.selection == store.items[0].id)
        model.kind = .image
        #expect(model.visible.isEmpty && model.selection == nil)
    }
}

// MARK: - Space

struct ClipboardSpaceTests {
    @Test func howMuchRoomTheCopiesTake() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        // Before there are enough copies: a typical mix.
        #expect(store.totalBytes == 0 && store.estimate(copies: 200) == "~24 MB")
        let board = testPasteboard()
        for number in 0..<10 {
            put([text(String(repeating: "\(number)", count: 1000))], on: board)
            try keep(store, from: board)
        }
        // Then from the copies themselves: 1 KB of text each.
        #expect(store.totalBytes == 10_000 && store.typicalBytes == 1000)
        #expect(store.estimate(copies: 1000) == "~1 MB")
        #expect(ClipboardStore.size(3_200_000) == "3.2 MB")
        // Estimates are whole numbers.
        #expect(ClipboardStore.roundedSize(3_200_000) == "3 MB" && ClipboardStore.roundedSize(2_600_000_000) == "3 GB")
        #expect(ClipboardStore.roundedSize(999_600) == "1 MB" && ClipboardStore.roundedSize(48_400) == "48 KB")
        #expect(ClipboardStore.roundedSize(512) == "512 bytes")
    }
}
