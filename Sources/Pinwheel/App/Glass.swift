import AppKit
import SwiftUI

/// The five steps of the "Glass" slider in Settings.
enum GlassLevel: Int, CaseIterable, Identifiable {
    case frosted = 1
    case soft
    case liquid
    case clear
    case crystal

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .frosted: "Frosted"
        case .soft: "Soft Glass"
        case .liquid: "Liquid Glass"
        case .clear: "Clear Glass"
        case .crystal: "Crystal"
        }
    }

    var detail: String {
        switch self {
        case .frosted: "The classic blurred background."
        case .soft: "Liquid Glass with a calm, milky tint."
        case .liquid: "Apple's standard Liquid Glass."
        case .clear: "See-through glass that shows more of what's behind."
        case .crystal: "No disc: every wedge is its own piece of clear glass."
        }
    }

    /// Liquid Glass arrived in macOS 26 (Tahoe).
    static var isLiquidGlassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static var defaultLevel: GlassLevel { isLiquidGlassAvailable ? .liquid : .frosted }

    /// What actually gets drawn: older macOS versions always get Frosted.
    var effective: GlassLevel { Self.isLiquidGlassAvailable ? self : .frosted }

    @available(macOS 26, *)
    var backgroundGlass: Glass {
        switch self {
        case .frosted, .soft, .liquid: .regular
        case .clear, .crystal: .clear
        }
    }

    /// Soft Glass adds a milky layer over regular glass. (A plain layer rather
    /// than a glass tint, which some offscreen renderers can't draw.)
    var milkiness: Double { self == .soft ? 0.45 : 0 }
}

/// A background at the chosen glass level, cut to a rounded shape
/// (use cornerRadius = half the width for a circle).
struct GlassSurface: View {
    var level: GlassLevel
    var cornerRadius: CGFloat
    /// `.behindWindow` blurs the desktop; `.withinWindow` blurs what's under
    /// the view in the same window (used by the preview in Settings).
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        if #available(macOS 26, *), level.effective != .frosted {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            Color.clear
                .glassEffect(level.backgroundGlass, in: shape)
                .overlay(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(level.milkiness)))
        } else {
            FrostedBackdrop(cornerRadius: cornerRadius, blending: blending)
        }
    }
}

/// Classic frosted glass (NSVisualEffectView). SwiftUI's own materials can't
/// blur the desktop behind a window, so this wraps the AppKit view.
struct FrostedBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat
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
    /// Clear Liquid Glass in `shape` (Crystal level). Does nothing when
    /// `enabled` is false or on macOS before 26.
    @ViewBuilder
    func crystalGlass(enabled: Bool, in shape: some Shape) -> some View {
        if #available(macOS 26, *), enabled {
            self.glassEffect(.clear, in: shape)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they render together and flow into each other
/// when they move (Crystal level). A plain container otherwise.
struct GlassGroup<Content: View>: View {
    var enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), enabled {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}
