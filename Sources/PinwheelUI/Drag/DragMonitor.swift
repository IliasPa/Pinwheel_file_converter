import AppKit
import PinwheelCore

/// Watches the whole system for file drags and tells the app when the wheel
/// should appear, change mode, or disappear.
///
/// How it knows a file drag started: macOS puts dragged items on a special
/// "drag" pasteboard. If that pasteboard changes between mouse-down and the
/// first mouse-dragged event, a new drag began, and we can read its file URLs.
final class DragMonitor {
    /// The wheel should appear for these files, at this screen point.
    var onShow: ((_ urls: [URL], _ mode: WheelMode, _ location: NSPoint) -> Void)?
    /// The user pressed or released Option while the wheel is open.
    var onModeChange: ((WheelMode) -> Void)?
    /// The wheel should go away. `dragEnded` is true when the mouse button was
    /// released (a drop may still be arriving) and false when the keys were let go.
    var onHide: ((_ dragEnded: Bool) -> Void)?
    /// The keys that open each wheel (Settings).
    var keys: () -> WheelKeys = { .standard }
    /// The wheel stays open after the keys are let go, until a drop or Esc.
    var keepsOpen: () -> Bool = { false }

    private let pasteboard = NSPasteboard(name: .drag)
    private var monitors: [Any] = []
    private var baselineChangeCount = 0
    private var dragChecked = true
    private var dragURLs: [URL] = []
    private var shownMode: WheelMode?
    /// Closed with Esc: stays closed until the next drag.
    private var dismissed = false
    private var pollTimer: Timer?

    func start() {
        stop()
        baselineChangeCount = pasteboard.changeCount
        addMonitor(.leftMouseDown) { monitor, _ in monitor.mouseDown() }
        addMonitor(.leftMouseDragged) { $0.mouseDragged($1) }
        addMonitor(.leftMouseUp) { monitor, _ in monitor.endDrag() }
        addMonitor(.flagsChanged) { $0.update(flags: $1.modifierFlags) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopPolling()
    }

    // MARK: - Events

    private func addMonitor(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (DragMonitor, NSEvent) -> Void) {
        // Global monitors are delivered on the main thread.
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, event)
            }
        }
        if let monitor { monitors.append(monitor) }
    }

    private func mouseDown() {
        if shownMode != nil { endDrag() }
        baselineChangeCount = pasteboard.changeCount
        dragChecked = false
        dragURLs = []
        dismissed = false
    }

    /// Esc closed the wheel: it stays closed for the rest of this drag.
    func dismiss() {
        guard shownMode != nil else { return }
        shownMode = nil
        dismissed = true
        onHide?(false)
    }

    private func mouseDragged(_ event: NSEvent) {
        if !dragChecked {
            // Finder fills the drag pasteboard a few pixels into the drag.
            guard pasteboard.changeCount != baselineChangeCount else { return }
            dragChecked = true
            dragURLs = readFileURLs()
            guard !dragURLs.isEmpty else { return }
            startPolling()
        }
        update(flags: event.modifierFlags)
    }

    private func endDrag() {
        stopPolling()
        dragChecked = true
        dragURLs = []
        baselineChangeCount = pasteboard.changeCount
        if shownMode != nil {
            shownMode = nil
            onHide?(true)
        }
    }

    private func update(flags: NSEvent.ModifierFlags) {
        guard !dragURLs.isEmpty, !dismissed else { return }
        let desired = Self.mode(for: ModifierKeys(flags), keys: keys(), shown: shownMode, keepsOpen: keepsOpen())
        guard desired != shownMode else { return }

        let previous = shownMode
        shownMode = desired
        switch (previous, desired) {
        case (nil, let mode?):
            onShow?(dragURLs, mode, NSEvent.mouseLocation)
        case (_?, nil):
            onHide?(false)
        case (_?, let mode?):
            onModeChange?(mode)
        case (nil, nil):
            break
        }
    }

    /// The wheel to show for the keys held: exactly a wheel's keys open it;
    /// with "keep open", letting go leaves the one already showing.
    static func mode(for pressed: ModifierKeys, keys: WheelKeys, shown: WheelMode?, keepsOpen: Bool) -> WheelMode? {
        keys.mode(for: pressed) ?? (keepsOpen ? shown : nil)
    }

    private func readFileURLs() -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL] ?? []).map(\.standardizedFileURL)
    }

    // MARK: - Polling

    /// While a file drag is in progress, re-check the modifier keys and the
    /// mouse button 30 times a second. This catches Shift being pressed while
    /// the mouse is standing still, and drags that end without a mouse-up event.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.endDrag()
                } else {
                    self.update(flags: NSEvent.modifierFlags)
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
