import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import PinwheelCore

/// What the little control box beside a scrolling capture says.
@Observable
final class ScrollingStatus {
    var message = "Scroll down slowly. Pinwheel joins what it sees."
    var pixels = 0
    var isWorking = false
}

/// A scrolling screenshot: you choose an area and scroll what's in it, and
/// Pinwheel takes pictures of it as it moves and joins them into one tall one.
/// Pressing the shortcut again (or Done) finishes; Cancel throws it away.
final class ScrollingSession {
    let area: NSRect
    let status = ScrollingStatus()
    /// Called once: the joined picture, or nil if cancelled.
    var onFinish: (CGImage?) -> Void = { _ in }

    private var stitcher = ScrollStitcher()
    private var loop: Task<Void, Never>?
    private var outline: NSPanel?
    private var controls: NSPanel?
    private var isFinished = false
    private var source: (filter: SCContentFilter, configuration: SCStreamConfiguration)?

    /// What the stitcher does on a background thread.
    private struct Work: @unchecked Sendable {
        var stitcher: ScrollStitcher
        let frame: CGImage
        var outcome = ScrollStitcher.Outcome.unchanged
    }

    init(area: NSRect) {
        self.area = area
    }

    // MARK: - Running

    func begin() {
        Task {
            guard await prepare() else {
                Toast.show("The scrolling capture couldn't start", detail: "Check Screen Recording in Settings › Screenshots.")
                finishNow(nil)
                return
            }
            showPanels()
            loop = Task { await run() }
        }
    }

    /// Done: one last picture, then the joined result.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        status.isWorking = true
        status.message = "Joining…"
        Task {
            loop?.cancel()
            await loop?.value
            if let frame = await grab() { await add(frame) }
            finishNow(stitcher.result())
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        loop?.cancel()
        finishNow(nil)
    }

    private func finishNow(_ picture: CGImage?) {
        outline?.orderOut(nil)
        controls?.orderOut(nil)
        outline = nil
        controls = nil
        let done = onFinish
        onFinish = { _ in }
        done(picture)
    }

    private func run() async {
        while !Task.isCancelled {
            if let frame = await grab() {
                let outcome = await add(frame)
                if outcome == .full {
                    Toast.show("That's as tall as it can go")
                    finish()
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    @discardableResult
    private func add(_ frame: CGImage) async -> ScrollStitcher.Outcome {
        let done = await Self.process(Work(stitcher: stitcher, frame: frame))
        stitcher = done.stitcher
        switch done.outcome {
        case .started, .added:
            status.pixels = stitcher.resultHeight
            status.message = "Keep scrolling down, then press Done."
        case .lost:
            status.message = "Too fast to follow: scroll back up a little."
        case .unchanged, .full:
            break
        }
        return done.outcome
    }

    @concurrent
    nonisolated private static func process(_ work: Work) async -> Work {
        var work = work
        work.outcome = work.stitcher.add(work.frame)
        return work
    }

    // MARK: - Taking pictures of the area

    /// The screen the area is on, with a filter that leaves Pinwheel's own
    /// windows (the outline and the control box) out of the pictures.
    private func prepare() async -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(area) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let content = try? await SCShareableContent.current,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return false }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        let inside = area.intersection(screen.frame)
        // The area counts from the screen's top left, in points.
        configuration.sourceRect = CGRect(
            x: inside.minX - screen.frame.minX, y: screen.frame.maxY - inside.maxY, width: inside.width, height: inside.height
        )
        configuration.width = Int((inside.width * screen.backingScaleFactor).rounded())
        configuration.height = Int((inside.height * screen.backingScaleFactor).rounded())
        configuration.showsCursor = false
        source = (SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: []), configuration)
        return true
    }

    private func grab() async -> CGImage? {
        guard let source else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: source.configuration)
    }

    // MARK: - The outline and the control box

    private func showPanels() {
        let frame = area.insetBy(dx: -3, dy: -3)
        let outline = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.level = .screenSaver
        outline.isOpaque = false
        outline.backgroundColor = .clear
        outline.hasShadow = false
        outline.ignoresMouseEvents = true  // scrolling goes through to what's underneath
        outline.isReleasedWhenClosed = false
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        outline.contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size))
        outline.orderFrontRegardless()
        self.outline = outline

        let hosting = NSHostingView(rootView: ScrollingControls(
            status: status, done: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.cancel() }
        ))
        let size = NSSize(width: 330, height: 64)
        hosting.frame = NSRect(origin: .zero, size: size)
        let controls = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controls.level = .screenSaver
        controls.isOpaque = false
        controls.backgroundColor = .clear
        controls.hasShadow = true
        controls.isReleasedWhenClosed = false
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        controls.contentView = hosting
        controls.setFrameOrigin(Self.controlsOrigin(for: size, around: area))
        controls.orderFrontRegardless()
        self.controls = controls
    }

    /// Below the area if there's room, else above it, else inside it (the
    /// pictures leave the box out anyway).
    static func controlsOrigin(for size: NSSize, around area: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(area) }?.frame ?? area
        let x = min(max(area.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        if area.minY - size.height - 10 >= screen.minY { return NSPoint(x: x, y: area.minY - size.height - 10) }
        if area.maxY + size.height + 10 <= screen.maxY { return NSPoint(x: x, y: area.maxY + 10) }
        return NSPoint(x: x, y: area.minY + 12)
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}

private struct ScrollingControls: View {
    var status: ScrollingStatus
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.pixels > 0 ? "\(status.pixels) px captured" : "Ready")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text(status.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Cancel", action: cancel)
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .disabled(status.isWorking)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 330, height: 64)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
