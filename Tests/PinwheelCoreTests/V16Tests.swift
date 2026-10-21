import AVFoundation
import AppKit
import CoreText
import Foundation
import Testing
@testable import PinwheelCore

/// A WAV whose left and right sides are made separately.
private func makeStereo(at url: URL, seconds: Double = 1, rate: Double = 44_100, left: (Double) -> Float, right: (Double) -> Float) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        let time = Double(index) / rate
        buffer.floatChannelData![0][index] = left(time)
        buffer.floatChannelData![1][index] = right(time)
    }
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

private func tone(_ frequency: Double, _ level: Float = 0.3) -> (Double) -> Float {
    { level * Float(sin(2 * .pi * frequency * $0)) }
}

/// A sound file's samples, by channel.
private func samples(of url: URL) throws -> (channels: [[Float]], rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let channels = (0..<Int(buffer.format.channelCount)).map { channel in
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }
    return (channels, file.processingFormat.sampleRate)
}

/// How loud a stretch is (root mean square).
private func rms(_ samples: [Float], rate: Double, from start: Double, to end: Double) -> Float {
    let slice = samples[Int(start * rate)..<min(Int(end * rate), samples.count)]
    return (slice.map { $0 * $0 }.reduce(0, +) / Float(max(slice.count, 1))).squareRoot()
}

private func edited(_ source: URL, _ edit: MediaEdit) async throws -> URL {
    let result = try await runRequest(ConversionRequest(file: SourceFile(url: source), action: .tool(.editMedia), parameters: .media(edit)))
    return try #require(result.outputs.first, "nothing saved: \(result.note ?? "")")
}

// MARK: - The edit

struct V16MediaEditTests {
    @Test func piecesAndBleepsInTime() {
        var edit = MediaEdit()
        edit.start = 1
        edit.end = 9
        edit.splits = [5, 3, 0.5, 9.5, 3.0001]
        let pieces = edit.pieces(duration: 10)
        #expect(pieces.map(\.start) == [1, 3, 5] && pieces.map(\.end) == [3, 5, 9], "outside the part, twice, or too close: left out")
        #expect(!edit.isEmpty(duration: 10) && edit.isTrimOnly)

        edit.speed = 2
        edit.bleeps = [.init(start: 4, end: 5), .init(start: 0, end: 2), .init(start: 4.5, end: 6)]
        let bleeps = edit.bleepTimes(duration: 10)
        #expect(bleeps.map(\.start) == [0, 1.5] && bleeps.map(\.end) == [0.5, 2.5], "in the result's time, overlaps merged")
        #expect(edit.changesSound && !edit.isTrimOnly)

        var cropped = MediaEdit()
        cropped.crop = RelativeRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(!cropped.isTrimOnly && !cropped.changesSound && !cropped.isEmpty(duration: 10))
        // A 9:16 strip of a 16:9 picture, full height; moved right, it stops at the edge.
        let strip = MediaEdit.cropRect(shape: AspectRatio(9, 16), scale: 1, center: RelativePoint(x: 0.9, y: 0.5), shownSize: CGSize(width: 1920, height: 1080))
        #expect(abs(strip.width - 0.31640625) < 0.0001 && strip.height == 1 && abs(strip.x + strip.width - 1) < 0.0001)
        let square = MediaEdit.cropRect(shape: .square, scale: 0.5, center: RelativePoint(x: 0.5, y: 0.5), shownSize: CGSize(width: 1080, height: 1920))
        #expect(square.width == 0.5 && abs(square.height - 0.28125) < 0.0001 && square.x == 0.25)
        #expect(AudioChannels.mono.count(from: 2) == 1 && AudioChannels.stereo.count(from: 1) == 2 && AudioChannels.unchanged.count(from: 6) == 2)
    }
}

// MARK: - Sound

