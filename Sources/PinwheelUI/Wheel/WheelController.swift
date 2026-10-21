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
    /// Esc during a drag: the drag monitor keeps the wheel closed until the next one.
    var onDismiss: () -> Void = {}

    private let settings: SettingsStore
    private let feedback = HoverFeedback()
    private lazy var panel: WheelPanel = makePanel()
    private weak var dropView: WheelDropView?
    private var files: [SourceFile] = []
    private var hideGeneration = 0
    private var pendingHide: Date?
    /// True while "Show on Desktop" is displaying a sample wheel (no drops).
    private var isDemo = false
    /// Watches for Esc and clicks elsewhere while the wheel waits for a click.
    private var clickMonitors: [Any] = []
    /// Watches the arrow keys, Return, Tab and Esc while the wheel shows.
    private var keyMonitors: [Any] = []
    /// A wedge was chosen with Return during a drag: the drop that follows
    /// when the mouse is let go is taken in quietly, so Finder doesn't move
    /// the files to wherever the pointer is.
    private var chosenWithKeys = false
    /// False in tests, which check what the wheel does without showing it.
    var showsOnScreen = true

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func show(urls: [URL], mode: WheelMode, at location: NSPoint) {
        isDemo = false
        setClickMode(false)
        files = urls.map(SourceFile.init)
        load(mode)
        present(at: location)
    }

    /// The wheel for files chosen in Finder's menu: it stays until a wedge
    /// is clicked, Esc is pressed or the pointer clicks somewhere else.
    func showForClick(urls: [URL], mode: WheelMode, at location: NSPoint) {
        isDemo = false
        files = urls.map(SourceFile.init)
        load(mode)
        present(at: location)
        setClickMode(true)
    }

    private func load(_ mode: WheelMode) {
        model.load(
            files: files, mode: mode, options: settings.conversionOptions, hidden: settings.hidden(in: mode),
            recipes: settings.recipes, availability: availability
        )
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
        guard mode != model.mode, !isDemo, !chosenWithKeys else { return }
        model.hovered = nil
        load(mode)
        // The new wheel's wedge under the pointer lights up at once, without
        // waiting for the pointer to move.
        if showsOnScreen, panel.isVisible {
            let pointer = NSEvent.mouseLocation
            let hit = WheelView.layout(count: model.items.count).hit(dx: pointer.x - panel.frame.midX, dy: pointer.y - panel.frame.midY)
            hoverChanged(to: hit == .outside ? nil : hit)
        }
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
            self.setClickMode(false)
            self.setKeysWatched(false)
            self.model.isPresented = false
            let fade = 0.18
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = fade
                self.panel.animator().alphaValue = 0
            }, completionHandler: nil)
            // Wait for the fade with a timer, not its "finished" signal: if
            // that signal never came, the wheel stayed on screen invisible,
            // and later hide requests waited for it.
            try? await Task.sleep(for: .seconds(fade + 0.02))
            guard generation == self.hideGeneration else { return }
            self.panel.orderOut(nil)
            self.model.hovered = nil
            self.pendingHide = nil
            self.isDemo = false
        }
    }

    // MARK: - Choosing with a click

    private func setClickMode(_ on: Bool) {
        model.isClickMode = on
        dropView?.isClickMode = on
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        guard on, showsOnScreen else { return }
        // A click in another app, or Esc, closes it.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { clickMonitors.append(outside) }
        if let escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.hide() } }
        }) { clickMonitors.append(escape) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.hide()
            return nil
        }) { clickMonitors.append(local) }
    }

    func handleClick(_ hit: WheelLayout.Hit) {
        switch hit {
        case .hub:
            setMode(model.mode.next)
        case .wedge:
            _ = handleDrop(hit, urls: [])
        case .outside:
            hide()
        }
    }

    // MARK: - Keyboard

    private func setKeysWatched(_ on: Bool) {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
        guard on, showsOnScreen else { return }
        // Keys usually go to Finder (the global monitor sees them); when
        // Pinwheel is in front, the local one takes them.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            MainActor.assumeIsolated { _ = self?.handleKey(code) }
        }) { keyMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKey(event.keyCode) == true ? nil : event
        }) { keyMonitors.append(local) }
    }

    /// ← → (and ↑ ↓) move between wedges, Return chooses, Tab switches
    /// wheels, Esc closes. Returns whether the key was used.
    @discardableResult
    func handleKey(_ code: UInt16) -> Bool {
        guard model.isPresented, !isDemo, !chosenWithKeys else { return false }
        switch code {
        case 123, 126: moveHighlight(by: -1)
        case 124, 125: moveHighlight(by: 1)
        case 36, 76: chooseHighlighted()
        case 48: setMode(model.mode.next)
        case 53:
            onDismiss()
            hide()
        default: return false
        }
        return true
    }

    private func moveHighlight(by step: Int) {
        let count = model.items.count
        guard count > 0 else { return }
        var index: Int
        if case .wedge(let current)? = model.hovered {
            index = (current + step + count) % count
        } else {
            index = step > 0 ? 0 : count - 1
        }
        // Grayed-out wedges are skipped.
        for _ in 0..<count where !model.items[index].isEnabled {
            index = (index + step + count) % count
        }
        hoverChanged(to: .wedge(index))
    }

    private func chooseHighlighted() {
        guard let hit = model.hovered, item(for: hit)?.isEnabled == true else { return }
        if model.isClickMode {
            _ = handleDrop(hit, urls: [])
            return
        }
        // During a drag: done now; the drop when the mouse is let go is taken in.
        guard let item = item(for: hit) else { return }
        onDrop?(files, item.action)
        model.confirmed = true
        chosenWithKeys = true
    }

    // MARK: - Private

    private func present(at location: NSPoint) {
        hideGeneration += 1
        pendingHide = nil
        model.hovered = nil
        model.confirmed = false
        chosenWithKeys = false
        if !isDemo { setKeysWatched(true) }

        let size = Self.panelSize
        let center = clampedCenter(for: location)
        guard showsOnScreen else {
            model.isPresented = true
            return
        }
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
        guard model.hovered != hit, !chosenWithKeys else { return }
        model.hovered = hit
        // A click (and a trackpad tap) when landing on a usable wedge.
        if let hit, item(for: hit)?.isEnabled == true {
            feedback.play(settings: settings)
        }
    }

    private func handleDrop(_ hit: WheelLayout.Hit, urls: [URL]) -> Bool {
        if chosenWithKeys { return true }  // already done with Return
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
            return self.chosenWithKeys || self.item(for: hit)?.isEnabled == true
        }
        dropView.onHover = { [weak self] hit in
            self?.hoverChanged(to: hit)
        }
        dropView.onDrop = { [weak self] hit, urls in
            self?.handleDrop(hit, urls: urls) ?? false
        }
        dropView.onClick = { [weak self] hit in
            self?.handleClick(hit)
        }
        self.dropView = dropView

        let hosting = PassthroughHostingView(rootView: WheelPanelContent(model: model, settings: settings))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.unregisterDraggedTypes()
        dropView.addSubview(hosting)

        panel.contentView = dropView
        return panel
    }
}

/// The wheel as its panel shows it: in the middle of the whole window, where
/// the drop view measures from, over a disc that keeps the pointer.
struct WheelPanelContent: View {
    var model: WheelModel
    var settings: SettingsStore

    /// The wheel and the margin around it where a drop still counts.
    static var catchDiameter: CGFloat { 2 * (WheelView.outerRadius + WheelView.layout(count: 1).outerSlack) }

    var body: some View {
        ZStack {
            // macOS hands the pointer (and a drag) to the window below
            // wherever nothing is drawn: between the blades, around the hub,
            // and on Liquid Glass most of each blade, since the glass itself
            // is drawn by macOS. A disc too faint to see keeps it on the wheel.
            Circle()
                .fill(Color.black.opacity(0.01))
                .frame(width: Self.catchDiameter, height: Self.catchDiameter)
            WheelView(model: model, settings: settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel is a titled window with its title bar hidden; without
        // this, the wheel sits below the title bar's room, off the middle.
        .ignoresSafeArea()
    }
}
