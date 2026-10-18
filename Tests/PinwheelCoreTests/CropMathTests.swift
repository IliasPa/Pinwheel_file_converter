import CoreGraphics
import Testing
@testable import PinwheelCore

struct CropMathTests {
    private let bounds = CGSize(width: 400, height: 300)
    private let rect = CGRect(x: 100, y: 100, width: 100, height: 100)

    @Test func grabsCornersEdgesAndInside() {
        #expect(CropMath.handle(at: CGPoint(x: 102, y: 98), in: rect, tolerance: 6) == .topLeft)
        #expect(CropMath.handle(at: CGPoint(x: 199, y: 201), in: rect, tolerance: 6) == .bottomRight)
        #expect(CropMath.handle(at: CGPoint(x: 150, y: 97), in: rect, tolerance: 6) == .top)
        #expect(CropMath.handle(at: CGPoint(x: 203, y: 150), in: rect, tolerance: 6) == .right)
        #expect(CropMath.handle(at: CGPoint(x: 150, y: 150), in: rect, tolerance: 6) == .move)
        #expect(CropMath.handle(at: CGPoint(x: 20, y: 20), in: rect, tolerance: 6) == .new)
    }

    @Test func movingStaysInside() {
        let moved = CropMath.dragged(.move, rect: rect, from: .zero, to: CGPoint(x: 500, y: -500), aspect: nil, bounds: bounds, minSize: 10)
        #expect(moved == CGRect(x: 300, y: 0, width: 100, height: 100))
    }

    @Test func cornersResizeFromTheOppositeCorner() {
        let free = CropMath.dragged(.bottomRight, rect: rect, from: .zero, to: CGPoint(x: 50, y: 20), aspect: nil, bounds: bounds, minSize: 10)
        #expect(free == CGRect(x: 100, y: 100, width: 150, height: 120))
        // With a shape, the bigger move wins and the shape is kept.
        let square = CropMath.dragged(.bottomRight, rect: rect, from: .zero, to: CGPoint(x: 50, y: 20), aspect: 1, bounds: bounds, minSize: 10)
        #expect(square == CGRect(x: 100, y: 100, width: 150, height: 150))
        // …and shrunk to fit when it would leave the picture.
        let big = CropMath.dragged(.bottomRight, rect: rect, from: .zero, to: CGPoint(x: 1000, y: 0), aspect: 1, bounds: bounds, minSize: 10)
        #expect(big == CGRect(x: 100, y: 100, width: 200, height: 200))
        let topLeft = CropMath.dragged(.topLeft, rect: rect, from: .zero, to: CGPoint(x: -20, y: -20), aspect: nil, bounds: bounds, minSize: 10)
        #expect(topLeft == CGRect(x: 80, y: 80, width: 120, height: 120))
    }

    @Test func edgesKeepTheShapeAroundTheMiddle() {
        let right = CropMath.dragged(.right, rect: rect, from: .zero, to: CGPoint(x: 60, y: 0), aspect: 1, bounds: bounds, minSize: 10)
        #expect(right == CGRect(x: 100, y: 70, width: 160, height: 160))
        let free = CropMath.dragged(.top, rect: rect, from: .zero, to: CGPoint(x: 0, y: -40), aspect: nil, bounds: bounds, minSize: 10)
        #expect(free == CGRect(x: 100, y: 60, width: 100, height: 140))
        let tooSmall = CropMath.dragged(.left, rect: rect, from: .zero, to: CGPoint(x: 500, y: 0), aspect: nil, bounds: bounds, minSize: 10)
        #expect(tooSmall.width == 10 && tooSmall.maxX == 200)
    }

    @Test func drawingANewBoxWorksInAnyDirection() {
        let box = CropMath.dragged(.new, rect: rect, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 250, y: 150), aspect: nil, bounds: bounds, minSize: 10)
        #expect(box == CGRect(x: 250, y: 150, width: 50, height: 100))
        let wide = CropMath.dragged(.new, rect: rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 170, y: 20), aspect: 16.0 / 9, bounds: bounds, minSize: 10)
        #expect(abs(wide.width / wide.height - 16.0 / 9) < 0.001)
    }
}
