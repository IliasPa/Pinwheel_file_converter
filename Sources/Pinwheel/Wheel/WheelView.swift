import SwiftUI
import PinwheelCore

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject var settings: SettingsStore
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

    private var level: GlassLevel { settings.glassLevel.effective }
    private var isCrystal: Bool { level == .crystal }

    var body: some View {
        ZStack {
            if !isCrystal {
                if level == .frosted {
                    // Soft shadow under the disc (glass brings its own depth).
                    Circle()
                        .fill(Color.black.opacity(0.22))
                        .blur(radius: 14)
                        .offset(y: 6)
                }
                GlassSurface(level: level, cornerRadius: Self.diameter / 2, blending: blending)
                Circle()
                    .strokeBorder(Color.primary.opacity(level == .frosted ? 0.12 : 0.06), lineWidth: 0.5)
            }

            GlassGroup(enabled: isCrystal) {
                ZStack {
                    wedges
                        .id(model.mode)  // cross-fade when switching between formats and tools
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    HubView(model: model, crystal: isCrystal)
                }
            }
            .scaleEffect(model.isPresented ? 1 : (model.confirmed ? 1.08 : 0.7))
            .rotationEffect(.degrees(model.isPresented || model.confirmed ? 0 : -14))
            .opacity(model.isPresented ? 1 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.isPresented)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.mode)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: settings.glassLevel)
    }

    private var wedges: some View {
        let layout = Self.layout(count: model.items.count)
        return ZStack {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                WedgeCell(
                    item: item, index: index, layout: layout,
                    isHovered: model.hovered == .wedge(index), crystal: isCrystal
                )
            }
        }
    }
}

struct WedgeShape: Shape {
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
    /// Crystal level: the wedge itself is a piece of clear glass.
    let crystal: Bool

    private var isHighlighted: Bool { isHovered && item.isEnabled }

    var body: some View {
        let direction = layout.direction(of: index)
        // A lone wedge is a full ring; sliding it sideways would look odd.
        let pop = isHighlighted && layout.count > 1 ? WheelView.popOut : 0
        let labelRadius = (layout.innerRadius + layout.outerRadius) / 2
        let shape = WedgeShape(layout: layout, index: index)
        ZStack {
            if crystal {
                Color.clear
                    .crystalGlass(enabled: true, in: shape)
                    .overlay(shape.fill(Brand.gradient).opacity(isHighlighted ? 0.85 : 0))
            } else {
                shape
                    .fill(fill)
                    .overlay {
                        shape.stroke(Color.primary.opacity(isHighlighted ? 0 : 0.10), lineWidth: 0.5)
                    }
                    .shadow(color: Brand.indigo.opacity(isHighlighted ? 0.45 : 0), radius: 10, y: 3)
            }

            VStack(spacing: 3) {
                Image(systemName: item.symbolName)
                    .font(.system(size: isHighlighted ? 19 : 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(item.title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 64)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .opacity(item.isEnabled ? 1 : 0.35)
            .offset(x: direction.dx * labelRadius, y: -direction.dy * labelRadius)
        }
        .offset(x: direction.dx * pop, y: -direction.dy * pop)
        .animation(.spring(response: 0.26, dampingFraction: 0.68), value: isHighlighted)
    }

    private var fill: AnyShapeStyle {
        if isHighlighted { return AnyShapeStyle(Brand.gradient) }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(0.10)) }
        return AnyShapeStyle(Color.primary.opacity(item.isEnabled ? 0.07 : 0.03))
    }
}

/// The circle in the middle: what's being dragged, or what the hovered wedge does.
private struct HubView: View {
    @ObservedObject var model: WheelModel
    let crystal: Bool

    private enum Content: Hashable {
        case idle, nothing, cancel, item(String)
    }

    private var content: Content {
        if model.items.isEmpty { return .nothing }
        if model.hovered == .hub { return .cancel }
        if let item = model.hoveredItem { return .item(item.id) }
        return .idle
    }

    var body: some View {
        ZStack {
            if crystal {
                Color.clear.crystalGlass(enabled: true, in: Circle())
            } else {
                Circle()
                    .fill(Color.primary.opacity(content == .cancel ? 0.12 : 0.05))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
            label
                .frame(width: 84)
                .id(content)
                .transition(.opacity)
        }
        .frame(width: (WheelView.innerRadius - 4) * 2, height: (WheelView.innerRadius - 4) * 2)
        .animation(.easeOut(duration: 0.12), value: content)
    }

    @ViewBuilder
    private var label: some View {
        switch content {
        case .nothing:
            stack(symbol: "nosign", title: "Can't convert", detail: model.summary)
        case .cancel:
            stack(symbol: "xmark", title: "Cancel", detail: nil)
        case .item:
            if let item = model.hoveredItem {
                stack(symbol: nil, title: item.title, detail: item.unavailableReason ?? item.detail)
            }
        case .idle:
            stack(
                symbol: model.summarySymbol,
                title: model.summary,
                detail: model.mode == .tools ? "Tools" : nil
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