struct V16SoundTests {
    @Test func channels() async throws {
        let folder = try TempFolder()
        let source = folder.file("interview.wav")
        try makeStereo(at: source, left: tone(440), right: { _ in 0 })  // the voice on one side only

        var edit = MediaEdit()
        edit.channels = .left
        let left = try samples(of: try await edited(source, edit))
        #expect(left.channels.count == 1)
        #expect(rms(left.channels[0], rate: left.rate, from: 0.1, to: 0.9) > 0.18)

        edit.channels = .right
        let right = try samples(of: try await edited(source, edit))
        #expect(right.channels.count == 1 && rms(right.channels[0], rate: right.rate, from: 0.1, to: 0.9) < 0.01)

        edit.channels = .mono
        let mono = try samples(of: try await edited(source, edit))
        let level = rms(mono.channels[0], rate: mono.rate, from: 0.1, to: 0.9)
        #expect(mono.channels.count == 1 && level > 0.09 && level < 0.12, "both sides mixed: half as loud")

        let single = folder.file("single.wav")
        try makeStereo(at: single, left: tone(440), right: tone(440))
        edit.channels = .mono
        let collapsed = try await edited(single, edit)
        edit.channels = .stereo
        let both = try samples(of: try await edited(collapsed, edit))
        #expect(both.channels.count == 2 && both.channels[0] == both.channels[1])
    }

    @Test func bleeps() async throws {
        let folder = try TempFolder()
        let source = folder.file("speech.wav")
        try makeStereo(at: source, seconds: 2, left: tone(300), right: tone(300))
        var edit = MediaEdit()
        edit.bleeps = [.init(start: 0.5, end: 1.0)]
        let beeped = try samples(of: try await edited(source, edit))
        let channel = beeped.channels[0]
        // Inside: exactly the beep (1 kHz at the beep's level); outside: untouched.
        let inside = Array(channel[Int(0.6 * beeped.rate)..<Int(0.9 * beeped.rate)])
        let expected = (Int(0.6 * beeped.rate)..<Int(0.9 * beeped.rate)).map { MediaEdit.bleepLevel * Float(sin(2 * .pi * 1000 * Double($0) / beeped.rate)) }
        #expect(zip(inside, expected).allSatisfy { abs($0 - $1) < 0.01 })
        #expect(abs(rms(channel, rate: beeped.rate, from: 1.2, to: 1.8) - Float(0.3) / Float(2).squareRoot()) < 0.01)

        edit.silentBleeps = true
        let silenced = try samples(of: try await edited(source, edit))
        #expect(rms(silenced.channels[0], rate: silenced.rate, from: 0.52, to: 0.98) < 0.001)
        #expect(rms(silenced.channels[0], rate: silenced.rate, from: 0.1, to: 0.45) > 0.2)
    }
}

// MARK: - Pieces and crops

struct V16VideoTests {
    @Test func splitIntoPieces() async throws {
        let folder = try TempFolder()
        let clip = folder.file("clip.mov")
        try await MediaFixtures.makeVideo(at: clip, seconds: 3)
        var edit = MediaEdit()
        edit.splits = [1, 2]
        let output = try await edited(clip, edit)
        #expect(output.lastPathComponent == "clip (split)")
        let parts = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(parts == ["clip part 1.mov", "clip part 2.mov", "clip part 3.mov"])
        for part in parts {
            let length = try await AVURLAsset(url: output.appendingPathComponent(part)).load(.duration).seconds
            #expect(abs(length - 1) < 0.15, "\(part): \(length)")
        }

        // Sound too, with the same change on every piece.
        let song = folder.file("song.wav")
        try MediaFixtures.makeWAV(at: song, seconds: 2)
        var louder = MediaEdit()
        louder.splits = [0.5]
        louder.volume = -6
        let pieces = try await edited(song, louder)
        let names = try FileManager.default.contentsOfDirectory(atPath: pieces.path).sorted()
        #expect(names == ["song part 1.wav", "song part 2.wav"])
        let second = try samples(of: pieces.appendingPathComponent(names[1]))
        #expect(abs(Double(second.channels[0].count) / second.rate - 1.5) < 0.01)
        #expect(abs(rms(second.channels[0], rate: second.rate, from: 0.2, to: 1.2) - Float(0.15) / Float(2).squareRoot()) < 0.01)
    }

