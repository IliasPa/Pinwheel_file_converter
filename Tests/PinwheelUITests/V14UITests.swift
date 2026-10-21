import AppKit
import CoreImage
import Foundation
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

private func freshDefaults() -> UserDefaults {
    let name = "PinwheelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Keys

struct WheelKeysTests {
    @Test func exactlyAWheelsKeysOpenIt() {
        let keys = WheelKeys.standard
        #expect(keys.mode(for: [.shift]) == .convert)
        #expect(keys.mode(for: [.option, .shift]) == .tools)
        #expect(keys.mode(for: [.control, .shift]) == .actions)
        #expect(keys.mode(for: [.option]) == nil)
        #expect(keys.mode(for: [.command, .shift]) == nil)
        #expect(keys.mode(for: []) == nil)
        #expect(keys.clashes.isEmpty)
    }

    @Test func tangerineStyleKeys() {
        var keys = WheelKeys.standard
        keys[.tools] = [.command]
        keys[.actions] = [.control]
        #expect(keys.mode(for: [.command]) == .tools)
        #expect(keys.mode(for: [.control]) == .actions)
        #expect(keys.mode(for: [.shift]) == .convert)
        keys[.actions] = [.command]
        #expect(keys.clashes == [.tools, .actions])
        #expect(keys.mode(for: [.command]) == .tools, "the first of two wheels with the same keys wins")
    }

    @Test func keepingTheWheelOpen() {
        let keys = WheelKeys.standard
        // Letting go closes it…
        #expect(DragMonitor.mode(for: [], keys: keys, shown: .convert, keepsOpen: false) == nil)
        // …unless it stays open, until a drop or Esc.
        #expect(DragMonitor.mode(for: [], keys: keys, shown: .convert, keepsOpen: true) == .convert)
        #expect(DragMonitor.mode(for: [.option, .shift], keys: keys, shown: .convert, keepsOpen: true) == .tools)
        #expect(DragMonitor.mode(for: [.command], keys: keys, shown: .tools, keepsOpen: true) == .tools)
        #expect(DragMonitor.mode(for: [], keys: keys, shown: nil, keepsOpen: true) == nil, "it opens with keys only")
    }

    @Test func keysFromMacOS() {
        #expect(ModifierKeys([.shift, .option, .capsLock, .function]) == [.shift, .option])
        #expect(ModifierKeys([.option, .shift]).symbols == "⌥⇧")
        #expect(ModifierKeys([.option, .shift]).title == "⌥ Option + ⇧ Shift")
        #expect(ModifierKeys([.command, .control]).symbols == "⌃⌘")
    }
}

// MARK: - Settings

struct V14SettingsTests {
    @Test func keysAndChoicesAreRememberedAndReset() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.wheelKeys == .standard && !store.keepWheelOpen && store.terminalApp == "com.apple.Terminal")
        store.wheelKeys[.tools] = [.command]
        store.keepWheelOpen = true
        store.setOnWheel(.file(.airDrop), for: .image, in: .actions, false)
        store.terminalApp = TerminalApp.iTerm.rawValue
        store.webpQuality = 0.6

        let again = SettingsStore(defaults: defaults)
        #expect(again.wheelKeys[.tools] == [.command] && again.wheelKeys[.convert] == [.shift])
        #expect(again.keepWheelOpen)
        #expect(!again.isOnWheel(.file(.airDrop), for: .video, in: .actions), "file actions are the same for every kind")
        #expect(again.shownCount(for: .pdf, in: .actions) == FormatCatalog.fileActions.count - 1)
        #expect(again.terminalApp == TerminalApp.iTerm.rawValue)
        #expect(again.conversionOptions.webpQuality == 0.6)

        again.resetToDefaults()
        #expect(again.wheelKeys == .standard && !again.keepWheelOpen && again.hiddenActions.isEmpty)
        #expect(again.terminalApp == "com.apple.Terminal")
        #expect(again.webpQuality == ConversionOptions().webpQuality && again.avifQuality == ConversionOptions().avifQuality)
    }

    @Test func helperToolsReachTheJobs() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.conversionOptions.cwebpURL == ExternalTool.cwebp.locate())
        #expect(store.isInstalled(.cwebp) == (ExternalTool.cwebp.locate() != nil))
    }

    @Test func searchFindsTheNewSettings() {
        func found(_ text: String) -> [SettingsPane] { SettingsPane.allCases.filter { $0.matches(text) } }
        #expect(found("keys") == [.wheel, .clipboard])  // the clipboard history has keys too (v1.7)
        #expect(found("airdrop") == [.tools])
        #expect(found("quick look") == [.tools])
        #expect(found("cwebp") == [.advanced])
        #expect(found("opus").contains(.conversions) && found("opus").contains(.compatibility))
        #expect(found("rar") == [.compatibility])
    }
}

