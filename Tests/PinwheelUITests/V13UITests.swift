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

// MARK: - Clear glass in windows that aren't key

struct GlassPanelTests {
    /// AppKit asks these to decide between clear and frosted glass.
    @Test func floatingPanelsLookActiveWithoutBeingKey() {
        typealias Question = @convention(c) (AnyObject, Selector) -> Bool
        let panels: [NSPanel] = [WheelPanel(size: 100), ProgressPanel(size: NSSize(width: 100, height: 60))]
        for panel in panels {
            for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus"] {
                let selector = NSSelectorFromString(name)
                let ask = unsafeBitCast(panel.method(for: selector), to: Question.self)
                #expect(ask(panel, selector), "\(type(of: panel)) \(name)")
            }
            #expect(!panel.isKeyWindow, "it only looks active; the keyboard stays with Finder")
        }
        #expect(!WheelPanel(size: 100).canBecomeKey)
    }
}

// MARK: - Trackpad vibration

struct VibrationTests {
    @Test func highUntilChosen() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.vibration == .high)
        #expect(Vibration.allCases.map(\.title) == ["Off", "Low", "High"])
    }

    @Test func theOldSwitchBecomesOffOrHigh() {
        let off = freshDefaults()
        off.set(false, forKey: "hapticFeedback")
        #expect(SettingsStore(defaults: off).vibration == .off)
        #expect(off.object(forKey: "hapticFeedback") == nil, "the old setting is gone once moved")
        #expect(SettingsStore(defaults: off).vibration == .off, "and stays moved")

        let on = freshDefaults()
        on.set(true, forKey: "hapticFeedback")
        #expect(SettingsStore(defaults: on).vibration == .high)
    }

    @Test func rememberedAndReset() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.vibration = .low
        #expect(SettingsStore(defaults: defaults).vibration == .low)
        store.resetToDefaults()
        #expect(store.vibration == .high)
        #expect(SettingsStore(defaults: defaults).vibration == .high)
    }

    @Test func lowIsLighterThanHigh() {
        #expect(Vibration.off.pattern == nil)
        #expect(Vibration.low.pattern == .alignment)
        #expect(Vibration.high.pattern == .levelChange)
    }
}
