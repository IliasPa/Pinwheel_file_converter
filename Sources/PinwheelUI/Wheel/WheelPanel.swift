import AppKit

/// A see-through panel that floats above everything (including full-screen
/// apps) without ever stealing focus from Finder.
final class WheelPanel: NSPanel {
    init(size: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: GlassWindow.styleMask,
            backing: .buffered,
            defer: true
        )
        GlassWindow.prepare(self, size: NSSize(width: size, height: size))
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = false  // the SwiftUI view draws its own soft shadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Settings shared by Pinwheel's floating windows (the wheel and the
/// progress window).
///
/// They're *titled* windows with the title bar hidden, not borderless ones:
/// on macOS 26, Liquid Glass in a borderless window can't see what's behind
/// the window and turns into a flat gray disc, while in a titled window it
/// shows the desktop through the glass. (Tested side by side in v0.5.1.)
enum GlassWindow {
    static let styleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]

    static func prepare(_ window: NSWindow, size: NSSize) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        // A titled window's frame includes the (hidden) title bar; make the
        // whole frame exactly `size`, all of it content.
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
    }
}
