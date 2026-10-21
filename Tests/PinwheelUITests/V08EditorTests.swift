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

struct OrganizeModelTests {
    private func pdf(_ scratch: Scratch, _ name: String, pages: Int) -> SourceFile {
        let url = scratch.url.appendingPathComponent(name)
        let document = PDFDocument()
        for _ in 0..<pages { document.insert(PDFPage(), at: document.pageCount) }
        document.write(to: url)
        return SourceFile(url: url)
    }

    @Test func reorderTurnRemoveAndUndo() throws {
        let scratch = try Scratch()
        let model = OrganizeModel(files: [pdf(scratch, "a.pdf", pages: 2), pdf(scratch, "b.pdf", pages: 2)])
        #expect(model.pages.map(\.id) == ["0:0", "0:1", "1:0", "1:1"])
        #expect(!model.isUnchanged, "two PDFs always make a new one")

        model.move(["1:1"], before: "0:0")
        #expect(model.pages.map(\.id) == ["1:1", "0:0", "0:1", "1:0"])
        // Dragging a selected page moves the whole selection.
        model.selection = ["0:0", "0:1"]
        model.move(["0:1"], before: nil)
        #expect(model.pages.map(\.id) == ["1:1", "1:0", "0:0", "0:1"])

        model.turn(clockwise: true)
        #expect(model.pages.filter { $0.turns == 1 }.map(\.id) == ["0:0", "0:1"])
        model.deleteSelected()
        #expect(model.pages.map(\.id) == ["1:1", "1:0"])
        model.undo()
        #expect(model.pages.count == 4)
        model.redo()
        #expect(model.pages.count == 2)

        var saved: PageArrangement?
        model.onSave = { _, arrangement in saved = arrangement }
        model.save()
        #expect(saved?.pages.map(\.id) == ["1:1", "1:0"])
    }

    @Test func aSinglePDFNeedsAChangeFirst() throws {
        let scratch = try Scratch()
        let model = OrganizeModel(files: [pdf(scratch, "one.pdf", pages: 3)])
        #expect(model.isUnchanged)
        model.reverse()
        #expect(!model.isUnchanged)
        #expect(model.name(of: model.pages[0]) == "Page 3")
    }
}

struct CollageModelTests {
    @Test func orderAndSpecGoToTheJob() async throws {
        let scratch = try Scratch()
        let files = try ["c.png", "a.png", "b.png"].map { SourceFile(url: try scratch.image($0, width: 200, height: 150)) }
        let model = CollageModel(files: files)
        #expect(model.files.map(\.url.lastPathComponent) == ["a.png", "b.png", "c.png"])
        try await waitUntil { model.preview != nil }
        #expect(model.preview != nil)
        #expect(model.outputSize.width == 3000)

        model.move(from: IndexSet(integer: 2), to: 0)
        model.change { $0.layout = .rows }
        var job: ([SourceFile], CollageSpec)?
        model.onSave = { job = ($0, $1) }
        model.save()
        #expect(job?.0.map(\.url.lastPathComponent) == ["c.png", "a.png", "b.png"])
        #expect(job?.1.layout == .rows)
    }
}

struct MediaEditorModelTests {
    private func tone(_ scratch: Scratch, _ name: String, seconds: Double = 4) throws -> SourceFile {
        let url = scratch.url.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 44_100))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.3 * Float(sin(Double(i) * 0.06)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return SourceFile(url: url)
    }

    @Test func handlesSharedSettingsAndSaving() async throws {
        let scratch = try Scratch()
        let model = MediaEditorModel(files: [try tone(scratch, "a.wav"), try tone(scratch, "b.wav")], ffmpegAvailable: false)
        defer { model.close() }
        try await waitUntil { model.duration > 0 && !model.waveform.isEmpty }
        #expect(abs(model.duration - 4) < 0.05)
        #expect(!model.waveform.isEmpty)
        #expect(model.changedCount == 0)

        // Grab the start handle and drag it to 1 s; the end handle to 3 s.
        model.beginDrag(at: 0.05, reach: 0.2)
        model.drag(to: 1)
        model.endDrag()
        model.beginDrag(at: 3.98, reach: 0.2)
        model.drag(to: 3)
        model.endDrag()
        #expect(model.edit.start == 1 && model.edit.end == 3)
        #expect(abs(model.resultLength - 2) < 0.001)

        // Away from the handles, a click moves the playhead.
        model.beginDrag(at: 2, reach: 0.2)
        model.endDrag()
        #expect(abs(model.currentTime - 2) < 0.01)

        model.change { $0.speed = 2 }
        #expect(model.edits[1].speed == 2, "shared with the other file")
        #expect(model.edits[1].start == 0, "but not the part")
        #expect(model.resultLength == 1)
        #expect(model.changedCount == 2)

        var saved: [String] = []
        model.onSave = { file, _ in saved.append(file.url.lastPathComponent) }
        model.save()
        #expect(saved == ["a.wav", "b.wav"])
    }
}

