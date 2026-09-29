import AppKit
import SwiftUI
import PinwheelCore

/// Shows, moves and hides the wheel panel, and turns drops into jobs.
@MainActor
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

    private lazy var panel: WheelPanel = makePanel()
    private var files: [SourceFile] = []
    private var hideGeneration = 0
    private var pendingHide: Date?

    func show(urls: [URL], mode: WheelMode, at location: NSPoint) {
        hideGeneration += 1
        pendingHide = nil
        files = urls.map(SourceFile.init)
        model.summary = FormatCatalog.summary(for: files)
        model.summarySymbol = FormatCatalog.symbolName(for: files)
        model.hovered = nil
        model.confirmed = false
        apply(mode: mode)

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
        Task { @MainActor in self.model.isPresented = true }
    }

    func setMode(_ mode: WheelMode) {
        guard mode != model.mode else { return }
        model.hovered = nil
        apply(mode: mode)
    }

    /// Hides the wheel. When several hide requests overlap, the earliest wins.
    func hide(after delay: TimeInterval = 0) {
        let deadline = Date().addingTimeInterval(delay)
        if let pendingHide, pendingHide <= deadline { return }
        pendingHide = deadline
        hideGeneration += 1
        let generation = hideGeneration

        Task { @MainActor in
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
        }
    }

    // MARK: - Private

    private func apply(mode: WheelMode) {
        model.mode = mode
        let kinds = Set(files.map(\.kind))
        let commonKind = kinds.count == 1 ? kinds.first! : nil
        model.items = FormatCatalog.actions(for: files, mode: mode).map { action in
            var reason: String?
            if case .unavailable(let why) = availability(action, files) { reason = why }
            return WheelItem(
                action: action,
                title: action.title(in: mode),
                symbolName: action.symbolName(in: mode),
                detail: action.detail(for: commonKind),
                unavailableReason: reason
            )
        }
    }

    private func item(for hit: WheelLayout.Hit) -> WheelItem? {
        guard case .wedge(let index) = hit, model.items.indices.contains(index) else { return nil }
        return model.items[index]
    }

    private func handleDrop(_ hit: WheelLayout.Hit, urls: [URL]) -> Bool {
        guard let item = item(for: hit), item.isEnabled else { return false }
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
            self?.item(for: hit)?.isEnabled == true
        }
        dropView.onHover = { [weak self] hit in
            guard let self, self.model.hovered != hit else { return }
            self.model.hovered = hit
        }
        dropView.onDrop = { [weak self] hit, urls in
            self?.handleDrop(hit, urls: urls) ?? false
        }

        let hosting = PassthroughHostingView(rootView: WheelView(model: model))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.unregisterDraggedTypes()
        dropView.addSubview(hosting)

        panel.contentView = dropView
        return panel
    }
}
