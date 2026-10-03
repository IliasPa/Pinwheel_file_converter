import AppKit
import ApplicationServices
import Observation

/// Tracks whether macOS lets Pinwheel watch the mouse and modifier keys in
/// other apps (System Settings › Privacy & Security › Accessibility).
///
/// While the permission is missing it checks every second, so Settings and
/// the menu turn green as soon as you flip the switch. Once it's granted it
/// stops checking on a timer: macOS announces changes, and the menu and
/// Settings check again whenever they open.
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted: Bool = AXIsProcessTrusted()
    private(set) var resetMessage: String?

    /// Called whenever the permission is turned on or off.
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Starts watching: every second while the permission is missing, and
    /// right away whenever macOS announces an Accessibility change.
    func startWatching() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new value is readable a moment after the announcement.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
        scheduleTimer()
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted { resetMessage = nil }
        scheduleTimer()
        onChange?(trusted)
    }

    /// Adds Pinwheel to the Accessibility list (switched off) and opens that
    /// page of System Settings, so you only have to flip the switch.
    func openSystemSettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Fixes "the switch is on but nothing works": removes Pinwheel's old
    /// entry (left over from an earlier build), then asks again.
    func resetAndAskAgain() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            resetMessage = process.terminationStatus == 0
                ? "Old entry removed. Now switch Pinwheel on again in System Settings."
                : "macOS didn't allow the reset. Remove Pinwheel with − in System Settings, then add it again."
        } catch {
            resetMessage = "Couldn't run the reset: \(error.localizedDescription)"
        }
        refresh()
        openSystemSettings()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard !isTrusted else { return }  // no need to wake up every few seconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }
}