struct SkippedNoticeTests {
    @Test func nothingSavedIsSaidOutLoud() async throws {
        let scratch = try Scratch()
        // A plain gray picture: no subject and nothing but background.
        let plain = scratch.url.appendingPathComponent("plain.png")
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        let dest = CGImageDestinationCreateWithURL(plain as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        let queue = JobQueue()
        queue.enqueue(files: [SourceFile(url: plain)], action: .tool(.removeBackground))
        try await waitUntil { queue.isIdle }
        #expect(queue.jobs.first?.isSkipped == true)
        let notice = try #require(Notifier.content(for: queue.jobs))
        #expect(notice.title == "Nothing saved for plain.png")
        #expect(notice.body.contains("subject"))

        // A quick success needs no notification; a long one does (timed from
        // the job's start, not the clock: a busy Mac may take a while).
        queue.enqueue(files: [SourceFile(url: try scratch.image("photo.png"))], action: .convert(.jpeg))
        try await waitUntil { queue.isIdle }
        let success = [try #require(queue.jobs.last)]
        #expect(Notifier.content(for: success, now: success[0].created.addingTimeInterval(2)) == nil)
        #expect(Notifier.content(for: success, now: success[0].created.addingTimeInterval(60))?.title == "photo.png is ready")
    }
}

struct WorkerVisionTests {
    @Test func removeBackgroundWorksInTheWorkerProcess() async throws {
        let worker = Bundle(for: Scratch.self).bundleURL.deletingLastPathComponent().appendingPathComponent("PinwheelWorker")
        try #require(FileManager.default.isExecutableFile(atPath: worker.path), "PinwheelWorker wasn't built next to the tests")
        let scratch = try Scratch()
        // An orange ball on a light floor: a clear subject.
        let ball = scratch.url.appendingPathComponent("ball.png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 600, height: 450, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 450))
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.75, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.8, green: 0.3, blue: 0.05, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.addEllipse(in: CGRect(x: 187, y: 112, width: 225, height: 225))
        ctx.clip()
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 270, y: 260), startRadius: 4, endCenter: CGPoint(x: 300, y: 225), endRadius: 150, options: [])
        let dest = CGImageDestinationCreateWithURL(ball as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)

        let queue = JobQueue()
        queue.runner = ConversionRunner(worker: worker)
        queue.enqueue(files: [SourceFile(url: ball)], action: .tool(.removeBackground))
        try await waitUntil { queue.isIdle }
        let job = try #require(queue.jobs.first)
        #expect(job.state == .finished, "\(job.state)")
        let output = try #require(job.outputs.first)
        let src = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyHasAlpha] as? Bool == true)
    }
}

struct StudioV08Tests {
    @Test func watermarkTabStartsWithTheLastWatermark() async throws {
        let scratch = try Scratch()
        var last = Watermark()
        last.text = "© Me"
        let model = StudioModel(files: [SourceFile(url: try scratch.image("p.png"))], tab: .watermark, watermark: last)
        model.undoManager.groupsByEvent = false
        #expect(model.watermark?.text == "© Me")
        #expect(model.canSave)
        for typed in ["©", "© I", "© Ilias"] { model.setWatermarkText(typed) }
        #expect(model.watermark?.text == "© Ilias")
        model.undo()
        #expect(model.watermark?.text == "© Me", "typing is one undo step")
        model.setWatermarkShown(false)
        #expect(model.watermark == nil)

        model.beginSliding()
        model.setStraighten(4.26)
        model.endSliding()
        #expect(model.edit.straighten == 4.3)
    }
}
