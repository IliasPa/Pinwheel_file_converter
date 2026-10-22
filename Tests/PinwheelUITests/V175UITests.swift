import AppKit
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.7.5: collections of copies, named by you and kept for good.
@MainActor
struct ClipCollectionTests {
    private func store(_ scratch: Scratch, _ words: [String]) -> ClipboardStore {
        let store = ClipboardStore(folder: scratch.url)
        for word in words {
            store.add([[(type: UTType.utf8PlainText.identifier, data: Data(word.utf8))]], appID: nil, appName: nil)
        }
        return store
    }

    private func item(_ store: ClipboardStore, _ word: String) throws -> ClipItem {
        try #require(store.items.first { $0.preview == word })
    }

    @Test func keptTogetherAndForGood() throws {
        let scratch = try Scratch()
        let store = store(scratch, ["alpha", "beta", "gamma"])
        #expect(store.addCollection(named: "   ") == nil)
        let work = try #require(store.addCollection(named: "  Work "))
        #expect(work.name == "Work")
        store.add(try item(store, "alpha"), to: work.id)
        store.add(try item(store, "alpha"), to: work.id)  // once is enough
        store.add(try item(store, "gamma"), to: work.id)
        #expect(store.collections[0].items.count == 2)
        let first = try item(store, "alpha")
        #expect(store.collections(of: first).map(\.name) == ["Work"])
        #expect(store.matching(collection: work.id).map(\.preview) == ["gamma", "alpha"])
        #expect(store.matching(search: "gam", collection: work.id).map(\.preview) == ["gamma"])
        store.rename(work.id, to: "Office")
        store.rename(work.id, to: " ")  // an empty name changes nothing

        // Kept on this Mac.
        let again = ClipboardStore(folder: scratch.url)
        #expect(again.collections.map(\.name) == ["Office"] && again.collections[0].items.count == 2)

        // Like favorites: past the limit and through Clear History.
        store.limit = 1
        #expect(store.items.map(\.preview) == ["gamma", "beta", "alpha"], "beta is the one newest copy outside")
        store.add([[(type: UTType.utf8PlainText.identifier, data: Data("delta".utf8))]], appID: nil, appName: nil)
        #expect(store.items.map(\.preview) == ["delta", "gamma", "alpha"])
        store.clear()
        #expect(store.items.map(\.preview) == ["gamma", "alpha"])

        // A copy removed from the history leaves its collections too.
        store.remove(try item(store, "gamma"))
        let alpha = try item(store, "alpha")
        #expect(store.collections[0].items == [alpha.id])

        // Without the collection, its copies count toward the limit again.
        store.limit = 0
        store.removeCollection(work.id)
        #expect(store.collections.isEmpty && store.items.isEmpty)
    }

    @Test func makingAndUsingThem() throws {
        let scratch = try Scratch()
        let model = ClipboardPanelModel(store: store(scratch, ["alpha", "beta", "gamma"]))
        model.prepare()
        let beta = try item(model.store, "beta")

        // From a copy's menu: New Collection…, a name, Return.
        model.startNewCollection(adding: beta)
        model.naming?.name = "Recipes"
        model.finishNaming()
        let recipes = try #require(model.store.collections.first)
        #expect(model.naming == nil && recipes.name == "Recipes" && recipes.items == [beta.id])
        #expect(model.notice == ClipNotice(item: beta.id, text: "Added to Recipes", isProblem: false))

        // Escape-like: started and dropped, nothing made.
        model.startNewCollection()
        model.naming = nil
        model.startNewCollection()
        model.finishNaming()
        #expect(model.store.collections.count == 1)

        // Showing one collection; Favorites and it don't mix.
        model.showCollection(recipes.id)
        #expect(model.visible.map(\.preview) == ["beta"])
        model.favoritesOnly = true
        model.showCollection(recipes.id)
        #expect(!model.favoritesOnly)

        // In and out from the menu.
        let gamma = try item(model.store, "gamma")
        model.toggle(gamma, in: model.store.collections[0])
        #expect(model.visible.map(\.preview) == ["gamma", "beta"])
        model.toggle(gamma, in: model.store.collections[0])
        #expect(model.visible.map(\.preview) == ["beta"])

        // Renaming.
        model.startRenaming(model.store.collections[0])
        #expect(model.naming?.name == "Recipes")
        model.naming?.name = "Kitchen"
        model.finishNaming()
        #expect(model.store.collections[0].name == "Kitchen")

        // Dropped on a chip while dragging a copy: added. Anything else: no.
        #expect(!model.drop(on: .collection(recipes.id)))
        model.dragging = gamma.id
        #expect(model.drop(on: .collection(recipes.id)) && model.landed == .collection(recipes.id))
        #expect(model.drop(on: .favorites))
        #expect(try item(model.store, "gamma").isFavorite)
        #expect(model.store.collections[0].items == [beta.id, gamma.id])

        // Deleting (after a yes): the copies stay, the filter goes.
        model.confirmingDelete = recipes.id
        model.deleteCollection(recipes.id)
        #expect(model.store.collections.isEmpty && model.collectionID == nil && model.confirmingDelete == nil)
        #expect(model.store.items.count == 3)
    }

    /// The copy's right-click menu: Add to Collection, with a tick by those
    /// it's in, and Remove from the one shown.
    @Test func theMenu() async throws {
        let scratch = try Scratch()
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let controller = ClipboardController(settings: SettingsStore(defaults: defaults), store: store(scratch, ["alpha", "beta"]),
                                             pasteboard: NSPasteboard(name: NSPasteboard.Name(name)))
        let work = try #require(controller.store.addCollection(named: "Work"))
        _ = controller.store.addCollection(named: "Home")
        controller.store.add(controller.store.items[0], to: work.id)
        controller.show()
        controller.model.isPinned = true
        defer {
            controller.model.isPinned = false
            controller.hide()
        }
        controller.model.showCollection(work.id)
        let window = controller.panel
        let row = try await firstRow(in: window)
        let pointer = try #require(window.contentView?.hitTest(row) as? ClipRowPointerView)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: row, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let menu = try #require(pointer.menu(for: click))
        let collections = try #require(menu.items.first { $0.title == "Add to Collection" }?.submenu)
        #expect(collections.items.map(\.title) == ["Work", "Home", "", "New Collection…"])
        #expect(collections.items.map(\.state) == [.on, .off, .off, .off])
        let remove = try #require(menu.items.first { $0.title == "Remove from \u{201C}Work\u{201D}" })
        _ = remove.target?.perform(remove.action)
        #expect(controller.store.collections[0].items.isEmpty)
    }
}
