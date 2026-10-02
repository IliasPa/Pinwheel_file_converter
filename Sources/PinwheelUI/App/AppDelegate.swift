import AppKit
import PinwheelCore

/// Connects the parts: drag detection → wheel → jobs → progress window,
/// plus the menu, Settings and notifications.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let recents = RecentsStore()
    private let launch = LaunchAtLogin()
    private let permission = AccessibilityPermission()
    private let dragMonitor = DragMonitor()
    private let jobs = JobQueue()
    private lazy var wheel = WheelController(settings: settings)
    private lazy var progress = ProgressController(queue: jobs, settings: settings)
    private lazy var notifier = Notifier()
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let permission = self.permission
        let settings = self.settings
        menuBar = MenuBarController(
            actions: .init(
                showSettings: { [weak self] in self?.showSettings() },
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
        jobs.maxConcurrent = { settings.maxConcurrentJobs }
        jobs.shouldTrashOriginals = { settings.moveOriginalToTrash }
        jobs.actionLabel = { action in action.title(in: .tools, options: settings.conversionOptions) }
        jobs.onChange = { [weak self] in
            self?.progress.jobsChanged()
        }
        jobs.onBatchFinished = { [weak self] batch in
            self?.batchFinished(batch)
        }

        // Re-register the event monitors once macOS grants the permission.
        permission.onChange = { [weak self] trusted in
            if trusted { self?.dragMonitor.start() }
        }
        permission.startWatching()
        // First launch (or the permission went missing): Settings explains it.
        if !permission.isTrusted {
            showSettings()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
    }

    // MARK: - Private

    /// Remembers what worked, shows it in Finder, and sends a notification
    /// for long conversions. Failures stay listed in the progress window.
    private func batchFinished(_ batch: [Job]) {
        for job in batch where job.state == .finished {
            recents.add(job.outputs, action: job.actionLabel)
        }
        let outputs = batch.flatMap(\.outputs)
        if settings.revealInFinder && !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if settings.notifyWhenDone {
            notifier.batchFinished(batch)
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                launch: launch,
                permission: permission,
                state: SettingsViewState(),
                onShowDemo: { [weak self] in
                    self?.wheel.showDemo(avoiding: self?.settingsWindow?.window?.frame)
                },
                onShowFFmpegHelp: { [weak self] in self?.showFFmpegHelp() }
            )
            settingsWindow = SettingsWindowController(view: view)
        }
        settingsWindow?.present()
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