    @Test func crop() async throws {
        let folder = try TempFolder()
        let clip = folder.file("wide.mp4")
        try await MediaFixtures.makeVideo(at: clip, seconds: 1, width: 320, height: 180, fileType: .mp4)
        var edit = MediaEdit()
        edit.crop = RelativeRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let cropped = try await edited(clip, edit)
        #expect(cropped.pathExtension == "mp4")
        #expect(try await shownSize(of: cropped) == CGSize(width: 160, height: 180))
        #expect(try await AVURLAsset(url: cropped).loadTracks(withMediaType: .audio).count == 1, "the sound stays")

        // Turned first, then cropped as shown: a 9:16 strip of the upright picture.
        edit.quarterTurns = 1
        edit.crop = RelativeRect(x: 0, y: 0.25, width: 1, height: 0.5)
        #expect(try await shownSize(of: try await edited(clip, edit)) == CGSize(width: 180, height: 160))

        // The frame too.
        let request = ConversionRequest(
            file: SourceFile(url: clip), action: .tool(.saveFrame),
            parameters: .frame(seconds: 0.5, quarterTurns: 0, crop: RelativeRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        )
        let frame = try #require(try await runRequest(request).outputs.first)
        let info = try #require(Fixtures.readImage(frame))
        #expect(info.width == 160 && info.height == 90)
    }

    private func shownSize(of url: URL) async throws -> CGSize {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let box = CGRect(origin: .zero, size: try await track.load(.naturalSize)).applying(try await track.load(.preferredTransform))
        return CGSize(width: abs(box.width), height: abs(box.height))
    }
}

// MARK: - Visualizer

struct V16VisualizerTests {
    @Test func barsFollowThePitch() {
        let spectrum = Visualizer.Spectrum(size: 2048, rate: 44_100, bands: 48)
        let tone = (0..<2048).map { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / 44_100)) }
        let levels = spectrum.levels(tone)
        let loudest = levels.indices.max { levels[$0] < levels[$1] }!
        // 48 bands from 50 Hz to 12 kHz: 1 kHz is band 26.
        #expect(abs(loudest - 26) <= 1, "loudest band \(loudest)")
        #expect(levels[loudest] > 0.8 && levels[2] < 0.3)
        #expect(spectrum.levels([Float](repeating: 0, count: 2048)).allSatisfy { $0 == 0 })
        // Music-like sound (quieter the higher it goes) moves the high bars too.
        var generator = SystemRandomNumberGenerator()
        var pink: Float = 0
        let noise = (0..<2048).map { _ -> Float in
            pink = pink * 0.9 + Float.random(in: -0.1...0.1, using: &generator)
            return pink
        }
        let spread = spectrum.levels(noise)
        #expect(spread[40...].reduce(0, +) / 8 > 0.3, "high bars: \(spread[40...])")
    }

    @Test func aVideoOfTheSound() async throws {
        let folder = try TempFolder()
        let song = folder.file("song.wav")
        // Low, then high: the bars move from left to right.
        try makeStereo(at: song, seconds: 2, left: { $0 < 1 ? 0.4 * Float(sin(2 * .pi * 120 * $0)) : 0.4 * Float(sin(2 * .pi * 4000 * $0)) },
                       right: { $0 < 1 ? 0.4 * Float(sin(2 * .pi * 120 * $0)) : 0.4 * Float(sin(2 * .pi * 4000 * $0)) })
        var spec = VisualizerSpec()
        spec.shape = .landscape
        spec.title = "My Song"
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: song), action: .tool(.visualize), parameters: .visualizer(spec)))
        let video = try #require(result.outputs.first)
        #expect(video.lastPathComponent == "song (visualizer).mp4")
        let asset = AVURLAsset(url: video)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1920, height: 1080))
        #expect(abs(try await track.load(.nominalFrameRate) - 30) < 0.5)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let low = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let high = try await generator.image(at: CMTime(seconds: 1.6, preferredTimescale: 600)).image
        // Bars start 10% in; the first fifth is low pitches, the last fifth high ones.
        func brightness(_ image: CGImage, from: Double, to: Double) -> Double {
            var total = 0.0
            for step in 0..<40 {
                let x = Int((from + (to - from) * Double(step) / 40) * Double(image.width))
                let pixel = Fixtures.pixel(image, x: x, y: image.height / 2 - 60)
                total += Double(pixel.r) + Double(pixel.g) + Double(pixel.b)
            }
            return total
        }
        #expect(brightness(low, from: 0.12, to: 0.25) > brightness(high, from: 0.12, to: 0.25))
        #expect(brightness(high, from: 0.75, to: 0.88) > brightness(low, from: 0.75, to: 0.88))
    }

    @Test func aPictureBehind() throws {
        let folder = try TempFolder()
        let picture = folder.file("cover.png")
        try Fixtures.makeImage(at: picture, width: 300, height: 200)  // red
        var spec = VisualizerSpec()
        spec.picture = picture.path
        let backdrop = try Visualizer.backdrop(spec, size: CGSize(width: 100, height: 100))
        let corner = Fixtures.pixel(backdrop, x: 2, y: 2)
        #expect(corner.r > 120 && corner.g < 40 && corner.b < 40, "the picture, a little darker: \(corner)")
        #expect(Visualizer.preview(spec) != nil)
        spec.picture = nil
        spec.gradient = .mint
        let gradient = Fixtures.pixel(try Visualizer.backdrop(spec, size: CGSize(width: 100, height: 100)), x: 50, y: 50)
        #expect(gradient.g > gradient.r && gradient.g > gradient.b)
    }
}

