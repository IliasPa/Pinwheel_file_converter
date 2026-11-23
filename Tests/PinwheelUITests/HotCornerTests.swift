import AppKit
import Foundation
import Testing
@testable import PinwheelUI

struct HotCornerTests {
    private let screen = NSRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func theFourCornersAreFoundAndTheMiddleIsNot() {
        let frames = [screen]
        #expect(ScreenCorner.corner(at: NSPoint(x: 0, y: 600), in: frames) == .topLeft)
        #expect(ScreenCorner.corner(at: NSPoint(x: 1000, y: 599), in: frames) == .topRight)
        #expect(ScreenCorner.corner(at: NSPoint(x: 1, y: 0), in: frames) == .bottomLeft)
        #expect(ScreenCorner.corner(at: NSPoint(x: 999, y: 1), in: frames) == .bottomRight)
        #expect(ScreenCorner.corner(at: NSPoint(x: 500, y: 300), in: frames) == nil)
        #expect(ScreenCorner.corner(at: NSPoint(x: 0, y: 300), in: frames) == nil)
        #expect(ScreenCorner.corner(at: NSPoint(x: 500, y: 600), in: frames) == nil)
    }

    @Test func aCornerNextToAnotherScreenIsNotACorner() {
        let right = NSRect(x: 1000, y: 0, width: 1000, height: 600)
        let frames = [screen, right]
        // The seam between the two: the pointer goes on through.
        #expect(ScreenCorner.corner(at: NSPoint(x: 999, y: 600), in: frames) == nil)
        #expect(ScreenCorner.corner(at: NSPoint(x: 999, y: 0), in: frames) == nil)
        // The outer corners still count.
        #expect(ScreenCorner.corner(at: NSPoint(x: 0, y: 600), in: frames) == .topLeft)
        #expect(ScreenCorner.corner(at: NSPoint(x: 2000, y: 0), in: frames) == .bottomRight)
    }

    @Test func appsAreSavedAndReadBack() {
        var apps = HotCornerApps()
        apps[.topRight] = URL(fileURLWithPath: "/Applications/Safari.app")
        let back = HotCornerApps(stored: apps.stored)
        #expect(back == apps)
        #expect(back[.topRight]?.path == "/Applications/Safari.app")
        #expect(back[.topLeft] == nil)
        #expect(HotCornerApps(stored: ["nowhere": "/x", "topLeft": ""]).isEmpty)
    }

