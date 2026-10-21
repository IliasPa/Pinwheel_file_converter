import AppKit
import AVFoundation
import Foundation
import PDFKit
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(25))
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "PinwheelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// MARK: - Undo

struct UndoTests {
    @Test func undoTakesBackAJobAndPutsTheOriginalBack() async throws {
        let scratch = try Scratch()
        let source = try scratch.image("photo.png")
        let trash = scratch.url.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        // A pretend Trash: a folder the files are moved into.
        let toTrash: (URL) throws -> URL = { url in
            let place = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: place)
            return place
        }

        let history = UndoHistory()
        history.moveToTrash = { _ = try toTrash($0) }
        let queue = JobQueue()
        queue.shouldTrashOriginals = { true }
        queue.moveToTrash = toTrash
        queue.onBatchFinished = { history.record(batch: $0) }
        queue.enqueue(files: [SourceFile(url: source)], action: .convert(.jpeg))
        try await waitUntil { queue.isIdle && history.last != nil }

        let output = try #require(queue.jobs.first?.outputs.first)
        #expect(exists(output) && !exists(source))
        #expect(history.last?.title == "Convert to JPEG")

        let report = try #require(history.undoLast())
        #expect(report.problems.isEmpty)
        #expect(exists(source), "the original is back")
        #expect(!exists(output), "the new file went to the Trash")
        #expect(history.last == nil)
        #expect(history.undoLast() == nil)
    }

    @Test func renamesComeBackAndWhatCantIsSaid() throws {
        let scratch = try Scratch()
        let a = try scratch.image("a.png"), b = try scratch.image("b.png")
        let moves = try Renamer.apply([
            .init(from: a, to: scratch.url.appendingPathComponent("x.png")),
            .init(from: b, to: scratch.url.appendingPathComponent("y.png")),
        ])
        let history = UndoHistory()
        history.recordRename(moves)
        #expect(history.last?.title == "Rename (2 files)")
        // Someone moved y.png away in the meantime.
        try FileManager.default.moveItem(at: scratch.url.appendingPathComponent("y.png"), to: scratch.url.appendingPathComponent("moved.png"))

        let report = try #require(history.undoLast())
        #expect(exists(a))
        #expect(!exists(b))
        #expect(report.problems.count == 1 && report.problems[0].contains("moved since"))
    }

    @Test func emptiedTrashIsExplained() throws {
        let scratch = try Scratch()
        let history = UndoHistory()
        var entry = UndoHistory.Entry(title: "Compress", date: Date())
        entry.trashed = [(scratch.url.appendingPathComponent("gone.jpg"), scratch.url.appendingPathComponent("Trash/gone.jpg"))]
        history.record(entry)
        let report = try #require(history.undoLast())
        #expect(report.problems == ["gone.jpg is no longer in the Trash."])

        // Only the newest steps are kept.
        for number in 0..<30 {
            var step = UndoHistory.Entry(title: "\(number)", date: Date())
            step.created = [scratch.url]
            history.record(step)
        }
        #expect(history.entries.count == UndoHistory.limit)
        #expect(history.last?.title == "29")
    }
}

// MARK: - Settings

struct V09SettingsTests {
    @Test func newToolsWaitWhereTheWheelWasArrangedByHand() {
        let defaults = freshDefaults()
        // As saved by 0.8 after swapping Resize for Get Text.
        defaults.set(["image:tool.resize", "image:tool.stripMetadata"], forKey: "hiddenTools")
        let store = SettingsStore(defaults: defaults)
        #expect(!store.isOnWheel(.open(.sizeLimit), for: .image))
        #expect(!store.isOnWheel(.open(.rename), for: .image))
        #expect(store.isOnWheel(.tool(.extractText), for: .image), "what was chosen stays")
        #expect(store.isOnWheel(.open(.markup), for: .image))
        #expect(store.shownCount(for: .image) == FormatCatalog.maxWedges)
        // PDFs still had 0.8's defaults, so they get 0.9's.
        #expect(!store.isOnWheel(.tool(.stripMetadata), for: .pdf))
        #expect(store.isOnWheel(.tool(.makeSearchable), for: .pdf))
        #expect(store.shownCount(for: .pdf) == FormatCatalog.maxWedges)
        #expect(store.isOnWheel(.open(.sizeLimit), for: .video) && store.isOnWheel(.open(.rename), for: .audio))

        // Once known, choices stick.
        store.setOnWheel(.open(.markup), for: .image, false)
        store.setOnWheel(.open(.rename), for: .image, true)
        let again = SettingsStore(defaults: defaults)
        #expect(again.hiddenTools == store.hiddenTools)
    }