// MARK: - The wheel and the keyboard

struct WheelKeyboardTests {
    private func wheel(_ store: SettingsStore = SettingsStore(defaults: freshDefaults())) -> WheelController {
        let wheel = WheelController(settings: store)
        wheel.showsOnScreen = false
        wheel.availability = { action, _ in action == .convert(.heic) ? .unavailable("Not now") : .available }
        return wheel
    }

    @Test func arrowsChooseAndReturnApplies() throws {
        let scratch = try Scratch()
        let photo = try scratch.image("photo.png")
        let wheel = wheel()
        var dropped: [WheelAction] = []
        wheel.onDrop = { _, action in dropped.append(action) }
        wheel.showForClick(urls: [photo], mode: .convert, at: NSPoint(x: 300, y: 300))

        #expect(wheel.handleKey(124))  // →
        #expect(wheel.model.hovered == .wedge(0))
        wheel.handleKey(124)
        #expect(wheel.model.hovered == .wedge(2), "HEIC is grayed out, so it's passed over")
        wheel.handleKey(123)  // ←
        #expect(wheel.model.hovered == .wedge(0))
        wheel.handleKey(123)
        #expect(wheel.model.hovered == .wedge(wheel.model.items.count - 1), "round the wheel")
        wheel.handleKey(48)  // Tab
        #expect(wheel.model.mode == .tools)
        wheel.handleKey(124)
        wheel.handleKey(36)  // Return
        #expect(dropped == [wheel.model.items[0].action])
        #expect(!wheel.handleKey(0), "other keys go on to Finder")
    }

    @Test func returnDuringADragTakesTheDropQuietly() throws {
        let scratch = try Scratch()
        let photo = try scratch.image("photo.png")
        let wheel = wheel()
        var dropped: [WheelAction] = []
        wheel.onDrop = { _, action in dropped.append(action) }
        wheel.show(urls: [photo], mode: .convert, at: NSPoint(x: 300, y: 300))
        wheel.handleKey(125)  // ↓
        wheel.handleKey(76)  // Enter
        #expect(dropped == [.convert(.jpeg)])
        #expect(wheel.model.confirmed)
        // The drop when the mouse is let go does nothing more…
        wheel.handleKey(124)
        wheel.setMode(.tools)
        #expect(wheel.model.mode == .convert && wheel.model.hovered == .wedge(0), "and nothing changes now")
        #expect(dropped.count == 1)
    }

    @Test func escClosesAndTellsTheDrag() throws {
        let scratch = try Scratch()
        let wheel = wheel()
        var dismissed = false
        wheel.onDismiss = { dismissed = true }
        wheel.show(urls: [try scratch.image("photo.png")], mode: .convert, at: NSPoint(x: 300, y: 300))
        #expect(wheel.handleKey(53))
        #expect(dismissed)
    }

