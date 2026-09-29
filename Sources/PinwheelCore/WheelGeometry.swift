import CoreGraphics
import Foundation

/// Which wheel is showing: output formats (Shift) or tools (Option+Shift).
public enum WheelMode: String, Sendable, Equatable {
    case convert
    case tools
}

/// Angles are measured in radians, clockwise from 12 o'clock.
public struct WheelLayout: Sendable, Equatable {
    public var count: Int
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat
    /// Extra distance past the outer edge that still counts as "on a wedge",
    /// so a drop just outside the rim isn't lost.
    public var outerSlack: CGFloat

    public init(count: Int, innerRadius: CGFloat, outerRadius: CGFloat, outerSlack: CGFloat = 16) {
        self.count = count
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.outerSlack = outerSlack
    }

    public enum Hit: Equatable, Sendable {
        case hub
        case wedge(Int)
        case outside
    }

    public var step: CGFloat { count > 0 ? 2 * .pi / CGFloat(count) : 2 * .pi }

    public func centerAngle(of index: Int) -> CGFloat { CGFloat(index) * step }
    public func startAngle(of index: Int) -> CGFloat { centerAngle(of: index) - step / 2 }
    public func endAngle(of index: Int) -> CGFloat { centerAngle(of: index) + step / 2 }

    /// `dx`/`dy` are the offset from the wheel center with y pointing up.
    public func hit(dx: CGFloat, dy: CGFloat) -> Hit {
        let r = hypot(dx, dy)
        if r < innerRadius { return .hub }
        if r > outerRadius + outerSlack || count == 0 { return .outside }
        var angle = atan2(dx, dy)  // clockwise from the top
        if angle < 0 { angle += 2 * .pi }
        let shifted = (angle + step / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return .wedge(min(Int(shifted / step), count - 1))
    }

    /// Unit direction (x right, y up) pointing through the middle of a wedge.
    public func direction(of index: Int) -> CGVector {
        let a = centerAngle(of: index)
        return CGVector(dx: sin(a), dy: cos(a))
    }

    /// Moves a desired wheel center just enough that a circle of `radius`
    /// stays inside `bounds` (both in the same coordinate space).
    public static func clampedCenter(_ desired: CGPoint, radius: CGFloat, within bounds: CGRect) -> CGPoint {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi)
        }
        return CGPoint(
            x: clamp(desired.x, bounds.minX + radius, bounds.maxX - radius),
            y: clamp(desired.y, bounds.minY + radius, bounds.maxY - radius)
        )
    }
}

/// Builds the outline of one rounded wheel wedge (an annular sector with
/// evenly wide gaps between neighbours and softly rounded corners).
public enum WedgePath {
    public static func make(
        center c: CGPoint,
        innerRadius: CGFloat,
        outerRadius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        gap: CGFloat,
        cornerRadius: CGFloat,
        yDown: Bool
    ) -> CGPath {
        let cr = max(0, min(cornerRadius, (outerRadius - innerRadius) / 2 - 0.5))
        // Shrink the wedge by the corner radius, then grow it back with a
        // round-joined stroke: that gives rounded corners on every side.
        let edgeOffset = gap / 2 + cr
        let rIn = innerRadius + cr
        let rOut = outerRadius - cr
        guard rIn > edgeOffset, rOut > rIn else { return CGMutablePath() }

        let outStart = startAngle + asin(edgeOffset / rOut)
        let outEnd = endAngle - asin(edgeOffset / rOut)
        let inStart = startAngle + asin(edgeOffset / rIn)
        let inEnd = endAngle - asin(edgeOffset / rIn)
        guard outEnd > outStart, inEnd > inStart else { return CGMutablePath() }

        func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: c.x + r * sin(a), y: yDown ? c.y - r * cos(a) : c.y + r * cos(a))
        }
        func arcSteps(_ from: CGFloat, _ to: CGFloat) -> Int {
            max(2, Int(abs(to - from) / (.pi / 90)))  // one point every 2 degrees
        }

        let core = CGMutablePath()
        core.move(to: point(rOut, outStart))
        let outerSteps = arcSteps(outStart, outEnd)
        for i in 1...outerSteps {
            core.addLine(to: point(rOut, outStart + (outEnd - outStart) * CGFloat(i) / CGFloat(outerSteps)))
        }
        core.addLine(to: point(rIn, inEnd))
        let innerSteps = arcSteps(inStart, inEnd)
        for i in 1...innerSteps {
            core.addLine(to: point(rIn, inEnd - (inEnd - inStart) * CGFloat(i) / CGFloat(innerSteps)))
        }
        core.closeSubpath()

        guard cr > 0 else { return core }
        let rim = core.copy(strokingWithWidth: cr * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return core.union(rim)
    }
}
