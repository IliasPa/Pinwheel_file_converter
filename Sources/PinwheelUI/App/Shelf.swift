import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// Files parked on the shelf, remembered between launches. Only where they
/// are is kept: the files themselves stay where they were.
@Observable
final class ShelfModel {
    private(set) var items: [URL] = []
    /// Files are being dragged over the shelf.
    var isTargeted = false

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "shelfItems"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = (defaults.stringArray(forKey: Self.key) ?? []).map { URL(fileURLWithPath: $0) }
        refresh()
    }

    func add(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) where !items.contains(url) {
            items.append(url)
        }
        save()
    }

    func remove(_ urls: [URL]) {
        let gone = Set(urls.map(\.standardizedFileURL))
        items.removeAll { gone.contains($0) }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Files moved or deleted since they were parked are let go.
    func refresh() {
        let present = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if present != items {
            items = present
            save()
        }
    }

    private func save() {
        defaults.set(items.map(\.path), forKey: Self.key)
    }
}

/// The shelf's floating window: drop files on it, then drag them (all, or
/// one at a time) to where they go. It never takes the keyboard from Finder.
final class ShelfController {
    let model: ShelfModel
    private let settings: SettingsStore
    private lazy var panel: ShelfPanel = makePanel()

    init(settings: SettingsStore, model: ShelfModel = ShelfModel()) {
        self.settings = settings
        self.model = model
    }

    var isShown: Bool { panel.isVisible }

    /// Parks the files and shows the shelf.
    func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    func show() {
        model.refresh()
        if !panel.isVisible {
            // First time: the top right of the screen with the pointer;
            // afterwards, wherever it was left.
            if !panel.setFrameUsingName(ShelfPanel.frameName) {
                let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                if let visible = screen?.visibleFrame {
                    panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - 24))
                }
            }
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.saveFrame(usingName: ShelfPanel.frameName)
        panel.orderOut(nil)
    }

    func toggle() {
        isShown ? hide() : show()
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel()
        let view = ShelfView(
            model: model, settings: settings,
            onClose: { [weak self] in self?.hide() },
            onDraggedOut: { [weak self] urls in
                guard let self else { return }
                self.model.remove(urls)
                if self.model.items.isEmpty { self.hide() }
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: ShelfPanel.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

final class ShelfPanel: GlassPanel {
    static let size = NSSize(width: 250, height: 330)
    static let frameName = "PinwheelShelf"

    init() {
        super.init(size: Self.size, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeMain: Bool { false }
}

struct ShelfView: View {
    var model: ShelfModel
    var settings: SettingsStore
    var onClose: () -> Void
    var onDraggedOut: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.items.isEmpty {
                empty
            } else {
                pile
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.items, id: \.self) { url in row(url) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(12)
        .frame(width: ShelfPanel.size.width, height: ShelfPanel.size.height, alignment: .top)
        .glassSurface(settings.glassLevel, cornerRadius: 22)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .opacity(model.isTargeted ? 1 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty
        } isTargeted: { model.isTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: model.isTargeted)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: FileAction.shelf.symbolName).foregroundStyle(.secondary)
            Text("Shelf").font(.system(size: 13, weight: .semibold))
            if !model.items.isEmpty {
                Text("\(model.items.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.items.isEmpty {
                Button("Clear", action: model.clear)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Takes everything off the shelf (the files stay where they are)")
            }
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 14)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Hides the shelf; what's on it stays")
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop files here").font(.system(size: 13, weight: .semibold))
            Text("Park them while you find where they go, then drag them off.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// All the files at once: drag the pile.
    private var pile: some View {
        HStack(spacing: 12) {
            ZStack {
                ForEach(Array(model.items.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 46, height: 46)
                        .rotationEffect(.degrees(Double(index) * -7))
                        .offset(x: CGFloat(index) * 5, y: CGFloat(index) * -2)
                }
            }
            .frame(width: 64, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.items.count == 1 ? "1 file" : "\(model.items.count) files").font(.system(size: 12, weight: .semibold))
                Text(model.items.count == 1 ? "Drag it where it goes" : "Drag the pile to take them all")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { FileDragArea(urls: model.items, onDraggedOut: onDraggedOut) }
        .help("Drag to Finder, Mail or any app")
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .overlay { FileDragArea(urls: [url], onDraggedOut: onDraggedOut) }
            Button { model.remove([url]) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Takes it off the shelf (the file stays where it is)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

/// Where files can be dragged out of the shelf from (AppKit, so several go
/// at once, as a pile).
private struct FileDragArea: NSViewRepresentable {
    let urls: [URL]
    let onDraggedOut: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.urls = urls
        view.onDraggedOut = onDraggedOut
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onDraggedOut: ([URL]) -> Void = { _ in }
    private var downEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !urls.isEmpty else { return }
        downEvent = nil
        let point = convert(down.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let shift = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: point.x - 24 + shift, y: point.y - 24 - shift, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Like dragging from Finder: moved within a disk, copied to another.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [] else { return }
        // Dropped back on the shelf (or another Pinwheel window): they stay.
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) { return }
        onDraggedOut(urls)
    }
}
