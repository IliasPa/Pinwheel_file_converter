import CoreGraphics
import Foundation
import Testing
@testable import PinwheelCore

/// The screenshot tools of 2.3: line, spotlight, soft blur and the ruler.
struct V22ToolTests {
    private func render(_ marks: [Annotation], on picture: CGImage? = nil, full: CGSize? = nil) throws -> CGImage {
        var edit = ImageEdit()
        edit.markup = marks
        let source = StudioSource(image: picture ?? StudioFixtures.solid(0.5, width: 400, height: 200), fullSize: full)
        return try StudioRenderer.render(source, mask: nil, edit: edit)
    }

    private func stripes() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 0, to: 400, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: 200)) }
        return ctx.makeImage()!
    }

    @Test func aLineIsDrawn() throws {
        let line = Annotation(kind: .line, points: [RelativePoint(x: 0.1, y: 0.5), RelativePoint(x: 0.9, y: 0.5)], color: .red, size: 0.03)
        let image = try render([line])
        let middle = Fixtures.pixel(image, x: 200, y: 100)
        #expect(middle.r > 200 && middle.g < 100)
        let away = Fixtures.pixel(image, x: 200, y: 20)
        #expect(away.r < 160 && away.g > 100, "the rest stays gray")
    }

    @Test func aSpotlightDimsEverythingElse() throws {
        let spot = Annotation(kind: .spotlight, points: [RelativePoint(x: 0.25, y: 0.25), RelativePoint(x: 0.75, y: 0.75)], color: .red, size: 0.01)
        let image = try render([spot])
        let inside = Fixtures.pixel(image, x: 200, y: 100)
        let outside = Fixtures.pixel(image, x: 10, y: 10)
        #expect(abs(Int(inside.r) - 128) < 6, "inside keeps its light")
        #expect(outside.r < 90, "outside is dimmed")
    }

    @Test func aSoftBlurSmoothsDetailInsideOnly() throws {
        let blur = Annotation(kind: .blur, points: [RelativePoint(x: 0, y: 0), RelativePoint(x: 0.5, y: 1)], color: .black, size: 0.01)
        let image = try render([blur], on: stripes())
        let a = Fixtures.pixel(image, x: 100, y: 100), b = Fixtures.pixel(image, x: 101, y: 100)
        #expect(abs(Int(a.r) - Int(b.r)) < 40, "neighbouring columns now look alike")
        let c = Fixtures.pixel(image, x: 300, y: 100), d = Fixtures.pixel(image, x: 301, y: 100)
        #expect(abs(Int(c.r) - Int(d.r)) > 200, "outside is still stripes")
    }

    @Test func theRulerDrawsAndTheNewKindsSurviveSaving() throws {
        let ruler = Annotation(kind: .measure, points: [RelativePoint(x: 0.1, y: 0.5), RelativePoint(x: 0.9, y: 0.5)], color: .blue, size: 0.01)
        let image = try render([ruler])
        #expect(Fixtures.pixel(image, x: 200, y: 100).b > 150, "its label sits on the line")
        // 2.3's kinds go into a job and back (the saved edit is sent as JSON).
        var edit = ImageEdit()
        edit.markup = [Annotation.Kind.line, .blur, .spotlight, .measure].map {
            Annotation(kind: $0, points: [RelativePoint(x: 0.1, y: 0.1), RelativePoint(x: 0.6, y: 0.7)], color: .red, size: 0.01)
        }
        let back = try JSONDecoder().decode(ImageEdit.self, from: JSONEncoder().encode(edit))
        #expect(back == edit)
        #expect(Annotation.Kind.allCases.filter(\.isTwoPoint).count == 15)
    }

    @Test func theRulerSaysPixelsOfTheOriginal() throws {
        // The editor draws on a half-size copy; the ruler still counts real pixels.
        let line = [RelativePoint(x: 0, y: 0.5), RelativePoint(x: 0.5, y: 0.5)]
        let mapping = MarkupMapping(
            turnedSize: CGSize(width: 400, height: 200), crop: CGRect(x: 0, y: 0, width: 400, height: 200),
            contentSize: CGSize(width: 400, height: 200), originalScale: 0.5
        )
        let pixels = hypot((line[1].x - line[0].x) * mapping.turnedSize.width, (line[1].y - line[0].y) * mapping.turnedSize.height) / mapping.originalScale
        #expect(Int(pixels.rounded()) == 400)
        // A full-size source reports its own size, a half-size copy of an 800-wide one the same distance.
        let full = StudioSource(image: StudioFixtures.solid(0.5, width: 400, height: 200))
        #expect(full.scale == 1)
        let copy = StudioSource(image: StudioFixtures.solid(0.5, width: 400, height: 200), fullSize: CGSize(width: 800, height: 400))
        #expect(copy.scale == 0.5)
    }
}

