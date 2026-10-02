import AppKit
import ApplicationServices

/// Tracks whether macOS lets Pinwheel watch the mouse and modifier keys in
/// other apps (System Settings › Privacy & Security › Accessibility).
///
/// It keeps checking for as long as the app runs, so every place that shows
/// the status (Settings, the menu) updates as soon as you flip the switch.
@MainActor
final class AccessibilityPermission: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var resetMessage: String?

    /// Called whenever the permission is turned on or off.
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// Starts watching. Checks every second while the permission is missing
    /// (every 3 seconds once it's granted, to notice if it's taken away), and
    /// right away when macOS announces an Accessibility change.
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
        timer = Timer.scheduledTimer(withTimeInterval: isTrusted ? 3 : 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }
}