    @Test func oldDefaultsBecomeTheNewOnes() {
        let defaults = freshDefaults()
        defaults.set(["image:tool.extractText", "image:tool.stripMetadata"], forKey: "hiddenTools")
        let store = SettingsStore(defaults: defaults)
        #expect(store.hiddenTools == FormatCatalog.defaultHidden)
        #expect(store.isOnWheel(.open(.sizeLimit), for: .image) && store.isOnWheel(.open(.rename), for: .image))
    }

    @Test func customActionsJoinTheWheelWhileThereIsRoom() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.shownCount(for: .video) == 8)
        let first = Recipe(name: "Share", kind: .video, steps: [.compress])
        store.saveRecipe(first)
        #expect(store.isOnWheel(.recipe(first), for: .video))
        let second = Recipe(name: "Tiny", kind: .video, steps: [.sizeLimit(megabytes: 8)])
        store.saveRecipe(second)
        #expect(!store.isOnWheel(.recipe(second), for: .video), "the wheel was full, so it waits")
        var renamed = first
        renamed.name = "Share Now"
        store.saveRecipe(renamed)
        #expect(store.recipes.map(\.name) == ["Share Now", "Tiny"])

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.recipes == store.recipes)
        reloaded.deleteRecipe(second)
        #expect(!reloaded.hiddenTools.contains(FormatCatalog.hiddenKey(.video, .recipe(second))))
        #expect(reloaded.recipes.count == 1)
    }

    @Test func appleTextRecognitionWhenChosen() {
        let store = SettingsStore(defaults: freshDefaults())
        store.textRecognition = .apple
        #expect(store.conversionOptions.textRecognition.engine == .vision)
        #expect(store.lastSizeLimit == 10)
        store.lastSizeLimit = 25
        #expect(store.lastSizeLimit == 25)
    }
}

// MARK: - The pinwheel command

struct CommandTests {
    private func request(_ command: String, _ value: String? = nil, files: [String] = ["/tmp/a.png"]) -> CommandCenter.Request {
        CommandCenter.Request(command: command, value: value, files: files)
    }

    @Test func commandsBecomeJobs() throws {
        let mine = Recipe(name: "Instagram", kind: .image, steps: [.compress])
        func job(_ r: CommandCenter.Request) -> WheelAction? { try? CommandCenter.job(for: r, recipes: [mine]).get().action }
        #expect(job(request("convert", "jpg")) == .convert(.jpeg))
        #expect(job(request("convert", ".TIF")) == .convert(.tiff))
        #expect(job(request("convert", "xyz")) == nil)
        #expect(job(request("searchable")) == .tool(.makeSearchable))
        #expect(job(request("run", "instagram")) == .recipe(mine))
        #expect(job(request("run", "nope")) == nil)
        #expect(job(request("dance")) == nil)
        let limit = try CommandCenter.job(for: request("size-limit", "10MB"), recipes: []).get()
        #expect(limit.parameters == .sizeLimit(bytes: 10_000_000))
        #expect(CommandCenter.bytes(from: "2,5 mb") == 2_500_000)
        #expect(CommandCenter.bytes(from: "500KB") == 500_000)
        #expect(CommandCenter.bytes(from: "8") == 8_000_000)
        #expect(CommandCenter.bytes(from: "big") == nil)
        #expect(CommandCenter.editor(named: "Rename") == .rename)
    }

