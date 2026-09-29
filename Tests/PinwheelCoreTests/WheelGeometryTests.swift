import CoreGraphics
import Testing
@testable import PinwheelCore

struct WheelGeometryTests {
    let layout = WheelLayout(count: 6, innerRadius: 50, outerRadius: 130)

    @Test func hubAndOutside() {
        #expect(layout.hit(dx: 0, dy: 0) == .hub)
        #expect(layout.hit(dx: 30, dy: 30) == .hub)
        #expect(layout.hit(dx: 0, dy: 200) == .outside)
    }

    @Test func wedgesGoClockwiseFromTheTop() {
        #expect(layout.hit(dx: 0, dy: 100) == .wedge(0))      // 12 o'clock
        #expect(layout.hit(dx: 87, dy: 50) == .wedge(1))      // ~2 o'clock
        #expect(layout.hit(dx: 87, dy: -50) == .wedge(2))     // ~4 o'clock
        #expect(layout.hit(dx: 0, dy: -100) == .wedge(3))     // 6 o'clock
        #expect(layout.hit(dx: -87, dy: -50) == .wedge(4))
        #expect(layout.hit(dx: -87, dy: 50) == .wedge(5))
        #expect(layout.hit(dx: -10, dy: 100) == .wedge(0))    // just left of top
    }

    @Test func slackPastTheRimStillHits() {
        #expect(layout.hit(dx: 0, dy: 140) == .wedge(0))
    }

    @Test func clampKeepsTheWheelOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(WheelLayout.clampedCenter(CGPoint(x: 700, y: 400), radius: 140, within: screen) == CGPoint(x: 700, y: 400))
        #expect(WheelLayout.clampedCenter(CGPoint(x: 5, y: 5), radius: 140, within: screen) == CGPoint(x: 140, y: 140))
        #expect(WheelLayout.clampedCenter(CGPoint(x: 1439, y: 899), radius: 140, within: screen) == CGPoint(x: 1300, y: 760))
    }

    @Test func clampWorksOnSecondaryScreensWithNegativeOrigins() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let c = WheelLayout.clampedCenter(CGPoint(x: -1910, y: 870), radius: 140, within: screen)
        #expect(c == CGPoint(x: -1780, y: 740))
    }

    @Test func wedgePathsAreNonEmptyAndInsideTheRing() {
        for i in 0..<layout.count {
            let path = WedgePath.make(
                center: .zero, innerRadius: 50, outerRadius: 130,
                startAngle: layout.startAngle(of: i), endAngle: layout.endAngle(of: i),
                gap: 4, cornerRadius: 8, yDown: false
            )
            let box = path.boundingBoxOfPath
            #expect(!box.isEmpty)
            #expect(hypot(box.midX, box.midY) > 50)
            #expect(box.maxX <= 130.5 && box.minX >= -130.5 && box.maxY <= 130.5 && box.minY >= -130.5)
            // The middle of the wedge is inside the shape.
            let d = layout.direction(of: i)
            #expect(path.contains(CGPoint(x: d.dx * 90, y: d.dy * 90)))
        }
    }
}
