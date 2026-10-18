import AppKit
import SwiftUI
import PinwheelCore

/// The part of the wheel window that receives the dragged files. It tells
/// the controller which wedge is under the pointer and handles the drop.
final class WheelDropView: NSView {
    /// Point is relative to the wheel center, y up.
    var hitTester: (@MainActor (NSPoint) -> WheelLayout.Hit)?
    var canDrop: (@MainActor (WheelLayout.Hit) -> Bool)?
    var onHover: (@MainActor (WheelLayout.Hit?) -> Void)?
    var onDrop: (@MainActor (WheelLayout.Hit, [URL]) -> Bool)?
    /// A click on the wheel, when it was opened to be clicked (not dragged to).
    var onClick: (@MainActor (WheelLayout.Hit) -> Void)?
    var isClickMode = false {
        didSet {
            window?.acceptsMouseMovedEvents = isClickMode
            if !isClickMode { onHover?(nil) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(nil) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canDrop?(hit(sender)) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return onDrop?(hit(sender), urls.map(\.standardizedFileURL)) ?? false
    }

    private func hit(_ sender: NSDraggingInfo) -> WheelLayout.Hit {
        hit(atWindowPoint: sender.draggingLocation)
    }

    private func hit(atWindowPoint point: NSPoint) -> WheelLayout.Hit {
        let p = convert(point, from: nil)
        return hitTester?(NSPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)) ?? .outside
    }

    // MARK: - Clicking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        guard isClickMode else { return }
        let hit = hit(atWindowPoint: event.locationInWindow)
        onHover?(hit == .outside ? nil : hit)
    }

    override func mouseExited(with event: NSEvent) {
        if isClickMode { onHover?(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        // Handled on mouse-up, like a button.
    }

    override func mouseUp(with event: NSEvent) {
        guard isClickMode else { return }
        onClick?(hit(atWindowPoint: event.locationInWindow))
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hit = hit(sender)
        onHover?(hit == .outside ? nil : hit)
        guard canDrop?(hit) == true else { return [] }
        // "Copy" tells Finder to leave the original file alone.
        let allowed = sender.draggingSourceOperationMask
        for operation in [NSDragOperation.copy, .generic, .link] where allowed.contains(operation) {
            return operation
        }
        return []
    }
}

/// Draws SwiftUI but lets drags pass through to the WheelDropView below.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
