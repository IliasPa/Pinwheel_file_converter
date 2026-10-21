import AppKit
import AVFoundation
import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

private func freshDefaults() -> UserDefaults {
    let name = "PinwheelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(25))
    }
}

// MARK: - The shelf

struct ShelfTests {
    @Test func parksFilesAndRemembersThem() throws {
        let scratch = try Scratch()
        let a = try scratch.image("a.png"), b = try scratch.image("b.png")
        let defaults = freshDefaults()
        let shelf = ShelfModel(defaults: defaults)
        shelf.add([a, b, a])
        #expect(shelf.items == [a, b].map(\.standardizedFileURL), "each file once")

        let again = ShelfModel(defaults: defaults)
        #expect(again.items == shelf.items, "kept between launches")
        again.remove([a])
        #expect(again.items == [b.standardizedFileURL])

        // A parked file that's moved or deleted is let go.
        try FileManager.default.removeItem(at: b)
        let later = ShelfModel(defaults: defaults)
        #expect(later.items.isEmpty)
        later.add([a])
        later.clear()
        #expect(ShelfModel(defaults: defaults).items.isEmpty)
    }

    @Test func fileActionsAndTheCommandPutFilesOnIt() throws {
        let actions = FileActions()
        var parked: [URL] = []
        actions.onShelf = { parked += $0 }
        actions.perform(.shelf, on: [URL(fileURLWithPath: "/tmp/x.txt")])
        #expect(parked == [URL(fileURLWithPath: "/tmp/x.txt")])
        #expect(FormatCatalog.fileActions.contains(.file(.shelf)) && FormatCatalog.fileActions.count <= FormatCatalog.maxWedges)

        let center = CommandCenter(channel: "PinwheelTests-\(UUID().uuidString)")
        var replies: [CommandCenter.Reply] = []
        center.send = { replies.append($0) }
        var shelved: [URL] = []
        center.addToShelf = { shelved = $0 }
        center.receive(.init(command: "shelf", files: ["/tmp/a.pdf", "/tmp/b.pdf"]))
        #expect(shelved.map(\.path) == ["/tmp/a.pdf", "/tmp/b.pdf"] && replies.last?.state == "finished")
    }
}

// MARK: - Commands, search, wheels

struct V16CommandAndSettingsTests {
    @Test func theNewToolsByName() throws {
        #expect(try CommandCenter.job(for: .init(command: "blur", files: []), recipes: []).get().action == .tool(.blurPrivate))
        #expect(CommandCenter.editor(named: "visualizer") == .visualizer)
    }

    @Test func searchFindsThem() {
        func found(_ text: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(text) } }
        for word in ["shelf", "visualizer", "bleep", "faces", "mono"] {
            #expect(found(word).contains(.tools), "\(word)")
        }
    }

    @Test func blurIsOffTheFullPicturesWheelButVisualizerIsOnTheAudioOne() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(!store.isOnWheel(.tool(.blurPrivate), for: .image, in: .tools))
        #expect(store.isOnWheel(.open(.visualizer), for: .audio, in: .tools))
        #expect(store.isOnWheel(.file(.shelf), for: .pdf, in: .actions))
    }
}

// MARK: - The video and audio editor

struct V16MediaEditorTests {
    @Test func cutsCropsAndBleeps() async throws {
        let scratch = try Scratch()
        let movie = scratch.url.appendingPathComponent("phone.mov")
        try await phoneVideo(at: movie, seconds: 3)
        let model = MediaEditorModel(files: [SourceFile(url: movie)], ffmpegAvailable: true)
        defer { model.close() }
        try await waitUntil { model.duration > 0 && model.uprightSize != .zero }
        #expect(model.shownSize == CGSize(width: 180, height: 320), "upright, as a phone filmed it")

        // Cut at 1 s and 2 s: three pieces; a cut too near another isn't added.
        model.seek(to: 1)
        model.splitHere()
        model.seek(to: 2)
        model.splitHere()
        model.seek(to: 2.05)
        model.splitHere()
        #expect(model.edit.splits == [1, 2] && model.pieceCount == 3)
        model.removeSplit(2)
        #expect(model.pieceCount == 2)

        // A square crop of the upright picture: as wide as it, in the middle.
        model.setCrop(.square)
        let crop = try #require(model.edit.crop)
        #expect(crop.width == 1 && abs(crop.height - 180.0 / 320) < 0.001 && abs(crop.y - (1 - 180.0 / 320) / 2) < 0.001)
        model.moveCrop(to: RelativePoint(x: 0.5, y: 0))
        #expect(model.edit.crop?.y == 0, "it stops at the top")
        #expect(model.croppedSize == CGSize(width: 180, height: 180))
        // Turned, the same shape fits the turned picture.
        model.turn(clockwise: true)
        #expect(model.shownSize == CGSize(width: 320, height: 180) && model.edit.crop?.height == 1)
        model.setCrop(nil)
        #expect(model.edit.crop == nil)

        model.bleepLength = 0.5
        model.seek(to: 1.5)
        model.bleepHere()
        #expect(model.edit.bleeps == [MediaEdit.Bleep(start: 1.5, end: 2)])
        model.removeBleep(model.edit.bleeps[0])
        #expect(model.edit.bleeps.isEmpty)
        #expect(model.changedCount == 1)

        var saved: [MediaEdit] = []
        model.onSave = { _, edit in saved.append(edit) }
        model.save()
        #expect(saved.first?.splits == [1] && saved.first?.quarterTurns == 1)
    }
}
