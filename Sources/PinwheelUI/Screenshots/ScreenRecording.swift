import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit
import SwiftUI

// MARK: - Drawing on the screen while recording

/// What the pointer does over the recorded area.
enum LiveTool: String, CaseIterable, Identifiable {
    /// Clicks go through to the apps (nothing is drawn).
    case pointer
    case pen, arrow, box, highlight

    var id: Self { self }

    var title: String {
        switch self {
        case .pointer: "Use apps (draw nothing)"
        case .pen: "Pen"
        case .arrow: "Arrow"
        case .box: "Box"
        case .highlight: "Highlighter"
        }
    }

    var symbolName: String {
        switch self {
        case .pointer: "cursorarrow"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .highlight: "highlighter"
        }
    }
}

/// A mark drawn on the screen during a recording, in the area's own points
/// (y down from its top left).
struct LiveMark {
    var tool: LiveTool
    var color: NSColor
    var points: [CGPoint]
    /// When the drag ended (nil while it's being drawn).
    var finished: Date?

    /// How long a mark stays fully visible, and how long it then takes to go.
    static let hold: TimeInterval = 2.5
    static let fade: TimeInterval = 0.8

    /// 1 while it's shown, falling to 0 as it fades (only when marks fade).
    func opacity(at now: Date, fades: Bool) -> Double {
        guard fades, let finished else { return 1 }
        let age = now.timeIntervalSince(finished) - Self.hold
        return age <= 0 ? 1 : max(0, 1 - age / Self.fade)
    }

    /// The two lines of an arrow's head, at `tip`, for a line from `start`.
    static func arrowHead(from start: CGPoint, to tip: CGPoint, length: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let spread = CGFloat.pi / 7
        return (
            CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)),
            CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        )
    }
}

/// A ring that grows and fades where you clicked.
struct ClickRing {
    var center: CGPoint
    var born: Date
    static let life: TimeInterval = 0.5

    func progress(at now: Date) -> Double { min(1, max(0, now.timeIntervalSince(born) / Self.life)) }
}

/// The recording's controls: what's being drawn and how long it's been.
@Observable
final class RecordingStatus {
    var tool = LiveTool.pointer
    var colorIndex = 0
    var fades = true
    var seconds = 0
    var isStopping = false
    /// Set by the session: marks to take away.
    @ObservationIgnored var onClear: () -> Void = {}

    static let colors: [NSColor] = [.systemRed, .systemYellow, .systemBlue, .systemGreen, .white]
    var color: NSColor { Self.colors[colorIndex % Self.colors.count] }

