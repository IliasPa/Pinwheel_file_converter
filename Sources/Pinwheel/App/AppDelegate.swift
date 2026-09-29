import AppKit
import PinwheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permission = AccessibilityPermission()
    private let dragMonitor = DragMonitor()
    private let wheel = WheelController()
    private let jobs = JobQueue()
    private var menuBar: MenuBarController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let permission = self.permission
        menuBar = MenuBarController(
            actions: .init(
                showPermissions: { [weak self] in self?.showOnboarding() },
                quit: { NSApp.terminate(nil) }
            ),
            isTrusted: {
                permission.refresh()
                return permission.isTrusted
            }
        )

        dragMonitor.onShow = { [weak self] urls, mode, location in
            self?.wheel.show(urls: urls, mode: mode, at: location)
        }
        dragMonitor.onModeChange = { [weak self] mode in
            self?.wheel.setMode(mode)
        }
        dragMonitor.onHide = { [weak self] dragEnded in
            // After a mouse-up, wait a moment so a drop on the wheel can land first.
            self?.wheel.hide(after: dragEnded ? 0.35 : 0)
        }
        dragMonitor.start()

        wheel.onDrop = { [weak self] files, action in
            self?.jobs.enqueue(files: files, action: action)
        }
        jobs.onBatchFinished = { [weak self] batch in
            self?.batchFinished(batch)
        }

        // Re-register the event monitors once macOS grants the permission.
        permission.onGranted = { [weak self] in self?.dragMonitor.start() }
        if !permission.isTrusted {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
    }

    /// Shows the new files in Finder, and explains anything that failed.
    private func batchFinished(_ batch: [Job]) {
        let outputs = batch.flatMap(\.outputs)
        if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        let failures = batch.compactMap { job -> String? in
            guard case .failed(let message) = job.state else { return nil }
            return "\(job.file.url.lastPathComponent): \(message)"
        }
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1 ? "A file couldn't be converted" : "\(failures.count) files couldn't be converted"
        alert.informativeText = failures.joined(separator: "\n\n")
        NSApp.activate()
        alert.runModal()
    }

    private func showOnboarding() {
        if onboarding == nil {
            let controller = OnboardingWindowController(permission: permission)
            controller.onClosed = { [weak self] in self?.onboarding = nil }
            onboarding = controller
        }
        onboarding?.present()
    }
}
