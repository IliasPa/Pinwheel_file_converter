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
}
