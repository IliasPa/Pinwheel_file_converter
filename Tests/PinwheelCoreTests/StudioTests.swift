import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PinwheelCore

/// Pictures made for the image editor's tests.
enum StudioFixtures {
    static let red = (255, 0, 0), green = (0, 255, 0), blue = (0, 0, 255), white = (255, 255, 255)

    /// Four colored quarters: red top left, green top right, blue bottom
    /// left, white bottom right. Shows any turn or flip at a glance.
    static func quarters(width: Int = 200, height: Int = 120) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // Core Graphics' y points up, so the top row is at y = h.
        for (color, rect) in [
            (red, CGRect(x: 0, y: h, width: w, height: h)), (green, CGRect(x: w, y: h, width: w, height: h)),
            (blue, CGRect(x: 0, y: 0, width: w, height: h)), (white, CGRect(x: w, y: 0, width: w, height: h)),
        ] {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    static func solid(_ gray: CGFloat, width: Int = 120, height: Int = 80) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A shaded orange ball on a light floor: a clear subject for Vision.
    static func ball(width: Int = 800, height: Int = 600) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let colors = [CGColor(srgbRed: 1, green: 0.75, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.8, green: 0.3, blue: 0.05, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        let side = CGFloat(min(width, height)) / 2
        let ball = CGRect(x: CGFloat(width) / 2 - side / 2, y: CGFloat(height) / 2 - side / 2, width: side, height: side)
        ctx.saveGState()
        ctx.addEllipse(in: ball)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient, startCenter: CGPoint(x: ball.midX - side * 0.15, y: ball.midY + side * 0.2), startRadius: 4,
            endCenter: CGPoint(x: ball.midX, y: ball.midY), endRadius: side * 0.65, options: []
        )
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    static func save(_ image: CGImage, to url: URL, type: String = "public.png", properties: [CFString: Any] = [:]) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The color nearest to one of the four quarter colors (nil: none close).
    static func name(_ image: CGImage, x: Int, y: Int) -> String? {
        let p = Fixtures.pixel(image, x: x, y: y)
        let named = [("red", red), ("green", green), ("blue", blue), ("white", white)]
        return named.first { abs(Int(p.r) - $0.1.0) < 40 && abs(Int(p.g) - $0.1.1) < 40 && abs(Int(p.b) - $0.1.2) < 40 }?.0
    }

    /// Colors near the four corners, clockwise from the top left.
    static func corners(_ image: CGImage) -> [String?] {
        let (w, h) = (image.width, image.height)
        return [name(image, x: 4, y: 4), name(image, x: w - 5, y: 4), name(image, x: w - 5, y: h - 5), name(image, x: 4, y: h - 5)]
    }
}

struct StudioGeometryTests {
    private let source = StudioSource(image: StudioFixtures.quarters())

    private func render(_ edit: ImageEdit) throws -> CGImage {
        try StudioRenderer.render(source, mask: nil, edit: edit)
    }

    @Test func turnsAndFlipsMatchWhatYouSee() throws {
        // Corner colors clockwise from the top left, moved by hand for each step.
        var expected = ["red", "green", "white", "blue"]
        var edit = ImageEdit()
        let steps: [(String, (inout ImageEdit) -> Void, ([String]) -> [String])] = [
            ("right", { $0.rotate(clockwise: true) }, { [$0[3], $0[0], $0[1], $0[2]] }),
            ("flip H", { $0.flip(horizontally: true) }, { [$0[1], $0[0], $0[3], $0[2]] }),
            ("left", { $0.rotate(clockwise: false) }, { [$0[1], $0[2], $0[3], $0[0]] }),
            ("flip V", { $0.flip(horizontally: false) }, { [$0[3], $0[2], $0[1], $0[0]] }),
            ("right", { $0.rotate(clockwise: true) }, { [$0[3], $0[0], $0[1], $0[2]] }),
            ("right", { $0.rotate(clockwise: true) }, { [$0[3], $0[0], $0[1], $0[2]] }),
            ("flip H", { $0.flip(horizontally: true) }, { [$0[1], $0[0], $0[3], $0[2]] }),
        ]
        for (name, change, move) in steps {
            change(&edit)
            expected = move(expected)
            let image = try render(edit)
            #expect(StudioFixtures.corners(image) == expected, "after \(name)")
            let turned = edit.quarterTurns % 2 == 1
            #expect((image.width, image.height) == (turned ? (120, 200) : (200, 120)), "size after \(name)")
        }
    }

    @Test func cropKeepsThePartChosen() throws {
        var edit = ImageEdit()
        edit.crop = RelativeRect(x: 0, y: 0, width: 0.5, height: 0.5)  // the red quarter
        let image = try render(edit)
        #expect((image.width, image.height) == (100, 60))
        #expect(Set(StudioFixtures.corners(image)) == ["red"])

        // Turning keeps the crop on the same part of the picture.
        edit.rotate(clockwise: true)
        let turned = try render(edit)
        #expect((turned.width, turned.height) == (60, 100))
        #expect(Set(StudioFixtures.corners(turned)) == ["red"])
        edit.flip(horizontally: true)
        #expect(Set(StudioFixtures.corners(try render(edit))) == ["red"])
    }

    @Test func aspectFitsPicturesOfOtherSizes() {
        var edit = ImageEdit()
        edit.aspect = .square
        edit.crop = RelativeRect(x: 0.2, y: 0, width: 0.6, height: 1)  // square on a 200 × 120 picture
        #expect(StudioRenderer.cropRect(in: CGSize(width: 200, height: 120), edit) == CGRect(x: 40, y: 0, width: 120, height: 120))
        // The same edit on a tall picture is still square, and inside it.
        let tall = StudioRenderer.cropRect(in: CGSize(width: 300, height: 900), edit)
        #expect(tall.width == tall.height)
        #expect(CGRect(x: 0, y: 0, width: 300, height: 900).contains(tall))
    }

    @Test func outputSizeIsExact() throws {
        var edit = ImageEdit()
        edit.aspect = AspectRatio(16, 9)
        edit.outputSize = PixelSize(width: 64, height: 36)
        let image = try render(edit)
        #expect((image.width, image.height) == (64, 36))
        #expect(StudioRenderer.contentSize(for: source.fullSize, edit) == PixelSize(width: 64, height: 36))
    }

    @Test func previewsScaleTheOutputSizeToo() throws {
        // A half-size preview of a 400 × 240 original.
        let preview = StudioSource(image: StudioFixtures.quarters(), fullSize: CGSize(width: 400, height: 240))
        var edit = ImageEdit()
        edit.outputSize = PixelSize(width: 100, height: 60)
        let image = try StudioRenderer.render(preview, mask: nil, edit: edit)
        #expect((image.width, image.height) == (50, 30))
    }

    @Test func emptyEditsAreEmpty() {
        var edit = ImageEdit()
        #expect(edit.isEmpty)
        edit.format = .png
        edit.crop = .full
        #expect(edit.isEmpty)
        edit.adjustments.exposure = 0.1
        #expect(!edit.isEmpty)
    }
}

struct StudioLookTests {
    private func average(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let p = Fixtures.pixel(image, x: image.width / 2, y: image.height / 2)
        return (Double(p.r), Double(p.g), Double(p.b))
    }

    private func adjusted(_ change: (inout Adjustments) -> Void, gray: CGFloat = 0.5) throws -> (r: Double, g: Double, b: Double) {
        var edit = ImageEdit()
        change(&edit.adjustments)
        return average(try StudioRenderer.render(StudioSource(image: StudioFixtures.solid(gray)), mask: nil, edit: edit))
    }

    @Test func slidersMoveTheRightWay() throws {
        let plain = try adjusted { _ in }
        #expect(try adjusted { $0.exposure = 1 }.g > plain.g + 20)
        #expect(try adjusted { $0.exposure = -1 }.g < plain.g - 20)
        let warm = try adjusted { $0.warmth = 1 }
        #expect(warm.r > warm.b + 15, "warmer should be redder than it is blue: \(warm)")
        let cool = try adjusted { $0.warmth = -1 }
        #expect(cool.b > cool.r + 15, "cooler should be bluer than it is red: \(cool)")
    }

    @Test func monoTakesTheColorOut() throws {
        var edit = ImageEdit()
        edit.adjustments.filter = .mono
        let image = try StudioRenderer.render(StudioSource(image: StudioFixtures.quarters()), mask: nil, edit: edit)
        let p = Fixtures.pixel(image, x: 10, y: 10)  // was red
        #expect(abs(Int(p.r) - Int(p.g)) < 12 && abs(Int(p.g) - Int(p.b)) < 12)
    }

    @Test(arguments: PhotoFilter.allCases)
    func everyFilterDraws(filter: PhotoFilter) throws {
        var edit = ImageEdit()
        edit.adjustments.filter = filter
        edit.adjustments.auto = true
        edit.adjustments.sharpness = 0.5
        edit.adjustments.vignette = 0.5
        edit.adjustments.highlights = filter == .vivid ? 0.5 : -0.5
        edit.adjustments.shadows = 0.4
        let image = try StudioRenderer.render(StudioSource(image: StudioFixtures.quarters()), mask: nil, edit: edit)
        #expect((image.width, image.height) == (200, 120))
    }
}

struct StudioMarkupTests {
    private let white = StudioSource(image: StudioFixtures.solid(1, width: 400, height: 200))

    private func render(_ annotations: [Annotation], crop: RelativeRect? = nil) throws -> CGImage {
        var edit = ImageEdit()
        edit.markup = annotations
        edit.crop = crop
        return try StudioRenderer.render(white, mask: nil, edit: edit)
    }

    private func isRed(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        let p = Fixtures.pixel(image, x: x, y: y)
        return p.r > 200 && p.g < 120 && p.b < 120
    }

    @Test func boxesAndArrowsLandWhereDrawn() throws {
        let box = Annotation(kind: .rectangle, points: [RelativePoint(x: 0.25, y: 0.25), RelativePoint(x: 0.75, y: 0.75)], color: .red, size: 0.01)
        let image = try render([box])
        #expect(isRed(image, 100, 100))  // left edge (x = 0.25 of 400), halfway down
        #expect(isRed(image, 200, 50))   // top edge
        #expect(!isRed(image, 200, 100))  // inside stays white

        let arrow = Annotation(kind: .arrow, points: [RelativePoint(x: 0.1, y: 0.5), RelativePoint(x: 0.9, y: 0.5)], color: .red, size: 0.01)
        let drawn = try render([arrow])
        #expect(isRed(drawn, 200, 100))
        #expect(isRed(drawn, 350, 100))  // the head
        #expect(!isRed(drawn, 200, 60))
    }

    @Test func markupFollowsTheCrop() throws {
        // A dot in the middle of the right half; crop to the right half.
        let dot = Annotation(kind: .pen, points: [RelativePoint(x: 0.75, y: 0.5)], color: .red, size: 0.05)
        let image = try render([dot], crop: RelativeRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect((image.width, image.height) == (200, 200))
        #expect(isRed(image, 100, 100))
    }

    @Test func textNumbersAndHighlightsDraw() throws {
        let text = Annotation(kind: .text, points: [RelativePoint(x: 0.5, y: 0.5)], color: .black, size: 0.12, text: "Hello")
        let badge = Annotation(kind: .number, points: [RelativePoint(x: 0.1, y: 0.2)], color: .blue, size: 0.08, text: "1")
        let mark = Annotation(
            kind: .highlighter, points: [RelativePoint(x: 0.6, y: 0.9), RelativePoint(x: 0.95, y: 0.9)], color: .yellow, size: 0.04
        )
        let image = try render([text, badge, mark])
        var dark = 0
        for x in stride(from: 140, to: 260, by: 2) where Fixtures.pixel(image, x: x, y: 100).r < 90 { dark += 1 }
        #expect(dark > 5, "the text should leave dark pixels")
        let ring = Fixtures.pixel(image, x: 40 - 13, y: 40)
        #expect(ring.b > 150 && ring.r < 120, "the badge is blue")
        let highlight = Fixtures.pixel(image, x: 300, y: 180)
        #expect(highlight.b < 200 && highlight.r > 200, "the highlighter tints yellow")
    }

    @Test func redactingHidesDetail() throws {
        // Fine stripes: every column alternates black and white.
        let ctx = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 0, to: 200, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: 100)) }
        var edit = ImageEdit()
        edit.markup = [Annotation(kind: .redact, points: [RelativePoint(x: 0, y: 0), RelativePoint(x: 0.5, y: 1)], color: .black, size: 0.01)]
        let image = try StudioRenderer.render(StudioSource(image: ctx.makeImage()!), mask: nil, edit: edit)
        // Inside: neighbouring columns now look alike. Outside: still stripes.
        let a = Fixtures.pixel(image, x: 40, y: 50), b = Fixtures.pixel(image, x: 41, y: 50)
        #expect(abs(Int(a.r) - Int(b.r)) < 30)
        let c = Fixtures.pixel(image, x: 150, y: 50), d = Fixtures.pixel(image, x: 151, y: 50)
        #expect(abs(Int(c.r) - Int(d.r)) > 200)
    }

