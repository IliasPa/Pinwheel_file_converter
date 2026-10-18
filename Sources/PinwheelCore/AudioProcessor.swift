import AVFoundation
import Foundation

/// Changes the sound of a file: keeps a part, changes the speed (keeping
/// the pitch), fades in and out, and makes it louder, quieter or as loud as
/// streaming services expect. Works on the soundtrack of videos too.
enum AudioProcessor {
    /// What came out of `process`, for the progress window.
    struct Outcome {
        var note: String?
    }

    /// Writes the edited sound of `source` to `destination`, in the format
    /// its extension asks for (M4A, WAV, AIFF, CAF or FLAC; anything else is
    /// encoded by ffmpeg).
    /// `skipIfAlreadyNormal`: when normalizing is the only change and the
    /// loudness is already right, stop with nothing saved.
    static func process(
        _ source: URL, edit: MediaEdit, to destination: URL, ffmpegURL: URL?,
        skipIfAlreadyNormal: Bool = false, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Outcome {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. The part kept, as plain samples (measuring loudness on the way).
        let decoded = work.appendingPathComponent("decoded.caf")
        let measured = try await decode(source, edit: edit, to: decoded) { progress($0 * 0.45) }
        try Task.checkCancellation()

        // 2. A different speed, with the same pitch.
        var samples = decoded
        if edit.speed != 1 {
            let stretched = work.appendingPathComponent("stretched.caf")
            try await Blocking.run { isCancelled in try stretch(decoded, rate: edit.speed, to: stretched, isCancelled: isCancelled) }
            samples = stretched
            progress(0.6)
        }
        try Task.checkCancellation()

        // 3. How much louder or quieter.
        var note: String?
        var gainDB = edit.volume
        if edit.normalize {
            guard let loudness = measured.loudness else {
                throw NothingToDo(reason: "It's silent, so there was nothing to make louder.")
            }
            gainDB = MediaEdit.targetLoudness - loudness
            let headroom = MediaEdit.peakCeiling - 20 * log10(max(Double(measured.peak), 1e-9))
            if gainDB > headroom {
                gainDB = headroom
                note = String(format: "Loudness %.1f → %.1f LUFS (peaks don't allow more).", loudness, loudness + gainDB)
            } else {
                note = String(format: "Loudness %.1f → %.1f LUFS.", loudness, MediaEdit.targetLoudness)
            }
            if skipIfAlreadyNormal && abs(gainDB) < 0.5 {
                throw NothingToDo(reason: String(format: "Already at %.1f LUFS, so nothing was changed.", loudness))
            }
        } else if edit.volume > 0, Double(measured.peak) * pow(10, edit.volume / 20) > 1 {
            note = "Some peaks were too loud and were clipped. Try a smaller boost, or Normalize."
        }

        // 4. Gain and fades, written in the final format.
        let ext = destination.pathExtension.lowercased()
        let input = samples, gain = gainDB
        if let settings = SendableSettings(nativeSettings(for: ext, like: samples)) {
            try await Blocking.run { isCancelled in
                try finish(input, gainDB: gain, fadeIn: edit.fadeIn, fadeOut: edit.fadeOut, to: destination, settings: settings.value, isCancelled: isCancelled) {
                    progress(0.6 + $0 * 0.4)
                }
            }
        } else {
            guard let ffmpeg = ffmpegURL else { throw ConversionError.needsFFmpeg }
            let wav = work.appendingPathComponent("final.wav")
            let settings = SendableSettings(pcmSettings(of: samples, bits: 24, bigEndian: false))!
            try await Blocking.run { isCancelled in
                try finish(input, gainDB: gain, fadeIn: edit.fadeIn, fadeOut: edit.fadeOut, to: wav, settings: settings.value, isCancelled: isCancelled) {
                    progress(0.6 + $0 * 0.2)
                }
            }
            var arguments = ["-map_metadata", "-1"]
            if ext == "mp3" { arguments += ["-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3"] }
            try await FFmpeg.convert(ffmpeg: ffmpeg, input: wav, output: destination, arguments: arguments, duration: nil) { progress(0.8 + $0 * 0.2) }
        }
        progress(1)
        return Outcome(note: note)
    }

    // MARK: - Steps

    struct Measured {
        /// Integrated loudness in LUFS, nil for silence.
        var loudness: Double?
        /// Highest sample, 0...1.
        var peak: Float
    }

    /// The kept part of the first soundtrack, as 32-bit float samples (at
    /// most 2 channels and 48 kHz).
    static func decode(
        _ source: URL, edit: MediaEdit, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Measured {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NothingToDo(reason: "\(source.lastPathComponent) has no sound.")
        }
        let duration = try await asset.load(.duration).seconds
        let (start, end) = edit.range(duration: duration)
        let format = try await AudioFormat.of(track)
        let box = TrackBox(track: track)  // only read, on that one thread
        return try await Blocking.run { isCancelled in
            try read(asset, track: box.track, from: start, to: end, format: format, into: destination, isCancelled: isCancelled, progress: progress)
        }
    }

    /// The decoding loop (it waits on AVFoundation, so it runs on its own thread).
    private static func read(
        _ asset: AVURLAsset, track: AVAssetTrack, from start: Double, to end: Double, format: AudioFormat,
        into destination: URL, isCancelled: () -> Bool, progress: (Double) -> Void
    ) throws -> Measured {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 48_000),
            end: CMTime(seconds: end, preferredTimescale: 48_000)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the sound.")
        }
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: AVAudioChannelCount(format.channels), interleaved: false)!
        let file = try AVAudioFile(forWriting: destination, settings: pcm.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var meter = LoudnessMeter(sampleRate: format.sampleRate, channels: format.channels)
        var peak: Float = 0
        let total = max(end - start, 0.001)
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw ConversionError.failed("Couldn't read the sound (\(status)).") }
            meter.add(buffer)
            peak = max(peak, buffer.peak)
            try file.write(from: buffer)
            progress(min((sample.presentationTimeStamp.seconds - start) / total, 1))
        }
        if reader.status == .failed {
            throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the sound.")
        }
        return Measured(loudness: meter.integratedLoudness, peak: peak)
    }

    /// Plays the file faster or slower through Apple's time-pitch unit,
    /// offline (as fast as the Mac can), keeping the pitch.
    static func stretch(_ source: URL, rate: Double, to destination: URL, isCancelled: () -> Bool) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(input, at: nil)
        player.play()

        let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw ConversionError.failed("Not enough memory to change the speed.")
        }
        let length = AVAudioFramePosition((Double(input.length) / rate).rounded())
        while engine.manualRenderingSampleTime < length {
            if isCancelled() { throw CancellationError() }
            let frames = min(AVAudioFrameCount(length - engine.manualRenderingSampleTime), buffer.frameCapacity)
            switch try engine.renderOffline(frames, to: buffer) {
            case .success:
                try output.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw ConversionError.failed("Couldn't change the speed.")
            @unknown default:
                throw ConversionError.failed("Couldn't change the speed.")
            }
        }
        player.stop()
    }

    /// Applies the gain (dB) and the fades while writing the final file.
    static func finish(
        _ source: URL, gainDB: Double, fadeIn: Double, fadeOut: Double, to destination: URL,
        settings: [String: Any], isCancelled: () -> Bool, progress: (Double) -> Void
    ) throws {
        let input = try AVAudioFile(forReading: source)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        let rate = input.processingFormat.sampleRate
        let total = input.length
        let fadeInFrames = AVAudioFramePosition(fadeIn * rate)
        let fadeOutFrames = AVAudioFramePosition(fadeOut * rate)
        let gain = Float(pow(10, gainDB / 20))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            throw ConversionError.failed("Not enough memory to change the sound.")
        }
        var position: AVAudioFramePosition = 0
        while input.framePosition < total {
            if isCancelled() { throw CancellationError() }
            try input.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                guard let data = buffer.floatChannelData?[channel] else { continue }
                for index in 0..<frames {
                    let at = position + AVAudioFramePosition(index)
                    var factor = gain
                    if at < fadeInFrames { factor *= Float(at) / Float(fadeInFrames) }
                    let fromEnd = total - at
                    if fromEnd < fadeOutFrames { factor *= Float(fromEnd) / Float(fadeOutFrames) }
                    data[index] = min(max(data[index] * factor, -1), 1)
                }
            }
            try output.write(from: buffer)
            position += AVAudioFramePosition(frames)
            progress(Double(position) / Double(max(total, 1)))
        }
    }

    // MARK: - Formats

    /// Settings for writing `ext` with Core Audio, or nil when only ffmpeg can.
    static func nativeSettings(for ext: String, like samples: URL) -> [String: Any]? {
        guard let format = try? AVAudioFile(forReading: samples).processingFormat else { return nil }
        let rate = format.sampleRate, channels = Int(format.channelCount)
        switch ext {
        case "m4a", "m4b", "mp4", "mov", "m4v":
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(rate, 48_000),
                AVNumberOfChannelsKey: min(channels, 2), AVEncoderBitRateKey: 256_000,
            ]
        case "wav": return pcmSettings(of: samples, bits: 24, bigEndian: false)
        case "aif", "aiff", "aifc": return pcmSettings(of: samples, bits: 24, bigEndian: true)
        case "caf": return pcmSettings(of: samples, bits: 24, bigEndian: false)
        case "flac":
            return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 24]
        default:
            return nil
        }
    }

    static func pcmSettings(of samples: URL, bits: Int, bigEndian: Bool) -> [String: Any] {
        let format = (try? AVAudioFile(forReading: samples).processingFormat)
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format?.sampleRate ?? 44_100,
            AVNumberOfChannelsKey: Int(format?.channelCount ?? 2),
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The loudness and peak of a whole file, for the editor's display.
    static func measure(_ source: URL) async throws -> Measured {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-measure-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await decode(source, edit: MediaEdit(), to: scratch) { _ in }
    }
}

