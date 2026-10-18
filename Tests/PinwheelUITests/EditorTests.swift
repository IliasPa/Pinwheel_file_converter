import AppKit
import Foundation
import PDFKit
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

/// Waits (up to 10 s) until the editor has drawn its preview.
@MainActor
private func waitForPreview(_ model: StudioModel) async throws {
    for _ in 0..<500 where model.preview == nil || model.isRendering {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.preview != nil, "the preview should be drawn")
}

struct StudioModelTests {
    private func makeModel(width: Int = 300, height: Int = 200, count: Int = 1) throws -> (StudioModel, Scratch) {
        let scratch = try Scratch()
        let files = try (0..<count).map { SourceFile(url: try scratch.image("photo\($0).png", width: width, height: height)) }
        let model = StudioModel(files: files, tab: .crop)
        // In the app, each click or key press is its own undo step because
        // the run loop closes the undo group after every event. Tests have no
        // run loop turning, so each change makes its own group instead.
        model.undoManager.groupsByEvent = false
        return (model, scratch)
    }

    @Test func loadsAndDrawsThePicture() async throws {
        let (model, _scratch) = try makeModel()
        _ = _scratch
        try await waitForPreview(model)
        #expect(model.originalSize == PixelSize(width: 300, height: 200))
        #expect(model.previewTab == .crop)
        #expect(!model.canSave)
    }

    @Test func draggingTheCropCanBeUndoneAndRedone() async throws {
        let (model, _scratch) = try makeModel()
        _ = _scratch
        try await waitForPreview(model)
        model.beginCrop(at: CGPoint(x: 300, y: 200), tolerance: 6)  // bottom-right corner
        model.moveCrop(to: CGPoint(x: 150, y: 100))
        model.endCrop()
        #expect(model.resultSize == PixelSize(width: 150, height: 100))
        #expect(model.canSave)

        model.undo()
        #expect(model.resultSize == PixelSize(width: 300, height: 200))
        model.redo()
        #expect(model.resultSize == PixelSize(width: 150, height: 100))

        // A click outside the box (no drag) changes nothing.
        model.resetCrop()
        model.beginCrop(at: CGPoint(x: 10, y: 10), tolerance: 0)
        model.moveCrop(to: CGPoint(x: 11, y: 11))
        model.endCrop()
        #expect(model.resultSize == PixelSize(width: 300, height: 200))
    }

    @Test func shapesFollowThePicture() async throws {
        let (model, _scratch) = try makeModel(width: 200, height: 300)  // a tall picture
        _ = _scratch
        try await waitForPreview(model)
        model.choose(aspect: AspectRatio(4, 3))
        #expect(model.aspect == AspectRatio(3, 4))
        #expect(model.resultSize.width == 200 && (266...267).contains(model.resultSize.height))
        model.turnAspect()
        #expect(model.aspect == AspectRatio(4, 3))

        // Typing a width keeps the shape, and scales the result exactly.
        model.setResultWidth(80)
        #expect(model.resultSize == PixelSize(width: 80, height: 60))
        model.useCropSize()
        #expect(model.edit.outputSize == nil)

        // On a free crop, typing both sides sets the shape.
        model.choose(aspect: nil)
        model.setResultHeight(50)
        #expect(model.aspect != nil)
        #expect(model.resultSize.height == 50)
    }

