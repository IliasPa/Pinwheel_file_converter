import AppKit

/// A see-through panel that floats above everything (including full-screen
/// apps) without ever stealing focus from Finder.
final class WheelPanel: GlassPanel {
    init(size: CGFloat) {
        super.init(size: NSSize(width: size, height: size), defer: true)
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

/// Pinwheel's floating windows (the wheel and the progress window), whose
/// Liquid Glass always looks like the active window's.
///
/// macOS draws the glass of a window that isn't the key window frosted: a
/// soft blur instead of clear glass that bends what's behind it. These panels
/// are hardly ever key (the wheel shows while Finder is dragging), so they
/// tell AppKit they look active, without taking the keyboard from anyone.
/// Those are AppKit's own questions, not public ones: if a later macOS stops
/// asking them, the glass just goes back to frosted. (Tested side by side on
/// macOS 27 in v1.3: overriding either one gives clear glass.)
class GlassPanel: NSPanel {
    init(size: NSSize, defer: Bool) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: GlassWindow.styleMask,
            backing: .buffered,
            defer: `defer`
        )
        GlassWindow.prepare(self, size: size)
    }

    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
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
