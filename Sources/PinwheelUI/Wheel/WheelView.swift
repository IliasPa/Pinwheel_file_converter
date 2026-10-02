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

    /// Liquid Glass: the wheel is one piece of glass, and the icons, labels
    /// and thin dividers are its content. Only the chosen wedge is colored.
    private var glassWheel: some View {
        let level = settings.glassLevel
        return WheelContent(model: model, style: .glass(dividers: level.showsDividers))
            .frame(width: Self.diameter, height: Self.diameter)
            .glassSurface(level, cornerRadius: Self.diameter / 2, blending: blending)
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
            WheelContent(model: model, style: .frosted)
                .scaleEffect(model.isPresented ? 1 : (model.confirmed ? 1.08 : 0.7))
                .rotationEffect(.degrees(model.isPresented || model.confirmed ? 0 : -14))
                .opacity(model.isPresented ? 1 : 0)
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.isPresented)
        }
    }
}

/// Wedges (or dividers), labels and the hub.
private struct WheelContent: View {
    enum Style: Equatable {
        case frosted
        case glass(dividers: Bool)
    }

    var model: WheelModel
    var style: Style

    var body: some View {
        let layout = WheelView.layout(count: model.items.count)
        ZStack {
            if case .glass(true) = style, layout.count > 1 {
                Dividers(layout: layout)
                    .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            ZStack {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    WedgeCell(
                        item: item, index: index, layout: layout,
                        isHovered: model.hovered == .wedge(index), frosted: style == .frosted
                    )
                }
            }
            .id(model.mode)  // cross-fade when switching between formats and tools
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            HubView(model: model, frosted: style == .frosted)
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

/// Thin lines between the wedges and around the hub (glass levels).
private nonisolated struct Dividers: Shape {
    let layout: WheelLayout

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in 0..<layout.count {
            let angle = layout.startAngle(of: index)
            let from = layout.innerRadius + 6
            let to = layout.outerRadius - 12
            path.move(to: CGPoint(x: center.x + from * sin(angle), y: center.y - from * cos(angle)))
            path.addLine(to: CGPoint(x: center.x + to * sin(angle), y: center.y - to * cos(angle)))
        }
        let hub = layout.innerRadius - 4
        path.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
        return path
    }
}

private struct WedgeCell: View {
    let item: WheelItem
    let index: Int
    let layout: WheelLayout
    let isHovered: Bool
    let frosted: Bool

    private var isHighlighted: Bool { isHovered && item.isEnabled }

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
                // On glass, only the chosen wedge is colored.
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
            .frame(width: 66)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .opacity(item.isEnabled ? 1 : 0.35)
            .offset(x: direction.dx * labelRadius, y: -direction.dy * labelRadius)
        }
        .offset(x: direction.dx * pop, y: -direction.dy * pop)
        .animation(.spring(response: 0.26, dampingFraction: 0.68), value: isHighlighted)
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
    let frosted: Bool

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
            if frosted {
                Circle()
                    .fill(Color.primary.opacity(content == .cancel ? 0.12 : 0.05))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            } else if content == .cancel {
                Circle().fill(Color.primary.opacity(0.08))
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
