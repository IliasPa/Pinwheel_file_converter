import AppKit
import Quartz
import PinwheelCore

/// Terminal apps the "Terminal" file action can open.
enum TerminalApp: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case warp = "dev.warp.Warp-Stable"
    case wezTerm = "com.github.wez.wezterm"
    case kitty = "net.kovidgoyal.kitty"
    case alacritty = "org.alacritty"

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .wezTerm: "WezTerm"
        case .kitty: "kitty"
        case .alacritty: "Alacritty"
        }
    }

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }

    /// The ones on this Mac (Terminal always is).
    static var installed: [TerminalApp] { allCases.filter { $0 == .terminal || $0.url != nil } }
}

/// The file actions wheel's chores, done right away (they're not jobs).
final class FileActions {
    /// Files were moved (for the menu bar's Undo).
    var onMoved: (_ moves: [Renamer.Move]) -> Void = { _ in }
    var terminalApp: () -> String = { TerminalApp.terminal.rawValue }
    var pasteboard = NSPasteboard.general

    func perform(_ action: FileAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop: airDrop(urls)
        case .copy: copy(urls)
        case .moveTo: chooseFolderAndMove(urls)
        case .copyPath: copyPaths(urls)
        case .terminal: openTerminal(at: urls)
        case .quickLook: QuickLookPresenter.shared.show(urls)
        }
    }

    private func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            alert("AirDrop isn't available", "Turn on Wi-Fi and Bluetooth, and check AirDrop in Control Center.")
            return
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Like ⌘C in Finder: paste them into any folder.
    func copy(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// One full path per line.
    func copyPaths(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func chooseFolderAndMove(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to:" : "Move \(urls.count) items to:"
        panel.directoryURL = urls[0].deletingLastPathComponent()
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let (moves, failures) = move(urls, to: folder)
        if !moves.isEmpty { onMoved(moves) }
        if !failures.isEmpty {
            alert("Some items couldn't be moved", failures.joined(separator: "\n"))
        }
    }

    /// Moves without ever replacing anything: a name that's taken gets a
    /// number ("photo 2.jpg"). Returns what moved, and what didn't (and why).
    func move(_ urls: [URL], to folder: URL) -> (moves: [Renamer.Move], failures: [String]) {
        var moves: [Renamer.Move] = []
        var failures: [String] = []
        for url in urls {
            guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { continue }
            let target = Self.freeName(for: url.lastPathComponent, in: folder)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                moves.append(Renamer.Move(from: url, to: target))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (moves, failures)
    }

    static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// A Terminal window in each folder (a file's own folder).
    private func openTerminal(at urls: [URL]) {
        let app = TerminalApp(rawValue: terminalApp()) ?? .terminal
        guard let appURL = app.url ?? TerminalApp.terminal.url else { return }
        for folder in Self.folders(of: urls) {
            NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Each folder once: folders themselves, and the folders files are in.
    static func folders(of urls: [URL]) -> [URL] {
        var folders: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let folder = isFolder ? url : url.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
        }
        return folders
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

/// The Quick Look panel (as with the Space bar in Finder), for any files.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        NSApp.activate()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
