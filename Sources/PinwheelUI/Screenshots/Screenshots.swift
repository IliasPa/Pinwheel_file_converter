import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers
import PinwheelCore

/// The ways to take a screenshot.
enum ScreenshotMode: String, CaseIterable, Identifiable {
    case area, window, screen, again, text, scrolling, record

    var id: Self { self }

    var title: String {
        switch self {
        case .area: "Capture an area"
        case .window: "Capture a window"
        case .screen: "Capture the whole screen"
        case .again: "Capture the same area again"
        case .text: "Copy the text or code in an area"
        case .scrolling: "Capture a scrolling area"
        case .record: "Record the screen"
        }
    }

    var symbolName: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .again: "arrow.counterclockwise"
        case .text: "text.viewfinder"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .record: "record.circle"
        }
    }

    /// ⌥⌘ and a number: macOS keeps ⇧⌘3, 4 and 5 for its own screenshots.
    var defaultShortcut: KeyShortcut {
        switch self {
        case .screen: KeyShortcut(keyCode: UInt16(kVK_ANSI_3), modifiers: [.option, .command], key: "3")
        case .area: KeyShortcut(keyCode: UInt16(kVK_ANSI_4), modifiers: [.option, .command], key: "4")
        case .window: KeyShortcut(keyCode: UInt16(kVK_ANSI_5), modifiers: [.option, .command], key: "5")
        case .again: KeyShortcut(keyCode: UInt16(kVK_ANSI_6), modifiers: [.option, .command], key: "6")
        case .text: KeyShortcut(keyCode: UInt16(kVK_ANSI_7), modifiers: [.option, .command], key: "7")
        case .scrolling: KeyShortcut(keyCode: UInt16(kVK_ANSI_8), modifiers: [.option, .command], key: "8")
        case .record: KeyShortcut(keyCode: UInt16(kVK_ANSI_9), modifiers: [.option, .command], key: "9")
        }
    }
}

/// The file a screenshot is saved as.
enum ScreenshotFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic

    var id: Self { self }

    var outputFormat: OutputFormat {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    /// In a few words, what it's like.
    var tagline: String {
        switch self {
        case .png: "Sharp and exact"
        case .jpeg: "Small, opens anywhere"
        case .heic: "Smallest, Apple-friendly"
        }
    }

    /// When to choose it, with everyday examples.
    var bestFor: String {
        switch self {
        case .png:
            "App windows, settings, code, tables, error messages, tutorials and bug reports: anything with text or thin lines. A screen of mostly flat color is often smaller as a PNG than as a JPEG."
        case .jpeg:
            "Photos, videos, maps and web pages full of pictures; pictures sent by email or chat, or uploaded where there's a size limit. A photo screen can take a fifth of the room of a PNG."
        case .heic:
            "A big collection you keep for yourself (iCloud, a Mac and an iPhone): about half the size of a JPEG that looks the same."
        }
    }

    /// What to watch for.
    var watchOut: String {
        switch self {
        case .png: "Large for photos (several MB for a full retina screen)."
        case .jpeg: "Letters get a little fuzzy at their edges, and a window's see-through shadow gets a solid background."
        case .heic: "Windows, many websites and older apps can't open it. Send a JPEG or PNG instead."
        }
    }
}

/// What happens to a new screenshot.
enum ScreenshotAfter: String, CaseIterable {
    case edit, pin, nothing

    var title: String {
        switch self {
        case .edit: "Open it in the editor"
        case .pin: "Pin it on the screen"
        case .nothing: "Nothing more"
        }
    }
}

/// Takes screenshots: from shortcuts or the menu bar's menu. The picture is
/// saved as a PNG, copied if you like, and then opened in the same image
/// editor the wheel uses (Markup), pinned on the screen, or left alone.
@Observable
final class ScreenshotController {
    private let settings: SettingsStore
    @ObservationIgnored private var hotKeys: [ScreenshotMode: GlobalHotKey] = [:]
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var selector: AreaSelector?
    @ObservationIgnored private var scrolling: ScrollingSession?
    @ObservationIgnored private var recording: RecordingSession?
    /// Whether the screen is being recorded now (the menu offers Stop).
    private(set) var isRecording = false
    @ObservationIgnored private var pins: [PinnedPicture] = []
    @ObservationIgnored private var isBusy = false
    /// What the area being chosen is for: a picture, or text to read.
    @ObservationIgnored private var purpose = ScreenshotMode.area
    /// The app that was in front when the shortcut was pressed (it names the file).
    @ObservationIgnored private var frontApp = ""
    /// How many pixels a point is, on the screen being captured (for 1×).
    @ObservationIgnored private var pixelsPerPoint: CGFloat = 1
    /// The screenshots taken lately (shown under the clipboard).
    let history = ScreenshotHistory()

