import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.8: quick buttons that look like buttons, categories only when
/// there's something in them, and one Wheels page in Settings.
@MainActor
struct V178Tests {
    private func freshDefaults() -> UserDefaults {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func add(_ text: String, to store: ClipboardStore) throws -> ClipItem {
        try #require(store.add([[(type: UTType.utf8PlainText.identifier, data: Data(text.utf8))]], appID: nil, appName: nil))
    }

    @Test func emptyCategoriesAreHidden() throws {
        let scratch = try Scratch()
        let store = ClipboardStore(folder: scratch.url)
        let model = ClipboardPanelModel(store: store)
        #expect(model.shownKinds.isEmpty && !model.showsFavorites)

        let note = try add("A note", to: store)
        _ = try add("https://example.com", to: store)
        #expect(model.shownKinds == [.text, .link], "no images or files yet")
        model.kind = .image
        #expect(model.shownKinds == [.text, .link, .image], "the one chosen stays, to be let go of")
        model.kind = nil

        store.toggleFavorite(note)
        #expect(model.showsFavorites)
        store.toggleFavorite(try #require(store.items.first { $0.id == note.id }))
        #expect(!model.showsFavorites)
        model.dragging = note.id
        #expect(model.showsFavorites, "while a copy is dragged, to drop it there")
        model.dragging = nil

        // A collection: shown while new, then only with something in it.
        model.naming = CollectionNaming(name: "Work")
        model.finishNaming()
        let work = try #require(store.collections.first)
        #expect(model.shows(work), "just made")
        model.prepare()
        #expect(!model.shows(work), "empty, next time the window opens")
        model.dragging = note.id
        #expect(model.shows(work), "while a copy is dragged")
        model.dragging = nil
        store.add(note, to: work.id)
        #expect(model.shows(try #require(store.collections.first)))
    }

    /// The quick buttons light up when pointed at, and more when pressed.
    @Test func quickButtonsLookLikeButtons() throws {
        let button = ClickAreaView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        #expect(button.layer?.backgroundColor == nil)
        button.mouseEntered(with: event)
        #expect(button.isHovered && button.layer?.backgroundColor != nil && button.layer?.borderWidth == 1)
        button.mouseExited(with: event)
        #expect(!button.isHovered && button.layer?.backgroundColor == nil && button.layer?.borderWidth == 0)
    }

    /// Conversions and Tools are one page, Wheels; Appearance and Wheel
    /// feedback are in General.
    @Test func oneWheelsPage() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Wheels", "Compatibility", "Clipboard", "Text Recognition", "Finder & Shortcuts", "Advanced"])
        func found(_ text: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(text) } }
        #expect(found("vibration") == [.general] && found("frosted") == [.general])
        #expect(found("keys").contains(.wheel) && found("airdrop") == [.wheel] && found("custom actions") == [.wheel])

        // A search opens the wheel it's about.
        let state = SettingsViewState()
        for (search, wheel) in [("crop", WheelMode.tools), ("airdrop", .actions), ("webm", .convert), ("custom actions", .tools), ("x", .tools)] {
            state.showWheel(for: search)
            #expect(state.wheelPage == wheel, "\(search)")
        }
    }

    @Test func everyWheelOpens() async throws {
        let state = SettingsViewState()
        let view = SettingsView(
            settings: SettingsStore(defaults: freshDefaults()), launch: LaunchAtLogin(), permission: AccessibilityPermission(),
            state: state, onShowDemo: {}, onShowFFmpegHelp: {}
        )
        let controller = SettingsWindowController(view: view) {}
        let window = try #require(controller.window)
        state.pane = .wheel
        for wheel in WheelMode.allCases {
            for kind in [FileKind.image, .video, .audio, .pdf, .archive] {
                state.wheelPage = wheel
                state.settingsKind = kind
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        window.close()
    }
}
