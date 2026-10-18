import AppKit
import SwiftUI
import PinwheelCore

/// Opens the window behind a "…" wedge (Crop…, Info…, Trim…) and turns
/// what's chosen there into jobs, which then run like any other.
final class EditorCoordinator {
    /// Starts jobs (the app hands its JobQueue in here).
    var enqueue: (_ files: [SourceFile], _ action: WheelAction, _ parameters: JobParameters?) -> Void = { _, _, _ in }

    private let settings: SettingsStore
    private var windows: [NSWindowController] = []
    private var closeObservers: [NSObjectProtocol] = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func open(_ editor: Editor, files: [SourceFile]) {
        let controller: NSWindowController
        switch editor {
        case .crop, .adjust, .background, .markup:
            let images = files.filter { $0.kind == .image }
            guard !images.isEmpty else { return }
            let model = StudioModel(files: images, tab: StudioModel.Tab(editor))
            model.onSave = { [weak self] edit in self?.enqueue(images, .tool(.edit), .image(edit)) }
            controller = StudioWindowController(model: model)
        case .info:
            let model = InfoModel(files: files, settings: settings)
            model.onSave = { [weak self] file, edit in self?.enqueue([file], .tool(.editInfo), .metadata(edit)) }
            model.onRemoveAll = { [weak self] files in self?.enqueue(files, .tool(.stripMetadata), nil) }
            controller = InfoWindowController(model: model)
        case .trim:
            let media = files.filter { $0.kind == .video || $0.kind == .audio }
            guard !media.isEmpty else { return }
            controller = TrimWindowController(
                files: media,
                onTrim: { [weak self] file, start, end in self?.enqueue([file], .tool(.trim), .timeRange(start: start, end: end)) },
                onFrame: { [weak self] file, seconds in self?.enqueue([file], .tool(.saveFrame), .frame(seconds: seconds)) }
            )
        case .password:
            let pdfs = files.filter { $0.kind == .pdf }
            guard !pdfs.isEmpty else { return }
            let model = PasswordModel(files: pdfs)
            model.onSave = { [weak self] password in self?.enqueue(pdfs, .tool(.protect), .password(password)) }
            controller = PasswordWindowController(model: model)
        }
        show(controller)
    }

    private func show(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        windows.append(controller)
        // While an editor is open, Pinwheel is in the Dock and ⌘-Tab, so its
        // window is easy to get back to from Finder.
        NSApp.setActivationPolicy(.regular)
        closeObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.windowClosed(window)
            }
        })
        window.center()
        if windows.count > 1, let previous = windows.dropLast().last?.window {
            window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        }
        NSApp.activate()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func windowClosed(_ window: NSWindow?) {
        windows.removeAll { $0.window === window }
        guard windows.isEmpty else { return }
        closeObservers.forEach(NotificationCenter.default.removeObserver)
        closeObservers.removeAll()
        // Back to a menu-bar-only app once the last editor is gone.
        Task { NSApp.setActivationPolicy(.accessory) }
    }
}

/// A normal, resizable window showing a SwiftUI editor. It hands its own
/// undo manager to the window, so the Edit menu's Undo reaches the editor.
class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let undo: UndoManager?
    var onClose: (() -> Void)?

    init<Content: View>(title: String, size: NSSize, resizable: Bool = true, undoManager: UndoManager? = nil, content: Content) {
        undo = undoManager
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = resizable ? [.minSize] : [.minSize, .maxSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(size)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