    /// Shortcuts macOS wouldn't give us (another app has them).
    private(set) var problems: [ScreenshotMode: String] = [:]
    /// What went wrong with the last screenshot, if anything.
    private(set) var message: String?

    /// Opens a saved screenshot in the editor.
    @ObservationIgnored var onEdit: (URL) -> Void = { _ in }
    /// Opens a saved recording in the video editor.
    @ObservationIgnored var onEditRecording: (URL) -> Void = { _ in }
    /// Screen Recording isn't allowed yet: the app shows how to.
    @ObservationIgnored var onNeedsPermission: () -> Void = {}

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - Shortcuts

    /// Follows Settings: on or off, and the keys.
    func apply() {
        problems = [:]
        guard settings.screenshotsEnabled, !isSuspended else {
            hotKeys.values.forEach { $0.unregister() }
            return
        }
        for mode in ScreenshotMode.allCases {
            let key = hotKeys[mode] ?? GlobalHotKey()
            hotKeys[mode] = key
            let shortcut = settings.screenshotShortcuts[mode] ?? mode.defaultShortcut
            if !key.register(shortcut, action: { [weak self] in self?.capture(mode) }) {
                problems[mode] = "\(shortcut.title) is taken by another app (perhaps another screenshot app). Quit it, or choose other keys."
            }
        }
    }

    /// While new keys are being recorded, ours must not answer them.
    func suspendShortcuts(_ suspended: Bool) {
        isSuspended = suspended
        apply()
    }

    // MARK: - Capturing

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func capture(_ mode: ScreenshotMode) {
        // Pressing the scrolling shortcut again finishes the one being taken.
        if mode == .scrolling, let scrolling {
            scrolling.finish()
            return
        }
        // And the recording shortcut stops a recording.
        if mode == .record, let recording {
            recording.stop()
            return
        }
        guard !isBusy, scrolling == nil, recording == nil else { return }
        guard Self.hasPermission else {
            CGRequestScreenCaptureAccess()
            onNeedsPermission()
            return
        }
        message = nil
        noteFrontApp()
        switch mode {
        case .area, .text, .scrolling, .record:
            isBusy = true
            purpose = mode
            chooseArea()
        case .again:
            purpose = .area
            if let area = settings.lastScreenshotArea {
                grab(area, waiting: 0)
            } else {
                isBusy = true
                chooseArea()
            }
        case .screen:
            purpose = .area
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
            if let screen { grab(screen.frame, waiting: 0) }
        case .window:
            isBusy = true
            purpose = .area
            var arguments = ["-x", "-i", "-W", "-t", "png"]
            if settings.screenshotCursor { arguments.append("-C") }
            if !settings.screenshotWindowShadow { arguments.append("-o") }
            if settings.screenshotDelay > 0 { arguments += ["-T", String(settings.screenshotDelay)] }
            Task { await finish(arguments, waiting: 0) }
        }
    }

    private func chooseArea() {
        // The screen is photographed first and shown still, so what you
        // select is exactly what was there when the key was pressed (menus,
        // tooltips and video can't change under you). With a timer set, the
        // picture is taken live when it runs out instead.
        // A scrolling area is chosen live (the page has to stay scrollable).
        let timed = settings.screenshotDelay > 0 || purpose == .scrolling || purpose == .record
        Task {
            let frozen = timed ? [] : await AreaSelector.freezeScreens(cursor: settings.screenshotCursor)
            let selector = AreaSelector()
            // A click (no drag) records the whole screen it's on.
            selector.clickPicksScreen = self.purpose == .record
            self.selector = selector
            selector.start(frozen: frozen) { [weak self] area in
                guard let self else { return }
                self.selector = nil
                guard let area else {
                    self.isBusy = false
                    return
                }
                if self.purpose == .area { self.settings.lastScreenshotArea = area }
                self.isBusy = false
                if self.purpose == .scrolling {
                    self.startScrolling(area)
                    return
                }
                if self.purpose == .record {
                    self.startRecording(area)
                    return
                }
                if let picture = selector.picture(of: area) {
                    self.save(frozen: picture)
                } else {
                    // The dimming windows must be gone before the picture is taken.
                    self.grab(area, waiting: 0.25)
                }
            }
        }
    }