    @Test func drawingMovingAndDeletingMarkup() async throws {
        let (model, _scratch) = try makeModel()
        _ = _scratch
        model.tab = .markup
        try await waitForPreview(model)

        model.tool = .arrow
        model.beginMarkup(at: RelativePoint(x: 0.2, y: 0.2))
        model.continueMarkup(to: RelativePoint(x: 0.6, y: 0.6))
        model.endMarkup()
        #expect(model.edit.markup.count == 1)

        // A click with a drawing tool doesn't leave a dot.
        model.beginMarkup(at: RelativePoint(x: 0.9, y: 0.9))
        model.endMarkup()
        #expect(model.edit.markup.count == 1)

        // Select and move it.
        model.tool = nil
        model.beginMarkup(at: RelativePoint(x: 0.4, y: 0.4))
        #expect(model.selection == model.edit.markup[0].id)
        model.continueMarkup(to: RelativePoint(x: 0.5, y: 0.4))
        model.endMarkup()
        #expect(abs(model.edit.markup[0].points[0].x - 0.3) < 0.0001)
        model.undo()
        #expect(abs(model.edit.markup[0].points[0].x - 0.2) < 0.0001)

        model.setColor(.blue)
        #expect(model.edit.markup[0].color == .blue)
        model.deleteSelected()
        #expect(model.edit.markup.isEmpty)
    }

    @Test func typingTextIsOneUndoStep() async throws {
        let (model, _scratch) = try makeModel()
        _ = _scratch
        model.tab = .markup
        try await waitForPreview(model)
        model.tool = .text
        model.beginMarkup(at: RelativePoint(x: 0.5, y: 0.5))
        model.endMarkup()
        #expect(model.edit.markup.first?.text == "Text")
        #expect(model.tool == nil, "after placing text, clicks select it")
        for typed in ["H", "Hi", "Hi!"] { model.setText(typed) }
        #expect(model.edit.markup.first?.text == "Hi!")
        model.undo()
        #expect(model.edit.markup.first?.text == "Text")

        model.tool = .number
        for x in [0.1, 0.2] {
            model.beginMarkup(at: RelativePoint(x: x, y: 0.1))
            model.endMarkup()
        }
        #expect(model.edit.markup.filter { $0.kind == .number }.map(\.text) == ["1", "2"])
    }

    @Test func turningKeepsTheCropAndMarkupOnThePicture() async throws {
        let (model, _scratch) = try makeModel()
        _ = _scratch
        try await waitForPreview(model)
        model.choose(aspect: .square)
        model.rotate(clockwise: true)
        #expect(model.resultSize == PixelSize(width: 200, height: 200))
        model.flip(horizontally: true)
        #expect(model.edit.mirrored)
        model.revertAll()
        #expect(model.edit.isEmpty)
    }

    @Test func savingHandsOverTheEdit() async throws {
        let (model, _scratch) = try makeModel(count: 2)
        _ = _scratch
        try await waitForPreview(model)
        var saved: ImageEdit?
        var closed = false
        model.onSave = { saved = $0 }
        model.onClose = { closed = true }
        model.save()
        #expect(saved == nil, "nothing to save yet")
        model.setFilter(.mono)
        model.setBackdrop(.color(.white))
        #expect(model.edit.frame.padding > 0, "a background comes with some room")
        model.save()
        #expect(saved?.adjustments.filter == .mono)
        #expect(closed)

        model.index = 1
        try await waitForPreview(model)
        #expect(model.file.url.lastPathComponent == "photo1.png")
    }
}

struct InfoModelTests {
    @Test func onlyRealChangesAreSaved() async throws {
        let scratch = try Scratch()
        let pdf = scratch.url.appendingPathComponent("notes.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Old title"]
        #expect(document.write(to: pdf))
        let other = try scratch.image("photo.png")
        let model = InfoModel(
            files: [SourceFile(url: pdf), SourceFile(url: other)],
            settings: SettingsStore(defaults: UserDefaults(suiteName: "PinwheelInfo-\(UUID().uuidString)")!)
        )
        for _ in 0..<250 where model.details == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.value(.title) == "Old title")
        #expect(model.canEdit)

        model.setValue(.title, "Old title")  // the same: not a change
        #expect(model.changedCount == 0)
        model.setValue(.title, "New title")
        model.setValue(.author, "  ")  // blank stays blank
        #expect(model.edit(for: 0).changes == [.title: "New title"])

