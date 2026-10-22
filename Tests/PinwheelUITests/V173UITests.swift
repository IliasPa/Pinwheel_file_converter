import AppKit
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.3: a copy's preview (press and hold, or Space) and dragging copies out.
@MainActor
struct ClipPreviewAndDragTests {
    private func freshSettings() -> SettingsStore {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    private func store(_ scratch: Scratch, _ words: [String]) -> ClipboardStore {
        let store = ClipboardStore(folder: scratch.url)
        for word in words {
            store.add([[(type: UTType.utf8PlainText.identifier, data: Data(word.utf8))]], appID: nil, appName: nil)
        }
        return store
    }

    @Test func theSetting() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.clipboardPreview == .holdOrSpace)
        settings.clipboardPreview = .space
        #expect(SettingsStore(defaults: defaults).clipboardPreview == .space)
        #expect(!ClipPreviewTrigger.space.byHolding && ClipPreviewTrigger.space.bySpace)
        #expect(ClipPreviewTrigger.hold.byHolding && !ClipPreviewTrigger.hold.bySpace)
        settings.resetToDefaults()
        #expect(settings.clipboardPreview == .holdOrSpace)
    }

    @Test func previewingWithTheKeyboard() throws {
        let scratch = try Scratch()
        let model = ClipboardPanelModel(store: store(scratch, ["alpha", "beta", "gamma"]))
        var copied: [String] = []
        model.onCopy = { copied.append($0.preview) }
        model.prepare()
        model.togglePreview()  // Space
        #expect(model.previewing == model.store.items[0].id)
        model.moveSelection(by: 1)
        #expect(model.previewing == model.store.items[1].id, "the preview follows the arrows")
        model.togglePreview()
        #expect(model.previewing == nil)

        // From the menu (or pressing and holding).
        let gamma = model.store.items[0]
        model.preview(gamma)
        #expect(model.previewing == gamma.id && model.selection == gamma.id)
        #expect(copied.isEmpty)

        // Removing the copy being previewed closes the preview.
        model.removeSelected()
        #expect(model.previewing == nil && model.store.items.count == 2)
    }

    @Test func whatTheStoreGivesBack() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let png = try Data(contentsOf: try scratch.image("shot.png", width: 30, height: 20))
        let picture = try #require(store.add([[(type: UTType.png.identifier, data: png)]], appID: nil, appName: nil))
        #expect(store.imageData(of: picture) == png)
        let rich = try #require(store.add([[
            (type: UTType.utf8PlainText.identifier, data: Data("Hi".utf8)),
            (type: UTType.rtf.identifier, data: Data("{\\rtf1 Hi}".utf8)),
        ]], appID: nil, appName: nil))
        #expect(store.imageData(of: rich) == nil)
        // Dragged out just as it was copied: every type.
        let items = store.pasteboardItems(of: rich)
        #expect(items.count == 1 && items[0].types.map(\.rawValue) == [UTType.utf8PlainText.identifier, UTType.rtf.identifier])
        #expect(items[0].string(forType: .string) == "Hi")
    }

    @Test func theCardThatIsDragged() throws {
        let scratch = try Scratch()
        let store = store(scratch, ["A note to drag"])
        let card = DragCard.image(of: store.items[0], store: store, appearance: NSAppearance(named: .darkAqua)!)
        // The card, turned a little, with room for its shadow.
        #expect(card.size.width > DragCard.width && card.size.width < DragCard.width + 80)
        #expect(card.size.height > 60 && card.size.height < 160)
    }

    @Test func droppedInAnotherApp() async throws {
        let scratch = try Scratch()
        let controller = ClipboardController(settings: freshSettings(), store: store(scratch, ["alpha", "beta"]),
                                             pasteboard: NSPasteboard(name: NSPasteboard.Name("PinwheelTests-\(UUID().uuidString)")))
        controller.show()
        // Anchored, so another test's window coming to the front can't close it.
        controller.model.isPinned = true
        defer {
            controller.model.isPinned = false
            controller.hide()
        }
        let item = controller.store.items[0]
        let window = controller.panel
        let outside = NSPoint(x: window.frame.maxX + 200, y: window.frame.midY)
        let inside = NSPoint(x: window.frame.midX, y: window.frame.midY)

        // Not dropped anywhere: the card flies back, the window stays.
        controller.model.dragging = item.id
        controller.dragEnded(item, at: outside, operation: [])
        #expect(controller.model.dragging == nil && controller.model.justDropped == nil && controller.isShown)
        // Dropped back on the window itself: nothing happens either.
        controller.dragEnded(item, at: inside, operation: .copy)
        #expect(controller.model.justDropped == nil && controller.isShown)

        // Anchored: it stays, and the row says it was dropped.
        controller.dragEnded(item, at: outside, operation: .copy)
        #expect(controller.model.justDropped == item.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.isShown)

        // Otherwise the window goes, as after a paste.
        controller.model.isPinned = false
        controller.dragEnded(item, at: outside, operation: .copy)
        for _ in 0..<40 where controller.isShown { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!controller.isShown && window.alphaValue == 1)
    }

    /// Real clicks in the window: a click pastes, a press and hold shows the
    /// preview, and a drag starts dragging the copy out.
    @Test func clickHoldAndDrag() async throws {
        let scratch = try Scratch()
        let controller = ClipboardController(settings: freshSettings(), store: store(scratch, ["alpha", "beta"]),
                                             pasteboard: NSPasteboard(name: NSPasteboard.Name("PinwheelTests-\(UUID().uuidString)")))
        var copied: [String] = []
        var dragged: [String] = []
        controller.mayPress = { false }  // so the menu says Copy
        controller.model.onCopy = { copied.append($0.preview) }
        controller.model.onDragOut = { item, view, event in
            #expect(view is ClipRowPointerView && event.type == .leftMouseDown)
            dragged.append(item.preview)
        }
        controller.show()
        controller.model.isPinned = true
        defer {
            controller.model.isPinned = false
            controller.hide()
        }
        try await Task.sleep(for: .milliseconds(300))
        let window = controller.panel
        // On the first copy's text: below the search field and the filters.
        let row = NSPoint(x: 260, y: window.frame.height - 149)
        var number = 0
        func send(_ type: NSEvent.EventType, at point: NSPoint) {
            number += 1
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )
            if let event { NSApp.sendEvent(event) }
        }

        // Once the list is laid out (a busy Mac takes a moment).
        for _ in 0..<80 where !(window.contentView?.hitTest(row) is ClipRowPointerView) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(window.contentView?.hitTest(row) is ClipRowPointerView)
        send(.leftMouseDown, at: row)
        try await Task.sleep(for: .milliseconds(60))
        send(.leftMouseUp, at: row)
        for _ in 0..<20 where copied.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(copied == ["beta"], "a click pastes")

        send(.leftMouseDown, at: row)
        try await Task.sleep(for: .milliseconds(800))
        #expect(controller.model.previewing == controller.store.items[0].id, "holding shows the preview")
        send(.leftMouseUp, at: row)
        try await Task.sleep(for: .milliseconds(200))
        #expect(copied == ["beta"], "letting go after holding doesn't paste")
        controller.model.closePreview()
        try await Task.sleep(for: .milliseconds(400))

        send(.leftMouseDown, at: row)
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(16))
            send(.leftMouseDragged, at: NSPoint(x: row.x + CGFloat(step) * 5, y: row.y - CGFloat(step) * 2))
        }
        #expect(dragged == ["beta"], "dragging starts dragging it out")
        send(.leftMouseUp, at: NSPoint(x: row.x + 30, y: row.y - 12))
        try await Task.sleep(for: .milliseconds(200))
        #expect(copied == ["beta"], "a drag isn't a click")

        // A right-click gives the copy's menu.
        let pointer = try #require(window.contentView?.hitTest(row) as? ClipRowPointerView)
        let rightClick = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: row, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 99, clickCount: 1, pressure: 1
        ))
        let menu = try #require(pointer.menu(for: rightClick))
        #expect(menu.items.map(\.title) == ["Copy", "Preview", "Add to Favorites", "", "Remove from History"])
        _ = menu.items[1].target?.perform(menu.items[1].action)
        #expect(controller.model.previewing == controller.store.items[0].id)
        controller.model.closePreview()

        // Clicks still work afterwards.
        send(.leftMouseDown, at: row)
        try await Task.sleep(for: .milliseconds(60))
        send(.leftMouseUp, at: row)
        for _ in 0..<20 where copied.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(copied == ["beta", "beta"])
    }
}

