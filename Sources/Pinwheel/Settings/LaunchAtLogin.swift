import Foundation
import ServiceManagement

/// Starts Pinwheel when you log in, using macOS's Login Items
/// (System Settings › General › Login Items & Extensions).
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    /// Registered, but macOS wants you to switch it on in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if enabled && needsApproval {
            openLoginItemsSettings()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