    @Test func clickingFindsAnnotations() {
        let box = Annotation(kind: .rectangle, points: [RelativePoint(x: 0.2, y: 0.2), RelativePoint(x: 0.4, y: 0.6)], color: .red, size: 0.01)
        let bounds = box.bounds(aspect: 2)
        #expect(bounds.x < 0.2 && bounds.x + bounds.width > 0.4)
        #expect(bounds.y < 0.2 && bounds.y + bounds.height > 0.6)
    }
}

struct StudioFrameTests {
    private let picture = StudioSource(image: StudioFixtures.solid(0.5, width: 200, height: 100))

    @Test func paddingGrowsTheCanvasOnItsBackground() throws {
        var edit = ImageEdit()
        edit.frame.padding = 0.1
        edit.frame.background = .color(.blue)
        let image = try StudioRenderer.render(picture, mask: nil, edit: edit)
        #expect((image.width, image.height) == (240, 140))
        #expect(StudioRenderer.finalSize(for: picture.fullSize, edit) == PixelSize(width: 240, height: 140))
        let corner = Fixtures.pixel(image, x: 2, y: 2)
        #expect(corner.b > 200 && corner.r < 60)
        let middle = Fixtures.pixel(image, x: 120, y: 70)
        #expect(abs(Int(middle.r) - 128) < 20)
    }

