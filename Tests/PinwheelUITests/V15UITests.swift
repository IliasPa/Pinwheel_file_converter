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

struct V15SettingsTests {
    @Test func pdfPagesAsPicturesIsRememberedAndReset() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(!store.pdfPagesAsPictures && !store.conversionOptions.pdfPagesAsPictures)
        store.pdfPagesAsPictures = true

        let again = SettingsStore(defaults: defaults)
        #expect(again.pdfPagesAsPictures && again.conversionOptions.pdfPagesAsPictures)
        again.resetToDefaults()
        #expect(!again.pdfPagesAsPictures)
    }

    @Test func appsCountAsInstalledWhenTheyAre() {
        let store = SettingsStore(defaults: freshDefaults())
        for app in [ExternalTool.pages, .keynote, .numbers] {
            #expect(store.isInstalled(app) == (app.locate() != nil), "\(app.name)")
        }
    }

    @Test func searchFindsDocumentSettings() {
        func found(_ text: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(text) } }
        #expect(found("word").contains(.conversions) && found("word").contains(.compatibility))  // and "Password" in Tools
        #expect(found("subtitles") == [.conversions, .compatibility])
        #expect(found("pages as pictures") == [.conversions])
        #expect(found("epub").contains(.conversions) && found("epub").contains(.compatibility))
    }
}

struct V15CommandTests {
    @Test func theNewFormatsByName() {
        let names: [String: OutputFormat] = [
            "docx": .docx, "Word": .docx, "pages": .pages, "pptx": .pptx, "powerpoint": .pptx, "xlsx": .xlsx, "excel": .xlsx,
            "epub": .epub, "md": .md, "markdown": .md, "txt": .txt, "text": .txt, "rtf": .rtf, "odt": .odt, "html": .html,
            "htm": .html, "ods": .ods, "csv": .csv, "tsv": .tsv, ".srt": .srt, "vtt": .vtt, "webvtt": .vtt,
        ]
        for (name, format) in names {
            #expect(CommandCenter.format(named: name) == format, "\(name)")
        }
    }
}
