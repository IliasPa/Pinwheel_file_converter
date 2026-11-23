import AppKit
import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

struct NewFileMenuTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-nf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aSavedMenuGetsNewKindsAtTheEndAndLosesUnknownOnes() {
        let saved = [
            NewFileEntry(id: "markdown", isOn: true), NewFileEntry(id: "word", isOn: false),
            NewFileEntry(id: "markdown", isOn: false), NewFileEntry(id: "gone-kind", isOn: true),
        ]
        let menu = NewFileEntry.completed(saved)
        #expect(menu.prefix(2).map(\.id) == ["markdown", "word"], "your order stays")
        #expect(menu.filter { $0.id == "markdown" }.count == 1)
        #expect(!menu.contains { $0.id == "gone-kind" })
        #expect(menu.count == NewFileKind.allCases.count)
        #expect(menu.dropFirst(2).allSatisfy { !$0.isOn }, "kinds you never chose start off")
        #expect(NewFileEntry.starting.filter(\.isOn).map(\.id) == NewFileKind.startingMenu.map(\.rawValue))
    }

    @Test func settingsKeepTheMenuAndSayWhenItChanges() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = SettingsStore(defaults: defaults)
        #expect(store.newFileMenu == NewFileEntry.starting)
        var changes = 0
        store.onNewFileMenuChange = { changes += 1 }
        store.newFileMenu.swapAt(0, 1)
        store.newFileMenu[0].isOn = false
        #expect(changes == 2)
        let again = SettingsStore(defaults: defaults)
        #expect(again.newFileMenu.first?.id == "excel" && again.newFileMenu.first?.isOn == false)
    }

    @Test func theExtensionsMenuFileListsWhatsOnInOrder() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = folder.appendingPathComponent("Invoice.xlsx")
        try Data([1, 2, 3]).write(to: template)
        let service = NewFileService()
        service.menuFile = folder.appendingPathComponent("menu.json")
        let custom = NewFileEntry.custom(template)
        let missing = NewFileEntry(id: "custom-x", isOn: true, title: "Gone", path: folder.appendingPathComponent("gone.txt").path)
        service.entries = { [custom, NewFileEntry(id: "text", isOn: true), NewFileEntry(id: "word", isOn: false), missing] }
        service.writeMenu()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: service.menuFile)) as? [String: [[String: String]]]
        let items = try #require(json?["items"])
        #expect(items.map { $0["title"] } == ["Invoice", "Text File"], "off items and missing templates are left out")
        #expect(items.map { $0["ext"] } == ["xlsx", "txt"])
        #expect(items.first?["id"] == custom.id)
    }

    @Test func aRequestFromFinderMakesTheFile() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = NewFileService()
        service.entries = { [NewFileEntry(id: "word", isOn: true), NewFileEntry(id: "markdown", isOn: false)] }
        var revealed: [URL] = []
        service.reveal = { revealed.append($0) }
        let request = try String(data: JSONSerialization.data(withJSONObject: ["id": "word", "folder": folder.path]), encoding: .utf8)
        service.handle(request)
        service.handle(request)
        for _ in 0..<100 where revealed.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(revealed.map(\.lastPathComponent) == ["New Word Document.docx", "New Word Document 2.docx"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("New Word Document 2.docx").path))
    }

    @Test func onlyWhatsOnIsMadeAndOnlyInAFolder() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = NewFileService()
        service.entries = { [NewFileEntry(id: "word", isOn: true), NewFileEntry(id: "markdown", isOn: false)] }
        await #expect(throws: (any Error).self) { _ = try await service.make("markdown", in: folder) }
        await #expect(throws: (any Error).self) { _ = try await service.make("../../etc", in: folder) }
        let file = folder.appendingPathComponent("plain.txt")
        try Data().write(to: file)
        await #expect(throws: (any Error).self) { _ = try await service.make("word", in: file) }
        await #expect(throws: (any Error).self) { _ = try await service.make("word", in: folder.appendingPathComponent("nowhere")) }
        let made = try await service.make("word", in: folder)
        #expect(made.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func yourOwnTemplateIsCopied() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = folder.appendingPathComponent("Letterhead.docx")
        try Data("my letterhead".utf8).write(to: template)
        let target = folder.appendingPathComponent("Letters", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let entry = NewFileEntry.custom(template)
        let service = NewFileService()
        service.entries = { [entry] }
        let made = try await service.make(entry.id, in: target)
        #expect(made.lastPathComponent == "Letterhead.docx")
        #expect(try Data(contentsOf: made) == Data("my letterhead".utf8))
        let second = try await service.make(entry.id, in: target)
        #expect(second.lastPathComponent == "Letterhead 2.docx")
    }

    @Test func aKeptBlankIWorkFileIsCopiedWithoutTheApp() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = NewFileService()
        service.blanksFolder = folder.appendingPathComponent("Blanks", isDirectory: true)
        try FileManager.default.createDirectory(at: service.blanksFolder, withIntermediateDirectories: true)
        try Data("pages".utf8).write(to: service.blanksFolder.appendingPathComponent("Blank.pages"))
        service.entries = { [NewFileEntry(id: "pages", isOn: true)] }
        let made = try await service.make("pages", in: folder)
        #expect(made.lastPathComponent == "New Pages Document.pages")
        #expect(try Data(contentsOf: made) == Data("pages".utf8))
    }
}
