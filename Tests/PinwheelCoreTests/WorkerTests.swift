import CoreGraphics
import Foundation
import Testing
@testable import PinwheelCore

/// The PinwheelWorker program, which `swift test` builds next to the tests.
private final class BundleMarker {}

func builtWorker() throws -> URL {
    let url = Bundle(for: BundleMarker.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("PinwheelWorker")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "PinwheelWorker wasn't built next to the tests")
    return url
}

struct WorkerTests {
    @Test func plannedJobsSurviveTheTripToTheWorker() throws {
        var options = ConversionOptions()
        options.saveLocation = .folder(URL(fileURLWithPath: "/tmp/somewhere"))
        options.resize = .fit1920
        options.gifMaxSeconds = nil
        options.ffmpegURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let request = ConversionRequest(file: SourceFile(url: URL(fileURLWithPath: "/tmp/a photo.png")), action: .tool(.resize))
        let job = try ConversionEngine.prepare(request, options: options, naming: OutputNaming())
        let copy = try JSONDecoder().decode(PlannedJob.self, from: JSONEncoder().encode(job))
        #expect(copy == job)
    }

    @Test func messagesAreOneLineEach() {
        let result = ConversionResult(outputs: [URL(fileURLWithPath: "/tmp/x (converted).jpg")], note: "Two\nlines")
        for message in [WorkerMessage.progress(0.5), .finished(result), .failed("Nope"), .cancelled] {
            let line = String(decoding: message.line, as: UTF8.self)
            #expect(line.hasSuffix("\n"))
            #expect(!line.dropLast().contains("\n"))
            #expect(WorkerMessage(line: String(line.dropLast())) == message)
        }
        // Anything else a framework prints is ignored.
        #expect(WorkerMessage(line: "objc[123]: Class X is implemented in both…") == nil)
    }

    @Test func convertsInTheWorkerProcess() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makePhoto(at: source)
        let runner = ConversionRunner(worker: try builtWorker())
        let progress = Locked(0.0)
        let request = ConversionRequest(file: SourceFile(url: source), action: .convert(.heic))
        let result = try await runner.run(request, options: ConversionOptions(), naming: OutputNaming()) { value in
            progress.value = max(progress.value, value)
        }
        let output = try #require(result.outputs.first)
        #expect(output.lastPathComponent == "photo (converted).heic")
        #expect(Fixtures.readImage(output)?.type == "public.heic")
        #expect(progress.value > 0)
    }

    @Test func workerErrorsComeBackAsErrors() async throws {
        let folder = try TempFolder()
        let broken = folder.file("broken.png")
        try Data("not an image".utf8).write(to: broken)
        let runner = ConversionRunner(worker: try builtWorker())
        do {
            _ = try await runner.run(ConversionRequest(file: SourceFile(url: broken), action: .convert(.jpeg)), options: ConversionOptions(), naming: OutputNaming()) { _ in }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("broken.png"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["broken.png"])
    }

    @Test func aCrashedWorkerIsAFailureAndLeavesNothingBehind() async throws {
        let folder = try TempFolder()
        let source = folder.file("photo.png")
        try Fixtures.makePhoto(at: source)
        // Stands in for a worker that crashes halfway.
        let crashing = folder.file("crashing-worker")
        try "#!/bin/sh\ncat > /dev/null\nexit 3\n".write(to: crashing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crashing.path)

        let request = ConversionRequest(file: SourceFile(url: source), action: .convert(.jpeg))
        let job = try ConversionEngine.prepare(request, options: ConversionOptions(), naming: OutputNaming())
        try Data("half a file".utf8).write(to: job.destination)
        do {
            _ = try await ConversionRunner.runInWorker(job, worker: crashing) { _ in }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("stopped unexpectedly"))
        }
        #expect(!FileManager.default.fileExists(atPath: job.destination.path))
    }

    @Test func stoppingAJobStopsTheWorkerAndCleansUp() async throws {
        let folder = try TempFolder()
        let source = folder.file("big.pdf")
        try makeSlowPDF(at: source, pages: 48)
        var options = ConversionOptions()
        options.pdfDPI = 300
        let request = ConversionRequest(file: SourceFile(url: source), action: .convert(.png))
        let job = try ConversionEngine.prepare(request, options: options, naming: OutputNaming())
        let worker = try builtWorker()

        let task = Task { try await ConversionRunner.runInWorker(job, worker: worker) { _ in } }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let stopped = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(stopped) < 5)
        #expect(!FileManager.default.fileExists(atPath: job.destination.path))
    }

    /// Letter-size pages full of random pixels: slow to save as PNG.
    private func makeSlowPDF(at url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        let noise = MediaFixtures.noiseImage(width: 600, height: 800)
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.draw(noise, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
