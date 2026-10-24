import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PinwheelCore

/// v1.8: what the yellow ticks lost, kept: pictures in RTF and beside
/// Markdown, every sheet as CSV, styled subtitles, sound kept at its bit
/// rate, a JPEG background of your choice, and GIFs without bands.
struct V18Tests {
    private func picture(_ color: CGColor = CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)) throws -> Document.Picture {
        let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        return try #require(Document.Picture.from(png, description: "A red box"))
    }

    private func documentWithPicture() throws -> Document {
        Document(title: "Notes", blocks: [
            .heading(1, [.init("Notes")]),
            .paragraph([.init("Before the picture.")]),
            .image(try picture()),
            .paragraph([.init("After it.")]),
        ])
    }

    @Test func rtfKeepsPictures() throws {
        let folder = try TempFolder()
        let url = folder.file("notes.rtf")
        try AttributedDocument.writeRTF(try documentWithPicture(), to: url)
        let rtf = try String(contentsOf: url, encoding: .utf8)
        #expect(rtf.contains("\\pict\\pngblip\\picw40\\pich30") && !rtf.contains("PinwheelPicture"))
        #expect(rtf.contains("\\picwgoal800\\pichgoal600"), "40 × 30 points, in twips")
        // macOS reads it back, picture and all.
        let back = try DocumentConverter.read(url)
        #expect(back.blocks.contains { if case .image = $0 { return true }; return false })
        #expect(back.plainText.contains("Before the picture.") && back.plainText.contains("After it."))
    }

    @Test func markdownPicturesGoInAFolder() throws {
        let folder = try TempFolder()
        let url = folder.file("Notes.md")
        let written = try DocumentConverter.writeMarkdown(try documentWithPicture(), to: url)
        let pictures = folder.file("Notes pictures")
        #expect(written.outputs?.map(\.path) == [url.path, pictures.path])
        #expect(FileManager.default.fileExists(atPath: pictures.appendingPathComponent("picture 1.png").path))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("![A red box](Notes%20pictures/picture%201.png)") && !text.contains("base64"))
        // Read back, the picture is found again.
        let back = try DocumentConverter.read(url)
        #expect(back.blocks.contains { if case .image = $0 { return true }; return false })
        // Without pictures: just the file.
        #expect(try DocumentConverter.writeMarkdown(Document(blocks: [.paragraph([.init("Hi")])]), to: folder.file("plain.md")).outputs == nil)
    }

    @Test func tablesLineUpInPlainText() {
        let text = Document(blocks: [.table([["Day", "Place", "Km"], ["1", "Chania", "0"], ["12", "Balos", "56"]])]).plainText
        #expect(text == "Day  Place   Km\n───  ──────  ──\n1    Chania  0\n12   Balos   56\n")
    }

    @Test func subtitlesKeepTheirLook() {
        let vtt = """
            WEBVTT

            STYLE
            ::cue(.warning) { color: #FFA500; }

            00:00:01.000 --> 00:00:02.000 line:0 align:start
            <b>Up</b> <c.yellow>here</c>

            00:00:03.000 --> 00:00:04.000
            <c.warning>Careful</c> <i>now</i>
            """
        let cues = Subtitles.parse(vtt)
        #expect(cues.map(\.place.number) == [7, 2], "top left, then the usual bottom center")
        let srt = Subtitles.srt(cues)
        #expect(srt.contains("{\\an7}<b>Up</b> <font color=\"#FFFF00\">here</font>"))
        #expect(srt.contains("<font color=\"#FFA500\">Careful</font> <i>now</i>"))
        // And back: the place goes along; VTT has no font colors, the words stay.
        let back = Subtitles.parse(srt)
        #expect(back.map(\.place.number) == [7, 2])
        let again = Subtitles.vtt(back)
        #expect(again.contains("00:00:01.000 --> 00:00:02.000 line:0 align:start\n<b>Up</b> here"))
        // Plain text, with times if asked.
        #expect(Subtitles.plainText(cues, times: true) == "[00:00:01] Up here\n[00:00:03] Careful now\n")
        #expect(Subtitles.plainText(cues) == "Up here\nCareful now\n")
    }

    @Test func soundKeepsItsBitRate() {
        let mp3 = FFmpeg.AudioStream(probe: "codec_name=mp3\nbit_rate=N/A\nbit_rate=320000\n")
        #expect(mp3.codec == "mp3" && mp3.bitRate == 320_000 && mp3.isLossy)
        #expect(MediaConverter.audioArguments(for: .opus, source: mp3) == ["-vn", "-c:a", "libopus", "-b:a", "256k"])
        #expect(MediaConverter.audioArguments(for: .ogg, source: mp3) == ["-vn", "-c:a", "libvorbis", "-q:a", "9"])
        #expect(MediaConverter.audioArguments(for: .mp3, source: FFmpeg.AudioStream(probe: "codec_name=aac\nbit_rate=256000")) ==
                ["-vn", "-c:a", "libmp3lame", "-b:a", "256k", "-id3v2_version", "3"])
        // Low bit rates: the usual settings, which are already higher.
        #expect(MediaConverter.audioArguments(for: .opus, source: FFmpeg.AudioStream(probe: "codec_name=mp3\nbit_rate=96000")) == nil)
        // Opus between .opus and .ogg: copied, not compressed again.
        let opus = FFmpeg.AudioStream(probe: "codec_name=opus\nbit_rate=96000")
        #expect(MediaConverter.audioArguments(for: .ogg, source: opus) == ["-vn", "-c:a", "copy"])
        // Lossless sound: nothing to keep.
        #expect(MediaConverter.audioArguments(for: .mp3, source: FFmpeg.AudioStream(probe: "codec_name=flac\nbit_rate=900000")) == nil)
    }

    @Test(.enabled(if: ffmpegInstalled, "needs ffmpeg")) func opusIntoOggIsCopied() async throws {
        let folder = try TempFolder()
        let wav = folder.file("tone.wav")
        try MediaFixtures.makeWAV(at: wav, seconds: 1)
        let opus = folder.file("tone.opus")
        try await MediaFixtures.ffmpegTranscode(wav, to: opus, arguments: ["-c:a", "libopus", "-b:a", "96k"])
        let ogg = try await runConversion(opus, .convert(.ogg))
        let ffmpeg = try #require(FFmpeg.locate())
        let stream = try #require(await FFmpeg.audioStream(of: SourceFile(url: ogg), ffmpeg: ffmpeg))
        #expect(ogg.pathExtension == "ogg" && stream.codec == "opus")
    }

    /// A 60 × 40 picture: see-through on the left half.
    private func halfSeeThrough(at url: URL) throws {
        let ctx = try #require(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.clear(CGRect(x: 0, y: 0, width: 60, height: 40))
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 0, width: 30, height: 40))
        let image = try #require(ctx.makeImage())
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    private func pixel(_ url: URL, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    @Test func jpegBackgroundOfYourChoice() async throws {
        let folder = try TempFolder()
        let png = folder.file("logo.png")
        try halfSeeThrough(at: png)
        let white = try await runConversion(png, .convert(.jpeg))
        #expect(try pixel(white, x: 5, y: 20).red > 240)
        var options = ConversionOptions()
        options.jpegBackground = "#000000"
        let black = try await runConversion(png, .convert(.jpeg), options: options)
        let corner = try pixel(black, x: 5, y: 20)
        #expect(corner.red < 15 && corner.green < 15 && corner.blue < 15)
        #expect(ImageConverter.color(hex: "#FFA500")?.components?.map { ($0 * 255).rounded() } == [255, 165, 0, 255])
        #expect(ImageConverter.color(hex: "nope") == nil)
    }

    /// Smooth shading in far more than 256 colors, the hardest case: the
    /// hues across, darker downwards.
    private func gradient(width: Int = 480, height: Int = 240) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let hue = Double(x) / Double(width) * 6, light = 1 - Double(y) / Double(height) * 0.8
                let rgb = [abs(hue - 3) - 1, 2 - abs(hue - 2), 2 - abs(hue - 4)].map { min(max($0, 0), 1) * light }
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = UInt8(rgb[channel] * 255) }
            }
        }
        let ctx = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(ctx.makeImage())
    }

    /// How far, on average, 8 × 8 blocks of `image` are from the same
    /// blocks of `original`: dithering keeps the blocks right, bands don't.
    private func blockError(_ image: CGImage, _ original: CGImage) throws -> Double {
        func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let a = try rgba(image), b = try rgba(original)
        var total = 0.0, blocks = 0
        for blockY in stride(from: 0, to: original.height - 7, by: 8) {
            for blockX in stride(from: 0, to: original.width - 7, by: 8) {
                for channel in 0..<3 {
                    var sumA = 0, sumB = 0
                    for y in blockY..<blockY + 8 {
                        for x in blockX..<blockX + 8 {
                            sumA += Int(a[(y * original.width + x) * 4 + channel]); sumB += Int(b[(y * original.width + x) * 4 + channel])
                        }
                    }
                    total += abs(Double(sumA - sumB)) / 64
                }
                blocks += 1
            }
        }
        return total / Double(blocks * 3)
    }

    @Test func gifsWithoutBands() async throws {
        let folder = try TempFolder()
        let source = folder.file("sky.png")
        let original = try gradient()
        try #require(NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:])).write(to: source)
        // macOS's own GIF, for comparison.
        let plain = folder.file("plain.gif")
        let dest = try #require(CGImageDestinationCreateWithURL(plain as CFURL, UTType.gif.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, original, nil)
        #expect(CGImageDestinationFinalize(dest))

        let gif = try await runConversion(source, .convert(.gif))
        func image(_ url: URL) throws -> CGImage { try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }) }
        let ours = try blockError(try image(gif), original), macOS = try blockError(try image(plain), original)
        #expect(ours < macOS / 2, "dithered: \(ours), banded: \(macOS)")

        // See-through stays see-through.
        let logo = folder.file("logo.png")
        try halfSeeThrough(at: logo)
        let logoGIF = try await runConversion(logo, .convert(.gif))
        #expect(try pixel(logoGIF, x: 5, y: 20).alpha == 0 && pixel(logoGIF, x: 50, y: 20).alpha == 255)
    }

    @Test func thePaletteHasAtMost255Colors() throws {
        let original = try gradient(width: 256, height: 64)
        let dithered = try #require(GIFPalette.dithered(original))
        var bytes = [UInt8](repeating: 0, count: 256 * 64 * 4)
        let ctx = try #require(CGContext(data: &bytes, width: 256, height: 64, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(dithered, in: CGRect(x: 0, y: 0, width: 256, height: 64))
        var colors = Set<UInt32>()
        for index in 0..<(256 * 64) {
            colors.insert(UInt32(bytes[index * 4]) << 16 | UInt32(bytes[index * 4 + 1]) << 8 | UInt32(bytes[index * 4 + 2]))
        }
        #expect(colors.count <= 255 && colors.count > 32)
    }
}
