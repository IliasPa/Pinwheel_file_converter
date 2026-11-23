import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

/// Settings › New File menu › Name new files.
struct NewFileNameSettingTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-nfn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theNameIsKeptAndResetToTheUsualNames() {
        let suite = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults)
        #expect(store.newFileName == "", "the usual names at first")
        store.newFileName = "{today} Untitled"
        #expect(SettingsStore(defaults: defaults).newFileName == "{today} Untitled")
        store.resetToDefaults()
        #expect(store.newFileName == "" && SettingsStore(defaults: defaults).newFileName == "")
    }

    @Test func everyNewFileGetsTheName() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = folder.appendingPathComponent("Letterhead.docx")
        try Data("my letterhead".utf8).write(to: template)
        let target = folder.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let custom = NewFileEntry.custom(template)
        let service = NewFileService()
        service.entries = { [NewFileEntry(id: "word", isOn: true), NewFileEntry(id: "excel", isOn: true), custom] }
        service.name = { "Untitled" }
        #expect(try await service.make("word", in: target).lastPathComponent == "Untitled.docx")
        #expect(try await service.make("word", in: target).lastPathComponent == "Untitled 2.docx")
        #expect(try await service.make("excel", in: target).lastPathComponent == "Untitled.xlsx")
        let copy = try await service.make(custom.id, in: target)
        #expect(copy.lastPathComponent == "Untitled 3.docx", "your template too")
        #expect(try Data(contentsOf: copy) == Data("my letterhead".utf8), "still a copy of it")
    }

    @Test func theRenameWordsAndNoNameAtAll() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("Invoices", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let service = NewFileService()
        service.entries = { [NewFileEntry(id: "markdown", isOn: true)] }
        service.name = { "{folder} {name}" }
        #expect(try await service.make("markdown", in: target).lastPathComponent == "Invoices New Markdown File.md")
        service.name = { "" }
        #expect(try await service.make("markdown", in: target).lastPathComponent == "New Markdown File.md")
    }
}
