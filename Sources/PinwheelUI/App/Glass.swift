import AppKit
import SwiftUI

/// The five steps of the "Glass" slider in Settings, from the classic frosted
/// blur to completely clear Liquid Glass.
enum GlassLevel: Int, CaseIterable, Identifiable {
    case frosted = 1
    case tinted
    case liquid
    case clear
    case crystal

    static let defaultLevel = GlassLevel.liquid

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .frosted: "Frosted"
        case .tinted: "Tinted Glass"
        case .liquid: "Liquid Glass"
        case .clear: "Clear Glass"
        case .crystal: "Crystal"
        }
    }

    var detail: String {
        switch self {
        case .frosted: "The classic blurred background, like a menu. Not Liquid Glass."
        case .tinted: "Liquid Glass with a hint of Pinwheel's indigo."
        case .liquid: "Apple's standard Liquid Glass."
        case .clear: "See-through glass with a light shade, so labels stay easy to read."
        case .crystal: "Fully see-through glass: nothing but glass and icons."
        }
    }

    /// The Liquid Glass to use, or nil for the classic frosted look.
    var glass: Glass? {
        switch self {
        case .frosted: nil
        case .tinted, .liquid: .regular
        case .clear, .crystal: .clear
        }
    }

    /// A see-through layer *behind* the glass, which the glass then shows:
    /// indigo for Tinted, a light shade for Clear (Apple recommends a shade
    /// under clear glass so text stays readable on bright backgrounds).
    /// A layer is used rather than tinting the glass itself, because tinted
    /// glass doesn't draw everywhere.
    var backing: Color {
        switch self {
        case .tinted: Brand.indigo.opacity(0.35)
        case .clear: Color.black.opacity(0.2)
        default: Color.clear
        }
    }

    /// Crystal leaves out the thin dividers between wedges.
    var showsDividers: Bool { self != .crystal }
}

/// A background at the chosen glass level, cut to a rounded shape
/// (cornerRadius = half the width gives a circle). Used where the content
/// can't be the glass's own content, such as the frosted fallback.
struct FrostedBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// `.behindWindow` blurs the desktop; `.withinWindow` blurs what's under
    /// the view in the same window (used by the preview in Settings).
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = blending
        view.maskImage = Self.mask(radius: cornerRadius)
    }

    /// A stretchable rounded rectangle; at exactly 2 × radius it's a circle.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// Puts this view on a surface at the chosen glass level, so the view is
    /// the glass's *content* (Liquid Glass then keeps it legible). Frosted
    /// draws the classic blur behind it instead.
    @ViewBuilder
    func glassSurface(
        _ level: GlassLevel,
        cornerRadius: CGFloat,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let glass = level.glass {
            self
                .glassEffect(glass, in: shape)
                .background(shape.fill(level.backing))
        } else {
            self.background(FrostedBackdrop(cornerRadius: cornerRadius, blending: blending))
        }
    }
}
