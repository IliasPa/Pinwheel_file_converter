import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

/// A fresh temporary folder, deleted when the value goes away.
final class Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PinwheelUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// A small PNG with a color gradient.
    func image(_ name: String, width: Int = 120, height: Int = 80) throws -> URL {
        let file = url.appendingPathComponent(name)
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let gradient = CGGradient(colorsSpace: nil, colors: [NSColor.red.cgColor, NSColor.blue.cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return file
    }
}

struct JobQueueTests {
    /// Waits (up to 20 s) until every job is done.
    private func waitUntilIdle(_ queue: JobQueue) async throws {
        for _ in 0..<400 where !queue.isIdle {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(queue.isIdle)
    }

    @Test func convertsAndRemembersTheOutput() async throws {
        let scratch = try Scratch()
        let source = try scratch.image("photo.png")
        let queue = JobQueue()
        var finishedBatches = 0
        queue.onBatchFinished = { _ in finishedBatches += 1 }
        queue.enqueue(files: [SourceFile(url: source)], action: .convert(.jpeg))
        try await waitUntilIdle(queue)

        let job = try #require(queue.jobs.first)
        #expect(job.state == .finished)
        #expect(job.outputs.map(\.lastPathComponent) == ["photo (converted).jpg"])
        #expect(job.outputSize != nil && job.sourceSize != nil)
        #expect(finishedBatches == 1)
    }

    @Test func severalImagesOnPDFBecomeOneJob() async throws {
        let scratch = try Scratch()
        let files = try ["b.png", "a.png", "c.png"].map { SourceFile(url: try scratch.image($0)) }
        let queue = JobQueue()
        queue.enqueue(files: files, action: .convert(.pdf))
        #expect(queue.jobs.count == 1)
        #expect(queue.jobs.first?.title == "b.png + 2 more")
        try await waitUntilIdle(queue)
        #expect(queue.jobs.first?.outputs.first?.lastPathComponent == "a (combined).pdf")
    }

    @Test func combiningCanBeSwitchedOff() throws {
        let scratch = try Scratch()
        let files = try ["a.png", "b.png"].map { SourceFile(url: try scratch.image($0)) }
        let queue = JobQueue()
        queue.optionsProvider = {
            var options = ConversionOptions()
            options.combineImagesIntoOnePDF = false
            return options
        }
        queue.enqueue(files: files, action: .convert(.pdf))
        #expect(queue.jobs.count == 2)
    }

    @Test func originalsGoToTheTrashOnlyWhenAskedAndAfterSuccess() async throws {
        let scratch = try Scratch()
        let source = try scratch.image("photo.png")
        let queue = JobQueue()
        var trashed: [URL] = []
        queue.moveToTrash = { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)  // stand-in for the real Trash
        }
        queue.shouldTrashOriginals = { true }
        queue.enqueue(files: [SourceFile(url: source)], action: .convert(.heic))
        try await waitUntilIdle(queue)
        #expect(trashed == [source])
        #expect(queue.jobs.first?.originalTrashed == true)

        // A failing job never trashes its original.
        let broken = scratch.url.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        trashed = []
        queue.enqueue(files: [SourceFile(url: broken)], action: .convert(.jpeg))
        try await waitUntilIdle(queue)
        #expect(trashed.isEmpty)
        #expect(queue.jobs.last?.isFailed == true)
    }

    @Test func skippedJobsExplainWhy() async throws {
        let scratch = try Scratch()
        let source = try scratch.image("small.png", width: 400, height: 300)
        let queue = JobQueue()
        queue.optionsProvider = {
            var options = ConversionOptions()
            options.resize = .fit1920
            return options
        }
        queue.enqueue(files: [SourceFile(url: source)], action: .tool(.resize))
        try await waitUntilIdle(queue)
        guard case .skipped(let reason)? = queue.jobs.first?.state else {
            Issue.record("expected a skipped job, got \(String(describing: queue.jobs.first?.state))")
            return
        }
        #expect(reason.contains("1920"))
    }
}

struct WheelModelTests {
    @Test func resizeWedgeShowsTheChosenSize() {
        var options = ConversionOptions()
        options.resize = .fit1280
        let model = WheelModel()
        model.load(files: [SourceFile.sample], mode: .tools, options: options) { _, _ in .available }
        #expect(model.items.map(\.title).contains("Fit 1280 px"))
    }
}

/// Draws the wheel and the progress list at every glass level in a hidden
/// window, to catch views that fail to draw. (Real Liquid Glass is drawn by
/// the system on screen; here only the content can be checked.)
struct RenderTests {
    private func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Distinct colors in a coarse grid: 1 means nothing was drawn.
    private func colorCount(_ rep: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 12) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 12) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.insert(String(format: "%.2f,%.2f,%.2f", c.redComponent, c.greenComponent, c.blueComponent))
                }
            }
        }
        return colors.count
    }

    @Test(arguments: GlassLevel.allCases)
    func wheelDrawsAtEveryGlassLevel(level: GlassLevel) throws {
        let name = "PinwheelRender-\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: name)!)
        settings.glassLevel = level
        let view = ZStack {
            LinearGradient(colors: [.yellow, .blue], startPoint: .leading, endPoint: .trailing)
            WheelView(model: WheelModel.sample(), settings: settings, blending: .withinWindow)
        }
        #expect(colorCount(render(view, size: CGSize(width: 340, height: 340))) > 20)
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}
