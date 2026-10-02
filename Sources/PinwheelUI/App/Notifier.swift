import AppKit
import UserNotifications

/// A macOS notification when a conversion took a while, so you can switch
/// away and still know when it's done. Clicking it shows the files in Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Conversions shorter than this don't need a notification.
    static let minimumDuration: TimeInterval = 10

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func batchFinished(_ batch: [Job]) {
        guard let started = batch.map(\.created).min(),
              Date().timeIntervalSince(started) >= Self.minimumDuration else { return }
        let finished = batch.filter { $0.state == .finished }
        let failed = batch.filter(\.isFailed).count
        guard !finished.isEmpty || failed > 0 else { return }

        let content = UNMutableNotificationContent()
        if failed == 0 {
            content.title = finished.count == 1 ? "\(finished[0].title) is ready" : "\(finished.count) files are ready"
            content.body = "Converted with Pinwheel (\(finished[0].actionLabel)). Click to show in Finder."
        } else {
            content.title = "\(failed) of \(batch.count) conversions failed"
            content.body = "The progress window explains what went wrong."
        }
        content.sound = .default
        content.userInfo = ["paths": finished.flatMap(\.outputs).map(\.path)]

        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        await MainActor.run {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