    /// Follows what scrolls in the area, until Done.
    private func startScrolling(_ area: NSRect) {
        let session = ScrollingSession(area: area)
        scrolling = session
        session.onFinish = { [weak self] picture in
            self?.scrolling = nil
            guard let picture else { return }
            self?.save(frozen: picture)
        }
        session.begin()
    }

    /// Records the area until Stop (or the shortcut again).
    private func startRecording(_ area: NSRect) {
        let options = RecordingOptions(
            framesPerSecond: settings.recordingFramesPerSecond, sound: settings.recordingSound,
            microphone: settings.recordingMicrophone, showsClicks: settings.recordingShowsClicks,
            showsPointer: true
        )
        let session = RecordingSession(area: area, options: options)
        recording = session
        isRecording = true
        session.onFinish = { [weak self] file in
            guard let self else { return }
            self.recording = nil
            self.isRecording = false
            guard let file else { return }
            self.keepRecording(file)
        }
        session.begin()
    }

    /// Moves the finished video to the screenshot folder and does what
    /// Settings says (the editor here is the video editor: trim, GIF…).
    private func keepRecording(_ file: URL) {
        let target = nextFile(extension: "mp4")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: target)
        } catch {
            Toast.show("The recording couldn't be saved: \(error.localizedDescription)")
            return
        }
        if settings.screenshotCopy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([target as NSURL])
        }
        switch settings.screenshotAfter {
        case .edit: onEditRecording(target)
        case .pin: NSWorkspace.shared.activateFileViewerSelecting([target])
        case .nothing: NSSound(named: "Pop")?.play()
        }
        Toast.show("Recording saved", detail: target.lastPathComponent)
    }

    /// Stops the recording (the menu bar's Stop Recording).
    func stopRecording() { recording?.stop() }

    /// Handles a part of the frozen screen (no waiting: it's already taken).
    private func save(frozen picture: CGImage) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-shot-\(UUID().uuidString).png")
            guard Self.writePNG(picture, to: raw) else {
                Toast.show("The screenshot couldn't be saved.")
                return
            }
            await handle(raw)
        }
    }

    /// Writes a picture as PNG, keeping its colors.
    static func writePNG(_ picture: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, picture, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Takes the picture of a part of the screen (in the Mac's own coordinates).
    private func grab(_ area: NSRect, waiting: Double) {
        guard !isBusy else { return }
        isBusy = true
        // screencapture counts from the top of the main screen.
        let top = NSScreen.screens.first?.frame.maxY ?? area.maxY
        let spot = "\(Int(area.minX.rounded())),\(Int((top - area.maxY).rounded())),\(Int(area.width.rounded())),\(Int(area.height.rounded()))"
        var arguments = ["-x", "-t", "png", "-R", spot]
        if settings.screenshotCursor { arguments.append("-C") }
        Task { await finish(arguments, waiting: waiting + Double(settings.screenshotDelay)) }
    }

    private func finish(_ arguments: [String], waiting: Double) async {
        defer { isBusy = false }
        if waiting > 0 { try? await Task.sleep(for: .seconds(waiting)) }
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-shot-\(UUID().uuidString).png")
        let ran = await Self.run(arguments + [raw.path])
        // Cancelled (Esc) leaves no file.
        guard ran, FileManager.default.fileExists(atPath: raw.path) else { return }
        await handle(raw)
    }

    /// What happens to a taken picture: read for text, or saved.
    private func handle(_ raw: URL) async {
        let isText = purpose == .text
        defer { try? FileManager.default.removeItem(at: raw) }
        if isText {
            await readText(in: raw)
            return
        }
        do {
            saved(try await store(raw))
        } catch {
            message = error.localizedDescription
            Toast.show("The screenshot couldn't be saved: \(error.localizedDescription)")
        }
    }

    /// Moves the picture to its folder, in the format chosen in Settings.
    private func store(_ raw: URL) async throws -> URL {
        let format = settings.screenshotFormat
        if !settings.screenshotFullResolution, pixelsPerPoint > 1 {
            Self.reduce(raw, by: pixelsPerPoint)
        }
        let target = nextFile(extension: format.outputFormat.fileExtension)
        if format == .png {
            try FileManager.default.moveItem(at: raw, to: target)
            return target
        }
        let options = settings.conversionOptions
        let output = format.outputFormat
        try await Blocking.run { _ in try ImageConverter.convert(raw, to: output, destination: target, options: options) }
        return target
    }

    /// Reads the words in the area, and any QR code or barcode, and copies
    /// them (Settings › Text Recognition says how the words are read: Apple's,
    /// or Tesseract for Greek).
    private func readText(in picture: URL) async {
        let recognition = settings.resolvedTextRecognition
        do {
            let text = try await PictureReader.shared.text(in: picture, recognition: recognition)
            // A picture with no code is no error here.
            let codes = (try? await PictureReader.shared.codes(in: picture)) ?? []
            guard let copied = Self.copied(text: text, codes: codes) else {
                Toast.show("No text or code found in that area")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied.text, forType: .string)
            Toast.show(copied.title, detail: copied.detail)
        } catch {
            Toast.show("Couldn't read the text: \(error.localizedDescription)")
        }
    }

    /// What goes on the clipboard for the words and codes found (nil: nothing).
    /// Words first, then each code on its own line.
    static func copied(text: String, codes: [ReadCode]) -> (text: String, title: String, detail: String)? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        let payloads = codes.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !words.isEmpty || !payloads.isEmpty else { return nil }
        let first = (payloads.first ?? words.split(separator: "\n").first.map(String.init) ?? words)
        if payloads.isEmpty {
            return (words, "Copied \(words.count) characters", first)
        }
        let kind = codes.first?.kind ?? "code"
        let what = payloads.count == 1 ? "a \(kind)" : "\(payloads.count) codes"
        let joined = payloads.joined(separator: "\n")
        if words.isEmpty {
            return (joined, "Copied \(what)", first)
        }
        return (words + "\n\n" + joined, "Copied the text and \(what)", first)
    }

    private func saved(_ url: URL) {
        history.add(url, app: frontApp)
        let picture = NSImage(contentsOf: url)
        if settings.screenshotCopy, let picture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([picture])
        }
        switch settings.screenshotAfter {
        case .edit: onEdit(url)
        case .pin:
            if let picture { pin(picture, file: url) }
        case .nothing: NSSound(named: "Pop")?.play()
        }
    }

    /// Runs macOS's own screenshot program (it needs the same Screen
    /// Recording permission, which Pinwheel passes on to it).
    nonisolated private static func run(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    // MARK: - Where they go

    /// The app in front now and the screen the pointer is on, noted before
    /// our own windows come forward.
    private func noteFrontApp() {
        let app = NSWorkspace.shared.frontmostApplication
        let isUs = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        frontApp = isUs ? "" : (app?.localizedName ?? "")
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        pixelsPerPoint = screen?.backingScaleFactor ?? 1
    }

    /// Safari_20261121_0930.png (and "_2", "_3"… if the minute has one already).
    /// Without an app in front: Screenshot_20261121_0930.
    static func fileName(app: String, date: Date, extension ext: String, exists: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let clean = app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(clean.isEmpty ? "Screenshot" : clean)_\(formatter.string(from: date))"
        var name = "\(base).\(ext)"
        var number = 2
        while exists(name) {
            name = "\(base)_\(number).\(ext)"
            number += 1
        }
        return name
    }

    private func nextFile(extension ext: String) -> URL {
        let folder = settings.screenshotFolder
        let name = Self.fileName(app: frontApp, date: Date(), extension: ext) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return folder.appendingPathComponent(name)
    }

    /// Shrinks a picture taken on a Retina screen to the size it has on
    /// screen (1×), in place.
    @discardableResult
    static func reduce(_ url: URL, by scale: CGFloat) -> Bool {
        guard scale > 1, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let small = reduced(image, by: scale) else { return false }
        return writePNG(small, to: url)
    }

    static func reduced(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) / scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) / scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Pinning

    /// Floats a picture over everything, to look at while you work.
    func pin(_ picture: NSImage, file: URL?) {
        let pinned = PinnedPicture(picture: picture, file: file)
        pinned.onEdit = { [weak self] url in self?.onEdit(url) }
        pinned.onClose = { [weak self, weak pinned] in
            self?.pins.removeAll { $0 === pinned }
        }
        pins.append(pinned)
        pinned.present()
    }

    var pinCount: Int { pins.count }

    func closePins() {
        for pin in pins { pin.close() }
        pins = []
    }
}

