import AppKit
import Carbon.HIToolbox
import Observation
import PinwheelCore
import SwiftUI
import UniformTypeIdentifiers

/// Watches the clipboard, keeps its history, and shows the history window
/// with the shortcut (⌥⌘V unless changed in Settings).
final class ClipboardController {
    let store: ClipboardStore
    let model: ClipboardPanelModel
    /// Settings › Clipboard.
    var onOpenSettings: () -> Void = {}
    /// Presses ⌘V in the app in front (swapped out in tests).
    var paste: () -> Void = { ClipboardController.pressCommandV() }
    /// Whether Pinwheel may press keys (the Accessibility permission).
    var mayPress: () -> Bool = { AXIsProcessTrusted() }
    private let settings: SettingsStore
    private let pasteboard: NSPasteboard
    private let hotKey = GlobalHotKey()
    private var timer: Timer?
    private var seenChangeCount: Int
    private var isSuspended = false
    /// Anchored, it's out of the way for a paste and comes back after.
    private var isSteppingAside = false
    /// Pictures waiting to be looked at for words and codes, and those
    /// already queued this time (each is looked at once).
    private var lookQueue: [ClipItem.ID] = []
    private var queuedLooks: Set<ClipItem.ID> = []
    private var isLooking = false
    private(set) lazy var panel: ClipboardPanel = makePanel()
    private let dragSource = ClipDragSource()

