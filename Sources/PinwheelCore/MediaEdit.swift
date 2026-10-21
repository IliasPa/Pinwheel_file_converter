import CoreGraphics
import Foundation

/// What the video and audio editor does: keep a part (or cut it into
/// several), change the speed, turn and crop the picture, and change the
/// sound (mute, fades, volume, loudness, bleeps, channels).
public struct MediaEdit: Codable, Sendable, Equatable {
    /// The part kept, in seconds of the original (`end` nil: to the end).
    public var start = 0.0
    public var end: Double?
    /// 0.25...4; the pitch of voices stays the same.
    public var speed = 1.0
    /// Clockwise quarter turns of the picture.
    public var quarterTurns = 0
    /// No sound at all (videos).
    public var mute = false
    /// Seconds of fading in and out.
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    /// Louder or quieter, in decibels (-20...20). Ignored when normalizing.
    public var volume = 0.0
    /// Brings the loudness to `targetLoudness`, like streaming services do.
    public var normalize = false
    /// Where the part is cut, in seconds of the original: each piece is
    /// saved on its own, in a folder.
    public var splits: [Double] = []
    /// The part of the picture kept, as a share of the picture as shown
    /// (after turning); nil keeps all of it.
    public var crop: RelativeRect?
    /// Stretches covered by a beep, in seconds of the original.
    public var bleeps: [Bleep] = []
    /// Bleeps are silent instead of a beep.
    public var silentBleeps = false
    public var channels: AudioChannels = .unchanged

    public init() {}

    public struct Bleep: Codable, Sendable, Equatable, Hashable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// The beep's pitch and level (about −10 dBFS).
    public static let bleepFrequency = 1000.0
    public static let bleepLevel: Float = 0.3

    /// LUFS: the level podcasts and Apple Music aim for.
    public static let targetLoudness = -16.0
    /// Peaks are kept below this (dBFS), so nothing clips.
    public static let peakCeiling = -1.0
    public static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// The sound itself changes (not just which part is kept).
    public var changesSound: Bool {
        speed != 1 || fadeIn > 0 || fadeOut > 0 || volume != 0 || normalize || !bleeps.isEmpty || channels != .unchanged
    }

    /// Only a part is kept: that can be copied as it is, without re-encoding.
    public var isTrimOnly: Bool {
        !changesSound && quarterTurns % 4 == 0 && !mute && crop == nil
    }

    /// The part kept, clamped to the file's length.
    public func range(duration: Double) -> (start: Double, end: Double) {
        let start = min(max(start, 0), max(duration - 0.05, 0))
        let end = min(max(end ?? duration, start + 0.05), duration)
        return (start, end)
    }

    /// Nothing would change for a file this long.
    public func isEmpty(duration: Double) -> Bool {
        let (start, end) = range(duration: duration)
        return isTrimOnly && start < 0.01 && end > duration - 0.01 && pieces(duration: duration).count == 1
    }

    /// The part, cut where the splits are: each piece's start and end.
    public func pieces(duration: Double) -> [(start: Double, end: Double)] {
        let (start, end) = range(duration: duration)
        let cuts = Set(splits.filter { $0 > start + 0.05 && $0 < end - 0.05 }.map { ($0 * 1000).rounded() / 1000 }).sorted()
        let bounds = [start] + cuts + [end]
        return zip(bounds, bounds.dropFirst()).map { ($0, $1) }
    }

    /// The bleeps in the result's own time (after cutting and the speed),
    /// in order and not overlapping.
    public func bleepTimes(duration: Double) -> [(start: Double, end: Double)] {
        let (start, end) = range(duration: duration)
        var result: [(start: Double, end: Double)] = []
        for bleep in bleeps.sorted(by: { $0.start < $1.start }) {
            let from = (max(bleep.start, start) - start) / speed, to = (min(bleep.end, end) - start) / speed
            guard to > from else { continue }
            if let last = result.last, from <= last.end {
                result[result.count - 1].end = max(last.end, to)
            } else {
                result.append((from, to))
            }
        }
        return result
    }

    /// The biggest box of `shape` in a picture shown at `shownSize`, made
    /// `scale` times as big (0.2...1) and moved to `center` (as far as it
    /// fits), as a share of the picture.
    public static func cropRect(shape: AspectRatio, scale: Double, center: RelativePoint, shownSize: CGSize) -> RelativeRect {
        let picture = shownSize.width / max(shownSize.height, 1)
        var width = 1.0, height = 1.0
        if shape.value > picture { height = picture / shape.value } else { width = shape.value / picture }
        let scale = min(max(scale, 0.2), 1)
        width *= scale
        height *= scale
        let x = min(max(center.x - width / 2, 0), 1 - width), y = min(max(center.y - height / 2, 0), 1 - height)
        return RelativeRect(x: x, y: y, width: width, height: height)
    }

    /// "1.5×"
    public static func speedTitle(_ speed: Double) -> String {
        speed.rounded() == speed ? "\(Int(speed))×" : String(format: "%g×", speed)
    }
}

/// What becomes of the sound's channels.
public enum AudioChannels: String, Codable, Sendable, CaseIterable {
    case unchanged
    /// Both sides mixed into one.
    case mono
    /// One side copied to both (for a mono recording).
    case stereo
    /// Just the left side (or the right), on both speakers: for a recording
    /// with the voice on one side only.
    case left, right

    public var title: String {
        switch self {
        case .unchanged: "As they are"
        case .mono: "Mono"
        case .stereo: "Stereo (from mono)"
        case .left: "Left side only"
        case .right: "Right side only"
        }
    }

    /// How many channels a sound with `channels` ends up with.
    public func count(from channels: Int) -> Int {
        switch self {
        case .unchanged: min(channels, 2)
        case .mono, .left, .right: 1
        case .stereo: 2
        }
    }
}
