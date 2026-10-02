import AppKit
import Observation
import SwiftUI

/// Tracks whether the pointer is over the progress window (so it stays open).
@Observable
final class HoverTracker {
    var isHovering = false
}

/// A small floating window in the top-right corner listing each job.
/// It opens when a conversion starts and closes a few seconds after the last
/// one finishes, unless something failed or the pointer is over it.
final class ProgressController {
    static let width: CGFloat = 380
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 58
    static let maxVisibleRows = 5
    static let cornerRadius: CGFloat = 16

    private let queue: JobQueue
    private let settings: SettingsStore
    private let hover = HoverTracker()
    private var panel: ProgressPanel?
    private var autoHide: Task<Void, Never>?

    init(queue: JobQueue, settings: SettingsStore) {
        self.queue = queue
        self.settings = settings
    }

    /// Call whenever the queue changes.
    func jobsChanged() {
        if !queue.jobs.isEmpty && panel?.isVisible != true {
            // Opens by itself only when that's switched on in Settings.
            if settings.showProgressWindow && !queue.isIdle { show() }
        } else {
            resize(animated: true)
        }
        scheduleAutoHide()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            let height = contentHeight
            panel.setFrame(
                NSRect(x: visible.maxX - Self.width - 12, y: visible.maxY - height - 12, width: Self.width, height: height),
                display: false
            )
        }
        resize(animated: false)
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }

    func close() {
        autoHide?.cancel()
        panel?.orderOut(nil)
        queue.clearFinished()
    }

    // MARK: - Private

    private var contentHeight: CGFloat {
        let rows = max(1, min(queue.jobs.count, Self.maxVisibleRows))
        return Self.headerHeight + CGFloat(rows) * Self.rowHeight + 8
    }

    /// Grows or shrinks the window, keeping its top-right corner in place.
    private func resize(animated: Bool) {
        guard let panel else { return }
        let height = contentHeight
        let frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        let newFrame = NSRect(x: frame.maxX - Self.width, y: frame.maxY - height, width: Self.width, height: height)
        panel.setFrame(newFrame, display: true, animate: animated && panel.isVisible)
        panel.invalidateShadow()
    }

    private func scheduleAutoHide() {
        autoHide?.cancel()
        guard panel?.isVisible == true, !queue.jobs.isEmpty, queue.isIdle, !queue.hasFailures else { return }
        autoHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            while self?.hover.isHovering == true, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, let self, self.queue.isIdle, !self.queue.hasFailures else { return }
            self.close()
        }
    }

    private func makePanel() -> ProgressPanel {
        let panel = ProgressPanel(size: NSSize(width: Self.width, height: contentHeight))
        let view = ProgressListView(
            queue: queue,
            settings: settings,
            hover: hover,
            onReveal: { job in NSWorkspace.shared.activateFileViewerSelecting(job.outputs) },
            onClose: { [weak self] in self?.close() }
        )
        panel.setContent(view)
        return panel
    }
}

/// Borderless floating panel (its glass or frosted background is drawn by
/// the SwiftUI view). It can take clicks (for the buttons) without pulling
/// Pinwheel or the panel to the front.
final class ProgressPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setContent<Content: View>(_ view: Content) {
        let hosting = FirstClickHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

/// Buttons respond to the first click even though the panel isn't focused.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
