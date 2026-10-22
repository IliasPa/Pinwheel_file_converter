import AppKit
import SwiftUI

/// What you drag out of the clipboard history: a card with the copy on it,
/// leaning into the drag (several files: a little stack, with how many).
struct DragCard: View {
    let item: ClipItem
    let picture: NSImage?
    let count: Int

    static let width: CGFloat = 250
    /// The Mac's accent color (drawn off screen, `.accentColor` is always blue).
    private let accent = Color(nsColor: .controlAccentColor)

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let name = item.appName {
                    Text("From \(name)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.75), lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent))
                    .offset(x: 8, y: -8)
            }
        }
        .rotationEffect(.degrees(-4))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .padding(22)
    }

    @ViewBuilder
    private var leading: some View {
        if let picture {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.14)))
        }
    }

    /// The card as a picture, for AppKit's drag.
    static func image(of item: ClipItem, store: ClipboardStore, appearance: NSAppearance) -> NSImage {
        let files = store.files(of: item)
        let picture = store.thumbnail(of: item).flatMap { NSImage(contentsOf: $0) }
            ?? files.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(content: DragCard(item: item, picture: picture, count: max(files.count, 1))
            .environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: width, height: 60))
    }
}

/// Hears how a drag out of the clipboard history goes.
final class ClipDragSource: NSObject, NSDraggingSource {
    var onMoved: (NSPoint) -> Void = { _ in }
    var onEnded: (NSPoint, NSDragOperation) -> Void = { _, _ in }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // As pasting would: a copy (files too; the originals stay put).
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onMoved(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded(screenPoint, operation)
    }
}

/// The pointer on a copy in the list (AppKit, like the shelf's drag area):
/// a click chooses it, pressing and holding shows its preview, a drag takes
/// it into another app, and a right-click gives its menu.
struct ClipRowPointer: NSViewRepresentable {
    var holdPreviews: Bool
    var onClick: () -> Void
    var onHold: () -> Void
    var onDragOut: (NSView, NSEvent) -> Void
    var onHover: () -> Void
    var menu: () -> NSMenu

    func makeNSView(context: Context) -> ClipRowPointerView {
        let view = ClipRowPointerView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ClipRowPointerView, context: Context) {
        view.holdPreviews = holdPreviews
        view.onClick = onClick
        view.onHold = onHold
        view.onDragOut = onDragOut
        view.onHover = onHover
        view.makeMenu = menu
    }
}

final class ClipRowPointerView: NSView {
    static let holdTime: TimeInterval = 0.45
    /// How far the pointer moves before it's a drag.
    static let dragDistance: CGFloat = 6

    var holdPreviews = true
    var onClick: () -> Void = {}
    var onHold: () -> Void = {}
    var onDragOut: (NSView, NSEvent) -> Void = { _, _ in }
    var onHover: () -> Void = {}
    var makeMenu: () -> NSMenu = { NSMenu() }
    private var down: NSEvent?
    private var holdTimer: Timer?
    private var held = false

    /// An anchored window that isn't in front still takes the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = event
        held = false
        holdTimer?.invalidate()
        guard holdPreviews else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.down != nil else { return }
                self.held = true
                self.onHold()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let moved = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard moved >= Self.dragDistance else { return }
        holdTimer?.invalidate()
        self.down = nil
        onDragOut(self, down)
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        guard down != nil else { return }
        down = nil
        if !held { onClick() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover() }
}

/// A menu item that runs a closure.
func actionMenuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = action
    item.representedObject = action  // the item keeps it (a target is weak)
    return item
}

final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