    @Test func aCornerCanOpenAFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var apps = HotCornerApps()
        apps[.bottomLeft] = folder
        #expect(HotCornerApps(stored: apps.stored)[.bottomLeft] == folder)
        let monitor = HotCornerMonitor()
        monitor.isFullScreenInFront = { false }
        monitor.apps = { apps }
        monitor.delay = { .instant }
        var opened: [URL] = []
        monitor.open = { opened.append($0) }
        monitor.update(corner: .bottomLeft, buttonsDown: false)
        #expect(opened == [folder])
    }

    @Test func settingsKeepTheCorners() {
        let name = "PinwheelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = SettingsStore(defaults: defaults)
        #expect(store.hotCornersEnabled)
        #expect(store.hotCornerApps.isEmpty)
        store.hotCornerApps[.bottomLeft] = URL(fileURLWithPath: "/System/Applications/Notes.app")
        store.hotCornerDelay = .long
        let again = SettingsStore(defaults: defaults)
        #expect(again.hotCornerApps[.bottomLeft]?.path == "/System/Applications/Notes.app")
        #expect(again.hotCornerDelay == .long)
        #expect(again.hotCornersSkipFullScreen, "on by default")
        again.hotCornersSkipFullScreen = false
        #expect(SettingsStore(defaults: defaults).hotCornersSkipFullScreen == false)
        again.resetToDefaults()
        #expect(again.hotCornersSkipFullScreen)
        #expect(again.hotCornerApps.isEmpty)
    }

    @Test func aVisitOpensTheAppOnceAndOnlyWhenNoButtonIsHeld() {
        let monitor = HotCornerMonitor()
        monitor.isFullScreenInFront = { false }
        var opened: [String] = []
        var apps = HotCornerApps()
        apps[.topLeft] = URL(fileURLWithPath: "/Applications/Safari.app")
        monitor.apps = { apps }
        monitor.delay = { .instant }
        monitor.open = { opened.append($0.lastPathComponent) }

        monitor.update(corner: .topLeft, buttonsDown: true)  // dragging: ignored
        monitor.update(corner: nil, buttonsDown: false)
        #expect(opened.isEmpty)
        monitor.update(corner: .topLeft, buttonsDown: false)
        monitor.update(corner: .topLeft, buttonsDown: false)  // still resting
        #expect(opened == ["Safari.app"])
        monitor.update(corner: .topRight, buttonsDown: false)  // a corner with no app
        monitor.update(corner: .topLeft, buttonsDown: false)  // back again: once more
        #expect(opened == ["Safari.app", "Safari.app"])
        monitor.isEnabled = { false }
        monitor.update(corner: nil, buttonsDown: false)
        monitor.update(corner: .topLeft, buttonsDown: false)
        #expect(opened.count == 2)
    }

    @Test func leavingBeforeTheDelayCancelsIt() async throws {
        let monitor = HotCornerMonitor()
        monitor.isFullScreenInFront = { false }
        var opened = 0
        var apps = HotCornerApps()
        apps[.topLeft] = URL(fileURLWithPath: "/Applications/Safari.app")
        monitor.apps = { apps }
        monitor.delay = { .short }
        monitor.open = { _ in opened += 1 }
        monitor.update(corner: .topLeft, buttonsDown: false)
        monitor.update(corner: nil, buttonsDown: false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(opened == 0)
        monitor.update(corner: .topLeft, buttonsDown: false)
        // The main thread is shared with other tests: give it time.
        for _ in 0..<100 where opened == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(opened == 1)
    }
}

struct HotCornerFullScreenTests {
    @Test func aGameOrFullScreenAppKeepsTheCornerQuiet() async throws {
        let monitor = HotCornerMonitor()
        var opened = 0
        var fullScreen = true
        var skip = true
        var apps = HotCornerApps()
        apps[.topLeft] = URL(fileURLWithPath: "/Applications/Safari.app")
        monitor.apps = { apps }
        monitor.delay = { .instant }
        monitor.open = { _ in opened += 1 }
        monitor.isFullScreenInFront = { fullScreen }
        monitor.skipsFullScreen = { skip }

        monitor.update(corner: .topLeft, buttonsDown: false)
        #expect(opened == 0, "full screen in front: nothing opens")
        monitor.update(corner: nil, buttonsDown: false)
        skip = false  // the switch is off: corners work everywhere
        monitor.update(corner: .topLeft, buttonsDown: false)
        #expect(opened == 1)
        monitor.update(corner: nil, buttonsDown: false)
        skip = true
        fullScreen = false  // a normal window in front
        monitor.update(corner: .topLeft, buttonsDown: false)
        #expect(opened == 2)
    }

    @Test func aWaitingCornerChecksAgainWhenTheDelayEnds() async throws {
        let monitor = HotCornerMonitor()
        var opened = 0
        var fullScreen = false
        var apps = HotCornerApps()
        apps[.topLeft] = URL(fileURLWithPath: "/Applications/Safari.app")
        monitor.apps = { apps }
        monitor.delay = { .short }
        monitor.open = { _ in opened += 1 }
        monitor.isFullScreenInFront = { fullScreen }
        monitor.update(corner: .topLeft, buttonsDown: false)
        fullScreen = true  // a game starts while the pointer rests
        try await Task.sleep(for: .seconds(0.6))
        #expect(opened == 0)
    }

    @Test func ourOwnWindowsAreNotFullScreen() {
        // The test runner isn't a game or a full-screen app.
        #expect(HotCornerMonitor.fullScreenInFront() == false || NSWorkspace.shared.frontmostApplication != nil)
    }
}