        var saved: [(String, MetadataEdit)] = []
        var stripped: [SourceFile] = []
        model.onSave = { saved.append(($0.url.lastPathComponent, $1)) }
        model.onRemoveAll = { stripped = $0 }
        model.save()
        #expect(saved.map(\.0) == ["notes.pdf"])
        model.removeAllInfo()
        #expect(stripped.count == 2)
    }
}

struct EditorJobTests {
    private func waitUntilIdle(_ queue: JobQueue) async throws {
        for _ in 0..<400 where !queue.isIdle {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(queue.isIdle)
    }

    @Test func editsFromTheEditorRunAsJobs() async throws {
        let scratch = try Scratch()
        let files = try ["a.png", "b.png"].map { SourceFile(url: try scratch.image($0, width: 200, height: 100)) }
        var edit = ImageEdit()
        edit.aspect = .square
        let queue = JobQueue()
        queue.enqueue(files: files, action: .tool(.edit), parameters: .image(edit))
        #expect(queue.jobs.count == 2)
        try await waitUntilIdle(queue)
        #expect(queue.jobs.map { $0.outputs.first?.lastPathComponent } == ["a (edited).png", "b (edited).png"])
    }

    @Test func takingTextOutKeepsTheOriginal() async throws {
        let scratch = try Scratch()
        // A picture with words in it, so Get Text really saves something.
        let source = scratch.url.appendingPathComponent("sign.png")
        let picture = NSImage(size: NSSize(width: 900, height: 200), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Pinwheel Sign" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 80)])
            return true
        }
        let rep = NSBitmapImageRep(data: try #require(picture.tiffRepresentation))
        try #require(rep?.representation(using: .png, properties: [:])).write(to: source)

        let queue = JobQueue()
        var trashed: [URL] = []
        queue.moveToTrash = { trashed.append($0) }
        queue.shouldTrashOriginals = { true }
        queue.enqueue(files: [SourceFile(url: source)], action: .tool(.extractText))
        try await waitUntilIdle(queue)
        #expect(queue.jobs.last?.state == .finished)
        #expect(trashed.isEmpty, "the text is taken from the picture; the picture stays")

        var edit = ImageEdit()
        edit.adjustments.filter = .mono
        queue.enqueue(files: [SourceFile(url: source)], action: .tool(.edit), parameters: .image(edit))
        try await waitUntilIdle(queue)
        #expect(trashed == [source], "an edited copy replaces the original")
    }

    @Test func mergeIsOneJob() throws {
        let files = ["b.pdf", "a.pdf"].map { SourceFile(url: URL(fileURLWithPath: "/tmp/\($0)")) }
        let queue = JobQueue()
        queue.enqueue(files: files, action: .tool(.merge))
        #expect(queue.jobs.count == 1)
    }
}

struct ToolsWheelSettingsTests {
    private func freshStore() -> SettingsStore {
        let name = "PinwheelTests-\(UUID().uuidString)"
        UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
        return SettingsStore(defaults: UserDefaults(suiteName: name)!)
    }

    @Test func imagesStartWithEightToolsAndCanSwap() {
        let store = freshStore()
        #expect(!store.isOnWheel(.tool(.stripMetadata), for: .image))
        #expect(store.isOnWheel(.tool(.stripMetadata), for: .video))
        let model = WheelModel()
        model.load(files: [SourceFile.sample], mode: .tools, options: ConversionOptions(), hidden: store.hiddenTools) { _, _ in .available }
        #expect(model.items.count == 8)
        #expect(!model.items.map(\.title).contains("Strip Info"))
        #expect(model.items.map(\.title).contains("Crop…"))

        store.setOnWheel(.open(.markup), for: .image, false)
        store.setOnWheel(.tool(.stripMetadata), for: .image, true)
        model.load(files: [SourceFile.sample], mode: .tools, options: ConversionOptions(), hidden: store.hiddenTools) { _, _ in .available }
        #expect(model.items.map(\.title).contains("Strip Info"))
        #expect(!model.items.map(\.title).contains("Markup…"))

        store.resetToDefaults()
        #expect(store.hiddenTools == FormatCatalog.defaultHidden)
    }
}
