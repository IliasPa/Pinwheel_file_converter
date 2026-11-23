import AppKit
import FinderSync
import PinwheelCore
import UniformTypeIdentifiers

/// One line of Finder's New File menu, as kept in Settings: a kind Pinwheel
/// makes, or a file of yours that's copied (your own template).
struct NewFileEntry: Codable, Identifiable, Equatable {
    /// A `NewFileKind`'s name, or "custom-" and a number for your own.
    var id: String
    var isOn: Bool
    /// Your own template: its name in the menu and the file that's copied.
    var title: String?
    var path: String?

    var kind: NewFileKind? { NewFileKind(rawValue: id) }
    var isCustom: Bool { path != nil }

    var menuTitle: String {
        if let kind { return kind.title }
        return title ?? URL(fileURLWithPath: path ?? "").deletingPathExtension().lastPathComponent
    }

    var fileExtension: String {
        if let kind { return kind.fileExtension }
        return URL(fileURLWithPath: path ?? "").pathExtension
    }

    static func custom(_ file: URL) -> NewFileEntry {
        NewFileEntry(id: "custom-\(UUID().uuidString)", isOn: true, title: file.deletingPathExtension().lastPathComponent, path: file.path)
    }

    /// The menu a new Pinwheel starts with: Office and iWork first, then text;
    /// the rest listed but off.
    static var starting: [NewFileEntry] {
        let on = NewFileKind.startingMenu
        return on.map { NewFileEntry(id: $0.rawValue, isOn: true) }
            + NewFileKind.allCases.filter { !on.contains($0) }.map { NewFileEntry(id: $0.rawValue, isOn: false) }
    }

    /// A saved menu, with any kind added in a later version put at the end (off).
    static func completed(_ saved: [NewFileEntry]) -> [NewFileEntry] {
        var entries = saved.filter { $0.kind != nil || $0.isCustom }
        var seen: Set<String> = []
        entries = entries.filter { seen.insert($0.id).inserted }
        for kind in NewFileKind.allCases where !seen.contains(kind.rawValue) {
            entries.append(NewFileEntry(id: kind.rawValue, isOn: false))
        }
        return entries
    }
}

/// Makes the files Finder's New File menu asks for, and keeps the menu the
/// Finder extension reads up to date.
final class NewFileService {
    static let notification = Notification.Name("com.iliasmac.Pinwheel.newFile")
    static let extensionID = "com.iliasmac.Pinwheel.NewFile"

    /// The menu, in order (Settings).
    var entries: () -> [NewFileEntry] = { NewFileEntry.starting }
    /// Where the extension reads the menu (tests use their own).
    var menuFile = NewFileService.defaultMenuFile
    /// Where Pages, Numbers and Keynote's empty files are kept once made.
    var blanksFolder = NewFileService.defaultBlanksFolder
    /// After a file is made: show it in Finder, ready to be named.
    var reveal: (URL) -> Void = { NewFileService.revealForRenaming($0) }

    private var observer: NSObjectProtocol?

    static var defaultMenuFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinwheel/NewFileMenu.json")
    }

    static var defaultBlanksFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinwheel/Blank Files", isDirectory: true)
    }

    func start() {
        writeMenu()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] note in
            let text = note.object as? String
            MainActor.assumeIsolated { self?.handle(text) }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    // MARK: - The menu the extension shows

    /// What's on: only kinds that can be made here (Pages needs Pages).
    func shownEntries() -> [NewFileEntry] {
        entries().filter { entry in
            guard entry.isOn else { return false }
            if let path = entry.path { return FileManager.default.fileExists(atPath: path) }
            guard let kind = entry.kind, kind.needsApp else { return true }
            return kind.installedApp != nil
        }
    }

    /// Writes the menu for the extension (it may only read, and only this file).
    func writeMenu() {
        let items = shownEntries().map { ["id": $0.id, "title": $0.menuTitle, "ext": $0.fileExtension] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["items": items], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: menuFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: menuFile, options: .atomic)
    }

    // MARK: - Making a file

    /// A request from the extension: {"id": "word", "folder": "/Users/…"}.
    func handle(_ text: String?) {
        guard let text, let data = text.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = request["id"], let path = request["folder"] else { return }
        Task {
            do {
                let made = try await make(id, in: URL(fileURLWithPath: path, isDirectory: true))
                reveal(made)
            } catch {
                Toast.show("The new file couldn't be made", detail: error.localizedDescription)
            }
        }
    }

    /// Makes the file in `folder` and returns it. Only what's in the menu can
    /// be made, only in a folder, and nothing is ever replaced.
    func make(_ id: String, in folder: URL) async throws -> URL {
        guard let entry = entries().first(where: { $0.id == id && $0.isOn }) else {
            throw ConversionError.failed("That isn't in the New File menu any more.")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ConversionError.failed("\(folder.lastPathComponent) isn't a folder.")
        }
        let baseName = entry.kind?.baseName ?? (entry.menuTitle)
        let target = NewFileMaker.freeURL(in: folder, baseName: baseName, fileExtension: entry.fileExtension)
        if let path = entry.path {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
        } else if let kind = entry.kind, kind.needsApp {
            let blank = try await blankFile(for: kind)
            try FileManager.default.copyItem(at: blank, to: target)
        } else if let kind = entry.kind {
            try NewFileMaker.write(kind, to: target)
        }
        return target
    }

    /// An empty Pages, Numbers or Keynote file: made by the app the first
    /// time (it opens for a moment), then kept and copied.
    func blankFile(for kind: NewFileKind) async throws -> URL {
        let blank = blanksFolder.appendingPathComponent("Blank.\(kind.fileExtension)")
        if FileManager.default.fileExists(atPath: blank.path) { return blank }
        guard let bundleID = kind.installedApp else {
            throw ConversionError.failed("\(kind.title)s need \(kind.appName), which isn't on this Mac.")
        }
        try FileManager.default.createDirectory(at: blanksFolder, withIntermediateDirectories: true)
        Toast.show("Making the first \(kind.title)…", detail: "\(kind.appName) opens once; after this it's instant.")
        let script = """
        tell application id "\(bundleID)"
            set made to make new document
            save made in POSIX file "\(blank.path.replacingOccurrences(of: "\"", with: "\\\""))"
            close made saving no
        end tell
        """
        let problem: String? = await Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error?[NSAppleScript.errorMessage] as? String
        }.value
        guard FileManager.default.fileExists(atPath: blank.path) else {
            throw ConversionError.failed(problem ?? "\(kind.appName) didn't save the file.")
        }
        return blank
    }

    /// Selects the new file in Finder and, when Pinwheel may press keys,
    /// presses Return so its name can be typed straight away (as on Windows).
    static func revealForRenaming(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        guard AXIsProcessTrusted() else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - The extension's switch

    /// Whether the extension is on in System Settings.
    static var isExtensionOn: Bool { FIFinderSyncController.isExtensionEnabled }

    /// Opens System Settings where Finder extensions are switched on.
    static func showExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}

extension NewFileKind {
    /// The bundle identifier of the app that makes it, if that's on this Mac.
    var installedApp: String? {
        makingApps.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    var appName: String {
        switch self {
        case .pages: "Pages"
        case .numbers: "Numbers"
        case .keynote: "Keynote"
        default: "Pinwheel"
        }
    }
}
