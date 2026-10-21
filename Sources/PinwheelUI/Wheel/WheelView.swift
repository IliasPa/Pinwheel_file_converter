import SwiftUI
import PinwheelCore

struct WheelView: View {
    var model: WheelModel
    var settings: SettingsStore
    /// The Settings preview blurs the picture behind it, not the desktop.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    static let diameter: CGFloat = 260
    static let outerRadius: CGFloat = 126
    static let innerRadius: CGFloat = 54
    /// How far a hovered wedge slides outward.
    static let popOut: CGFloat = 8

    static func layout(count: Int) -> WheelLayout {
        WheelLayout(count: count, innerRadius: innerRadius, outerRadius: outerRadius)
    }

    var body: some View {
        Group {
            if settings.glassLevel == .frosted {
                frostedWheel
            } else {
                glassWheel
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: settings.glassLevel)
    }

    /// Liquid Glass with nothing behind it: each wedge is a blade of glass
    /// with its icon and label, and the hub a glass circle (Crystal leaves
    /// the circle out: just its words). Only the chosen wedge is colored.
    private var glassWheel: some View {
        WheelContent(model: model, glass: settings.glassLevel)
            .frame(width: Self.diameter, height: Self.diameter)
            // Glass only grows in; the window itself does the fading.
            .scaleEffect(model.isPresented ? 1 : (model.confirmed ? 1.06 : 0.8))
            .animation(.spring(response: 0.34, dampingFraction: 0.74), value: model.isPresented)
    }

    /// The classic look: a frosted disc with softly filled wedges.
    private var frostedWheel: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.22))
                .blur(radius: 14)
                .offset(y: 6)
            FrostedBackdrop(cornerRadius: Self.diameter / 2, blending: blending)
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            WheelContent(model: model, glass: nil)
                .scaleEffect(model.isPresented ? 1 : (model.confirmed ? 1.08 : 0.7))
                .rotationEffect(.degrees(model.isPresented || model.confirmed ? 0 : -14))
                .opacity(model.isPresented ? 1 : 0)
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.isPresented)
        }
    }
}

/// Wedges, labels and the hub.
private struct WheelContent: View {
    var model: WheelModel
    /// The Liquid Glass level, or nil for the classic frosted look.
    var glass: GlassLevel?

    var body: some View {
        let layout = WheelView.layout(count: model.items.count)
        ZStack {
            ZStack {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    WedgeCell(item: item, index: index, layout: layout, isHovered: model.hovered == .wedge(index), glass: glass)
                }
            }
            .id(model.mode)  // cross-fade when switching between formats and tools
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            HubView(model: model, glass: glass)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.mode)
    }
}

nonisolated struct WedgeShape: Shape {
    let layout: WheelLayout
    let index: Int

    func path(in rect: CGRect) -> Path {
        Path(WedgePath.make(
            center: CGPoint(x: rect.midX, y: rect.midY),
            innerRadius: layout.innerRadius,
            outerRadius: layout.outerRadius,
            startAngle: layout.startAngle(of: index),
            endAngle: layout.endAngle(of: index),
            gap: 5,
            cornerRadius: 10,
            yDown: true
        ))
    }
}

private struct WedgeCell: View {
    let item: WheelItem
    let index: Int
    let layout: WheelLayout
    let isHovered: Bool
    let glass: GlassLevel?

    private var isHighlighted: Bool { isHovered && item.isEnabled }
    private var frosted: Bool { glass == nil }
    private var halo: Bool { glass?.labelHalo ?? false }

