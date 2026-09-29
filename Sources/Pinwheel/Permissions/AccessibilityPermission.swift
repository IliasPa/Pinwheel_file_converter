import AppKit
import ApplicationServices

/// Tracks whether macOS lets Pinwheel watch the mouse and modifier keys in
/// other apps (System Settings › Privacy & Security › Accessibility).
@MainActor
final class AccessibilityPermission: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    /// Called once when the permission flips from off to on.
    var onGranted: (() -> Void)?

    private var timer: Timer?

    /// Checks every second until the permission is granted.
    func startWatching() {
        refresh()
        guard !isTrusted, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted {
            stopWatching()
            onGranted?()
        }
    }

    /// Adds Pinwheel to the Accessibility list (switched off) and opens that
    /// page of System Settings so the user only has to flip the switch.
    func openSystemSettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startWatching()
    }
}