// MARK: - Blur faces and text

struct V16BlurTests {
    @Test func textIsBlurredOut() async throws {
        let folder = try TempFolder()
        let card = folder.file("card.png")
        let size = CGSize(width: 800, height: 400)
        let ctx = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "IBAN 1234 5678" as CFString, [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ] as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 80, y: 260)  // the top half (y up)
        CTLineDraw(line, ctx)
        let destination = CGImageDestinationCreateWithURL(card as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(destination)

        let regions = try PrivacyBlur.regions(in: ctx.makeImage()!, faces: false)
        let text = try #require(regions.first)
        #expect(regions.count == 1 && text.y < 0.4 && text.y + text.height > 0.25 && text.x < 0.12, "\(regions)")

        let blurred = try await runConversion(card, .tool(.blurPrivate))
        #expect(blurred.lastPathComponent == "card (blurred).png")
        let before = try #require(Fixtures.readImage(card)?.image), after = try #require(Fixtures.readImage(blurred)?.image)
        var changed = 0
        for x in stride(from: 90, to: 700, by: 10) where Fixtures.pixel(before, x: x, y: 120) != Fixtures.pixel(after, x: x, y: 120) { changed += 1 }
        #expect(changed > 20, "the text is hidden")
        #expect(Fixtures.pixel(after, x: 400, y: 350) == Fixtures.pixel(before, x: 400, y: 350), "the rest stays")

        // Nothing to hide: nothing saved.
        let plain = folder.file("plain.png")
        try Fixtures.makeImage(at: plain, width: 200, height: 200)
        let result = try await runRequest(ConversionRequest(file: SourceFile(url: plain), action: .tool(.blurPrivate)))
        #expect(result.outputs.isEmpty && result.note?.contains("No faces or text") == true)
    }
}

// MARK: - Wheels, custom actions and symbols

struct V16CatalogTests {
    @Test func whereTheNewToolsAre() {
        #expect(FormatCatalog.actions(for: .audio, mode: .tools).contains(.open(.visualizer)))
        #expect(FormatCatalog.actions(for: .image, mode: .tools).contains(.tool(.blurPrivate)))
        #expect(FormatCatalog.defaultHidden.contains(FormatCatalog.hiddenKey(.image, .tool(.blurPrivate))))
        #expect(FormatCatalog.fileActions.contains(.file(.shelf)))
    }

    @Test func customActionSteps() async throws {
        #expect(RecipeStep.templates(for: .image).contains(.blurFacesAndText))
        #expect(RecipeStep.templates(for: .audio).contains(.mono) && RecipeStep.mono.works(on: .video) && !RecipeStep.mono.works(on: .image))
        #expect(RecipeStep.blurFacesAndText.job.action == .tool(.blurPrivate))

        let folder = try TempFolder()
        let song = folder.file("talk.wav")
        try makeStereo(at: song, left: tone(440), right: { _ in 0 })
        let recipe = Recipe(name: "Podcast", kind: .audio, steps: [.mono, .convert(.m4a)])
        let output = try await runConversion(song, .recipe(recipe))
        #expect(output.pathExtension == "m4a")
        #expect(try AVAudioFile(forReading: output).processingFormat.channelCount == 1)
    }

    @Test func everyNewSymbolExists() {
        let names = [
            ToolAction.blurPrivate.symbolName, ToolAction.visualize.symbolName, Editor.visualizer.symbolName,
            FileAction.shelf.symbolName, RecipeStep.mono.symbolName, "speaker.badge.exclamationmark", "person.crop.square",
            "tray.and.arrow.down", "scissors",
        ]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }
}
