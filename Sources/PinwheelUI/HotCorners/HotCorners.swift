import AppKit

/// The four corners of a screen.
enum ScreenCorner: String, CaseIterable, Identifiable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: Self { self }

    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    /// How close to the very corner the pointer must be, in points. The
    /// pointer stops at the screen's edge, so a fast flick lands inside this.
    static let reach: CGFloat = 2

    /// The corner the point is in, for screens laid out as `frames` (global
    /// coordinates, y up). A corner that touches another screen isn't one:
    /// the pointer goes on through it.
    static func corner(at point: NSPoint, in frames: [NSRect]) -> ScreenCorner? {
        guard let frame = frames.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
        let left = point.x <= frame.minX + reach
        let right = point.x >= frame.maxX - reach
        let bottom = point.y <= frame.minY + reach
        let top = point.y >= frame.maxY - reach
        let corner: ScreenCorner
        switch (left, right, top, bottom) {
        case (true, _, true, _): corner = .topLeft
        case (_, true, true, _): corner = .topRight
        case (true, _, _, true): corner = .bottomLeft
        case (_, true, _, true): corner = .bottomRight
        default: return nil
        }
        // Another screen just past the corner means the pointer can go on.
        let tip = NSPoint(
            x: corner == .topLeft || corner == .bottomLeft ? frame.minX : frame.maxX,
            y: corner == .topLeft || corner == .topRight ? frame.maxY : frame.minY
        )
        let open = frames.contains { $0 != frame && $0.insetBy(dx: -3, dy: -3).contains(tip) }
        return open ? nil : corner
    }
}

/// Where each corner leads, as saved in Settings.
struct HotCornerApps: Equatable {
    /// Corner → the app's path.
    var paths: [ScreenCorner: String] = [:]

    subscript(corner: ScreenCorner) -> URL? {
        get { paths[corner].map { URL(fileURLWithPath: $0) } }
        set { paths[corner] = newValue?.path }
    }

    var isEmpty: Bool { paths.isEmpty }

    /// As saved in the preferences: ["topLeft": "/Applications/Safari.app"].
    var stored: [String: String] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0.key.rawValue, $0.value) })
    }

    init() {}

    init(stored: [String: Any]?) {
        for (key, value) in stored ?? [:] {
            if let corner = ScreenCorner(rawValue: key), let path = value as? String, !path.isEmpty {
                paths[corner] = path
            }
        }
    }
}

/// How long the pointer rests in a corner before its app opens.
enum HotCornerDelay: Double, CaseIterable {
    case instant = 0
    case short = 0.3
    case medium = 0.6
    case long = 1

    var title: String {
        switch self {
        case .instant: "Right away"
        case .short: "Briefly (0.3 s)"
        case .medium: "A moment (0.6 s)"
        case .long: "One second"
        }
    }
}

/// Opens an app when the pointer rests in a corner of the screen.
///
/// Each visit to a corner opens its app once; the pointer has to leave and
/// come back to do it again. Nothing happens while a mouse button is held
/// (dragging files to a corner, or a game, isn't asking for an app).
final class HotCornerMonitor {
    /// The apps to open (Settings).
    var apps: () -> HotCornerApps = { HotCornerApps() }
    var isEnabled: () -> Bool = { true }
    var delay: () -> HotCornerDelay = { .short }
    /// Settings: leave full-screen apps and games alone.
    var skipsFullScreen: () -> Bool = { true }
    /// Whether a full-screen app or a game is in front. Tests put their own here.
    var isFullScreenInFront: () -> Bool = { HotCornerMonitor.fullScreenInFront() }
    /// Opens an app. Tests put their own here.
    var open: (URL) -> Void = { HotCornerMonitor.launch($0) }

    private var monitor: Any?
    private var inCorner: ScreenCorner?
    private var waiting: Task<Void, Never>?
    /// The corner whose app already opened on this visit.
    private var fired: ScreenCorner?

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func reset() {
        waiting?.cancel()
        waiting = nil
        inCorner = nil
        fired = nil
    }

    private func pointerMoved() {
        let frames = NSScreen.screens.map(\.frame)
        update(corner: ScreenCorner.corner(at: NSEvent.mouseLocation, in: frames),
               buttonsDown: NSEvent.pressedMouseButtons != 0)
    }

    /// The pointer is now in `corner` (nil: in none).
    func update(corner: ScreenCorner?, buttonsDown: Bool) {
        let corner = buttonsDown || !isEnabled() ? nil : corner
        guard corner != inCorner else { return }
        waiting?.cancel()
        waiting = nil
        inCorner = corner
        // Leaving a corner, or going straight to another, ends the visit.
        fired = nil
        guard let corner, let app = apps()[corner] else { return }
        // A game or a full-screen app owns the corner (a game's menu, a video's
        // controls): the pointer rests there on purpose.
        if skipsFullScreen() && isFullScreenInFront() { return }
        let seconds = delay().rawValue
        if seconds == 0 {
            fire(corner, app)
            return
        }
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.inCorner == corner else { return }
            // Something may have gone full screen while the pointer rested.
            if self.skipsFullScreen() && self.isFullScreenInFront() { return }
            self.fire(corner, app)
        }
    }

    private func fire(_ corner: ScreenCorner, _ app: URL) {
        fired = corner
        open(app)
    }

    /// True when the app in front is a game, or has a window covering a whole
    /// screen (full screen in macOS, a game's own full screen, a video player).
    /// Our own windows don't count.
    static func fullScreenInFront() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if let bundle = front.bundleURL.flatMap(Bundle.init(url:)),
           let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           category.lowercased().hasSuffix("games") {
            return true
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window bounds count from the top of the main screen; so do these sizes.
        let sizes = NSScreen.screens.map(\.frame.size)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return false }
            return sizes.contains { bounds.width >= $0.width - 1 && bounds.height >= $0.height - 1 }
        }
    }

    /// Opens the app the way Finder does. (NSWorkspace's own call can't bring
    /// an app forward from a menu-bar app like this one: macOS only lets the
    /// app in front hand over focus. `open` has no such limit.)
    static func launch(_ app: URL) {
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [app.path]
        try? process.run()
    }
}