    @Test func roundedCornersAreSeeThroughWithoutABackground() throws {
        var edit = ImageEdit()
        edit.frame.cornerRadius = 0.3
        let image = try StudioRenderer.render(picture, mask: nil, edit: edit)
        #expect(Fixtures.pixel(image, x: 1, y: 1).a == 0)
        #expect(Fixtures.pixel(image, x: 100, y: 50).a == 255)
        #expect(edit.hasTransparency(sourceHasAlpha: false))
        edit.frame.background = .gradient(.ocean)
        #expect(!edit.hasTransparency(sourceHasAlpha: false))
    }

    @Test func shadowsDarkenBelowThePicture() throws {
        var edit = ImageEdit()
        edit.frame.padding = 0.2
        edit.frame.background = .color(.white)
        edit.frame.shadow = 1
        let image = try StudioRenderer.render(StudioSource(image: StudioFixtures.solid(1, width: 200, height: 100)), mask: nil, edit: edit)
        let below = Fixtures.pixel(image, x: image.width / 2, y: image.height - 34)  // just under the picture
        let far = Fixtures.pixel(image, x: 2, y: 2)
        #expect(Int(below.r) < Int(far.r) - 10)
    }

    @Test func canvasShapeAndBlurredBackdrop() throws {
        var edit = ImageEdit()
        edit.frame.canvasAspect = .square
        edit.frame.background = .blur
        let image = try StudioRenderer.render(StudioSource(image: StudioFixtures.quarters()), mask: nil, edit: edit)
        #expect(image.width == image.height)
        #expect(Fixtures.pixel(image, x: 2, y: 2).a == 255)
    }
}