private struct TrackBox: @unchecked Sendable {
    let track: AVAssetTrack
}

/// Audio settings travel to the thread that writes the file.
private struct SendableSettings: @unchecked Sendable {
    let value: [String: Any]

    init?(_ value: [String: Any]?) {
        guard let value else { return nil }
        self.value = value
    }
}

private extension AVAudioPCMBuffer {
    var peak: Float {
        var peak: Float = 0
        for channel in 0..<Int(format.channelCount) {
            guard let data = floatChannelData?[channel] else { continue }
            for index in 0..<Int(frameLength) { peak = max(peak, abs(data[index])) }
        }
        return peak
    }
}

/// Integrated loudness as defined by ITU-R BS.1770 (what "LUFS" means):
/// K-weighted, in 400 ms blocks, ignoring silence and quiet passages.
struct LoudnessMeter {
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var stages: [[Biquad]]
    private let blockFrames: Int
    /// Mean square of each 100 ms step, summed over the channels.
    private var steps: [Double] = []
    private var stepSum = 0.0
    private var stepFill = 0

    init(sampleRate: Double, channels: Int) {
        // Stage 1: a high shelf (the head's effect); stage 2: a high pass.
        var k = tan(Double.pi * 1681.974450955533 / sampleRate)
        let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416), q1 = 0.7071752369554196
        var a0 = 1 + k / q1 + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
            a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0
        )
        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        let q2 = 0.5003270373238773
        a0 = 1 + k / q2 + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        stages = Array(repeating: [shelf, highPass], count: max(channels, 1))
        blockFrames = max(Int(sampleRate * 0.1), 1)
    }

    mutating func add(_ buffer: AVAudioPCMBuffer) {
        let channels = min(Int(buffer.format.channelCount), stages.count)
        for index in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                guard let data = buffer.floatChannelData?[channel] else { continue }
                var value = Double(data[index])
                value = stages[channel][0].process(value)
                value = stages[channel][1].process(value)
                stepSum += value * value
            }
            stepFill += 1
            if stepFill == blockFrames {
                steps.append(stepSum / Double(blockFrames))
                stepSum = 0
                stepFill = 0
            }
        }
    }

    /// LUFS, or nil when there's nothing but silence.
    var integratedLoudness: Double? {
        // 400 ms blocks overlapping by 75% are four 100 ms steps.
        guard steps.count >= 4 else {
            let power = steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count)
            return power > 0 ? -0.691 + 10 * log10(power) : nil
        }
        let blocks = (0...(steps.count - 4)).map { (steps[$0] + steps[$0 + 1] + steps[$0 + 2] + steps[$0 + 3]) / 4 }
        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let audible = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relativeGate = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