    @Test func theFileActionsWheel() throws {
        let scratch = try Scratch()
        let wheel = wheel()
        // A folder gets it too, every action usable.
        wheel.showForClick(urls: [scratch.url], mode: .actions, at: NSPoint(x: 300, y: 300))
        #expect(wheel.model.items.map(\.action) == FormatCatalog.fileActions)
        #expect(wheel.model.items.allSatisfy { $0.isEnabled })
        // The middle goes round the three wheels.
        wheel.handleClick(.hub)
        #expect(wheel.model.mode == .convert)
        wheel.handleClick(.hub)
        #expect(wheel.model.mode == .tools)
        wheel.handleClick(.hub)
        #expect(wheel.model.mode == .actions)
    }
}

// MARK: - File actions

struct FileActionsTests {
    private func actions() -> FileActions {
        let actions = FileActions()
        actions.pasteboard = NSPasteboard(name: NSPasteboard.Name("PinwheelTest-\(UUID().uuidString)"))
        return actions
    }

    @Test func copyAndCopyPath() throws {
        let scratch = try Scratch()
        let a = try scratch.image("a.png"), b = try scratch.image("b.png")
        let actions = actions()
        defer { actions.pasteboard.releaseGlobally() }
        actions.copy([a, b])
        let urls = actions.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL) == [a, b].map(\.standardizedFileURL))
        actions.copyPaths([a, b])
        #expect(actions.pasteboard.string(forType: .string) == "\(a.path)\n\(b.path)")
    }

    @Test func moveNeverReplacesAndCanBeUndone() throws {
        let scratch = try Scratch()
        let a = try scratch.image("a.png")
        let target = scratch.url.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("there already".utf8).write(to: target.appendingPathComponent("a.png"))

        let (moves, failures) = actions().move([a], to: target)
        #expect(failures.isEmpty)
        #expect(moves == [Renamer.Move(from: a, to: target.appendingPathComponent("a 2.png"))])
        #expect(!FileManager.default.fileExists(atPath: a.path))
        let kept = try String(contentsOf: target.appendingPathComponent("a.png"), encoding: .utf8)
        #expect(kept == "there already")

        let history = UndoHistory()
        history.recordMove(moves)
        #expect(history.entries.last?.title == "Move")
        history.undoLast()
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func terminalOpensEachFolderOnce() throws {
        let scratch = try Scratch()
        let a = try scratch.image("a.png"), b = try scratch.image("b.png")
        #expect(FileActions.folders(of: [a, b, scratch.url]) == [scratch.url])
        #expect(TerminalApp.installed.contains(.terminal))
    }
}

// MARK: - The pinwheel command and Read Codes

struct V14CommandTests {
    @Test func newCommands() throws {
        func job(_ command: String, _ value: String? = nil) throws -> WheelAction {
            try CommandCenter.job(for: .init(command: command, value: value, files: []), recipes: []).get().action
        }
        #expect(try job("zip") == .tool(.archive))
        #expect(try job("extract") == .tool(.extract))
        #expect(try job("convert", "webp") == .convert(.webp))
        #expect(try job("convert", "tar.gz") == .convert(.tgz))
        #expect(try job("convert", "tgz") == .convert(.tgz))
        #expect(try job("convert", "7z") == .convert(.sevenZip))
        #expect(try job("convert", "opus") == .convert(.opus))
        #expect(CommandCenter.wheel(named: "actions") == .actions)
        #expect(CommandCenter.wheel(named: "tools") == .tools)
        #expect(CommandCenter.wheel(named: nil) == .convert)
        #expect(CommandCenter.editor(named: "codes") == .codes)
    }

    @Test func readCodesFindsWhatsThere() async throws {
        let scratch = try Scratch()
        let code = scratch.url.appendingPathComponent("code.png")
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("Hello Pinwheel".utf8)]))
        let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let padded = image.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(over: CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -40, dy: -40).offsetBy(dx: 40, dy: 40)))
        try CIContext().writePNGRepresentation(of: padded, to: code, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let plain = try scratch.image("plain.png")

        let model = CodesModel(files: [code, plain])
        await model.read()
        #expect(!model.isReading && !model.foundNothing)
        #expect(model.results.map(\.codes.count) == [1, 0])
        #expect(model.results.first?.codes.first?.text == "Hello Pinwheel")
    }
}