    @Test func answersWhenTheJobsAreDone() async throws {
        let scratch = try Scratch()
        let photo = try scratch.image("photo.png")
        let queue = JobQueue()
        let center = CommandCenter(channel: "test-\(UUID().uuidString)")
        var replies: [CommandCenter.Reply] = []
        center.send = { replies.append($0) }
        center.enqueue = { queue.enqueue(files: $0, action: $1, parameters: $2) }
        queue.onBatchFinished = { center.batchFinished($0) }
        var shown: ([URL], WheelMode)?
        center.showWheel = { shown = ($0, $1) }

        let convert = CommandCenter.Request(id: "one", command: "convert", value: "jpg", files: [photo.path])
        center.receive(convert)
        #expect(replies.map(\.state) == ["accepted"])
        try await waitUntil { replies.count == 2 }
        #expect(replies.last?.state == "finished")
        #expect(replies.last?.outputs.map { URL(fileURLWithPath: $0).lastPathComponent } == ["photo (converted).jpg"])

        // The command repeats a request until it hears back: done once only.
        center.receive(convert)
        #expect(queue.jobs.count == 1 && replies.last?.state == "accepted")

        center.availability = { _, _ in .unavailable("Drop two or more PDFs to merge them") }
        center.receive(CommandCenter.Request(id: "two", command: "merge", files: [photo.path]))
        #expect(replies.last?.state == "failed" && replies.last?.messages == ["Drop two or more PDFs to merge them"])

        center.receive(CommandCenter.Request(id: "three", command: "show", value: "tools", files: [photo.path]))
        #expect(shown?.1 == .tools && shown?.0 == [photo])
    }

