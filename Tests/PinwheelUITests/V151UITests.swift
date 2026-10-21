import AppKit
import SwiftUI
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

struct V151WheelTests {
    /// The drawn wheel, off screen, in the same kind of window as the real
    /// one: where its pixels are (any that aren't fully see-through).
    private func drawnBox(_ level: GlassLevel) throws -> (box: CGRect, size: CGSize) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "PinwheelTests-\(UUID().uuidString)")!)
        settings.glassLevel = level
        let model = WheelModel.sample(hovered: 0)
        model.hovered = nil
        let size = WheelController.panelSize
        let panel = WheelPanel(size: size)
        let hosting = NSHostingView(rootView: WheelPanelContent(model: model, settings: settings))
        hosting.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let scale = CGFloat(rep.pixelsWide) / size
        return (CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale),
                CGSize(width: size, height: size))
    }

    @Test(arguments: [GlassLevel.frosted, .liquid, .crystal])
    func theWheelIsWhereItsMeasuredFrom(_ level: GlassLevel) throws {
        let (box, size) = try drawnBox(level)
        // Centered: the drop view measures from the middle of the window
        // (the hidden title bar used to push the wheel 14 points down).
        #expect(abs(box.midX - size.width / 2) < 1.5 && abs(box.midY - size.height / 2) < 1.5, "\(level): drawn at \(box)")
        // And the whole wheel and its margin have pixels, so macOS hands the
        // pointer to the wheel there (not to the window below).
        #expect(box.width >= WheelPanelContent.catchDiameter - 1 && box.height >= WheelPanelContent.catchDiameter - 1, "\(level): \(box)")
        #expect(WheelPanelContent.catchDiameter >= 2 * (WheelView.outerRadius + WheelView.popOut))
        #expect(WheelPanelContent.catchDiameter <= WheelController.panelSize)
    }
}