    init(settings: SettingsStore, store: ClipboardStore = ClipboardStore(), pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.store = store
        self.pasteboard = pasteboard
        model = ClipboardPanelModel(store: store)
        seenChangeCount = pasteboard.changeCount
        model.onCopy = { [weak self] item in self?.copy(item) }
        model.onClose = { [weak self] in self?.hide() }
        model.onDragOut = { [weak self] item, view, event in self?.dragOut(item, from: view, event: event) }
        model.onAction = { [weak self] item, action in self?.run(action, on: item) }
        model.onLook = { [weak self] item in self?.look(at: item) }
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
            // Made a moment after launch, so the first ⌥⌘V opens it at once.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.prepareWindow()
                try? await Task.sleep(for: .seconds(30))
                await self?.warmUpReader()
            }
        }
        registerShortcut()
    }

    /// The first time a new version of Pinwheel reads text in a picture,
    /// macOS takes about 40 seconds to get Apple's text reading ready for it
    /// (then it's quick). So that's done once, early, in the background,
    /// rather than when you copy your first screenshot.
    func warmUpReader() async {
        // Per version and per place: macOS gets it ready for each program file.
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        let build = version + " " + Bundle.main.bundlePath
        let key = "readerReadyFor"
        guard settings.clipboardEnabled, settings.clipboardActions,
              UserDefaults.standard.string(forKey: key) != build, let picture = Self.wordPicture() else { return }
        defer { try? FileManager.default.removeItem(at: picture) }
        if (try? await PictureReader.shared.text(in: picture, recognition: TextRecognition())) != nil {
            UserDefaults.standard.set(build, forKey: key)
        }
    }

    /// A small picture of a word, to read.
    private static func wordPicture() -> URL? {
        guard let context = CGContext(data: nil, width: 400, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 120))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Pinwheel" as NSString).draw(at: NSPoint(x: 30, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-ready-\(UUID().uuidString).png")
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Makes the window and lays out its first copies, out of sight.
    func prepareWindow() {
        guard settings.clipboardEnabled, !panel.isVisible else { return }
        model.prepare()
        panel.contentView?.layoutSubtreeIfNeeded()
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
        if let added = store.add(contents, appID: app?.bundleIdentifier, appName: app?.localizedName) {
            look(at: added)
        }
    }

    /// A picture is looked at once, in the background, for words and for a
    /// QR code or barcode: its buttons then show only for what's there, and
    /// paste at once. One picture at a time; only while the buttons are on.
    func look(at item: ClipItem) {
        guard settings.clipboardActions, !queuedLooks.contains(item.id), ClipActions.needsLook(item, store: store) else { return }
        queuedLooks.insert(item.id)
        lookQueue.append(item.id)
        guard !isLooking else { return }
        isLooking = true
        Task {
            while !lookQueue.isEmpty {
                let id = lookQueue.removeFirst()
                guard let item = store.items.first(where: { $0.id == id }), let picture = store.picture(of: item) else { continue }
                if let found = await ClipActions.look(at: picture, recognition: settings.resolvedTextRecognition) {
                    store.setPictureFindings(of: item, text: found.text, codes: found.codes)
                }
            }
            isLooking = false
        }
    }

    /// On the clipboard and, unless Settings says just copy, pasted where
    /// the cursor was: the window closes and ⌘V goes to the app in front.
    /// Pinned, the window stays (it steps aside for the paste).
    func copy(_ item: ClipItem) {
        store.copy(item, to: pasteboard)
        seenChangeCount = pasteboard.changeCount  // not a new copy
        finishChoosing(item.id)
    }

    /// A button under a copy: works out what to paste (reading a picture
    /// takes a moment), then it's pasted like a chosen copy, and kept.
    func run(_ action: ClipAction, on item: ClipItem) {
        guard model.working == nil else { return }
        model.working = ClipWork(item: item.id, action: action)
        let recognition = settings.resolvedTextRecognition
        Task {
            var text: String?
            var problem = action.nothingFound
            do {
                text = try await ClipActions.text(of: action, for: item, store: store, recognition: recognition)
            } catch {
                problem = "Couldn't read it"
            }
            model.working = nil
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.flash(problem, on: item.id)
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            seenChangeCount = pasteboard.changeCount
            let kept = store.add([[(type: UTType.utf8PlainText.identifier, data: Data(text.utf8))]], appID: item.appID, appName: item.appName)
            // Closed meanwhile: you've moved on, so it's only copied. (Out
            // of the way for a paste, anchored, isn't closed.)
            guard isShown || isSteppingAside else { return }
            finishChoosing(kept?.id ?? item.id)
        }
    }

    /// What's chosen is on the clipboard: paste it where the cursor was, or
    /// say it's copied.
    private func finishChoosing(_ id: ClipItem.ID) {
        model.previewing = nil
        guard settings.clipboardPastes, mayPress() else {
            model.justCopied = id
            guard !model.isPinned else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                hide()
            }
            return
        }
        let staysOpen = model.isPinned
        hide()
        isSteppingAside = staysOpen
        Task {
            // The app in front gets its keyboard back first.
            try? await Task.sleep(for: .milliseconds(60))
            paste()
            guard staysOpen else { return }
            try? await Task.sleep(for: .milliseconds(120))
            // Back in view, leaving the keyboard to that app (unless it was
            // closed meanwhile).
            guard isSteppingAside else { return }
            isSteppingAside = false
            panel.orderFrontRegardless()
            model.justCopied = id
        }
    }

    /// ⌘V, as if typed (whatever else is held down).
    static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    var isShown: Bool { panel.isVisible }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        checkClipboard()
        model.prepare()
        model.pastes = settings.clipboardPastes && mayPress()
        // In the upper middle of the screen with the pointer, like Spotlight.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            let top = visible.maxY - visible.height * 0.18 + ClipboardPanel.margin
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        isSteppingAside = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        model.justCopied = nil
        model.justDropped = nil
        model.previewing = nil
    }

    // MARK: - Dragging a copy out

    /// Drags a copy into another app, just as it was copied, on a card that
    /// leans into the drag. While the pointer is over other apps the window
    /// fades, so you see where it goes.
    func dragOut(_ item: ClipItem, from view: NSView, event down: NSEvent) {
        guard model.dragging == nil else { return }
        let writers = store.pasteboardItems(of: item)
        guard !writers.isEmpty else { return }
        let card = DragCard.image(of: item, store: store, appearance: panel.effectiveAppearance)
        let point = view.convert(down.locationInWindow, from: nil)
        let draggingItems = writers.enumerated().map { index, writer in
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            // Several files: a little stack of cards.
            let shift = CGFloat(min(index, 3)) * 6
            let origin = NSPoint(x: point.x - card.size.width / 2 + shift, y: point.y - card.size.height / 2 + shift)
            dragging.setDraggingFrame(NSRect(origin: origin, size: card.size), contents: card)
            return dragging
        }
        dragSource.onMoved = { [weak self] point in self?.dragMoved(to: point) }
        dragSource.onEnded = { [weak self] point, operation in self?.dragEnded(item, at: point, operation: operation) }
        model.previewing = nil
        model.dragging = item.id
        let session = view.beginDraggingSession(with: draggingItems, event: down, source: dragSource)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    /// The glass, on the screen (the window has room around it for its shadow).
    private var glassFrame: NSRect {
        panel.frame.insetBy(dx: ClipboardPanel.margin, dy: ClipboardPanel.margin)
    }

    func dragMoved(to point: NSPoint) {
        fade(to: glassFrame.contains(point) ? 1 : 0.25)
    }

    /// Dropped in another app: the window fades away (anchored, it comes
    /// back and the row says so). Not dropped: the card flies back.
    func dragEnded(_ item: ClipItem, at point: NSPoint, operation: NSDragOperation) {
        model.dragging = nil
        model.dropTarget = nil
        guard operation != [], !glassFrame.contains(point) else {
            fade(to: 1)
            return
        }
        model.justDropped = item.id
        fade(to: model.isPinned ? 1 : 0)
        Task {
            try? await Task.sleep(for: .milliseconds(model.isPinned ? 1400 : 220))
            if model.isPinned {
                if model.justDropped == item.id { model.justDropped = nil }
            } else {
                hide()
            }
        }
    }

    private func fade(to alpha: CGFloat) {
        guard panel.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = alpha
        }
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        panel.onResignKey = { [weak self] in
            guard self?.model.isPinned == false else { return }
            self?.hide()
        }
        // Anchored and behind another app, it still takes the first click.
        let hosting = FirstClickHostingView(rootView: ClipboardView(model: model, settings: settings))
        // The window keeps its size (else it grows by the hidden title bar).
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: ClipboardPanel.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

/// Takes the keyboard (to search) without bringing Pinwheel to the front,
/// so a copy can be pasted straight into the app that was in use.
final class ClipboardPanel: GlassPanel {
    /// The glass.
    static let contentSize = NSSize(width: 580, height: 560)
    /// Room around it for its shadow.
    static let margin: CGFloat = 36
    static let size = NSSize(width: contentSize.width + 2 * margin, height: contentSize.height + 2 * margin)
    var onResignKey: () -> Void = {}

    init() {
        super.init(size: Self.size, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // macOS outlines a window's shadow with a dark line, around the
        // whole window rather than the glass; the view draws a soft one.
        hasShadow = false
        // At once, like Spotlight: a fade in made ⌥⌘V feel slow.
        animationBehavior = .none
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
    /// Only the copies in this collection.
    var collectionID: ClipCollection.ID? {
        didSet { selectFirst() }
    }
    /// A collection being named, new or renamed.
    var naming: CollectionNaming?
    /// The collection asked to be deleted (it waits for a yes).
    var confirmingDelete: ClipCollection.ID?
    /// Where a copy being dragged would land now.
    var dropTarget: ClipDropTarget?
    /// Where a copy just landed (it bounces).
    var landed: ClipDropTarget?
    var selection: ClipItem.ID?
    /// Where the list scrolls to: the copy chosen with the keyboard.
    var scrollTarget: ClipItem.ID?
    /// Flashes on the row just copied.
    var justCopied: ClipItem.ID?
    /// Why the shortcut couldn't be set up, for Settings (nil when it works).
    var shortcutProblem: String?
    /// Choosing a copy pastes it too (else it's only copied).
    var pastes = true
    /// Stays open when another window is clicked or a copy is chosen (the anchor).
    var isPinned = false
    /// The copy shown big (press and hold, or Space).
    var previewing: ClipItem.ID? {
        didSet { if previewing != oldValue { previewFile = 0 } }
    }
    /// Which of its files the preview shows, for a copy of several.
    var previewFile = 0
    /// Being dragged out of the window.
    var dragging: ClipItem.ID?
    /// Just dropped into another app (flashes on its row).
    var justDropped: ClipItem.ID?
    /// A button under a copy at work (reading a picture takes a moment).
    var working: ClipWork?
    /// A short note on a copy's row ("No text found").
    var notice: ClipNotice?
    /// The buttons under each copy, worked out once (a copy doesn't change).
    @ObservationIgnored private var actionsFound: [ClipItem.ID: [ClipAction]] = [:]

    var onCopy: (ClipItem) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// Starts dragging a copy out, from where the pointer went down on it.
    var onDragOut: (ClipItem, NSView, NSEvent) -> Void = { _, _, _ in }
    var onAction: (ClipItem, ClipAction) -> Void = { _, _ in }
    /// A picture's row came into view: look at it if that hasn't happened.
    var onLook: (ClipItem) -> Void = { _ in }

    init(store: ClipboardStore) {
        self.store = store
    }

    var visible: [ClipItem] {
        store.matching(search: search, kind: kind, appID: appID, favoritesOnly: favoritesOnly, collection: collectionID)
    }

    /// Each time the window opens: a fresh search, filters kept.
    func prepare() {
        search = ""
        if let appID, !store.apps.contains(where: { $0.id == appID }) { self.appID = nil }
        if let collectionID, !store.collections.contains(where: { $0.id == collectionID }) { self.collectionID = nil }
        naming = nil
        confirmingDelete = nil
        selectFirst()
    }

    /// A short note on a copy's row, for a moment.
    func flash(_ text: String, on id: ClipItem.ID, isProblem: Bool = true) {
        let flashed = ClipNotice(item: id, text: text, isProblem: isProblem)
        notice = flashed
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == flashed { notice = nil }
        }
    }

    func selectFirst() {
        selection = visible.first?.id
        scrollTarget = selection
    }

    /// The pointer moved onto a copy.
    func hover(_ item: ClipItem) {
        if selection != item.id { selection = item.id }
    }

    func moveSelection(by step: Int) {
        let shown = visible
        guard !shown.isEmpty else { return }
        let index = shown.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : shown.count)
        selection = shown[min(max(index + step, 0), shown.count - 1)].id
        scrollTarget = selection
        // The preview follows, as in Quick Look.
        if previewing != nil { previewing = selection }
    }

    func actions(for item: ClipItem) -> [ClipAction] {
        // A picture's change once it's been looked at (and are quick to work out).
        guard item.kind == .text || item.kind == .link else { return ClipActions.available(for: item, store: store) }
        if let found = actionsFound[item.id] { return found }
        let found = ClipActions.available(for: item, store: store)
        if actionsFound.count > 500 { actionsFound.removeAll() }
        actionsFound[item.id] = found
        return found
    }

    /// Space, pressing and holding, or the menu: the copy shown big.
    func preview(_ item: ClipItem) {
        selection = item.id
        previewing = item.id
    }

    /// Space: the chosen copy's preview, or back to the list.
    func togglePreview() {
        if previewing == nil {
            previewing = selection
        } else {
            closePreview()
        }
    }

    func closePreview() {
        previewing = nil
    }

    func copySelected() {
        guard let item = visible.first(where: { $0.id == selection }) ?? visible.first else { return }
        onCopy(item)
    }

    func removeSelected() {
        let shown = visible
        guard let index = shown.firstIndex(where: { $0.id == selection }) else { return }
        store.remove(shown[index])
        closePreview()
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
            CollectionsBar(model: model)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            apps
                .padding(.horizontal, 12)
                .padding(.top, 6)
            Divider().padding(.top, 10)
            if shown.isEmpty {
                empty
            } else {
                ClipList(shown: shown, model: model, holdPreviews: settings.clipboardPreview.byHolding, showsActions: settings.clipboardActions)
            }
            Divider()
            footer(shown.count)
        }
        .frame(width: ClipboardPanel.contentSize.width, height: ClipboardPanel.contentSize.height)
        .overlay {
            if let id = model.previewing, let item = model.store.items.first(where: { $0.id == id }) {
                ClipPreview(item: item, model: model)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.previewing)
        .glassSurface(settings.glassLevel, cornerRadius: 24)
        .background(OuterShadow(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.justCopied) { searchFocused = true }
        .onChange(of: model.previewing) { searchFocused = true }
        .onChange(of: model.naming == nil) { if model.naming == nil { searchFocused = true } }
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
                .onKeyPress(.escape) {
                    if model.previewing != nil { model.closePreview() } else { model.onClose() }
                    return .handled
                }
                .onKeyPress(.space) {
                    // While searching, Space is a space.
                    guard settings.clipboardPreview.bySpace, model.search.isEmpty || model.previewing != nil else { return .ignored }
                    model.togglePreview()
                    return .handled
                }
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
            chip("All", symbol: nil, isOn: model.kind == nil && !model.favoritesOnly && model.collectionID == nil) {
                model.kind = nil
                model.favoritesOnly = false
                model.collectionID = nil
            }
            chip("Favorites", symbol: "heart.fill", isOn: model.favoritesOnly) {
                model.favoritesOnly.toggle()
                if model.favoritesOnly { model.collectionID = nil }
            }
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: model.dropTarget == .favorites ? 2 : 0))
            .scaleEffect(model.dropTarget == .favorites ? 1.08 : (model.landed == .favorites ? 1.12 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.dropTarget)
            .animation(.spring(response: 0.3, dampingFraction: 0.4), value: model.landed)
            .onDrop(of: [.item], isTargeted: model.isTargeted(.favorites)) { _ in model.drop(on: .favorites) }
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

    private var empty: some View {
        let collection = model.store.collections.first { $0.id == model.collectionID }
        return VStack(spacing: 8) {
            Image(systemName: model.store.items.isEmpty ? "list.clipboard" : (collection?.items.isEmpty == true ? "folder" : "magnifyingglass"))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.store.items.isEmpty ? "Nothing copied yet" : (collection?.items.isEmpty == true ? "\(collection?.name ?? "") is empty" : "Nothing matches"))
                .font(.system(size: 14, weight: .semibold))
            Text(model.store.items.isEmpty
                 ? "Copy something in any app and it shows up here."
                 : collection?.items.isEmpty == true
                 ? "Drag a copy onto \(collection?.name ?? "its chip"), or right-click one › Add to Collection."
                 : (model.favoritesOnly ? "Click a heart to keep a copy here for good." : "Try other words, or another filter."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Text("Click or ↩ \(model.pastes ? "pastes" : "copies") · \(previewHint) · ⌘⌫ removes · Esc closes")
            Spacer()
            Text(count == model.store.items.count ? "\(count) copies" : "\(count) of \(model.store.items.count)").monospacedDigit()
            anchor
                .padding(.trailing, 14)
            Button(action: model.onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Clipboard settings")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var previewHint: String {
        switch settings.clipboardPreview {
        case .holdOrSpace: "Hold or Space previews"
        case .hold: "Hold previews"
        case .space: "Space previews"
        }
    }

    /// Keeps the window open while you work in other apps.
    private var anchor: some View {
        Button { model.isPinned.toggle() } label: {
            AnchorIcon()
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 14)
                .foregroundStyle(model.isPinned ? Color.accentColor : Color.secondary)
                .padding(5)
                .background(Circle().fill(model.isPinned ? Color.accentColor.opacity(0.2) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.isPinned
              ? "Anchored: stays open while you use other apps. Click to let it close again"
              : "Anchor: keep the window open while you use other apps")
    }
}

/// An anchor (SF Symbols has none).
nonisolated struct AnchorIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        let ring = width * 0.16
        let tipY = rect.minY + height * 0.6
        let left = CGPoint(x: rect.minX + width * 0.06, y: tipY)
        let right = CGPoint(x: rect.maxX - width * 0.06, y: tipY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.midX - ring, y: rect.minY, width: ring * 2, height: ring * 2))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + ring * 2))
        path.addLine(to: bottom)
        path.move(to: CGPoint(x: rect.midX - width * 0.26, y: rect.minY + height * 0.34))
        path.addLine(to: CGPoint(x: rect.midX + width * 0.26, y: rect.minY + height * 0.34))
        path.move(to: left)
        path.addQuadCurve(to: bottom, control: CGPoint(x: rect.minX + width * 0.1, y: rect.maxY))
        path.addQuadCurve(to: right, control: CGPoint(x: rect.maxX - width * 0.1, y: rect.maxY))
        // The barbs at the tips.
        for (tip, side) in [(left, 1.0), (right, -1.0)] {
            path.move(to: CGPoint(x: tip.x - side * width * 0.04, y: tip.y + height * 0.1))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x + side * width * 0.14, y: tip.y + height * 0.04))
        }
        return path
    }
}

