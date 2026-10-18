import CoreGraphics
import Foundation

/// The part of the crop box the pointer grabbed.
public enum CropHandle: Sendable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// Inside the box: moves it.
    case move
    /// Outside the box: draws a new one from that point.
    case new

    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
}

/// Dragging the crop box. Everything is in pixels of the turned picture,
/// y down; `aspect` (width / height) keeps the box's shape when set.
public enum CropMath {
    /// What the pointer grabbed: corners first, then edges, then inside.
    public static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> CropHandle {
        let nearLeft = abs(point.x - rect.minX) <= tolerance, nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearTop = abs(point.y - rect.minY) <= tolerance, nearBottom = abs(point.y - rect.maxY) <= tolerance
        let withinX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let withinY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        return rect.contains(point) ? .move : .new
    }

    /// The box after dragging `handle` from `start` to `point`.
    public static func dragged(
        _ handle: CropHandle, rect: CGRect, from start: CGPoint, to point: CGPoint,
        aspect: Double?, bounds: CGSize, minSize: CGFloat
    ) -> CGRect {
        let dx = point.x - start.x, dy = point.y - start.y
        switch handle {
        case .move:
            var moved = rect.offsetBy(dx: dx, dy: dy)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            return moved
        case .new:
            return box(anchor: clamp(start, bounds), moving: clamp(point, bounds), aspect: aspect, bounds: bounds, minSize: minSize)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let anchor = CGPoint(x: handle.movesLeft ? rect.maxX : rect.minX, y: handle.movesTop ? rect.maxY : rect.minY)
            let corner = CGPoint(x: handle.movesLeft ? rect.minX : rect.maxX, y: handle.movesTop ? rect.minY : rect.maxY)
            return box(anchor: anchor, moving: clamp(CGPoint(x: corner.x + dx, y: corner.y + dy), bounds), aspect: aspect, bounds: bounds, minSize: minSize)
        case .left, .right:
            var minX = rect.minX, maxX = rect.maxX
            if handle == .left { minX = min(max(rect.minX + dx, 0), maxX - minSize) } else { maxX = max(min(rect.maxX + dx, bounds.width), minX + minSize) }
            var width = maxX - minX, height = rect.height
            if let aspect {
                height = width / aspect
                if height > bounds.height {
                    height = bounds.height
                    width = height * aspect
                    if handle == .left { minX = maxX - width } else { maxX = minX + width }
                }
            }
            let y = min(max(rect.midY - height / 2, 0), bounds.height - height)
            return CGRect(x: minX, y: aspect == nil ? rect.minY : y, width: width, height: height)
        case .top, .bottom:
            var minY = rect.minY, maxY = rect.maxY
            if handle == .top { minY = min(max(rect.minY + dy, 0), maxY - minSize) } else { maxY = max(min(rect.maxY + dy, bounds.height), minY + minSize) }
            var height = maxY - minY, width = rect.width
            if let aspect {
                width = height * aspect
                if width > bounds.width {
                    width = bounds.width
                    height = width / aspect
                    if handle == .top { minY = maxY - height } else { maxY = minY + height }
                }
            }
            let x = min(max(rect.midX - width / 2, 0), bounds.width - width)
            return CGRect(x: aspect == nil ? rect.minX : x, y: minY, width: width, height: height)
        }
    }

    /// A box from a fixed corner to a moving one, kept inside the picture.
    static func box(anchor: CGPoint, moving: CGPoint, aspect: Double?, bounds: CGSize, minSize: CGFloat) -> CGRect {
        let towardRight = moving.x >= anchor.x, towardBottom = moving.y >= anchor.y
        var width = max(abs(moving.x - anchor.x), minSize)
        var height = max(abs(moving.y - anchor.y), minSize)
        let roomX = max(towardRight ? bounds.width - anchor.x : anchor.x, 1)
        let roomY = max(towardBottom ? bounds.height - anchor.y : anchor.y, 1)
        if let aspect {
            if width / height > aspect { height = width / aspect } else { width = height * aspect }
            let fit = min(1, roomX / width, roomY / height)
            width *= fit
            height *= fit
        } else {
            width = min(width, roomX)
            height = min(height, roomY)
        }
        return CGRect(x: towardRight ? anchor.x : anchor.x - width, y: towardBottom ? anchor.y : anchor.y - height, width: width, height: height)
    }

    static func clamp(_ point: CGPoint, _ bounds: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }
}