    @Test func theCommandTalksToTheApp() async throws {
        let cli = Bundle(for: Scratch.self).bundleURL.deletingLastPathComponent().appendingPathComponent("PinwheelCLI")
        try #require(FileManager.default.isExecutableFile(atPath: cli.path), "PinwheelCLI wasn't built next to the tests")
        let scratch = try Scratch()
        let photo = try scratch.image("photo.png")

        func run(_ arguments: [String], channel: String) async throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = ["PINWHEEL_CHANNEL": channel, "PINWHEEL_PATIENCE": "6"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            // Keep the main thread free for the notifications while it runs,
            // for at most a minute (a command that hangs fails the test).
            for _ in 0..<2400 where process.isRunning { try await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning {
                process.terminate()
                Issue.record("pinwheel \(arguments.joined(separator: " ")) didn't finish within a minute")
            }
            process.waitUntilExit()
            let text = { (pipe: Pipe) in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
            return (process.terminationStatus, text(out), text(err))
        }

        let channel = "com.iliasmac.Pinwheel.test-\(UUID().uuidString)"
        let help = try await run(["help"], channel: channel)
        #expect(help.status == 0 && help.out.contains("Usage: pinwheel"))
        #expect(try await run(["dance", photo.path], channel: channel).status == 2)
        #expect(try await run(["convert", "jpg", scratch.url.appendingPathComponent("missing.png").path], channel: channel).status == 2)
        // Nobody listening on this channel: it says so instead of waiting forever.
        #expect(try await run(["compress", photo.path], channel: channel).status == 3)

        let queue = JobQueue()
        let center = CommandCenter(channel: channel)
        center.enqueue = { queue.enqueue(files: $0, action: $1, parameters: $2) }
        queue.onBatchFinished = { center.batchFinished($0) }
        center.start()
        let result = try await run(["convert", "jpg", photo.path], channel: channel)
        #expect(result.status == 0, "\(result.err)")
        #expect(result.out.trimmingCharacters(in: .whitespacesAndNewlines) == scratch.url.appendingPathComponent("photo (converted).jpg").path)
        center.stop()

        // Pinwheel takes the job, then goes quiet (it quit): the command says
        // so after a while instead of waiting forever.
        let quitting = CommandCenter(channel: "\(channel).quit")
        quitting.enqueue = { _, _, _ in UUID() }  // never finishes
        quitting.start()
        Task {
            try? await Task.sleep(for: .seconds(1))
            quitting.stop()
        }
        let gone = try await run(["compress", photo.path], channel: "\(channel).quit")
        #expect(gone.status == 3)
        #expect(gone.err.contains("stopped answering"))
    }
}

// MARK: - Rename window

struct RenameModelTests {
    @Test func previewThenRename() async throws {
        let scratch = try Scratch()
        let files = try ["IMG_2.png", "IMG_10.png", "IMG_1.png"].map { try scratch.image($0) }
        let model = RenameModel(urls: files)
        try await waitUntil { !model.isReading }
        #expect(model.files.map(\.lastPathComponent) == ["IMG_1.png", "IMG_2.png", "IMG_10.png"], "in natural name order")
        #expect(model.changedCount == 0 && !model.canRename)

        model.rules = [
            { var r = RenameRule(.replace); r.text = "IMG_"; r.text2 = "Beach "; return r }(),
            { var r = RenameRule(.padNumbers); r.digits = 2; return r }(),
        ]
        #expect(model.previews.map(\.newName) == ["Beach 01.png", "Beach 02.png", "Beach 10.png"])
        #expect(model.canRename)

        // Dragging names sets the order, and numbering follows it.
        model.rules = [{ var r = RenameRule(.pattern); r.text = "Day {n}"; r.digits = 0; return r }()]
        model.moveFiles(from: IndexSet(integer: 2), to: 0)
        #expect(model.order == .manual)
        #expect(model.previews.map(\.url.lastPathComponent) == ["IMG_10.png", "IMG_1.png", "IMG_2.png"])
        #expect(model.previews.map(\.newName) == ["Day 1.png", "Day 2.png", "Day 3.png"])

        var moves: [Renamer.Move] = []
        model.onRenamed = { moves = $0 }
        model.rename()
        #expect(moves.count == 3)
        #expect(exists(scratch.url.appendingPathComponent("Day 1.png")))
        #expect(!exists(files[1]))
    }

    @Test func clashesStopItAndPresetsComeBack() throws {
        let scratch = try Scratch()
        let files = try ["a.png", "b.png"].map { try scratch.image($0) }
        let model = RenameModel(urls: files)
        model.rules = [{ var r = RenameRule(.pattern); r.text = "same"; return r }()]
        #expect(model.problemCount == 2 && !model.canRename)
        model.rename()
        #expect(exists(files[0]) && exists(files[1]), "nothing happens")

        var saved: [RenamePreset] = []
        model.onPresetsChanged = { saved = $0 }
        model.savePreset(named: "  Same  ")
        #expect(saved.map(\.name) == ["Same"])
        model.rules = []
        model.apply(saved[0])
        #expect(model.rules.map(\.text) == ["same"])
        #expect(model.rules[0].id != saved[0].rules[0].id, "a copy, so the preset itself stays as it is")
        model.addRule(.ext)
        #expect(model.expanded == model.rules.last?.id)
        model.move(model.rules[1].id, by: -1)
        #expect(model.rules.first?.kind == .ext)
    }
}

// MARK: - Size limit window

struct SizeLimitModelTests {
    @Test func eachOrAllTogether() throws {
        let scratch = try Scratch()
        func file(_ name: String, megabytes: Double) throws -> SourceFile {
            let url = scratch.url.appendingPathComponent(name)
            try Data(repeating: 7, count: Int(megabytes * 1_000_000)).write(to: url)
            return SourceFile(url: url)
        }
        let files = [try file("a.jpg", megabytes: 3), try file("b.jpg", megabytes: 1), try file("c.jpg", megabytes: 0.5)]
        let model = SizeLimitModel(files: files, megabytes: 10)
        #expect(model.toShrink.isEmpty, "all fit under 10 MB")
        model.choose(2)
        #expect(model.toShrink.map(\.file.url.lastPathComponent) == ["a.jpg"])
        model.together = true
        #expect(model.toShrink.count == 3, "4.5 MB together must become 2 MB")
        let shares = model.rows.map(\.limit)
        #expect(shares.reduce(0, +) <= 2_000_000)
        #expect(shares[0] > shares[1] && shares[1] > shares[2])

        model.text = "2,5"
        #expect(model.megabytes == 2.5)
        model.text = "abc"
        #expect(model.megabytes == 2.5)
        model.tidyText()
        #expect(model.text == "2.5")

        var sent: [ConversionRequest] = []
        model.onSave = { requests, _ in sent = requests }
        model.save()
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.action == .tool(.sizeLimit) })
    }
}

// MARK: - Organize: where a dragged page lands