    var body: some View {
        let direction = layout.direction(of: index)
        // A lone wedge is a full ring; sliding it sideways would look odd.
        let pop = isHighlighted && layout.count > 1 ? WheelView.popOut : 0
        let labelRadius = (layout.innerRadius + layout.outerRadius) / 2
        let shape = WedgeShape(layout: layout, index: index)
        ZStack {
            if frosted {
                shape
                    .fill(frostedFill)
                    .overlay {
                        shape.stroke(Color.primary.opacity(isHighlighted ? 0 : 0.10), lineWidth: 0.5)
                    }
                    .shadow(color: Brand.indigo.opacity(isHighlighted ? 0.45 : 0), radius: 10, y: 3)
            } else {
                // Only the chosen blade is colored.
                shape
                    .fill(Brand.gradient)
                    .opacity(isHighlighted ? 0.88 : (isHovered ? 0.12 : 0))
                    .shadow(color: Brand.indigo.opacity(isHighlighted ? 0.4 : 0), radius: 10, y: 3)
            }

            VStack(spacing: 3) {
                Image(systemName: item.symbolName)
                    .font(.system(size: isHighlighted ? 19 : 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(item.title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: labelWidth)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .labelHalo(halo && !isHighlighted)
            .opacity(item.isEnabled ? 1 : 0.35)
            .offset(x: direction.dx * labelRadius, y: -direction.dy * labelRadius)
        }
        .glassPiece(glass, in: shape)
        // After the glass, so a chosen blade slides out glass and all.
        .offset(x: direction.dx * pop, y: -direction.dy * pop)
        .animation(.spring(response: 0.26, dampingFraction: 0.68), value: isHighlighted)
    }

    /// As wide as a wedge allows: with 12 formats, neighbours sit closer.
    private var labelWidth: CGFloat {
        guard layout.count > 1 else { return 66 }
        let chord = 2 * (layout.innerRadius + layout.outerRadius) / 2 * sin(layout.step / 2)
        return min(66, chord - 4)
    }

    private var frostedFill: AnyShapeStyle {
        if isHighlighted { return AnyShapeStyle(Brand.gradient) }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(0.10)) }
        return AnyShapeStyle(Color.primary.opacity(item.isEnabled ? 0.07 : 0.03))
    }
}

/// The circle in the middle: what's being dragged, or what the hovered wedge does.
private struct HubView: View {
    var model: WheelModel
    let glass: GlassLevel?

    private var frosted: Bool { glass == nil }
    private var halo: Bool { glass?.labelHalo ?? false }
    /// A glass circle on every Liquid Glass level but Crystal, which shows just the words.
    private var circle: GlassLevel? { glass?.hasHubCircle == true ? glass : nil }

    private enum Content: Hashable {
        case idle, nothing, cancel, switchMode, item(String)
    }

    private var content: Content {
        if model.hovered == .hub && model.isClickMode { return .switchMode }
        if model.items.isEmpty { return .nothing }
        if model.hovered == .hub { return .cancel }
        if let item = model.hoveredItem { return .item(item.id) }
        return .idle
    }

    var body: some View {
        ZStack {
            if frosted {
                Circle()
                    .fill(Color.primary.opacity(content == .cancel ? 0.12 : 0.05))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            } else if circle != nil && (content == .cancel || content == .switchMode) {
                Circle().fill(Color.primary.opacity(0.08))
            }
            label
                .frame(width: 84)
                .labelHalo(halo)
                .id(content)
                .transition(.opacity)
        }
        .frame(width: (WheelView.innerRadius - 4) * 2, height: (WheelView.innerRadius - 4) * 2)
        .glassPiece(circle, in: Circle())
        .animation(.easeOut(duration: 0.12), value: content)
    }

    @ViewBuilder
    private var label: some View {
        switch content {
        case .nothing:
            stack(symbol: "nosign", title: "Can't convert", detail: model.summary)
        case .cancel:
            stack(symbol: "xmark", title: "Cancel", detail: nil)
        case .switchMode:
            stack(symbol: model.mode.next.wheelSymbol, title: model.mode.next.wheelTitle, detail: "Click to switch")
        case .item:
            if let item = model.hoveredItem {
                stack(symbol: nil, title: item.title, detail: item.unavailableReason ?? item.detail)
            }
        case .idle:
            stack(
                symbol: model.summarySymbol,
                title: model.summary,
                detail: model.isClickMode
                    ? (model.mode == .convert ? "" : "\(model.mode.wheelTitle) · ") + "Click here for \(model.mode.next.wheelTitle.lowercased())"
                    : (model.mode == .convert ? nil : model.mode.wheelTitle)
            )
        }
    }

    private func stack(symbol: String?, title: String, detail: String?) -> some View {
        VStack(spacing: 2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}
