import AppKit
import Carbon.HIToolbox
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.2: the clipboard window's size and shadow, and its anchor.
@MainActor
struct ClipboardWindowTests {
    private func controller(_ scratch: Scratch) -> ClipboardController {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        let store = ClipboardStore(folder: scratch.url)
        for word in ["alpha", "beta"] {
            store.add([[(type: "public.utf8-plain-text", data: Data(word.utf8))]], appID: nil, appName: nil)
        }
        let controller = ClipboardController(settings: settings, store: store, pasteboard: board)
        controller.mayPress = { true }
        return controller
    }

    @Test func theWindowIsTheGlassAndItsShadow() async throws {
        let scratch = try Scratch()
        let controller = controller(scratch)
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(300))
        let panel = controller.panel
        // It used to grow by the hidden title bar, leaving an empty strip
        // below the glass that macOS's shadow outlined in dark.
        #expect(panel.frame.size == ClipboardPanel.size)
        #expect(!panel.hasShadow)
        #expect(ClipboardPanel.size.height == ClipboardPanel.contentSize.height + 2 * ClipboardPanel.margin)
    }

    @Test func anchoredItStaysOpen() async throws {
        let scratch = try Scratch()
        let controller = controller(scratch)
        var pasted = 0
        controller.paste = { pasted += 1 }
        controller.show()
        defer {
            controller.model.isPinned = false
            controller.hide()
        }
        try await Task.sleep(for: .milliseconds(200))
        // Clicking another window closes it…
        controller.panel.resignKey()
        #expect(!controller.isShown)

        // …unless it's anchored.
        controller.show()
        controller.model.isPinned = true
        try await Task.sleep(for: .milliseconds(200))
        controller.panel.resignKey()
        #expect(controller.isShown)

        // Choosing a copy: it steps aside for the paste, then comes back.
        controller.copy(controller.store.items[1])
        for _ in 0..<40 where !(pasted == 1 && controller.isShown) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(pasted == 1 && controller.isShown)
        #expect(controller.model.justCopied == controller.store.items[0].id)

        // Just copying: it stays.
        controller.mayPress = { false }
        controller.copy(controller.store.items[1])
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.isShown && pasted == 1)

        // Esc still closes it, even while it's out of the way for a paste.
        controller.model.onClose()
        #expect(!controller.isShown)
        controller.show()
        controller.mayPress = { true }
        controller.copy(controller.store.items[1])
        for _ in 0..<40 where pasted < 2 { try await Task.sleep(for: .milliseconds(10)) }
        controller.model.onClose()
        try await Task.sleep(for: .milliseconds(300))
        #expect(pasted == 2 && !controller.isShown)
    }
}