struct OrganizeDropTests {
    private func pdf(_ scratch: Scratch, _ name: String, pages: Int) -> SourceFile {
        let url = scratch.url.appendingPathComponent(name)
        let document = PDFDocument()
        for _ in 0..<pages { document.insert(PDFPage(), at: document.pageCount) }
        document.write(to: url)
        return SourceFile(url: url)
    }

    @Test func theBarShowsWhereItGoes() throws {
        let scratch = try Scratch()
        let model = OrganizeModel(files: [pdf(scratch, "a.pdf", pages: 2), pdf(scratch, "b.pdf", pages: 2)])
        model.dragging = "1:1"
        model.hover(OrganizeModel.DropTarget(page: "0:0", after: true))
        #expect(model.dropTarget == OrganizeModel.DropTarget(page: "0:0", after: true))
        model.dropDragged()
        #expect(model.pages.map(\.id) == ["0:0", "1:1", "0:1", "1:0"])
        #expect(model.dropTarget == nil)

        // Onto itself: no bar, nothing moves.
        model.dragging = "0:1"
        model.hover(OrganizeModel.DropTarget(page: "0:1", after: false))
        #expect(model.dropTarget == nil)

        // At the end.
        model.hover(OrganizeModel.DropTarget(page: nil))
        model.dropDragged()
        #expect(model.pages.map(\.id).last == "0:1")

        // A selected page brings the selection along.
        model.selection = ["0:0", "1:1"]
        model.dragging = "1:1"
        model.hover(OrganizeModel.DropTarget(page: "1:0", after: true))
        model.dropDragged()
        #expect(model.pages.map(\.id) == ["1:0", "0:0", "1:1", "0:1"])
        model.undo()
        #expect(model.pages.map(\.id) == ["0:0", "1:1", "1:0", "0:1"])
    }
}

// MARK: - Space shows the original

struct StudioSpaceTests {
    @Test func holdingSpaceComparesUnlessTyping() throws {
        _ = NSApplication.shared
        let scratch = try Scratch()
        let model = StudioModel(files: [SourceFile(url: try scratch.image("p.png"))], tab: .adjust, watermark: nil)
        let controller = StudioWindowController(model: model)
        let window = try #require(controller.window)
        func space(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
            )!
        }
        #expect(controller.handleSpace(space(.keyDown)))
        #expect(model.showOriginal)
        #expect(controller.handleSpace(space(.keyUp)))
        #expect(!model.showOriginal)

        // While typing, Space is a space.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        if window.firstResponder is NSText {
            #expect(!controller.handleSpace(space(.keyDown)))
            #expect(!model.showOriginal)
        }
        controller.window?.close()
    }
}

// MARK: - The wheel from Finder's menu

struct ClickWheelTests {
    @Test func clickAWedgeOrTheMiddle() async throws {
        let scratch = try Scratch()
        let photo = try scratch.image("photo.png")
        let wheel = WheelController(settings: SettingsStore(defaults: freshDefaults()))
        wheel.showsOnScreen = false
        wheel.availability = { _, _ in .available }
        var chosen: ([SourceFile], WheelAction)?
        wheel.onDrop = { chosen = ($0, $1) }

        wheel.showForClick(urls: [photo], mode: .convert, at: NSPoint(x: 300, y: 300))
        #expect(wheel.model.isClickMode && wheel.model.mode == .convert)
        wheel.handleClick(.hub)
        #expect(wheel.model.mode == .tools, "the middle switches to tools")
        let first = try #require(wheel.model.items.first)
        wheel.handleClick(.wedge(0))
        #expect(chosen?.1 == first.action && chosen?.0.map(\.url) == [photo])
        try await waitUntil { !wheel.model.isClickMode }
        #expect(!wheel.model.isClickMode)
    }

