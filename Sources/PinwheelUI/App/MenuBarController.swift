import AppKit

/// Owns the menu-bar icon and rebuilds its menu each time it opens.
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var showSettings: @MainActor () -> Void
        var showProgress: @MainActor () -> Void
        var showFFmpegHelp: @MainActor () -> Void
        var quit: @MainActor () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let actions: Actions
    private let recents: RecentsStore
    private let launch: LaunchAtLogin
    private let isTrusted: @MainActor () -> Bool
    private let hasFFmpeg: @MainActor () -> Bool

    init(
        actions: Actions,
        recents: RecentsStore,
        launch: LaunchAtLogin,
        isTrusted: @escaping @MainActor () -> Bool,
        hasFFmpeg: @escaping @MainActor () -> Bool
    ) {
        self.actions = actions
        self.recents = recents
        self.launch = launch
        self.isTrusted = isTrusted
        self.hasFFmpeg = hasFFmpeg
        super.init()
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.toolTip = "Pinwheel — hold ⇧ while dragging files"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        var warned = false
        if !isTrusted() {
            menu.addItem(item("⚠︎ Accessibility permission needed…", #selector(showSettings)))
            warned = true
        }
        if !hasFFmpeg() {
            menu.addItem(item("ffmpeg not found: some formats are off…", #selector(showFFmpegHelp)))
            warned = true
        }
        if warned { menu.addItem(.separator()) }

        menu.addItem(hint("Drag files and hold ⇧ Shift to convert"))
        menu.addItem(hint("Hold ⌥ Option + ⇧ Shift for tools"))
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent Conversions", action: nil, keyEquivalent: "")
        recentItem.submenu = recentsMenu()
        menu.addItem(recentItem)
        menu.addItem(item("Show Progress Window", #selector(showProgress)))
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        launch.refresh()
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = launch.isEnabled ? .on : (launch.needsApproval ? .mixed : .off)
        if launch.needsApproval { login.toolTip = "Waiting for your approval in System Settings › Login Items" }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Pinwheel", #selector(quit), key: "q"))
    }

    // MARK: - Recents

    private func recentsMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        guard !recents.items.isEmpty else {
            submenu.addItem(hint("Nothing yet"))
            return submenu
        }
        let dates = RelativeDateTimeFormatter()
        dates.unitsStyle = .short
        for recent in recents.items {
            let entry = NSMenuItem(title: recent.url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = recent.path
            entry.toolTip = "\(recent.action) · \(dates.localizedString(for: recent.date, relativeTo: Date()))"
            if recent.exists {
                let icon = NSWorkspace.shared.icon(forFile: recent.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            } else {
                entry.isEnabled = false
                entry.title += " (moved or deleted)"
            }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item("Clear Recent Conversions", #selector(clearRecents)))
        return submenu
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func clearRecents() { recents.clear() }

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

    @objc private func showSettings() { actions.showSettings() }
    @objc private func showProgress() { actions.showProgress() }
    @objc private func showFFmpegHelp() { actions.showFFmpegHelp() }
    @objc private func toggleLaunchAtLogin() {
        launch.setEnabled(!(launch.isEnabled || launch.needsApproval))
        guard let error = launch.lastError else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't change Launch at Login"
        alert.informativeText = "\(error)\n\nTip: this works best when Pinwheel is in your Applications folder (run “make install”)."
        NSApp.activate()
        alert.runModal()
    }
    @objc private func quit() { actions.quit() }
}
