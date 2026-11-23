import AppKit
import AVFoundation
import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

struct RecordingPartsTests {
    @Test func videoSizeIsEvenPixels() {
        let size = RecordingSession.videoSize(points: CGSize(width: 301, height: 151), scale: 1)
        #expect(size.width == 300 && size.height == 150)
        let retina = RecordingSession.videoSize(points: CGSize(width: 300.4, height: 200), scale: 2)
        #expect(retina.width == 600 && retina.height == 400)
        let tiny = RecordingSession.videoSize(points: CGSize(width: 0.2, height: 0.2), scale: 1)
        #expect(tiny.width == 2 && tiny.height == 2)
    }

    @Test func theClockReadsLikeAClock() {
        #expect(RecordingStatus.clock(7) == "0:07")
        #expect(RecordingStatus.clock(760) == "12:40")
        #expect(RecordingStatus.clock(3723) == "1:02:03")
    }

    @Test func marksStayThenFade() {
        let done = Date()
        let mark = LiveMark(tool: .pen, color: .red, points: [.zero, CGPoint(x: 5, y: 5)], finished: done)
        #expect(mark.opacity(at: done, fades: true) == 1)
        #expect(mark.opacity(at: done.addingTimeInterval(LiveMark.hold + LiveMark.fade / 2), fades: true) - 0.5 < 0.001)
        #expect(mark.opacity(at: done.addingTimeInterval(LiveMark.hold + LiveMark.fade + 1), fades: true) == 0)
        #expect(mark.opacity(at: done.addingTimeInterval(100), fades: false) == 1, "pinned marks stay")
        let drawing = LiveMark(tool: .pen, color: .red, points: [], finished: nil)
        #expect(drawing.opacity(at: done.addingTimeInterval(100), fades: true) == 1, "still being drawn")
    }

    @Test func anArrowHeadPointsBackAlongTheLine() {
        let (a, b) = LiveMark.arrowHead(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), length: 20)
        #expect(a.x < 100 && b.x < 100)
        #expect(abs(a.y + b.y) < 0.001, "the two sides mirror each other")
        #expect(abs(hypot(100 - a.x, a.y) - 20) < 0.001)
    }

    @Test func aClickRingGrowsForHalfASecond() {
        let born = Date()
        let ring = ClickRing(center: .zero, born: born)
        #expect(ring.progress(at: born) == 0)
        #expect(ring.progress(at: born.addingTimeInterval(ClickRing.life / 2)) == 0.5)
        #expect(ring.progress(at: born.addingTimeInterval(5)) == 1)
    }

    @Test func drawingMakesMarksOnlyWithADrawingTool() throws {
        let status = RecordingStatus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        let view = LiveCanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), status: status)
        window.contentView = view
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        view.mouseDown(with: try event(.leftMouseDown, 10, 10))
        #expect(view.marks.isEmpty, "the pointer tool draws nothing")

        status.tool = .arrow
        status.colorIndex = 2
        view.mouseDown(with: try event(.leftMouseDown, 10, 90))
        view.mouseDragged(with: try event(.leftMouseDragged, 50, 50))
        view.mouseDragged(with: try event(.leftMouseDragged, 150, 20))
        view.mouseUp(with: try event(.leftMouseUp, 150, 20))
        #expect(view.marks.count == 1)
        let arrow = try #require(view.marks.first)
        #expect(arrow.points.count == 2, "an arrow keeps its two ends")
        #expect(arrow.points[0] == CGPoint(x: 10, y: 10), "y counts down from the top")
        #expect(arrow.points[1] == CGPoint(x: 150, y: 80))
        #expect(arrow.color == RecordingStatus.colors[2])
        #expect(arrow.finished != nil)

        status.tool = .pen
        view.mouseDown(with: try event(.leftMouseDown, 10, 10))
        for x in stride(from: 20, through: 60, by: 10) {
            view.mouseDragged(with: try event(.leftMouseDragged, CGFloat(x), 10))
        }
        view.mouseUp(with: try event(.leftMouseUp, 60, 10))
        #expect(view.marks.count == 2 && view.marks[1].points.count == 7)
        view.clear()
        #expect(view.marks.isEmpty)
    }

    @Test func settingsHaveRecordingDefaults() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = SettingsStore(defaults: defaults)
        #expect(store.recordingFramesPerSecond == 30)
        #expect(!store.recordingSound && !store.recordingMicrophone)
        #expect(store.recordingShowsClicks)
        #expect(store.screenshotShortcuts[.record] == ScreenshotMode.record.defaultShortcut)
        #expect(ScreenshotMode.record.defaultShortcut.title.contains("9"))
        store.recordingFramesPerSecond = 60
        #expect(SettingsStore(defaults: defaults).recordingFramesPerSecond == 60)
        defaults.set(45, forKey: "recordingFramesPerSecond")
        #expect(SettingsStore(defaults: defaults).recordingFramesPerSecond == 30, "only 30 or 60")
    }

    @Test func aClickWithoutADragChoosesTheWholeScreen() throws {
        let screen = try #require(NSScreen.screens.first)
        let selector = AreaSelector()
        var chosen: NSRect??
        selector.completion = { chosen = .some($0) }
        selector.clickPicksScreen = true
        selector.begin(at: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        selector.end()
        #expect(chosen == .some(screen.frame))

        let plain = AreaSelector()
        var picked: NSRect??
        plain.completion = { picked = .some($0) }
        plain.begin(at: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        plain.end()
        #expect(picked == .some(nil), "a screenshot click gives up, as before")
    }
}

/// Records a second of the screen for real. Needs Screen Recording for the
/// program running the tests, so it's skipped without it.
struct RealRecordingTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func aSecondOfTheScreenBecomesAnMP4() async throws {
        let screen = try #require(NSScreen.screens.first)
        let area = NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 321, height: 201)
        let session = RecordingSession(area: area, options: RecordingOptions())
        var result: URL??
        session.onFinish = { result = .some($0) }
        session.begin()
        try await Task.sleep(for: .seconds(1.5))
        session.stop()
        for _ in 0..<200 where result == nil { try await Task.sleep(for: .milliseconds(50)) }
        let finished = try #require(result)
        let file = try #require(finished)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
        #expect(try await asset.load(.duration).seconds > 0.5)
    }
}

/// The menu-bar icon › Record the screen: a line of its own, under Screenshot.
@MainActor
struct MenuBarRecordTests {
    @Test func recordingHasItsOwnLineUnderScreenshot() throws {
        let scratch = try Scratch()
        let history = ScreenshotHistory(file: scratch.url.appendingPathComponent("history.json"))
        let menu = MenuBarTesting.menu(history: history)
        let titles = menu.items.map(\.title)
        let screenshot = try #require(titles.firstIndex(of: "Screenshot"))
        #expect(titles[screenshot + 1] == ScreenshotMode.record.title)
        let record = menu.items[screenshot + 1]
        #expect(record.keyEquivalent == "9")
        #expect(record.keyEquivalentModifierMask == [.option, .command])
        // Not twice: the Screenshot submenu no longer lists it.
        let captures = try #require(menu.items[screenshot].submenu).items.map(\.title)
        #expect(!captures.contains(ScreenshotMode.record.title))
        #expect(captures.contains(ScreenshotMode.area.title))
    }
}
