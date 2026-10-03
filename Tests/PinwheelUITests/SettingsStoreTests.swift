import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

struct SettingsStoreTests {
    private func freshStore() -> SettingsStore {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    @Test func defaultsMatchTheEngine() {
        let options = freshStore().conversionOptions
        let factory = ConversionOptions()
        #expect(options.jpegQuality == factory.jpegQuality)
        #expect(options.resize == factory.resize)
        #expect(options.audioBitRate == factory.audioBitRate)
        #expect(options.gifMaxSeconds == factory.gifMaxSeconds)
        #expect(options.saveLocation == .nextToOriginal)
    }

    @Test func filesAtTheSameTimeIsAutomaticUnlessChosen() {
        let store = freshStore()
        #expect(store.concurrencyLimit == .automatic)
        store.maxConcurrentJobs = 4
        #expect(store.concurrencyLimit == .fixed(4))
    }
}

struct SettingsWindowTests {
    @Test func closingSettingsTellsTheAppSoItCanLetGo() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let view = SettingsView(
            settings: SettingsStore(defaults: UserDefaults(suiteName: name)!),
            launch: LaunchAtLogin(),
            permission: AccessibilityPermission(),
            state: SettingsViewState(),
            onShowDemo: {},
            onShowFFmpegHelp: {}
        )
        var closed = false
        let controller = SettingsWindowController(view: view) { closed = true }
        controller.window?.close()
        #expect(closed)
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}