// MARK: - Choosing an area

/// Dims the screens and lets you drag a box over what to capture
/// (Esc or a right-click gives up).
final class AreaSelector {
    private var panels: [NSPanel] = []
    private var anchor: NSPoint?
    private(set) var area: NSRect?
    /// Called once, with the box or nil. (Tests set it to try the box without windows.)
    var completion: ((NSRect?) -> Void)?
    /// A click without a drag chooses the whole screen it's on (recording).
    var clickPicksScreen = false

    /// A photograph of a screen, taken before the dimming began.
    struct FrozenScreen {
        let frame: NSRect
        let image: CGImage
    }

    private(set) var frozen: [FrozenScreen] = []

    /// Tests give it a photograph without opening any windows.
    func setFrozenForTesting(_ screens: [FrozenScreen]) { frozen = screens }
    /// The screen the drag began on (with frozen screens the box stays inside it).
    private var anchorFrame: NSRect?

    /// Photographs every screen, right now. Empty if macOS won't (no permission).
    static func freezeScreens(cursor: Bool = false) async -> [FrozenScreen] {
        guard let content = try? await SCShareableContent.current else { return [] }
        var shots: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let configuration = SCStreamConfiguration()
            configuration.width = Int((CGFloat(display.width) * screen.backingScaleFactor).rounded())
            configuration.height = Int((CGFloat(display.height) * screen.backingScaleFactor).rounded())
            configuration.showsCursor = cursor
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                shots.append(FrozenScreen(frame: screen.frame, image: image))
            }
        }
        return shots
    }

    /// The part of the frozen screen under `area`, in the screen's own pixels.
    func picture(of area: NSRect) -> CGImage? {
        guard let shot = frozen.first(where: { $0.frame.intersects(area) }) else { return nil }
        let frame = shot.frame
        let inside = area.intersection(frame)
        let (sx, sy) = (CGFloat(shot.image.width) / frame.width, CGFloat(shot.image.height) / frame.height)
        let pixels = CGRect(
            x: (inside.minX - frame.minX) * sx, y: (frame.maxY - inside.maxY) * sy,
            width: inside.width * sx, height: inside.height * sy
        ).integral
        return shot.image.cropping(to: pixels)
    }

    func start(frozen: [FrozenScreen] = [], completion: @escaping (NSRect?) -> Void) {
        self.completion = completion
        self.frozen = frozen
        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), selector: self)
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)
        }
        NSApp.activate()
        for panel in panels { panel.makeKeyAndOrderFront(nil) }
    }

    func begin(at point: NSPoint) {
        anchor = point
        anchorFrame = frozen.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }?.frame
        area = NSRect(origin: point, size: .zero)
        redraw()
    }

    func drag(to point: NSPoint) {
        guard let anchor else { return }
        var point = point
        if let anchorFrame {
            point.x = min(max(point.x, anchorFrame.minX), anchorFrame.maxX)
            point.y = min(max(point.y, anchorFrame.minY), anchorFrame.maxY)
        }
        area = NSRect(
            x: min(anchor.x, point.x), y: min(anchor.y, point.y),
            width: abs(anchor.x - point.x), height: abs(anchor.y - point.y)
        )
        redraw()
    }

    func end() {
        guard let area, area.width >= 4, area.height >= 4 else {
            if clickPicksScreen, let anchor,
               let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) }) {
                finish(screen.frame)
                return
            }
            finish(nil)
            return
        }
        finish(area)
    }

    func finish(_ chosen: NSRect?) {
        let done = completion
        completion = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        done?(chosen)
    }

    private func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }
}