    /// "0:07", "12:40", "1:02:03".
    static func clock(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The see-through window over the recorded area: it shows the marks and
/// click rings, and it's in the video. With the pointer tool, clicks go
/// through it to the apps underneath.
final class LiveCanvasView: NSView {
    let status: RecordingStatus
    var showsClicks = true
    private(set) var marks: [LiveMark] = []
    private var rings: [ClickRing] = []
    private var ticker: Timer?

    init(frame: NSRect, status: RecordingStatus) {
        self.status = status
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clear() {
        marks = []
        needsDisplay = true
    }

    /// A click somewhere on the screen (global coordinates).
    func click(at point: NSPoint) {
        guard showsClicks, let window else { return }
        let inWindow = window.convertPoint(fromScreen: point)
        let local = convert(inWindow, from: nil)
        guard bounds.contains(local) else { return }
        rings.append(ClickRing(center: local, born: Date()))
        keepAnimating()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard status.tool != .pointer else { return }
        marks.append(LiveMark(tool: status.tool, color: status.color, points: [point, point], finished: nil))
        click(at: NSEvent.mouseLocation)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var mark = marks.last, mark.finished == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if mark.tool == .pen || mark.tool == .highlight {
            mark.points.append(point)
        } else {
            mark.points[1] = point
        }
        marks[marks.count - 1] = mark
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !marks.isEmpty, marks[marks.count - 1].finished == nil else { return }
        marks[marks.count - 1].finished = Date()
        keepAnimating()
    }

    /// Redraws 30 times a second while something fades or grows, then stops.
    private func keepAnimating() {
        needsDisplay = true
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        if status.fades {
            marks.removeAll { $0.finished != nil && $0.opacity(at: now, fades: true) <= 0 }
        }
        rings.removeAll { $0.progress(at: now) >= 1 }
        needsDisplay = true
        let fading = status.fades && marks.contains { $0.finished != nil }
        if rings.isEmpty && !fading {
            ticker?.invalidate()
            ticker = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for mark in marks {
            let alpha = mark.opacity(at: now, fades: status.fades)
            guard alpha > 0, let first = mark.points.first, let last = mark.points.last else { continue }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            var color = mark.color
            switch mark.tool {
            case .pointer:
                continue
            case .pen, .highlight:
                path.move(to: first)
                for point in mark.points.dropFirst() { path.line(to: point) }
                path.lineWidth = mark.tool == .highlight ? 22 : 5
                if mark.tool == .highlight { color = color.withAlphaComponent(0.4) }
            case .arrow:
                path.move(to: first)
                path.line(to: last)
                let (a, b) = LiveMark.arrowHead(from: first, to: last, length: 22)
                path.move(to: a)
                path.line(to: last)
                path.line(to: b)
                path.lineWidth = 5
            case .box:
                path.appendRect(NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
                path.lineWidth = 5
            }
            color.withAlphaComponent(color.alphaComponent * alpha).setStroke()
            path.stroke()
        }
        for ring in rings {
            let progress = ring.progress(at: now)
            let radius = 10 + 18 * progress
            let circle = NSBezierPath(ovalIn: NSRect(x: ring.center.x - radius, y: ring.center.y - radius, width: radius * 2, height: radius * 2))
            circle.lineWidth = 3
            NSColor.systemYellow.withAlphaComponent(0.9 * (1 - progress)).setStroke()
            circle.stroke()
            NSColor.systemYellow.withAlphaComponent(0.25 * (1 - progress)).setFill()
            circle.fill()
        }
    }
}

// MARK: - The recording

/// What a recording takes (from Settings).
struct RecordingOptions {
    var framesPerSecond = 30
    var sound = false
    var microphone = false
    var showsClicks = true
    var showsPointer = true
}

/// Hears from ScreenCaptureKit when the file is finished (on its own queue).
nonisolated private final class RecordingEnd: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<String?, Never>?
    private var outcome: String??

    /// Waits for the file to be finished: nil when it is, else what went wrong.
    func wait() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func end(_ problem: String?) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = .some(problem)
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: problem)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { end(nil) }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        end(error.localizedDescription)
    }
}

/// Records an area of the screen to an MP4 file. While it runs you can draw
/// on the screen (a pen, arrows, boxes, a highlighter), and clicks show as
/// rings: all of that is in the video. The little control bar isn't.
final class RecordingSession {
    let area: NSRect
    let options: RecordingOptions
    let status = RecordingStatus()
    /// Called once: the finished file, or nil (cancelled or failed).
    var onFinish: (URL?) -> Void = { _ in }

    private let file: URL
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private let end = RecordingEnd()
    private var canvas: NSPanel?
    private var canvasView: LiveCanvasView?
    private var outline: NSPanel?
    private var controls: NSPanel?
    private var clickMonitor: Any?
    private var clock: Timer?
    private var started = Date()
    private var isFinished = false

    init(area: NSRect, options: RecordingOptions) {
        self.area = area
        self.options = options
        file = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-recording-\(UUID().uuidString).mp4")
    }

    /// The pixel size of the video: even numbers, as H.264 needs.
    static func videoSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ value: CGFloat) -> Int { max(2, Int((value * scale).rounded()) / 2 * 2) }
        return (even(points.width), even(points.height))
    }

