import Foundation

/// What the video and audio editor does: keep a part, change the speed,
/// turn the picture, and change the sound (mute, fades, volume, loudness).
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

    public init() {}

    /// LUFS: the level podcasts and Apple Music aim for.
    public static let targetLoudness = -16.0
    /// Peaks are kept below this (dBFS), so nothing clips.
    public static let peakCeiling = -1.0
    public static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// The sound itself changes (not just which part is kept).
    public var changesSound: Bool {
        speed != 1 || fadeIn > 0 || fadeOut > 0 || volume != 0 || normalize
    }

    /// Only a part is kept: that can be copied as it is, without re-encoding.
    public var isTrimOnly: Bool {
        !changesSound && quarterTurns % 4 == 0 && !mute
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
        return isTrimOnly && start < 0.01 && end > duration - 0.01
    }

    /// "1.5×"
    public static func speedTitle(_ speed: Double) -> String {
        speed.rounded() == speed ? "\(Int(speed))×" : String(format: "%g×", speed)
    }
}
