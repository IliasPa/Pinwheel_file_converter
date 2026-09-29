import AppKit
import PinwheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let recents = RecentsStore()
    private let launch = LaunchAtLogin()
    private let permission = AccessibilityPermission()
    private let dragMonitor = DragMonitor()
    private let jobs = JobQueue()
    private lazy var wheel = WheelController(settings: settings)
    private lazy var progress = ProgressController(queue: jobs, settings: settings)
    private var menuBar: MenuBarController?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let permission = self.permission
        let settings = self.settings
        menuBar = MenuBarController(
            actions: .init(
                showSettings: { [weak self] in self?.showSettings() },
                showPermissions: { [weak self] in self?.showOnboarding() },
                showProgress: { [weak self] in self?.progress.show() },
                showFFmpegHelp: { [weak self] in self?.showFFmpegHelp() },
                quit: { NSApp.terminate(nil) }
            ),
            recents: recents,
            launch: launch,
            isTrusted: {
                permission.refresh()
                return permission.isTrusted
            },
            hasFFmpeg: { settings.ffmpegURL != nil }
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
            ConversionEngine.availability(of: action, for: files, ffmpegAvailable: settings.ffmpegURL != nil)
        }
        wheel.onDrop = { [weak self] files, action in
            self?.jobs.enqueue(files: files, action: action)
        }
        jobs.optionsProvider = { settings.conversionOptions }
        jobs.onChange = { [weak self] in
            self?.progress.jobsChanged()
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

    // MARK: - Private

    /// Remembers what worked and shows it in Finder. Failures stay listed in
    /// the progress window.
    private func batchFinished(_ batch: [Job]) {
        for job in batch where job.state == .finished {
            recents.add(job.outputs, action: job.action.title(in: .tools))
        }
        let outputs = batch.flatMap(\.outputs)
        if settings.revealInFinder && !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                launch: launch,
                permission: permission,
                onShowDemo: { [weak self] in
                    self?.wheel.showDemo(avoiding: self?.settingsWindow?.window?.frame)
                },
                onShowPermissions: { [weak self] in self?.showOnboarding() },
                onShowFFmpegHelp: { [weak self] in self?.showFFmpegHelp() }
            )
            settingsWindow = SettingsWindowController(view: view)
        }
        settingsWindow?.present()
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