/// The second round of 2.3: strength, more shapes, contrast and snapping.
struct V22MoreToolsTests {
    private func render(_ marks: [Annotation], on picture: CGImage? = nil) throws -> CGImage {
        var edit = ImageEdit()
        edit.markup = marks
        return try StudioRenderer.render(StudioSource(image: picture ?? StudioFixtures.solid(0.5, width: 400, height: 200)), mask: nil, edit: edit)
    }

    private func two(_ kind: Annotation.Kind, size: Double = 0.02, strength: Double = 0.5) -> Annotation {
        Annotation(kind: kind, points: [RelativePoint(x: 0.25, y: 0.25), RelativePoint(x: 0.75, y: 0.75)], color: .red, size: size, strength: strength)
    }

    @Test func contrastMatchesTheWebStandard() {
        let blackOnWhite = ContrastCheck(.black, on: .white)
        #expect(abs(blackOnWhite.ratio - 21) < 0.01)
        #expect(blackOnWhite.isAAA && blackOnWhite.isAA && blackOnWhite.isAALarge)
        #expect(ContrastCheck(.white, on: .white).ratio == 1)
        // #767676 on white is the classic "just passes AA" gray: 4.54 : 1.
        let gray = ContrastCheck(MarkupColor(hex: 0x767676), on: .white)
        #expect(abs(gray.ratio - 4.54) < 0.02)
        #expect(gray.isAA && !gray.isAAA)
        #expect(gray.ratioText == "4.5 : 1", "rounded down, so a near miss never reads as a pass")
        let pale = ContrastCheck(MarkupColor(hex: 0x949494), on: .white)
        #expect(!pale.isAA && pale.isAALarge)
        #expect(ContrastCheck(.white, on: .black).ratio == blackOnWhite.ratio, "the order doesn't matter")
    }

    @Test func newShapesDrawOnlyWhereTheyShould() throws {
        // A filled box shades its middle, a plain rounded box leaves it alone.
        let filled = try render([two(.filledBox)])
        #expect(Fixtures.pixel(filled, x: 200, y: 100).r > 140 && Fixtures.pixel(filled, x: 200, y: 100).g < 120)
        let rounded = try render([two(.roundedBox)])
        #expect(abs(Int(Fixtures.pixel(rounded, x: 200, y: 100).r) - 128) < 6, "hollow")
        // A cross puts ink on the diagonal, nothing at the box's side middle.
        let cross = try render([two(.cross)])
        #expect(Fixtures.pixel(cross, x: 200, y: 100).r > 200)
        #expect(abs(Int(Fixtures.pixel(cross, x: 105, y: 100).r) - 128) < 6)
        // A check mark has ink low in the box (its bend), none in the top left corner of it.
        let check = try render([two(.checkmark)])
        #expect(Fixtures.pixel(check, x: 172, y: 132).r > 200)
        #expect(abs(Int(Fixtures.pixel(check, x: 110, y: 60).r) - 128) < 6)
        // A two-way arrow has a head at each end: ink right beside both tips.
        let both = Annotation(kind: .doubleArrow, points: [RelativePoint(x: 0.1, y: 0.5), RelativePoint(x: 0.9, y: 0.5)], color: .red, size: 0.02)
        let arrows = try render([both])
        #expect(Fixtures.pixel(arrows, x: 50, y: 100).r > 200 && Fixtures.pixel(arrows, x: 350, y: 100).r > 200)
        // A dashed line has gaps.
        let dashed = Annotation(kind: .dashedLine, points: [RelativePoint(x: 0.05, y: 0.5), RelativePoint(x: 0.95, y: 0.5)], color: .red, size: 0.02)
        let line = try render([dashed])
        let inks = stride(from: 30, to: 370, by: 2).map { Fixtures.pixel(line, x: $0, y: 100).r > 200 }
        #expect(inks.contains(true) && inks.contains(false))
    }

