import AppKit

/// Owns the menu-bar icon and rebuilds its menu each time it opens.
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var showSettings: @MainActor () -> Void
        var showProgress: @MainActor () -> Void
        var showFFmpegHelp: @MainActor () -> Void
        var showFeedback: @MainActor () -> Void
        var toggleShelf: @MainActor () -> Void
        var showClipboard: @MainActor () -> Void = {}
        var capture: @MainActor (ScreenshotMode) -> Void = { _ in }
        var closePins: @MainActor () -> Void = {}
        /// A screenshot chosen in Screenshot History: pasted or copied, as from the clipboard window.
        var useScreenshot: @MainActor (ScreenshotEntry) -> Void = { _ in }
        /// A screenshot chosen with ⌥ held: opened in the editor.
        var editScreenshot: @MainActor (ScreenshotEntry) -> Void = { _ in }
        var quit: @MainActor () -> Void
    }

    /// How many screenshots Screenshot History lists (the clipboard window shows them all).
    static let screenshotsListed = 10


    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let actions: Actions
    private let recents: RecentsStore
    private let history: UndoHistory
    private let launch: LaunchAtLogin
    private let isTrusted: @MainActor () -> Bool
    private let hasFFmpeg: @MainActor () -> Bool
    private let shelfCount: @MainActor () -> Int
    private let clipboardShortcut: @MainActor () -> KeyShortcut?
    private let screenshotShortcuts: @MainActor () -> [ScreenshotMode: KeyShortcut]?
    private let pinCount: @MainActor () -> Int
    private let screenshotHistory: @MainActor () -> ScreenshotHistory?

    init(
        actions: Actions,
        shelfCount: @escaping @MainActor () -> Int = { 0 },
        clipboardShortcut: @escaping @MainActor () -> KeyShortcut? = { nil },
        screenshotShortcuts: @escaping @MainActor () -> [ScreenshotMode: KeyShortcut]? = { nil },
        pinCount: @escaping @MainActor () -> Int = { 0 },
        screenshotHistory: @escaping @MainActor () -> ScreenshotHistory? = { nil },
        recents: RecentsStore,
        history: UndoHistory,
        launch: LaunchAtLogin,
        isTrusted: @escaping @MainActor () -> Bool,
        hasFFmpeg: @escaping @MainActor () -> Bool
    ) {
        self.actions = actions
        self.shelfCount = shelfCount
        self.clipboardShortcut = clipboardShortcut
        self.screenshotShortcuts = screenshotShortcuts
        self.pinCount = pinCount
        self.screenshotHistory = screenshotHistory
        self.recents = recents
        self.history = history
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

        menu.addItem(undoItem())
        menu.addItem(.separator())

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
        menu.addItem(hint("Hold ⌥ Option + ⇧ Shift for tools and editing"))
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent Conversions", action: nil, keyEquivalent: "")
        recentItem.submenu = recentsMenu()
        menu.addItem(recentItem)
        menu.addItem(item("Show Progress Window", #selector(showProgress)))
        let parked = shelfCount()
        menu.addItem(item(parked > 0 ? "Shelf (\(parked))" : "Shelf", #selector(toggleShelf)))
        if let shortcut = clipboardShortcut() {
            let history = item("Clipboard History", #selector(showClipboard))
            // Shown beside it, as menus show shortcuts (single letters only).
            if shortcut.key.count == 1 {
                history.keyEquivalent = shortcut.key.lowercased()
                history.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
            }
            menu.addItem(history)
        }
        if let screenshots = screenshotHistoryItem() {
            menu.addItem(screenshots)
        }
        menu.addItem(screenshotItem())
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        launch.refresh()
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = launch.isEnabled ? .on : (launch.needsApproval ? .mixed : .off)
        if launch.needsApproval { login.toolTip = "Waiting for your approval in System Settings › Login Items" }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Send Feedback…", #selector(showFeedback)))
        menu.addItem(item("About Pinwheel", #selector(showAbout)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pinwheel", #selector(quit), key: "q"))
    }

    // MARK: - Screenshots

    /// "Screenshot ▸" with each way to take one (and the keys), and Close Pins.
    private func screenshotItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Screenshot", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let shortcuts = screenshotShortcuts()
        for mode in ScreenshotMode.allCases {
            let entry = item(mode.title, #selector(capture(_:)))
            entry.representedObject = mode.rawValue
            entry.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)
            if let shortcut = shortcuts?[mode], shortcut.key.count == 1 {
                entry.keyEquivalent = shortcut.key.lowercased()
                entry.keyEquivalentModifierMask = shortcut.modifiers.eventFlags
            }
            submenu.addItem(entry)
        }
        let pins = pinCount()
        if pins > 0 {
            submenu.addItem(.separator())
            submenu.addItem(item(pins == 1 ? "Close the Pinned Picture" : "Close \(pins) Pinned Pictures", #selector(closePins)))
        }
        parent.submenu = submenu
        return parent
    }

    /// "Screenshot History ▸": the last screenshots, newest first. Click one
    /// to paste or copy it (as in the clipboard window); with ⌥ held, each
    /// one reads "Edit…" and opens in the editor. Not shown while there are
    /// none and screenshots are off.
    private func screenshotHistoryItem() -> NSMenuItem? {
        guard let history = screenshotHistory() else { return nil }
        let entries = history.entries.filter { history.exists($0) }
        guard !entries.isEmpty || screenshotShortcuts() != nil else { return nil }
        let parent = NSMenuItem(title: "Screenshot History", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        guard !entries.isEmpty else {
            let take = screenshotShortcuts()?[.area].map { " (\($0.title))" } ?? ""
            submenu.addItem(hint("No screenshots yet: capture an area\(take) to start"))
            parent.submenu = submenu
            return parent
        }
        let dates = RelativeDateTimeFormatter()
        dates.unitsStyle = .full
        for entry in entries.prefix(Self.screenshotsListed) {
            let when = dates.localizedString(for: entry.date, relativeTo: Date()).capitalizedFirst
            let subtitle = entry.app.isEmpty ? when : "\(when) · \(entry.app)"
            let thumbnail = history.thumbnail(of: entry).map(Self.menuThumbnail)

            let use = item(entry.url.lastPathComponent, #selector(useScreenshot(_:)))
            use.representedObject = entry
            use.subtitle = subtitle
            use.image = thumbnail
            use.toolTip = "Click to paste or copy it. Hold ⌥ Option to edit it."
            use.keyEquivalentModifierMask = []  // so the ⌥ line below takes its place
            submenu.addItem(use)

            let edit = item("Edit \(entry.url.lastPathComponent)…", #selector(editScreenshot(_:)))
            edit.representedObject = entry
            edit.subtitle = subtitle
            edit.image = thumbnail
            edit.isAlternate = true
            edit.keyEquivalentModifierMask = .option
            submenu.addItem(edit)
        }
        submenu.addItem(.separator())
        if entries.count > Self.screenshotsListed, clipboardShortcut() != nil {
            submenu.addItem(item("Show All \(entries.count) in Clipboard History", #selector(showClipboard)))
        }
        submenu.addItem(hint("Hold ⌥ Option to edit one"))
        submenu.addItem(item("Clear Screenshot History", #selector(clearScreenshots)))
        parent.submenu = submenu
        return parent
    }

    /// A screenshot's thumbnail at menu size (48 × 30 points at most, its shape kept).
    static func menuThumbnail(_ picture: NSImage) -> NSImage {
        let box = NSSize(width: 48, height: 30)
        let scale = min(box.width / max(picture.size.width, 1), box.height / max(picture.size.height, 1))
        let size = NSSize(width: max(1, (picture.size.width * scale).rounded()), height: max(1, (picture.size.height * scale).rounded()))
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            picture.draw(in: rect)
            return true
        }
    }

    @objc private func useScreenshot(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ScreenshotEntry else { return }
        // Let the menu close first, so the paste goes to the app in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [actions] in actions.useScreenshot(entry) }
    }

    @objc private func editScreenshot(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ScreenshotEntry else { return }
        actions.editScreenshot(entry)
    }

    @objc private func clearScreenshots() { screenshotHistory()?.removeAll() }

    @objc private func capture(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ScreenshotMode(rawValue: raw) else { return }
        // Let the menu close first, so it isn't in the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [actions] in actions.capture(mode) }
    }

    @objc private func closePins() { actions.closePins() }

    // MARK: - Undo

    /// "Undo Compress (3 files)", with when it happened; the newest step first.
    private func undoItem() -> NSMenuItem {
        guard let last = history.last else {
            let item = NSMenuItem(title: "Nothing to Undo", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            return item
        }
        let item = self.item("Undo \(last.title)", #selector(undoLast), key: "z")
        item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        let dates = RelativeDateTimeFormatter()
        dates.unitsStyle = .full
        item.subtitle = dates.localizedString(for: last.date, relativeTo: Date()).capitalizedFirst
        item.toolTip = "New files go to the Trash, originals come back from it, and renamed files get their old names."
        return item
    }

    @objc private func undoLast() {
        guard let report = history.undoLast(), !report.problems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Undid \(report.title), except:"
        alert.informativeText = report.problems.joined(separator: "\n")
        NSApp.activate()
        alert.runModal()
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
    @objc private func toggleShelf() { actions.toggleShelf() }
    @objc private func showClipboard() { actions.showClipboard() }
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
    @objc private func showFeedback() { actions.showFeedback() }
    @objc private func showAbout() { UpdateChecker.showAbout() }
    @objc private func checkForUpdates() { Task { await UpdateChecker.check() } }
}

private extension String {
    /// "yesterday" → "Yesterday".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
