import AppKit
import SwiftUI

/// Frosted-glass circle that blurs whatever is *behind* the window (the desktop,
/// Finder). SwiftUI's own materials only blur content inside the same window,
/// and the wheel's window is otherwise empty, so this wraps NSVisualEffectView.
struct WheelBackdrop: NSViewRepresentable {
    var diameter: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.circleMask(diameter: diameter)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func circleMask(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