    @Test func strengthChangesHowHardTheyAct() throws {
        // Dimming: stronger is darker outside the spotlight.
        let weak = try render([two(.spotlight, strength: 0.1)])
        let strong = try render([two(.spotlight, strength: 1)])
        #expect(Fixtures.pixel(weak, x: 10, y: 10).r > Fixtures.pixel(strong, x: 10, y: 10).r + 40)
        #expect(abs(Int(Fixtures.pixel(strong, x: 200, y: 100).r) - 128) < 6, "inside is untouched at any strength")
        // The default strength is the look 2.2 had before the slider.
        let standard = try render([two(.spotlight)])
        #expect(abs(Int(Fixtures.pixel(standard, x: 10, y: 10).r) - Int(128 * 0.45)) < 4)
        #expect(MarkupPainter.coarseness(0.5) == 1)
        #expect(MarkupPainter.coarseness(1) == 2 && MarkupPainter.coarseness(0) == 0.5)
    }

    @Test func editsFromBeforeStrengthStillOpen() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"arrow","points":[{"x":0.1,"y":0.1},{"x":0.5,"y":0.5}],"color":{"red":1,"green":0,"blue":0,"alpha":1},"size":0.01,"text":""}"#
        let note = try JSONDecoder().decode(Annotation.self, from: Data(old.utf8))
        #expect(note.strength == 0.5 && note.kind == .arrow)
        #expect(Set(Annotation.Kind.allCases.filter(\.usesStrength)) == [.redact, .blur, .spotlight])
    }

    private func blocks() -> CGImage {
        // A white picture with a black bar down the middle.
        let ctx = CGContext(
            data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 0, width: 20, height: 60))
        return ctx.makeImage()!
    }

    @Test func rulerFindsEdges() throws {
        let map = try #require(EdgeMap(blocks()))
        // From inside the white on the left, the space runs to the bar at x = 40.
        let left = map.span(x: 10, y: 30, horizontal: true)
        #expect(left.start == 0 && left.end == 40)
        // Inside the bar: 20 pixels wide.
        let bar = map.span(x: 50, y: 30, horizontal: true)
        #expect(bar.end - bar.start == 20 && bar.start == 40)
        // Up and down there are no edges: the whole height.
        let tall = map.span(x: 10, y: 30, horizontal: false)
        #expect(tall.end - tall.start == 60)
        // A ruler end placed near the bar's edge lands on it; far away it stays.
        #expect(map.snap(43, line: 30, horizontal: true, radius: 6) == 40)
        #expect(map.snap(57, line: 30, horizontal: true, radius: 6) == 60)
        #expect(map.snap(20, line: 30, horizontal: true, radius: 6) == 20)
    }
}

struct V23EraseTests {
    private func render(_ marks: [Annotation], on picture: CGImage) throws -> CGImage {
        var edit = ImageEdit()
        edit.markup = marks
        return try StudioRenderer.render(StudioSource(image: picture), mask: nil, edit: edit)
    }

