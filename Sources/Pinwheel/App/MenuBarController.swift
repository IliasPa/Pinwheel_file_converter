import AppKit

/// Owns the menu-bar icon and rebuilds its menu each time it opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var showPermissions: @MainActor () -> Void
        var quit: @MainActor () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let actions: Actions
    private let isTrusted: @MainActor () -> Bool

    init(actions: Actions, isTrusted: @escaping @MainActor () -> Bool) {
        self.actions = actions
        self.isTrusted = isTrusted
        super.init()
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Pinwheel — hold ⇧ while dragging files"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !isTrusted() {
            menu.addItem(item("⚠︎ Accessibility permission needed…", #selector(showPermissions)))
            menu.addItem(.separator())
        }

        menu.addItem(hint("Drag files and hold ⇧ Shift to convert"))
        menu.addItem(hint("Hold ⌥ Option + ⇧ Shift for tools"))
        menu.addItem(.separator())
        menu.addItem(item("Permissions Help…", #selector(showPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pinwheel", #selector(quit), key: "q"))
    }

    // MARK: - Helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func hint(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func showPermissions() { actions.showPermissions() }
    @objc private func quit() { actions.quit() }
}
