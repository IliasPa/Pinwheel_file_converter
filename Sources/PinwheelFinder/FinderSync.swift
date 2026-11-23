import Cocoa
import FinderSync
import UniformTypeIdentifiers

/// Finder's right-click › New File. The menu is the one chosen in Pinwheel's
/// Settings (read from a file Pinwheel writes). Choosing an item asks
/// Pinwheel to make the file: this extension may only read, by Apple's rules
/// for Finder extensions, so it can't write into your folders itself.
@objc(FinderSync)
final class FinderSync: FIFinderSync {
    /// One line of the menu, as Pinwheel saved it.
    struct Item: Decodable {
        var id: String
        var title: String
        var ext: String
    }

    private struct Menu: Decodable {
        var items: [Item]
    }

    /// The items the menu showed last, by tag.
    private var shown: [Item] = []

    override init() {
        super.init()
        // Every folder: the menu belongs everywhere, like Windows' New.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// The real home folder (in the sandbox, NSHomeDirectory is the extension's own).
    private static var home: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private static var menuFile: URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Pinwheel/NewFileMenu.json")
    }

    private func load() -> [Item] {
        guard let data = try? Data(contentsOf: Self.menuFile), let menu = try? JSONDecoder().decode(Menu.self, from: data) else { return [] }
        return menu.items
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems || menuKind == .toolbarItemMenu else { return nil }
        let items = load()
        guard !items.isEmpty else { return nil }
        shown = items
        let menu = NSMenu(title: "")
        let parent = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        let submenu = NSMenu(title: "New File")
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(make(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            let type = UTType(filenameExtension: item.ext) ?? .data
            let icon = NSWorkspace.shared.icon(for: type)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    @objc private func make(_ sender: NSMenuItem) {
        let items = shown.isEmpty ? load() : shown
        guard items.indices.contains(sender.tag) else { return }
        let controller = FIFinderSyncController.default()
        // Right-clicking a folder makes the file in it; the empty part of a
        // window makes it in the folder shown.
        var folder = controller.targetedURL()
        if let selected = controller.selectedItemURLs(), selected.count == 1,
           (try? selected[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           (try? selected[0].resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
            folder = selected[0]
        }
        guard let folder else { return }
        let request: [String: String] = ["id": items[sender.tag].id, "folder": folder.path]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else { return }
        // A sandboxed sender can pass a string, but not a dictionary.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.iliasmac.Pinwheel.newFile"), object: text, userInfo: nil, deliverImmediately: true
        )
    }
}
