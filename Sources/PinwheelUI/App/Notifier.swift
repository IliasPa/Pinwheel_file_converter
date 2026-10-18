import AppKit
import UserNotifications

/// A macOS notification when a conversion took a while, so you can switch
/// away and still know when it's done, and whenever something couldn't be
/// saved (with the reason). Clicking it shows the files in Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Successful conversions shorter than this don't need a notification.
    static let minimumDuration: TimeInterval = 10

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func batchFinished(_ batch: [Job]) {
        guard let content = Self.content(for: batch) else { return }
        content.sound = .default
        content.userInfo = ["paths": batch.filter { $0.state == .finished }.flatMap(\.outputs).map(\.path)]

        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// What to say about a finished batch, or nil when there's no need.
    static func content(for batch: [Job], now: Date = Date()) -> UNMutableNotificationContent? {
        let finished = batch.filter { $0.state == .finished }
        let failed = batch.filter(\.isFailed)
        let skipped = batch.filter(\.isSkipped)
        let long = batch.map(\.created).min().map { now.timeIntervalSince($0) >= minimumDuration } ?? false
        let content = UNMutableNotificationContent()
        if !failed.isEmpty {
            content.title = failed.count == 1 && batch.count == 1
                ? "\(failed[0].title) couldn't be saved"
                : "\(failed.count) of \(batch.count) conversions failed"
            content.body = failed[0].failureReason ?? "The progress window explains what went wrong."
        } else if !skipped.isEmpty {
            content.title = skipped.count == 1 && batch.count == 1
                ? "Nothing saved for \(skipped[0].title)"
                : "\(skipped.count) of \(batch.count) files weren't saved"
            content.body = skipped[0].skipReason ?? ""
        } else if long && !finished.isEmpty {
            content.title = finished.count == 1 ? "\(finished[0].title) is ready" : "\(finished.count) files are ready"
            content.body = "Converted with Pinwheel (\(finished[0].actionLabel)). Click to show in Finder."
        } else {
            return nil
        }
        return content
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