private final class SelectionPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private unowned let selector: AreaSelector

    init(frame: NSRect, selector: AreaSelector) {
        self.selector = selector
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) { selector.begin(at: screenPoint(event)) }
    override func mouseDragged(with event: NSEvent) { selector.drag(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { selector.end() }
    override func rightMouseDown(with event: NSEvent) { selector.finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { selector.finish(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The frozen screen, if there is one, is the backdrop.
        if let window, let shot = selector.frozen.first(where: { $0.frame == window.frame }),
           let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .none
            ctx.draw(shot.image, in: bounds)
        }
        let shade = NSColor.black.withAlphaComponent(selector.area == nil ? 0.12 : 0.35)
        guard let window, let area = selector.area else {
            shade.setFill()
            bounds.fill()
            return
        }
        let hole = window.convertFromScreen(area)
        let path = NSBezierPath(rect: bounds)
        path.appendRect(hole)
        path.windingRule = .evenOdd
        shade.setFill()
        path.fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()

        // "640 × 480", in pixels, beside the box.
        let scale = window.backingScaleFactor
        let label = "\(Int((area.width * scale).rounded())) × \(Int((area.height * scale).rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let text = label.size(withAttributes: attributes)
        var pill = NSRect(x: hole.maxX - text.width - 18, y: hole.minY - text.height - 12, width: text.width + 14, height: text.height + 6)
        if pill.minY < bounds.minY + 2 { pill.origin.y = hole.minY + 6 }
        pill.origin.x = max(bounds.minX + 4, pill.origin.x)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attributes)
    }
}

// MARK: - Pinned screenshots

/// A picture floating above every window. Drag it, scroll to resize it,
/// double-click or press Esc to close it; right-click for more.
final class PinnedPicture: NSPanel {
    var onEdit: (URL) -> Void = { _ in }
    var onClose: () -> Void = {}
    private let picture: NSImage
    private let file: URL?

    init(picture: NSImage, file: URL?) {
        self.picture = picture
        self.file = file
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var size = picture.size
        let fit = min(1, visible.width * 0.8 / max(size.width, 1), visible.height * 0.8 / max(size.height, 1))
        size = NSSize(width: size.width * fit, height: size.height * fit)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinView(picture: picture, owner: self)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        // Near the pointer, where you were looking.
        let pointer = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(
            x: min(max(visible.minX, pointer.x - size.width / 2), visible.maxX - size.width),
            y: min(max(visible.minY, pointer.y - size.height / 2), visible.maxY - size.height)
        ))
    }

    override var canBecomeKey: Bool { true }

    func present() { orderFrontRegardless() }

    override func close() {
        super.close()
        onClose()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { close() } else { super.keyDown(with: event) }
    }

    /// Scrolling makes it bigger or smaller around its middle.
    func zoom(by delta: CGFloat) {
        let factor = 1 + delta * 0.01
        let ratio = picture.size.height / max(picture.size.width, 1)
        let width = min(max(frame.width * factor, 60), (NSScreen.main?.frame.width ?? 3000) * 2)
        let size = NSSize(width: width, height: width * ratio)
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    func copyPicture() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
    }

    func openInEditor() {
        guard let file else { return }
        onEdit(file)
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let holder = PinMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(PinMenuAction.fire), keyEquivalent: "")
            item.target = holder
            item.representedObject = holder
            menu.addItem(item)
        }
        add("Copy") { [weak self] in self?.copyPicture() }
        if file != nil { add("Edit…") { [weak self] in self?.openInEditor() } }
        menu.addItem(.separator())
        for percent in [100, 75, 50, 25] {
            add("Opacity \(percent)%") { [weak self] in self?.alphaValue = CGFloat(percent) / 100 }
        }
        menu.addItem(.separator())
        add("Close") { [weak self] in self?.close() }
        return menu
    }
}

