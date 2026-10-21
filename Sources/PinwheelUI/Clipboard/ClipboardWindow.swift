import AppKit
import Observation
import SwiftUI

/// Watches the clipboard, keeps its history, and shows the history window
/// with the shortcut (⌥⌘V unless changed in Settings).
final class ClipboardController {
    let store: ClipboardStore
    let model: ClipboardPanelModel
    /// Settings › Clipboard.
    var onOpenSettings: () -> Void = {}
    private let settings: SettingsStore
    private let pasteboard: NSPasteboard
    private let hotKey = GlobalHotKey()
    private var timer: Timer?
    private var seenChangeCount: Int
    private var isSuspended = false
    private lazy var panel: ClipboardPanel = makePanel()

    init(settings: SettingsStore, store: ClipboardStore = ClipboardStore(), pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.store = store
        self.pasteboard = pasteboard
        model = ClipboardPanelModel(store: store)
        seenChangeCount = pasteboard.changeCount
        model.onCopy = { [weak self] item in self?.copy(item) }
        model.onClose = { [weak self] in self?.hide() }
        model.onOpenSettings = { [weak self] in
            self?.hide()
            self?.onOpenSettings()
        }
    }

    /// Follows Settings: on or off, the shortcut, how many copies to keep.
    func apply() {
        store.limit = settings.clipboardLimit
        guard settings.clipboardEnabled else {
            timer?.invalidate()
            timer = nil
            hotKey.unregister()
            model.shortcutProblem = nil
            hide()
            return
        }
        if timer == nil {
            seenChangeCount = pasteboard.changeCount
            // macOS doesn't announce copies; looking twice a second is cheap.
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClipboard() }
            }
        }
        registerShortcut()
    }

    /// While Settings records a new shortcut, the old one mustn't open the window.
    func suspendShortcut(_ suspended: Bool) {
        isSuspended = suspended
        if suspended { hotKey.unregister() } else { registerShortcut() }
    }

    private func registerShortcut() {
        guard settings.clipboardEnabled, !isSuspended else { return }
        let shortcut = settings.clipboardShortcut
        model.shortcutProblem = hotKey.register(shortcut) { [weak self] in self?.toggle() }
            ? nil : "\(shortcut.title) is taken by another app (perhaps another clipboard app). Quit it, or choose other keys."
    }

    /// Keeps a new copy, if there is one.
    func checkClipboard() {
        let count = pasteboard.changeCount
        guard count != seenChangeCount else { return }
        seenChangeCount = count
        guard settings.clipboardEnabled, let contents = ClipboardStore.read(pasteboard) else { return }
        let app = NSWorkspace.shared.frontmostApplication
        store.add(contents, appID: app?.bundleIdentifier, appName: app?.localizedName)
    }

    /// On the clipboard, ready to paste; the window closes.
    func copy(_ item: ClipItem) {
        store.copy(item, to: pasteboard)
        seenChangeCount = pasteboard.changeCount  // not a new copy
        model.justCopied = item.id
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            hide()
        }
    }

    var isShown: Bool { panel.isVisible }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        checkClipboard()
        model.prepare()
        // In the upper middle of the screen with the pointer, like Spotlight.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.18 - size.height))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.justCopied = nil
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        panel.onResignKey = { [weak self] in self?.hide() }
        let hosting = NSHostingView(rootView: ClipboardView(model: model, settings: settings))
        hosting.frame = NSRect(origin: .zero, size: ClipboardPanel.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

/// Takes the keyboard (to search) without bringing Pinwheel to the front,
/// so a copy can be pasted straight into the app that was in use.
final class ClipboardPanel: GlassPanel {
    static let size = NSSize(width: 580, height: 560)
    var onResignKey: () -> Void = {}

    init() {
        super.init(size: Self.size, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Clicking anywhere else closes it.
    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

// MARK: - The window's contents

@Observable
final class ClipboardPanelModel {
    let store: ClipboardStore
    var search = "" {
        didSet { selectFirst() }
    }
    var kind: ClipKind? {
        didSet { selectFirst() }
    }
    var favoritesOnly = false {
        didSet { selectFirst() }
    }
    var appID: String? {
        didSet { selectFirst() }
    }
    var selection: ClipItem.ID?
    /// Flashes on the row just copied.
    var justCopied: ClipItem.ID?
    /// Why the shortcut couldn't be set up, for Settings (nil when it works).
    var shortcutProblem: String?

    var onCopy: (ClipItem) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    init(store: ClipboardStore) {
        self.store = store
    }

    var visible: [ClipItem] {
        store.matching(search: search, kind: kind, appID: appID, favoritesOnly: favoritesOnly)
    }

    /// Each time the window opens: a fresh search, filters kept.
    func prepare() {
        search = ""
        if let appID, !store.apps.contains(where: { $0.id == appID }) { self.appID = nil }
        selectFirst()
    }

    func selectFirst() {
        selection = visible.first?.id
    }

    func moveSelection(by step: Int) {
        let shown = visible
        guard !shown.isEmpty else { return }
        let index = shown.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : shown.count)
        selection = shown[min(max(index + step, 0), shown.count - 1)].id
    }

    func copySelected() {
        guard let item = visible.first(where: { $0.id == selection }) ?? visible.first else { return }
        onCopy(item)
    }

    func removeSelected() {
        let shown = visible
        guard let index = shown.firstIndex(where: { $0.id == selection }) else { return }
        store.remove(shown[index])
        let rest = visible
        selection = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
    }
}

struct ClipboardView: View {
    var model: ClipboardPanelModel
    var settings: SettingsStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = model.visible
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)
            filters
                .padding(.horizontal, 12)
            apps
                .padding(.horizontal, 12)
                .padding(.top, 6)
            Divider().padding(.top, 10)
            if shown.isEmpty {
                empty
            } else {
                list(shown)
            }
            Divider()
            footer(shown.count)
        }
        .frame(width: ClipboardPanel.size.width, height: ClipboardPanel.size.height)
        .glassSurface(settings.glassLevel, cornerRadius: 24)
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.justCopied) { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the clipboard history", text: Binding(get: { model.search }, set: { model.search = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
                .onSubmit { model.copySelected() }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { model.onClose(); return .handled }
                .onKeyPress(.delete, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.removeSelected()
                    return .handled
                }
            Text("BETA")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            chip("All", symbol: nil, isOn: model.kind == nil && !model.favoritesOnly) {
                model.kind = nil
                model.favoritesOnly = false
            }
            chip("Favorites", symbol: "heart.fill", isOn: model.favoritesOnly) { model.favoritesOnly.toggle() }
            ForEach(ClipKind.allCases, id: \.self) { kind in
                chip(kind.title, symbol: kind.symbolName, isOn: model.kind == kind) { model.kind = model.kind == kind ? nil : kind }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var apps: some View {
        let apps = model.store.apps
        if apps.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip("All apps", symbol: nil, isOn: model.appID == nil) { model.appID = nil }
                    ForEach(apps, id: \.id) { app in
                        Button { model.appID = model.appID == app.id ? nil : app.id } label: {
                            HStack(spacing: 5) {
                                AppIcon(bundleID: app.id).frame(width: 16, height: 16)
                                Text(app.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(model.appID == app.id ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .help("Only what was copied in \(app.name)")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func chip(_ title: String, symbol: String?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func list(_ shown: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { item in
                        ClipRow(item: item, model: model).id(item.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selection) {
                if let selection = model.selection { proxy.scrollTo(selection) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: model.store.items.isEmpty ? "list.clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.store.items.isEmpty ? "Nothing copied yet" : "Nothing matches").font(.system(size: 14, weight: .semibold))
            Text(model.store.items.isEmpty
                 ? "Copy something in any app and it shows up here."
                 : (model.favoritesOnly ? "Click a heart to keep a copy here for good." : "Try other words, or another filter."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Text("Click or ↩ copies · ↑↓ · ⌘⌫ removes · Esc closes")
            Spacer()
            Text(count == model.store.items.count ? "\(count) copies" : "\(count) of \(model.store.items.count)").monospacedDigit()
            Button(action: model.onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Clipboard settings")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    var model: ClipboardPanelModel

    private var isSelected: Bool { model.selection == item.id }

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let appID = item.appID { AppIcon(bundleID: appID).frame(width: 12, height: 12) }
                    Text(item.appName ?? "Unknown app")
                    Text("·")
                    Text(item.date, format: .relative(presentation: .named))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.justCopied == item.id {
                Label("Copied", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            Button { model.store.toggleFavorite(item) } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isFavorite ? Color.pink : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? "Take it off the favorites" : "Keep it as a favorite (never removed)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.onCopy(item) }
        .onHover { if $0 { model.selection = item.id } }
        .contextMenu {
            Button("Copy") { model.onCopy(item) }
            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.store.toggleFavorite(item) }
            Divider()
            Button("Remove from History", role: .destructive) { model.store.remove(item) }
        }
        .help(model.store.text(of: item).map { String($0.prefix(600)) } ?? item.preview)
    }

    @ViewBuilder
    private var leading: some View {
        if let thumbnail = model.store.thumbnail(of: item), let image = NSImage(contentsOf: thumbnail) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if let file = model.store.files(of: item).first {
            // As Finder shows it (several: the first one's).
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 36, height: 36)
        } else {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// An app's icon, from its bundle identifier (kept once found).
struct AppIcon: View {
    let bundleID: String
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let icon = Self.icon(for: bundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
        }
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let icon = cache[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
