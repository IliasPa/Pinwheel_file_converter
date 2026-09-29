import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import PinwheelCore

/// Small audio, video and PDF files made on the fly for the tests.
enum MediaFixtures {
    /// A stereo 440 Hz tone.
    static func makeWAV(at url: URL, seconds: Double = 1, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / sampleRate) * 0.3)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// An H.264 movie with an AAC soundtrack (either can be left out), plus
    /// optional metadata such as a title or GPS location.
    static func makeVideo(
        at url: URL, seconds: Double = 1, width: Int = 160, height: Int = 120,
        withAudio: Bool = true, withVideo: Bool = true, fileType: AVFileType = .mov,
        metadata: [AVMetadataItem] = []
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.metadata = metadata

        var video: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if withVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            writer.add(input)
            video = input
        }

        let sampleRate = 44_100
        var audio: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 15
        let frameCount = video == nil ? 0 : Int(seconds * Double(fps))
        let audioFrames = audio == nil ? 0 : Int(seconds * Double(sampleRate))
        let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
        var nextFrame = 0
        var nextSample = 0

        // Feed both tracks in turn; AVAssetWriter wants them interleaved.
        while nextFrame < frameCount || nextSample < audioFrames {
            var fed = false
            if let video, let adaptor, nextFrame < frameCount, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(40 + nextFrame * 10 % 200),
                       CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: fps))
                nextFrame += 1
                if nextFrame == frameCount { video.markAsFinished() }
                fed = true
            }
            if let audio, nextSample < audioFrames, audio.isReadyForMoreMediaData {
                let count = min(4_410, audioFrames - nextSample)
                let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    buffer.int16ChannelData![0][i] = Int16(sin(Double(nextSample + i) * 2 * .pi * 440 / Double(sampleRate)) * 8_000)
                }
                audio.append(try sampleBuffer(buffer, at: CMTime(value: CMTimeValue(nextSample), timescale: CMTimeScale(sampleRate))))
                nextSample += count
                if nextSample == audioFrames { audio.markAsFinished() }
                fed = true
            }
            if !fed { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A title and a GPS location, the kind of thing Strip Info should remove.
    static func privateMetadata() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .quickTimeMetadataTitle
        title.value = "Secret trip" as NSString
        title.dataType = kCMMetadataBaseDataType_UTF8 as String
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+37.9838+023.7275+000.000/" as NSString
        location.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        return [title, location]
    }

    /// An iTunes-style title tag, for .m4a files.
    static func titleTag() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .iTunesMetadataSongName
        title.value = "Secret song" as NSString
        return [title]
    }

    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw CocoaError(.fileWriteUnknown) }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard status == noErr else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }

    /// A PDF with `pages` pages of 200×100 points, each a different color.
    static func makePDF(at url: URL, pages: Int, withPhoto: Bool = false) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextAuthor: "Pinwheel Tests"] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(page) / CGFloat(max(pages, 1)), green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 60))
            if withPhoto {
                ctx.draw(noiseImage(width: 1200, height: 600), in: CGRect(x: 0, y: 0, width: 200, height: 100))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Random pixels: compresses badly, so shrinking it is easy to measure.
    private static func noiseImage(width: Int, height: Int) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = UInt8.random(in: 0...255, using: &generator)
            bytes[i + 1] = UInt8.random(in: 0...255, using: &generator)
            bytes[i + 2] = UInt8.random(in: 0...255, using: &generator)
            bytes[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Uses the app's own ffmpeg runner to make MKV/OGG inputs for tests.
    static func ffmpegTranscode(_ input: URL, to output: URL, arguments: [String]) async throws {
        let ffmpeg = try #require(FFmpeg.locate())
        try await FFmpeg.convert(ffmpeg: ffmpeg, input: input, output: output, arguments: arguments, duration: nil) { _ in }
    }
}

/// Runs a conversion the same way the app does, with a fresh name.
func runConversion(_ source: URL, _ action: WheelAction, options: ConversionOptions? = nil,
                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
    var options = options ?? ConversionOptions()
    if options.ffmpegURL == nil { options.ffmpegURL = FFmpeg.locate() }
    let file = SourceFile(url: source)
    let plan = ConversionEngine.plan(for: file, action: action)
    let destination = OutputNaming().reserve(for: source, suffix: plan.suffix, fileExtension: plan.fileExtension)
    let outputs = try await ConversionEngine.run(file: file, action: action, destination: destination, options: options, progress: progress)
    return try #require(outputs.first)
}

let ffmpegInstalled = FFmpeg.locate() != nil