    @Test func finderSendsItsFiles() throws {
        let scratch = try Scratch()
        let a = try scratch.image("a.png"), b = try scratch.image("b.png")
        let board = NSPasteboard(name: NSPasteboard.Name("PinwheelTest-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([a as NSURL, b as NSURL])

        let provider = ServicesProvider()
        var shown: ([URL], WheelMode)?
        var opened: (Editor, [URL])?
        provider.showWheel = { shown = ($0, $1) }
        provider.openEditor = { opened = ($0, $1) }
        var error: NSString?
        provider.showToolsWheel(board, userData: nil, error: &error)
        #expect(shown?.0 == [a, b] && shown?.1 == .tools)
        provider.renameFiles(board, userData: nil, error: &error)
        #expect(opened?.0 == .rename && opened?.1 == [a, b])
        #expect(error == nil)

        board.clearContents()
        provider.showConvertWheel(board, userData: nil, error: &error)
        #expect(error != nil)
    }
}

// MARK: - The video editor with a real video

/// A short H.264 movie filmed "upright" like a phone does it: landscape
/// pixels with a quarter turn to show it portrait.
func phoneVideo(at url: URL, seconds: Int = 2) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
    ])
    input.expectsMediaDataInRealTime = false
    input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

struct MediaEditorVideoTests {
    @Test func playsTurnsAndShowsFrames() async throws {
        let scratch = try Scratch()
        let movie = scratch.url.appendingPathComponent("phone.mov")
        try await phoneVideo(at: movie)
        let model = MediaEditorModel(files: [SourceFile(url: movie)], ffmpegAvailable: true)
        defer { model.close() }
        try await waitUntil { !model.filmstrip.isEmpty }
        #expect(model.isVideo && abs(model.duration - 2) < 0.1)
        let first = try #require(model.filmstrip.first)
        #expect(first.height > first.width, "frames are shown upright")

        // Playing moves the playhead (with no window, as when nobody looks).
        model.togglePlay()
        try await waitUntil { model.currentTime > 0.3 }
        #expect(model.currentTime > 0.3 && model.isPlaying)
        model.togglePlay()
        #expect(!model.isPlaying)

        model.turn(clockwise: true)
        let turned = try #require(model.filmstrip.first)
        #expect(turned.width > turned.height, "the timeline turns with the picture")
        model.turn(clockwise: false)
        #expect(try #require(model.filmstrip.first).height > first.width)
    }
}

// MARK: - Windows whose files make one result

struct CombinedJobTests {
    @Test func aCollageAndOrganizedPagesAreOneJobEach() async throws {
        let scratch = try Scratch()
        let pictures = try ["a.png", "b.png", "c.png"].map { SourceFile(url: try scratch.image($0)) }
        let queue = JobQueue()
        queue.enqueue(files: pictures, action: .tool(.collage), parameters: .collage(CollageSpec()))
        #expect(queue.jobs.count == 1, "three pictures, one collage")

        func pdf(_ name: String, pages: Int) -> SourceFile {
            let url = scratch.url.appendingPathComponent(name)
            let document = PDFDocument()
            for _ in 0..<pages { document.insert(PDFPage(), at: document.pageCount) }
            document.write(to: url)
            return SourceFile(url: url)
        }
        let pdfs = [pdf("x.pdf", pages: 2), pdf("y.pdf", pages: 1)]
        let pages = PageArrangement(pages: [.init(file: 1, page: 0), .init(file: 0, page: 1), .init(file: 0, page: 0)])
        queue.enqueue(files: pdfs, action: .tool(.organize), parameters: .pages(pages))
        #expect(queue.jobs.count == 2)
        try await waitUntil { queue.isIdle }

        let collage = try #require(queue.jobs[0].outputs.first)
        #expect(collage.lastPathComponent.hasPrefix("a (collage)"))
        let organized = try #require(queue.jobs[1].outputs.first)
        #expect(PDFDocument(url: organized)?.pageCount == 3, "pages from both PDFs")
        #expect(queue.jobs.allSatisfy { $0.state == .finished })
    }
}

// MARK: - Updates

struct UpdateCheckerTests {
    @Test func versionsCompareNumberByNumber() throws {
        #expect(UpdateChecker.isNewer("1.1", than: "1.0"))
        #expect(UpdateChecker.isNewer("v1.10", than: "1.9"))
        #expect(UpdateChecker.isNewer("2", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("0.9.2", than: "1.0"))
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(#"{"tag_name": "v1.1", "html_url": "https://github.com/IliasPa/Pinwheel_file_converter/releases/tag/v1.1", "name": "x"}"#.utf8))
        #expect(release.version == "1.1")
    }
}