/// A soft shadow around a rounded rectangle, drawn only outside it, so the
/// glass on top stays as clear as it is.
struct OuterShadow: View {
    var cornerRadius: CGFloat
    var radius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.black)
            .shadow(color: .black.opacity(0.32), radius: radius, y: radius / 3)
            .mask {
                Rectangle()
                    .padding(-radius * 3)
                    .overlay(shape.blendMode(.destinationOut))
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

/// The copies. Its own view, so the pointer moving from copy to copy
/// redraws just the two rows that change, not the whole window.
private struct ClipList: View {
    let shown: [ClipItem]
    var model: ClipboardPanelModel
    var holdPreviews: Bool
    var showsActions: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { item in
                        ClipRow(item: item, model: model, isSelected: model.selection == item.id, holdPreviews: holdPreviews, showsActions: showsActions)
                            .id(item.id)
                    }
                }
                .padding(8)
            }
            // Only for the keyboard: a copy under the pointer is in view.
            .onChange(of: model.scrollTarget) {
                if let target = model.scrollTarget { proxy.scrollTo(target) }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    var model: ClipboardPanelModel
    let isSelected: Bool
    /// Pressing and holding shows the preview (Settings).
    var holdPreviews: Bool
    /// The small buttons under it (Settings).
    var showsActions: Bool
    private var isDragged: Bool { model.dragging == item.id }
    private var wasDropped: Bool { model.justDropped == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            line
            if showsActions {
                let actions = model.actions(for: item)
                if !actions.isEmpty {
                    ClipActionBar(item: item, actions: actions, model: model)
                        .padding(.leading, 50)  // under the text
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected && !isDragged ? Color.accentColor.opacity(0.18) : .clear))
        // Dragged out: what's left is the copy's outline, until it lands
        // (or springs back if it doesn't).
        .overlay {
            if isDragged {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .scaleEffect(isDragged ? 0.96 : (wasDropped ? 1.015 : 1))
        .opacity(isDragged ? 0.5 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: isDragged)
        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: wasDropped)
        .onHover { if $0 { model.hover(item) } }
        .onAppear { if showsActions { model.onLook(item) } }
        .help(model.store.text(of: item).map { String($0.prefix(600)) } ?? item.preview)
    }

    /// The copy, its app and when, and its heart.
    private var line: some View {
        HStack(spacing: 10) {
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
                        let collections = model.store.collections(of: item)
                        if !collections.isEmpty {
                            Text("·")
                            Image(systemName: "folder").font(.system(size: 9))
                            Text(collections.map(\.name).joined(separator: ", "))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let notice = model.notice, notice.item == item.id {
                    Text(notice.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(notice.isProblem ? Color.orange : Color.accentColor)
                } else if wasDropped {
                    Label("Dropped", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if model.justCopied == item.id {
                    Label("Copied", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .overlay {
                ClipRowPointer(
                    holdPreviews: holdPreviews,
                    onClick: { model.onCopy(item) },
                    onHold: { model.preview(item) },
                    onDragOut: { view, event in model.onDragOut(item, view, event) },
                    onHover: { model.hover(item) },
                    menu: menu
                )
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
    }

    /// The right-click menu.
    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionMenuItem(model.pastes ? "Paste" : "Copy") { model.onCopy(item) })
        menu.addItem(actionMenuItem("Preview") { model.preview(item) })
        menu.addItem(actionMenuItem(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.store.toggleFavorite(item) })
        // Collections: a tick by those it's in; choosing one puts it in or takes it out.
        let collections = NSMenu()
        for collection in model.store.collections {
            let entry = actionMenuItem(collection.name) { model.toggle(item, in: collection) }
            entry.state = collection.items.contains(item.id) ? .on : .off
            collections.addItem(entry)
        }
        if !model.store.collections.isEmpty { collections.addItem(.separator()) }
        collections.addItem(actionMenuItem("New Collection…") { model.startNewCollection(adding: item) })
        let collectionsItem = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
        collectionsItem.submenu = collections
        menu.addItem(collectionsItem)
        if let shown = model.store.collections.first(where: { $0.id == model.collectionID }) {
            menu.addItem(actionMenuItem("Remove from \u{201C}\(shown.name)\u{201D}") { model.store.remove(item, from: shown.id) })
        }
        menu.addItem(.separator())
        menu.addItem(actionMenuItem("Remove from History") { model.store.remove(item) })
        return menu
    }

    @ViewBuilder
    private var leading: some View {
        if let image = model.store.thumbnailImage(of: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if let file = model.store.files(of: item).first {
            // As Finder shows it (several: the first one's).
            Image(nsImage: AppIcon.fileIcon(file)).resizable().frame(width: 36, height: 36)
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

    private static var fileIcons: [String: NSImage] = [:]

    /// A file's icon, as Finder shows it (kept once found).
    static func fileIcon(_ file: URL) -> NSImage {
        if let icon = fileIcons[file.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        if fileIcons.count > 300 { fileIcons.removeAll() }
        fileIcons[file.path] = icon
        return icon
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let icon = cache[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
