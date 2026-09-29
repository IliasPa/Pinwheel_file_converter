import AppKit
import PinwheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permission = AccessibilityPermission()
    private let dragMonitor = DragMonitor()
    private let wheel = WheelController()
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
}
