import AppKit
import PinwheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permission = AccessibilityPermission()
    private let dragMonitor = DragMonitor()
    private let wheel = WheelController()
    private let jobs = JobQueue()
    private lazy var progress = ProgressController(queue: jobs)
    private var menuBar: MenuBarController?
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let permission = self.permission
        menuBar = MenuBarController(
            actions: .init(
                showPermissions: { [weak self] in self?.showOnboarding() },
                showProgress: { [weak self] in self?.progress.show() },
                showFFmpegHelp: { [weak self] in self?.showFFmpegHelp() },
                quit: { NSApp.terminate(nil) }
            ),
            isTrusted: {
                permission.refresh()
                return permission.isTrusted
            },
            hasFFmpeg: { FFmpeg.locate() != nil }
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

        wheel.availability = { action, files in
            ConversionEngine.availability(of: action, for: files, ffmpegAvailable: FFmpeg.locate() != nil)
        }
        wheel.onDrop = { [weak self] files, action in
            self?.jobs.enqueue(files: files, action: action)
        }
        jobs.optionsProvider = {
            var options = ConversionOptions()
            options.ffmpegURL = FFmpeg.locate()
            return options
        }
        jobs.onChange = { [weak self] in
            self?.progress.jobsChanged()
        }
        jobs.onBatchFinished = { batch in
            // Failures stay listed in the progress window; show what worked.
            let outputs = batch.flatMap(\.outputs)
            if !outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
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

    private func showOnboarding() {
        if onboarding == nil {
            let controller = OnboardingWindowController(permission: permission)
            controller.onClosed = { [weak self] in self?.onboarding = nil }
            onboarding = controller
        }
        onboarding?.present()
    }

    private func showFFmpegHelp() {
        let alert = NSAlert()
        alert.messageText = "ffmpeg isn't installed"
        alert.informativeText = """
            Pinwheel uses the free tool ffmpeg for MP3 files, GIFs made from videos, \
            and MKV, WebM or OGG files. Everything else works without it.

            To install it:
            1. Open Terminal (Applications › Utilities).
            2. Paste the command below and press Return:
                  \(FFmpeg.installCommand)
            3. Wait until it finishes. Pinwheel finds it by itself, with no restart needed.

            No Homebrew yet? Get it first at brew.sh.
            """
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(FFmpeg.installCommand, forType: .string)
        }
    }
}