    func begin() {
        Task {
            showPanels()
            if let problem = await start() {
                Toast.show("The recording couldn't start", detail: problem)
                close()
                finishNow(nil)
                return
            }
            started = Date()
            clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.status.seconds = Int(Date().timeIntervalSince(self.started))
                }
            }
        }
    }

    /// Stop: the file is finished and handed on.
    func stop() {
        guard !isFinished else { return }
        isFinished = true
        status.isStopping = true
        Task {
            try? await stream?.stopCapture()
            let problem = stream == nil ? "It never started." : await end.wait()
            close()
            if let problem {
                Toast.show("The recording couldn't be saved", detail: problem)
                try? FileManager.default.removeItem(at: file)
                finishNow(nil)
            } else {
                finishNow(file)
            }
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        Task {
            try? await stream?.stopCapture()
            if stream != nil { _ = await end.wait() }
            close()
            try? FileManager.default.removeItem(at: file)
            finishNow(nil)
        }
    }

    private func finishNow(_ result: URL?) {
        let done = onFinish
        onFinish = { _ in }
        done(result)
    }

    // MARK: - Capturing

    /// Starts the stream and its file. Pinwheel's own windows are left out,
    /// except the drawing canvas.
    private func start() async -> String? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(area) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "The area isn't on a screen."
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            return "Check Screen Recording in System Settings › Privacy & Security."
        }
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return "The screen wasn't found." }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let canvasNumber = canvas.map { CGWindowID($0.windowNumber) }
        let kept = content.windows.filter { $0.windowID == canvasNumber }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: kept)

        let configuration = SCStreamConfiguration()
        let inside = area.intersection(screen.frame)
        configuration.sourceRect = CGRect(
            x: inside.minX - screen.frame.minX, y: screen.frame.maxY - inside.maxY, width: inside.width, height: inside.height
        )
        let size = Self.videoSize(points: inside.size, scale: screen.backingScaleFactor)
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        configuration.showsCursor = options.showsPointer
        configuration.queueDepth = 6
        configuration.capturesAudio = options.sound
        configuration.captureMicrophone = options.microphone

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = file
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: end)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            return error.localizedDescription
        }
        self.stream = stream
        self.output = output
        return nil
    }

    // MARK: - The canvas, the outline and the controls

    private func showPanels() {
        let canvas = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        canvas.level = .screenSaver
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.hasShadow = false
        canvas.ignoresMouseEvents = true
        canvas.isReleasedWhenClosed = false
        canvas.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = LiveCanvasView(frame: NSRect(origin: .zero, size: area.size), status: status)
        view.showsClicks = options.showsClicks
        canvas.contentView = view
        canvas.orderFrontRegardless()
        self.canvas = canvas
        canvasView = view
        status.onClear = { [weak view] in view?.clear() }

        // The outline sits just outside the area, so it isn't in the video.
        let frame = area.insetBy(dx: -4, dy: -4)
        let outline = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.level = .screenSaver
        outline.isOpaque = false
        outline.backgroundColor = .clear
        outline.hasShadow = false
        outline.ignoresMouseEvents = true
        outline.isReleasedWhenClosed = false
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        outline.contentView = RecordingOutlineView(frame: NSRect(origin: .zero, size: frame.size))
        outline.orderFrontRegardless()
        self.outline = outline

        let hosting = NSHostingView(rootView: RecordingControls(
            status: status, stop: { [weak self] in self?.stop() }, cancel: { [weak self] in self?.cancel() }
        ))
        let size = NSSize(width: 470, height: 46)
        hosting.frame = NSRect(origin: .zero, size: size)
        let controls = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controls.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        controls.isOpaque = false
        controls.backgroundColor = .clear
        controls.hasShadow = true
        controls.isReleasedWhenClosed = false
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        controls.contentView = hosting
        controls.setFrameOrigin(ScrollingSession.controlsOrigin(for: size, around: area))
        controls.orderFrontRegardless()
        self.controls = controls

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvasView?.click(at: NSEvent.mouseLocation) }
        }
        observeTool()
    }

    /// The canvas takes the pointer only while a drawing tool is chosen.
    private func observeTool() {
        withObservationTracking {
            _ = status.tool
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let canvas = self.canvas else { return }
                canvas.ignoresMouseEvents = self.status.tool == .pointer
                self.observeTool()
            }
        }
    }

    private func close() {
        clock?.invalidate()
        clock = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        for panel in [canvas, outline, controls] { panel?.orderOut(nil) }
        canvas = nil
        canvasView = nil
        outline = nil
        controls = nil
    }
}

private final class RecordingOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}

private struct RecordingControls: View {
    @Bindable var status: RecordingStatus
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text(RecordingStatus.clock(status.seconds))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 44, alignment: .leading)
            Divider().frame(height: 22)
            ForEach(LiveTool.allCases) { tool in
                Button { status.tool = tool } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(status.tool == tool ? Color.accentColor.opacity(0.3) : .clear))
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
            Divider().frame(height: 22)
            ForEach(RecordingStatus.colors.indices, id: \.self) { index in
                Button { status.colorIndex = index } label: {
                    Circle()
                        .fill(Color(nsColor: RecordingStatus.colors[index]))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(status.colorIndex == index ? 0.9 : 0.2), lineWidth: status.colorIndex == index ? 2 : 0.5))
                }
                .buttonStyle(.plain)
            }
            Button { status.fades.toggle() } label: {
                Image(systemName: status.fades ? "timer" : "pin")
            }
            .buttonStyle(.plain)
            .help(status.fades ? "Marks fade after a few seconds (click to keep them)" : "Marks stay (click to make them fade)")
            Button { status.onClear() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .help("Take all marks away")
            Spacer(minLength: 2)
            Button("Cancel", action: cancel)
            Button("Stop", action: stop)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(status.isStopping)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(width: 470, height: 46)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
