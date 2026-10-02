import AppKit
import SwiftUI
import PinwheelCore

/// Shows, moves and hides the wheel panel, and turns drops into jobs.
final class WheelController {
    /// Room around the wheel for its shadow and for a hovered wedge popping out.
    static let padding: CGFloat = 36
    static var panelSize: CGFloat { WheelView.diameter + padding * 2 }

    let model = WheelModel()
    /// Called when files are dropped on an enabled wedge.
    var onDrop: ((_ files: [SourceFile], _ action: WheelAction) -> Void)?
    /// Decides which wedges are grayed out.
    var availability: (WheelAction, [SourceFile]) -> Availability = {
        ConversionEngine.availability(of: $0, for: $1, ffmpegAvailable: false)
    }

    private let settings: SettingsStore
    private let feedback = HoverFeedback()
    private lazy var panel: WheelPanel = makePanel()
    private var files: [SourceFile] = []
    private var hideGeneration = 0
    private var pendingHide: Date?
    /// True while "Show on Desktop" is displaying a sample wheel (no drops).
    private var isDemo = false

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func show(urls: [URL], mode: WheelMode, at location: NSPoint) {
        isDemo = false
        files = urls.map(SourceFile.init)
        model.load(files: files, mode: mode, options: settings.conversionOptions, availability: availability)
        present(at: location)
    }

    /// Shows a sample wheel for a few seconds so the glass setting can be
    /// seen over the real desktop. Placed beside `avoiding` (the Settings window).
    func showDemo(avoiding frame: NSRect?) {
        isDemo = true
        files = [SourceFile.sample]
        model.load(files: files, mode: .convert, options: settings.conversionOptions) { _, _ in .available }

        let screen = NSScreen.main ?? NSScreen.screens.first
        var location = NSPoint(x: screen?.visibleFrame.midX ?? 600, y: screen?.visibleFrame.midY ?? 400)
        if let frame, let visible = screen?.visibleFrame {
            let room = WheelView.diameter / 2 + 40
            location.y = frame.midY
            location.x = frame.minX - room >= visible.minX + room ? frame.minX - room : frame.maxX + room
        }
        present(at: location)
        model.hovered = .wedge(1)
        hide(after: 3)
    }

    func setMode(_ mode: WheelMode) {
        guard mode != model.mode, !isDemo else { return }
        model.hovered = nil
        model.load(files: files, mode: mode, options: settings.conversionOptions, availability: availability)
    }

    /// Hides the wheel. When several hide requests overlap, the earliest wins.
    func hide(after delay: TimeInterval = 0) {
        let deadline = Date().addingTimeInterval(delay)
        if let pendingHide, pendingHide <= deadline { return }
        pendingHide = deadline
        hideGeneration += 1
        let generation = hideGeneration

        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard generation == self.hideGeneration else { return }
            self.model.isPresented = false
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.panel.animator().alphaValue = 0
            }
            guard generation == self.hideGeneration else { return }
            self.panel.orderOut(nil)
            self.model.hovered = nil
            self.pendingHide = nil
            self.isDemo = false
        }
    }

    // MARK: - Private

    private func present(at location: NSPoint) {
        hideGeneration += 1
        pendingHide = nil
        model.hovered = nil
        model.confirmed = false

        let size = Self.panelSize
        let center = clampedCenter(for: location)
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        // Start from the "hidden" state, then spring in on the next frame.
        model.isPresented = false
        Task { self.model.isPresented = true }
    }

    private func item(for hit: WheelLayout.Hit) -> WheelItem? {
        guard case .wedge(let index) = hit, model.items.indices.contains(index) else { return nil }
        return model.items[index]
    }

    private func hoverChanged(to hit: WheelLayout.Hit?) {
        guard model.hovered != hit else { return }
        model.hovered = hit
        // A click (and a trackpad tap) when landing on a usable wedge.
        if let hit, item(for: hit)?.isEnabled == true {
            feedback.play(settings: settings)
        }
    }

    private func handleDrop(_ hit: WheelLayout.Hit, urls: [URL]) -> Bool {
        guard !isDemo, let item = item(for: hit), item.isEnabled else { return false }
        // Normally the dropped files are the ones seen when the drag started.
        let dropped = urls.isEmpty || Set(urls) == Set(files.map(\.url)) ? files : urls.map(SourceFile.init)
        onDrop?(dropped, item.action)
        model.confirmed = true
        hide(after: 0.12)
        return true
    }

    /// Centers the wheel on the pointer, nudged so it stays fully on screen.
    private func clampedCenter(for location: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame.insetBy(dx: 6, dy: 6) else { return location }
        // Radius includes the few points a hovered wedge pops outward.
        return WheelLayout.clampedCenter(location, radius: WheelView.diameter / 2 + WheelView.popOut, within: bounds)
    }

    private func makePanel() -> WheelPanel {
        let size = Self.panelSize
        let panel = WheelPanel(size: size)

        let dropView = WheelDropView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        dropView.hitTester = { [weak self] point in
            guard let self else { return .outside }
            return WheelView.layout(count: self.model.items.count).hit(dx: point.x, dy: point.y)
        }
        dropView.canDrop = { [weak self] hit in
            guard let self, !self.isDemo else { return false }
            return self.item(for: hit)?.isEnabled == true
        }
        dropView.onHover = { [weak self] hit in
            self?.hoverChanged(to: hit)
        }
        dropView.onDrop = { [weak self] hit, urls in
            self?.handleDrop(hit, urls: urls) ?? false
        }

        let hosting = PassthroughHostingView(rootView: WheelView(model: model, settings: settings))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.unregisterDraggedTypes()
        dropView.addSubview(hosting)

        panel.contentView = dropView
        return panel
    }
}