private final class PinView: NSView {
    private let picture: NSImage
    private unowned let owner: PinnedPicture

    init(picture: NSImage, owner: PinnedPicture) {
        self.picture = picture
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        picture.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner.close() } else { super.mouseDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) { owner.zoom(by: event.scrollingDeltaY) }
    override func menu(for event: NSEvent) -> NSMenu? { owner.menu() }
}

/// Runs a closure when its menu item is chosen (the item keeps it alive).
private final class PinMenuAction: NSObject {
    private let run: () -> Void

    init(_ action: @escaping () -> Void) { run = action }

    @objc func fire() { run() }
}

// MARK: - A short message

/// A small message near the top of the screen that fades by itself:
/// "Copied 214 characters".
final class Toast: NSPanel {
    private static var current: Toast?

    static func show(_ message: String, detail: String? = nil) {
        current?.orderOut(nil)
        let toast = Toast(message: message, detail: detail)
        current = toast
        toast.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; toast.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated {
                    toast.orderOut(nil)
                    if current === toast { current = nil }
                }
            })
        }
    }

    private init(message: String, detail: String?) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let title = NSTextField(labelWithString: message)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let detail, !detail.isEmpty {
            let line = NSTextField(labelWithString: String(detail.prefix(60)))
            line.font = .systemFont(ofSize: 12)
            line.textColor = .secondaryLabelColor
            line.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(line)
        }
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -11),
        ])
        contentView = glass
        let size = glass.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 24, width: size.width, height: size.height), display: true)
    }
}
