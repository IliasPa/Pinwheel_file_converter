import AppKit
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

/// v1.8: the JPEG background and subtitle times in Settings.
@MainActor
struct V18UITests {
    @Test func newFormatSettings() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.jpegBackground == "#FFFFFF" && !settings.subtitleTimes)
        settings.jpegBackground = ConversionsPane.hex(.black)
        settings.subtitleTimes = true
        #expect(settings.conversionOptions.jpegBackground == "#000000" && settings.conversionOptions.subtitleTimes)
        // Kept, and put back by Reset.
        #expect(SettingsStore(defaults: defaults).jpegBackground == "#000000")
        settings.resetToDefaults()
        #expect(settings.jpegBackground == "#FFFFFF" && !settings.subtitleTimes)

        let orange = ConversionsPane.color(hex: "#FFA500")
        #expect(orange.map(ConversionsPane.hex) == "#FFA500" && ConversionsPane.color(hex: "blue") == nil)
        #expect(SettingsPane.allCases.filter { $0.matches("transparent") } == [.wheel])
    }
}