struct StudioJobTests {
    @Test func editsAreSavedNextToTheOriginal() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.jpg")
        try StudioFixtures.save(StudioFixtures.quarters(width: 400, height: 240), to: source, type: "public.jpeg", properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PinwheelCam"],
        ])
        var edit = ImageEdit()
        edit.crop = RelativeRect(x: 0, y: 0, width: 0.5, height: 1)
        edit.rotate(clockwise: true)
        let request = ConversionRequest(file: SourceFile(url: source), action: .tool(.edit), parameters: .image(edit))
        let output = try #require(try await runRequest(request).outputs.first)
        #expect(output.lastPathComponent == "photo (edited).jpg")
        let info = try #require(Fixtures.readImage(output))
        #expect((info.width, info.height) == (240, 200))
        #expect(info.properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        let tiff = info.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "PinwheelCam")  // details are kept
    }

    @Test func seeThroughResultsBecomePNG() async throws {
        let folder = try TempFolder()
        let source = folder.file("shot.jpg")
        try StudioFixtures.save(StudioFixtures.quarters(), to: source, type: "public.jpeg")
        var edit = ImageEdit()
        edit.frame.cornerRadius = 0.2
        let file = SourceFile(url: source)
        #expect(edit.outputFormat(for: file, hasAlpha: false) == .png)
        let output = try #require(try await runRequest(ConversionRequest(file: file, action: .tool(.edit), parameters: .image(edit))).outputs.first)
        #expect(output.lastPathComponent == "shot (edited).png")
        #expect(try #require(Fixtures.readImage(output)).properties[kCGImagePropertyHasAlpha] as? Bool == true)

        // Asking for JPEG puts the see-through parts on white.
        edit.format = .jpeg
        let jpeg = try #require(try await runRequest(ConversionRequest(file: file, action: .tool(.edit), parameters: .image(edit))).outputs.first)
        #expect(jpeg.pathExtension == "jpg")
        let corner = Fixtures.pixel(try #require(Fixtures.readImage(jpeg)).image, x: 0, y: 0)
        #expect(corner.r > 240 && corner.g > 240 && corner.b > 240)
    }

    @Test func savingWithoutChangesSavesNothing() async throws {
        let folder = try TempFolder()
        let source = folder.file("same.png")
        try StudioFixtures.save(StudioFixtures.quarters(), to: source)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .tool(.edit), parameters: .image(ImageEdit())))
        #expect(result.skipped)
    }

    @Test func removeBackgroundKeepsTheSubject() async throws {
        let folder = try TempFolder()
        let source = folder.file("ball.jpg")
        try StudioFixtures.save(StudioFixtures.ball(), to: source, type: "public.jpeg")
        let output = try await runConversion(source, .tool(.removeBackground))
        #expect(output.lastPathComponent == "ball (no background).png")
        let image = try #require(Fixtures.readImage(output)).image
        #expect(Fixtures.pixel(image, x: 10, y: 10).a < 20, "the floor is gone")
        #expect(Fixtures.pixel(image, x: 400, y: 300).a > 235, "the ball stays")
    }

    @Test func noSubjectMeansNothingSaved() async throws {
        let folder = try TempFolder()
        let source = folder.file("plain.png")
        try StudioFixtures.save(StudioFixtures.solid(0.6, width: 300, height: 200), to: source)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .tool(.removeBackground)))
        #expect(result.skipped)
        #expect(result.note?.contains("subject") == true)
    }

    @Test func editsTravelToTheWorkerIntact() throws {
        var edit = ImageEdit()
        edit.rotate(clockwise: true)
        edit.markup = [Annotation(kind: .text, points: [RelativePoint(x: 0.3, y: 0.4)], color: .orange, size: 0.05, text: "Hi\nthere")]
        edit.frame.background = .gradient(.sunrise)
        edit.adjustments.filter = .noir
        let request = ConversionRequest(file: SourceFile(url: URL(fileURLWithPath: "/tmp/a.png")), action: .tool(.edit), parameters: .image(edit))
        let decoded = try JSONDecoder().decode(ConversionRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }
}
