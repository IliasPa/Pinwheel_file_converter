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
        let p = convert(sender.draggingLocation, from: nil)
        return hitTester?(NSPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)) ?? .outside
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
