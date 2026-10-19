import AppKit
import Foundation

/// Where Pinwheel lives online, About Pinwheel, and "Check for Updates…",
/// which asks GitHub for the newest release only when it's chosen.
enum UpdateChecker {
    static let repository = URL(string: "https://github.com/IliasPa/Pinwheel_file_converter")!
    static let releasesPage = URL(string: "https://github.com/IliasPa/Pinwheel_file_converter/releases/latest")!
    static let latestRelease = URL(string: "https://api.github.com/repos/IliasPa/Pinwheel_file_converter/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release: Decodable, Equatable {
        let tag: String
        let page: URL

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
        }

        /// "v1.1" → "1.1".
        var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    }

    /// Compares versions number by number: "1.10" is newer than "1.9".
    static func isNewer(_ version: String, than current: String) -> Bool {
        func numbers(_ text: String) -> [Int] {
            (text.hasPrefix("v") ? String(text.dropFirst()) : text).split(separator: ".").map { Int($0) ?? 0 }
        }
        let new = numbers(version), old = numbers(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Asks GitHub, then says what it found.
    static func check() async {
        let alert = NSAlert()
        do {
            let latest = try await fetchLatest()
            if isNewer(latest.version, than: currentVersion) {
                alert.messageText = "Pinwheel \(latest.version) is available"
                alert.informativeText = "You have \(currentVersion). Download the new one, quit Pinwheel, and put the new one in Applications in its place. Your settings stay."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(latest.page) }
                return
            }
            alert.messageText = "You have the newest Pinwheel"
            alert.informativeText = "Version \(currentVersion)."
        } catch {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "\(error.localizedDescription)\n\nThe newest version is always on GitHub."
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "Close")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
            return
        }
        NSApp.activate()
        alert.runModal()
    }

    /// The standard About window, with a link to the project.
    static func showAbout() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Convert, compress and edit files with a drop wheel.\nFree and open source: ",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        )
        credits.append(NSAttributedString(
            string: "Pinwheel on GitHub",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repository, .paragraphStyle: style]
        ))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