    /// Blue everywhere, with a red 20 × 20 square in the middle (an "object").
    private func picture() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 90, y: 40, width: 20, height: 20))
        return ctx.makeImage()!
    }

    @Test func eraseTakesAnObjectOutOfAPlainBackground() throws {
        let erase = Annotation(kind: .erase, points: [RelativePoint(x: 0.4, y: 0.3), RelativePoint(x: 0.6, y: 0.7)], color: .black, size: 0.01)
        let before = Fixtures.pixel(picture(), x: 100, y: 50)
        #expect(before.r > 200, "the red square is there")
        let image = try render([erase], on: picture())
        let middle = Fixtures.pixel(image, x: 100, y: 50)
        #expect(middle.r < 12 && middle.b > 240, "now it's the blue around it")
        #expect(Fixtures.pixel(image, x: 10, y: 10).b > 240, "the rest is untouched")
    }

    @Test func eraseFollowsASmoothGradient() throws {
        // Black on the left to white on the right, with a red blob in the middle.
        let ctx = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 200, y: 0), options: [])
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 90, y: 40, width: 20, height: 20))
        let erase = Annotation(kind: .erase, points: [RelativePoint(x: 0.4, y: 0.3), RelativePoint(x: 0.6, y: 0.7)], color: .black, size: 0.01)
        let image = try render([erase], on: ctx.makeImage()!)
        let left = Fixtures.pixel(image, x: 82, y: 50), middle = Fixtures.pixel(image, x: 100, y: 50), right = Fixtures.pixel(image, x: 118, y: 50)
        #expect(abs(Int(middle.r) - Int(middle.b)) < 6, "gray, not red")
        #expect(left.r < middle.r && middle.r < right.r, "it keeps getting lighter to the right")
    }

    @Test func eraseSurvivesSaving() throws {
        var edit = ImageEdit()
        edit.markup = [Annotation(kind: .erase, points: [RelativePoint(x: 0.1, y: 0.1), RelativePoint(x: 0.3, y: 0.3)], color: .black, size: 0.01)]
        let back = try JSONDecoder().decode(ImageEdit.self, from: JSONEncoder().encode(edit))
        #expect(back == edit)
    }

    @Test func aTwoWayArrowEndsExactlyAtBothTips() throws {
        let both = Annotation(kind: .doubleArrow, points: [RelativePoint(x: 0.1, y: 0.5), RelativePoint(x: 0.9, y: 0.5)], color: .red, size: 0.02)
        let image = try render([both], on: picture())
        // The picture's own blue is "no ink". Nothing may stick out past a tip.
        for x in [18, 17, 16] { #expect(Fixtures.pixel(image, x: x, y: 50).r < 40, "left of the left tip at x \(x)") }
        for x in [182, 183, 184] { #expect(Fixtures.pixel(image, x: x, y: 50).r < 40, "right of the right tip at x \(x)") }
        #expect(Fixtures.pixel(image, x: 26, y: 50).r > 200 && Fixtures.pixel(image, x: 174, y: 50).r > 200, "a head at each end")
    }
}

/// Scrolling capture: joining pictures of a scrolling area.
struct V23ScrollTests {
    /// A tall "page": every row different (pseudo-random brightness per block).
    private func page(width: Int = 320, height: Int = 1600) -> CGImage {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            // Paragraph-like rows: blocks of 20 pixels with their own shade, new every 3 rows.
            if y % 3 == 0 { _ = next() }
            for x in 0..<width {
                let shade = UInt8(truncatingIfNeeded: Int(next() >> 2) &+ x / 20 * 17 &+ (y / 3) * 5)
                let at = (y * width + x) * 4
                bytes[at] = shade; bytes[at + 1] = shade &+ 20; bytes[at + 2] = shade &+ 40; bytes[at + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func same(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        for y in stride(from: 0, to: a.height, by: 7) {
            for x in stride(from: 0, to: a.width, by: 13) {
                let p = Fixtures.pixel(a, x: x, y: y), q = Fixtures.pixel(b, x: x, y: y)
                if p.r != q.r || p.g != q.g || p.b != q.b { return false }
            }
        }
        return true
    }

    @Test func framesJoinIntoTheWholePage() throws {
        let whole = page()
        var stitcher = ScrollStitcher()
        #expect(stitcher.add(try #require(whole.cropping(to: CGRect(x: 0, y: 0, width: 320, height: 400)))) == .started)
        var offset = 0
        for step in [90, 130, 60, 200, 120, 150, 40] {
            offset += step
            let outcome = stitcher.add(try #require(whole.cropping(to: CGRect(x: 0, y: offset, width: 320, height: 400))))
            #expect(outcome == .added(step), "scrolled \(step) rows")
        }
        let joined = try #require(stitcher.result())
        #expect(joined.height == offset + 400)
        #expect(same(joined, try #require(whole.cropping(to: CGRect(x: 0, y: 0, width: 320, height: offset + 400)))))
    }

    @Test func standingStillOrScrollingBackAddsNothing() throws {
        let whole = page()
        func frame(_ y: Int) throws -> CGImage { try #require(whole.cropping(to: CGRect(x: 0, y: y, width: 320, height: 400))) }
        var stitcher = ScrollStitcher()
        stitcher.add(try frame(100))
        #expect(stitcher.add(try frame(100)) == .unchanged)
        #expect(stitcher.add(try frame(160)) == .added(60))
        #expect(stitcher.add(try frame(120)) != .added(40), "going back up isn't added")
        let height = stitcher.resultHeight
        #expect(stitcher.add(try frame(200)) == .added(40), "and going down again carries on")
        #expect(stitcher.resultHeight == height + 40)
        // Jumping further than the picture is tall can't be followed.
        #expect(stitcher.add(try frame(1000)) == .lost)
    }

    @Test func aHeaderAndFooterThatStayPutAppearOnce() throws {
        let whole = page(height: 1400)
        let ctx = CGContext(
            data: nil, width: 320, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // A sticky header (rows 0-39) and footer (rows 360-399) painted over each frame.
        func frame(_ y: Int) throws -> CGImage {
            ctx.draw(try #require(whole.cropping(to: CGRect(x: 0, y: y, width: 320, height: 400))), in: CGRect(x: 0, y: 0, width: 320, height: 400))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 360, width: 320, height: 40))   // top in the picture
            ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 40))     // bottom in the picture
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 40, y: 372, width: 100, height: 8))   // some "text" in the header
            ctx.fill(CGRect(x: 40, y: 14, width: 100, height: 8))    // and in the footer
            return ctx.makeImage()!
        }
        var stitcher = ScrollStitcher()
        stitcher.add(try frame(0))
        var offset = 0
        for step in [70, 100, 80] {
            offset += step
            #expect(stitcher.add(try frame(offset)) == .added(step))
        }
        let joined = try #require(stitcher.result())
        #expect(joined.height == 400 + offset, "the header and footer aren't repeated")
        let head = Fixtures.pixel(joined, x: 5, y: 5), foot = Fixtures.pixel(joined, x: 5, y: joined.height - 5)
        #expect(head.b > 120 && head.r < 60, "the blue header is at the top")
        #expect(foot.r > 180 && foot.b < 60, "the red footer is at the very bottom")
        // The middle is the page, with no bars in it.
        for y in [200, 330, 500, 600] {
            let p = Fixtures.pixel(joined, x: 5, y: y)
            let expected = Fixtures.pixel(whole, x: 5, y: y)
            #expect(p.r == expected.r && p.g == expected.g, "row \(y)")
        }
    }

    @Test func aRetinaSizedFrameIsJoinedQuickly() throws {
        let whole = page(width: 2400, height: 5200)
        var stitcher = ScrollStitcher()
        stitcher.add(try #require(whole.cropping(to: CGRect(x: 0, y: 0, width: 2400, height: 1600))))
        let start = Date()
        var offset = 0
        for step in [120, 240, 90, 300] {
            offset += step
            #expect(stitcher.add(try #require(whole.cropping(to: CGRect(x: 0, y: offset, width: 2400, height: 1600)))) == .added(step))
        }
        let each = Date().timeIntervalSince(start) / 4
        // A debug build under a full test run is many times slower than the app; this only catches a collapse.
        #expect(each < 2, "took \(each) s a picture")
    }

    @Test func aBlankPageCantBeFollowed() throws {
        let blank = StudioFixtures.solid(0.9, width: 320, height: 400)
        var stitcher = ScrollStitcher()
        stitcher.add(blank)
        let outcome = stitcher.add(blank)
        #expect(outcome == .unchanged)
        #expect(stitcher.resultHeight == 400)
    }
}
