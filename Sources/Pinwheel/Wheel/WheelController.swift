import AppKit
import SwiftUI
import PinwheelCore

/// Shows, moves and hides the wheel panel.
@MainActor
final class WheelController {
    /// Room around the wheel for its shadow and for a hovered wedge popping out.
    static let padding: CGFloat = 36
    static var panelSize: CGFloat { WheelView.diameter + padding * 2 }

    let model = WheelModel()
    private lazy var panel: WheelPanel = makePanel()
    private var hideGeneration = 0

    func show(urls: [URL], mode: WheelMode, at location: NSPoint) {
        hideGeneration += 1
        model.mode = mode
        model.fileCount = urls.count

        let size = Self.panelSize
        let center = clampedCenter(for: location)
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: false)
        panel.orderFrontRegardless()

        // Start from the "hidden" state, then animate in on the next frame.
        model.isPresented = false
        Task { @MainActor in self.model.isPresented = true }
    }

    func setMode(_ mode: WheelMode) {
        model.mode = mode
    }

    func hide(after delay: TimeInterval = 0) {
        hideGeneration += 1
        let generation = hideGeneration
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard generation == self.hideGeneration else { return }
            self.model.isPresented = false
            try? await Task.sleep(for: .milliseconds(220))
            guard generation == self.hideGeneration else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: - Private

    /// Centers the wheel on the pointer, nudged so it stays fully on screen.
    private func clampedCenter(for location: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame.insetBy(dx: 6, dy: 6) else { return location }
        // Radius includes the few points a hovered wedge pops outward.
        return WheelLayout.clampedCenter(location, radius: WheelView.diameter / 2 + 10, within: bounds)
    }

    private func makePanel() -> WheelPanel {
        let panel = WheelPanel(size: Self.panelSize)
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}
