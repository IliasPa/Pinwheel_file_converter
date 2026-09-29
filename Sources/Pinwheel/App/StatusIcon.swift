import AppKit
import PinwheelCore

/// The menu-bar icon: a small six-wedge wheel with one wedge "picked".
enum StatusIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let layout = WheelLayout(count: 6, innerRadius: 3.2, outerRadius: 8)
            ctx.setFillColor(NSColor.black.cgColor)
            for i in 0..<layout.count {
                let picked = i == 1
                var c = center
                if picked {
                    let d = layout.direction(of: i)
                    c.x += d.dx * 0.9
                    c.y += d.dy * 0.9
                }
                let path = WedgePath.make(
                    center: c,
                    innerRadius: layout.innerRadius,
                    outerRadius: picked ? 9 : 7.4,
                    startAngle: layout.startAngle(of: i),
                    endAngle: layout.endAngle(of: i),
                    gap: 1.3, cornerRadius: 0.8, yDown: false
                )
                ctx.addPath(path)
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true  // lets macOS tint it for light/dark menu bars
        image.accessibilityDescription = "Pinwheel"
        return image
    }
}
