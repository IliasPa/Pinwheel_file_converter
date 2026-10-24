import AppKit
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

// MARK: - Formats on the wheel (Settings › Conversions)

struct FormatWheelSettingsTests {
    @Test func everyFormatIsOnUntilSwitchedOff() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.hiddenFormats.isEmpty)
        for kind in FileKind.allCases {
            #expect(store.shownCount(for: kind, in: .convert) == FormatCatalog.choices(for: kind, mode: .convert).count)
        }
        #expect(store.shownCount(for: .image, in: .convert) == 12, "eleven formats and Collage")
    }

    @Test func formatsAndToolsAreSwitchedOffSeparately() {
        let store = SettingsStore(defaults: freshDefaults())
        let pdf = SourceFile(url: URL(fileURLWithPath: "/tmp/pinwheel-v12/a.pdf"))
        // Compress off the PDF tools wheel…
        store.setOnWheel(.tool(.compress), for: .pdf, false)
        #expect(!store.isOnWheel(.tool(.compress), for: .pdf))
        #expect(!FormatCatalog.actions(for: [pdf], mode: .tools, hidden: store.hidden(in: .tools)).contains(.tool(.compress)))
        // …leaves Smaller PDF on the PDF format wheel, and the other way round.
        #expect(store.isOnWheel(.tool(.compress), for: .pdf, in: .convert))
        #expect(FormatCatalog.actions(for: [pdf], mode: .convert, hidden: store.hidden(in: .convert)).contains(.tool(.compress)))
        store.setOnWheel(.tool(.compress), for: .pdf, true)
        store.setOnWheel(.tool(.compress), for: .pdf, in: .convert, false)
        #expect(store.isOnWheel(.tool(.compress), for: .pdf))
        #expect(!store.isOnWheel(.tool(.compress), for: .pdf, in: .convert))
        #expect(store.hiddenTools == FormatCatalog.defaultHidden)
    }

    @Test func switchedOffFormatsAreRememberedAndReset() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.setOnWheel(.convert(.tiff), for: .image, in: .convert, false)
        store.setOnWheel(.convert(.mp3), for: .video, in: .convert, false)
        #expect(store.shownCount(for: .image, in: .convert) == 11)
        let again = SettingsStore(defaults: defaults)
        #expect(again.hiddenFormats == [FormatCatalog.hiddenKey(.image, .convert(.tiff)), FormatCatalog.hiddenKey(.video, .convert(.mp3))])
        #expect(again.isOnWheel(.convert(.mp3), for: .audio, in: .convert), "MP3 stays for audio files")
        again.resetToDefaults()
        #expect(again.hiddenFormats.isEmpty)
        #expect(SettingsStore(defaults: defaults).hiddenFormats.isEmpty)
    }

    @Test func theWheelLeavesOutWhatsSwitchedOff() throws {
        let scratch = try Scratch()
        let photo = try scratch.image("photo.png")
        let store = SettingsStore(defaults: freshDefaults())
        store.setOnWheel(.convert(.gif), for: .image, in: .convert, false)
        let wheel = WheelController(settings: store)
        wheel.showsOnScreen = false
        wheel.availability = { _, _ in .available }

        wheel.show(urls: [photo], mode: .convert, at: NSPoint(x: 300, y: 300))
        #expect(wheel.model.items.map(\.action) == [
            .convert(.jpeg), .convert(.heic), .convert(.webp), .convert(.avif), .convert(.tiff), .convert(.bmp), .convert(.ico),
            .convert(.icns), .convert(.pdf),
        ])
        // The tools wheel isn't touched by it.
        wheel.setMode(.tools)
        #expect(wheel.model.items.map(\.action).contains(.tool(.compress)))
        wheel.hide()
    }
}

// MARK: - The Settings window

struct SettingsPaneTests {
    private func found(_ search: String) -> [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(search) }
    }

    @Test func searchFindsThePages() {
        #expect(found("") == SettingsPane.allCases)
        #expect(found("  ") == SettingsPane.allCases)
        #expect(found("Glass") == [.general])
        #expect(found("greek") == [.textRecognition])
        #expect(found("JPEG") == [.wheel, .compatibility])
        #expect(found("webm") == [.wheel, .compatibility])
        #expect(found("rar") == [.compatibility])
        #expect(found("crop").contains(.wheel))
        #expect(found("custom actions") == [.wheel])
        #expect(found("ffmpeg") == [.advanced])
        #expect(found("login") == [.general])
        #expect(found("compat") == [.compatibility])
        #expect(found("nothing like this").isEmpty)
    }

    @Test func everyPageHasItsSymbol() {
        for pane in SettingsPane.allCases {
            // Wheels draws a pinwheel of its own.
            guard let symbol = pane.symbolName else { continue }
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "missing SF Symbol \(symbol)")
        }
        #expect(Set(SettingsPane.allCases.map(\.title)).count == SettingsPane.allCases.count)
    }

    @Test func everyPageOpens() async throws {
        let state = SettingsViewState()
        #expect(state.pane == .general, "General, with the permission, comes first")
        let view = SettingsView(
            settings: SettingsStore(defaults: freshDefaults()), launch: LaunchAtLogin(), permission: AccessibilityPermission(),
            state: state, onShowDemo: {}, onShowFFmpegHelp: {}
        )
        let controller = SettingsWindowController(view: view) {}
        let window = try #require(controller.window)
        for pane in SettingsPane.allCases {
            state.pane = pane
            if pane == .compatibility { state.tableSpot = CompatibilityPane.Spot(kind: .image, row: 0, column: 1) }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        window.close()
    }
}
