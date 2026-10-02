import AppKit

/// The little click (and trackpad tap) when the pointer moves onto a wedge.
final class HoverFeedback {
    /// Short macOS system sounds that work well as a tick.
    static let soundNames = ["Tink", "Pop", "Bottle", "Morse", "Purr", "Frog"]

    private var pool: [NSSound] = []
    private var poolName = ""
    private var next = 0

    func play(settings: SettingsStore) {
        if settings.hoverSound {
            playSound(named: settings.hoverSoundName, volume: settings.hoverSoundVolume)
        }
        if settings.hapticFeedback {
            // Only Force Touch trackpads can do this, and only while touched.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// Several copies take turns, so fast moves across wedges each get a click.
    func playSound(named name: String, volume: Double) {
        if name != poolName {
            pool = (0..<3).compactMap { _ in NSSound(named: NSSound.Name(name))?.copy() as? NSSound }
            poolName = name
        }
        guard !pool.isEmpty else { return }
        let sound = pool[next % pool.count]
        next += 1
        sound.stop()
        sound.volume = Float(volume)
        sound.play()
    }
}