/// What the video and audio editor shows about the sound.
public enum MediaAnalysis {
    /// The loudness (LUFS; nil for silence) and the highest peak (0...1).
    public static func loudness(of url: URL) async throws -> (loudness: Double?, peak: Float) {
        let measured = try await AudioProcessor.measure(url)
        return (measured.loudness, measured.peak)
    }

    /// `count` peaks across the whole soundtrack (0...1), for drawing it.
    public static func waveform(of url: URL, count: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        let box = TrackBox(track: track)
        return try await Blocking.run { isCancelled in
            let reader = try AVAssetReader(asset: asset)
            let rate = 8_000.0  // the lowest AVFoundation allows
            let output = AVAssetReaderTrackOutput(track: box.track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            guard reader.startReading() else { return [] }
            let perBucket = max(Int(duration * rate) / max(count, 1), 1)
            var peaks: [Float] = []
            var current: Float = 0
            var filled = 0
            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                // Copied out: the samples may be split over several pieces of memory.
                var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 4, destination: &samples) == noErr else { continue }
                for value in samples {
                    current = max(current, abs(value))
                    filled += 1
                    if filled == perBucket {
                        peaks.append(min(current, 1))
                        current = 0
                        filled = 0
                    }
                }
            }
            if filled > 0 { peaks.append(min(current, 1)) }
            return peaks
        }
    }
}
