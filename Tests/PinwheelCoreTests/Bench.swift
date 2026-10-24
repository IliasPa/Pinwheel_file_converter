import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PinwheelCore

/// The big check: every format and tool on every hard file the bench makes
/// (scripts/bench/make-files.sh), each result looked at and measured.
/// Runs only when asked: scripts/bench/run.sh. Writes results.md there.
struct Bench {
    static let environment = ProcessInfo.processInfo.environment
    static let files = environment["PINWHEEL_BENCH"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: files != nil), .timeLimit(.minutes(240)))
    func everything() async throws {
        let files = try #require(Self.files)
        let results = URL(fileURLWithPath: Self.environment["PINWHEEL_BENCH_OUT"] ?? files.deletingLastPathComponent().appendingPathComponent("results").path)
        let worker = Self.environment["PINWHEEL_BENCH_WORKER"].map { URL(fileURLWithPath: $0) }
        let only = Self.environment["PINWHEEL_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let iWork = Self.environment["PINWHEEL_BENCH_IWORK"] != "0"
        try? FileManager.default.removeItem(at: results)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)

        let bench = try BenchRun(files: files, results: results, worker: worker, iWork: iWork)
        var jobs = bench.jobs()
        if let only { jobs = jobs.filter { only.contains($0.category) || only.contains($0.sources[0].lastPathComponent) } }
        print("Bench: \(jobs.count) jobs")
        let outcomes = await bench.run(jobs, parallel: Int(Self.environment["PINWHEEL_BENCH_PARALLEL"] ?? "") ?? 4)
        try BenchReport.write(outcomes, to: results)
        let problems = outcomes.filter { !$0.problems.isEmpty || $0.status == .failed }.count
        print("Bench: \(outcomes.count) jobs, \(problems) with problems. See \(results.appendingPathComponent("results.md").path)")
    }
}

// MARK: - Jobs

struct BenchJob: Sendable {
    var category: String
    var sources: [URL]
    var action: WheelAction
    var parameters: JobParameters?
    /// What this job is called in the report ("→ PNG", "Compress", "Trim 0.5–2 s").
    var label: String
    /// A job that should fail (a damaged or locked file): its message is checked instead.
    var shouldFail = false
}

struct BenchOutcome: Sendable, Codable {
    enum Status: String, Codable { case ok, skipped, failed }
    var category: String
    var source: String
    var label: String
    var status: Status
    var seconds: Double
    var megabytes: Double?
    var outputs: [String]
    var outputBytes: Int64
    var message: String?
    var problems: [String]
    var notes: [String]
}

final class BenchRun: @unchecked Sendable {
    let files: URL
    let results: URL
    let options: ConversionOptions
    let runner: ConversionRunner
    let memoryLog: URL
    let iWork: Bool
    let naming = OutputNaming()

    init(files: URL, results: URL, worker: URL?, iWork: Bool) throws {
        self.files = files
        self.results = results
        self.iWork = iWork
        // A PowerPoint deck as PowerPoint and Pinwheel write them (Keynote reads it).
        let deck = files.appendingPathComponent("slides/from pinwheel.pptx")
        if !FileManager.default.fileExists(atPath: deck.path) {
            try SlideDeck.write(try PDFSlides.slides(files.appendingPathComponent("pdf/slides 16x9.pdf")) { _ in }, to: deck)
        }
        memoryLog = results.appendingPathComponent("memory.log")
        var options = ConversionOptions()
        options.ffmpegURL = ExternalTool.ffmpeg.locate()
        options.pngquantURL = ExternalTool.pngquant.locate()
        options.cwebpURL = ExternalTool.cwebp.locate()
        // As "Automatic" sets it up when Greek is installed for Tesseract.
        if let tesseract = ExternalTool.tesseract.locate(), TesseractData.languages(in: TesseractData.ownFolder).contains("ell") {
            options.textRecognition.engine = .tesseract
            options.textRecognition.tesseractURL = tesseract
            options.textRecognition.checksWithVision = true
            options.textRecognition.dataFolder = TesseractData.ownFolder
            options.textRecognition.languages = ["ell", "eng"]
        }
        self.options = options
        // Each job in the app's own worker (a crash can't stop the bench),
        // through a wrapper that notes its peak memory.
        if let worker {
            let wrapper = results.appendingPathComponent("worker.sh")
            try """
            #!/bin/bash
            input="$(cat)"
            destination="$(printf '%s' "$input" | /usr/bin/plutil -extract destination raw -o - - 2>/dev/null)"
            log="$(mktemp)"
            job="$(mktemp)"
            printf '%s' "$input" > "$job"
            # In the background, so a stop (on a timeout) reaches the worker itself.
            /usr/bin/time -l "\(worker.path)" < "$job" 2>"$log" &
            timer=$!
            trap 'pkill -TERM -P $timer; kill -TERM $timer 2>/dev/null' TERM
            wait $timer
            status=$?
            rm -f "$job"
            peak="$(grep 'peak memory footprint' "$log" | awk '{print $1}')"
            echo "$destination	$peak" >> "\(memoryLog.path)"
            rm -f "$log"
            exit $status
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            runner = ConversionRunner(worker: wrapper)
        } else {
            runner = ConversionRunner()
        }
    }

    func contents(_ category: String) -> [URL] {
        let folder = files.appendingPathComponent(category)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// Every wedge of every file's wheels, with what its window would choose.
    func jobs() -> [BenchJob] {
        var jobs: [BenchJob] = []
        for category in ["images", "video", "audio", "pdf", "documents", "sheets", "slides", "subtitles", "archives"] {
            for url in contents(category) {
                let file = SourceFile(url: url)
                let broken = Expectations.broken.contains(url.lastPathComponent)
                for mode in [WheelMode.convert, .tools] {
                    for action in FormatCatalog.actions(for: [file], mode: mode) {
                        // As the wheel shows it: grayed-out wedges can't be chosen.
                        if case .unavailable = ConversionEngine.availability(of: action, for: [file], ffmpegAvailable: true) { continue }
                        for (action, parameters, label) in variants(of: action, for: file) {
                            if !iWork, ConversionEngine.app(for: action, file: file) != nil { continue }
                            jobs.append(BenchJob(category: category, sources: [url], action: action, parameters: parameters, label: label, shouldFail: broken))
                        }
                    }
                }
            }
        }
        // Several files at once.
        let images = files.appendingPathComponent("images"), pdfs = files.appendingPathComponent("pdf")
        let pictures = ["photo p3 gps.jpg", "phone rotated exif6.jpg", "soft shadow alpha.png", "Ελληνικό όνομα 😀.png"].map { images.appendingPathComponent($0) }
        jobs.append(BenchJob(category: "together", sources: Array(pictures.prefix(3)), action: .convert(.pdf), label: "3 pictures → one PDF"))
        var collage = CollageSpec()
        collage.layout = .grid
        jobs.append(BenchJob(category: "together", sources: pictures, action: .tool(.collage), parameters: .collage(collage), label: "Collage (grid)"))
        collage.layout = .contactSheet
        jobs.append(BenchJob(category: "together", sources: pictures, action: .tool(.collage), parameters: .collage(collage), label: "Collage (contact sheet)"))
        let three = ["invoice tables.pdf", "two column article.pdf", "mixed sizes.pdf"].map { pdfs.appendingPathComponent($0) }
        jobs.append(BenchJob(category: "together", sources: three, action: .tool(.merge), label: "Merge 3 PDFs"))
        let arrangement = PageArrangement(pages: [
            .init(file: 1, page: 1, turns: 1), .init(file: 0, page: 0), .init(file: 2, page: 2), .init(file: 2, page: 4, turns: 2),
        ])
        jobs.append(BenchJob(category: "together", sources: three, action: .tool(.organize), parameters: .pages(arrangement), label: "Organize pages from 3 PDFs"))
        let mixed = [pictures[3], files.appendingPathComponent("documents/notes.md"), files.appendingPathComponent("archives")]
        jobs.append(BenchJob(category: "together", sources: mixed, action: .tool(.archive), label: "ZIP a picture, a note and a folder"))
        return jobs
    }

    /// One wedge as the bench uses it: the editor windows' wedges become the
    /// jobs those windows start, with typical choices.
    func variants(of action: WheelAction, for file: SourceFile) -> [(WheelAction, JobParameters?, String)] {
        let size = FileSize.of(file.url) ?? 0
        switch action {
        case .convert(let format): return [(action, nil, "→ \(format.title)")]
        case .tool(.compress) where file.kind == .pdf: return [(action, nil, "Compress")]
        case .tool(let tool): return [(action, nil, tool.title)]
        case .open(.sizeLimit): return [(.tool(.sizeLimit), .sizeLimit(bytes: max(size / 3, 20_000)), "Size Limit (a third)")]
        case .open(.info):
            let edit = MetadataEdit(changes: [.title: "Bench Τίτλος"], removeLocation: true)
            return [(.tool(.editInfo), .metadata(edit), "Info: new title, no place")]
        case .open(.crop):
            var edit = ImageEdit()
            edit.quarterTurns = 1
            edit.crop = RelativeRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
            return [(.tool(.edit), .image(edit), "Crop and turn")]
        case .open(.adjust):
            var edit = ImageEdit()
            edit.adjustments.exposure = 0.5
            edit.adjustments.saturation = 0.4
            edit.adjustments.vignette = 0.5
            return [(.tool(.edit), .image(edit), "Adjust light and color")]
        case .open(.background):
            var edit = ImageEdit()
            edit.frame.background = .color(MarkupColor(0.9, 0.9, 1))
            edit.frame.padding = 0.08
            edit.frame.cornerRadius = 0.05
            edit.frame.shadow = 0.6
            return [(.tool(.edit), .image(edit), "Background and corners")]
        case .open(.markup):
            var edit = ImageEdit()
            edit.markup = [
                Annotation(kind: .arrow, points: [RelativePoint(x: 0.1, y: 0.1), RelativePoint(x: 0.5, y: 0.5)], color: MarkupColor(1, 0, 0), size: 0.01),
                Annotation(kind: .text, points: [RelativePoint(x: 0.5, y: 0.8)], color: MarkupColor(1, 1, 0), size: 0.05, text: "Γεια σου"),
                Annotation(kind: .redact, points: [RelativePoint(x: 0.6, y: 0.1), RelativePoint(x: 0.9, y: 0.3)], color: MarkupColor(0, 0, 0), size: 0.01),
            ]
            return [(.tool(.edit), .image(edit), "Markup")]
        case .open(.watermark):
            var edit = ImageEdit()
            var mark = Watermark()
            mark.text = "© Bench 2026"
            mark.placement = .tiled
            edit.watermark = mark
            return [(.tool(.edit), .image(edit), "Watermark (tiled)")]
        case .open(.trim):
            var trim = MediaEdit()
            trim.start = 0.5
            trim.end = 2.0
            trim.fadeIn = 0.2
            var turn = MediaEdit()
            turn.quarterTurns = 1
            turn.speed = 2
            var result: [(WheelAction, JobParameters?, String)] = [(.tool(.editMedia), .media(trim), "Trim 0.5–2 s, fade in")]
            if file.kind == .video {
                result.append((.tool(.editMedia), .media(turn), "Turn and double speed"))
                result.append((.tool(.saveFrame), .frame(seconds: 1), "Save frame at 1 s"))
                result.append((.convert(.gif), .media(trim), "GIF of 0.5–2 s"))
            }
            return result
        case .open(.visualizer): return [(.tool(.visualize), .visualizer(VisualizerSpec()), "Visualizer")]
        case .open(.password): return [(.tool(.protect), .password("pass word"), "Add password")]
        case .open(.organize):
            let count = PDFConverter.pageCount(of: file.url)
            let pages = (0..<count).reversed().map { PageArrangement.Page(file: 0, page: $0, turns: $0 == 0 ? 1 : 0) }
            return [(.tool(.organize), .pages(PageArrangement(pages: pages)), "Organize: reverse, turn one")]
        case .open(.rename), .open(.codes), .open(.collage), .open, .recipe, .file:
            return []
        }
    }

    // MARK: Running

    func run(_ jobs: [BenchJob], parallel: Int) async -> [BenchOutcome] {
        // The apps (Pages, Keynote, Numbers) one at a time, after the rest.
        let (apps, rest) = jobs.reduce(into: ([BenchJob](), [BenchJob]())) { split, job in
            let file = SourceFile(url: job.sources[0])
            if ConversionEngine.app(for: job.action, file: file) != nil { split.0.append(job) } else { split.1.append(job) }
        }
        var outcomes: [BenchOutcome] = []
        var done = 0
        let total = jobs.count
        await withTaskGroup(of: BenchOutcome.self) { group in
            var queue = rest[...]
            for _ in 0..<min(parallel, queue.count) {
                let job = queue.removeFirst()
                group.addTask { await self.run(job) }
            }
            for await outcome in group {
                outcomes.append(outcome)
                done += 1
                if done % 25 == 0 { print("Bench: \(done)/\(total)") }
                if let job = queue.popFirst() { group.addTask { await self.run(job) } }
            }
        }
        for job in apps {
            outcomes.append(await run(job))
            done += 1
            if done % 25 == 0 { print("Bench: \(done)/\(total)") }
        }
        return outcomes
    }

    func run(_ job: BenchJob) async -> BenchOutcome {
        var options = self.options
        let name = job.sources.count == 1 ? job.sources[0].lastPathComponent : "\(job.sources.count) files"
        let folder = results.appendingPathComponent(job.category).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        options.saveLocation = .folder(folder)
        let request = ConversionRequest(files: job.sources.map(SourceFile.init(url:)), action: job.action, parameters: job.parameters)
        var outcome = BenchOutcome(category: job.category, source: name, label: job.label, status: .ok, seconds: 0, outputs: [], outputBytes: 0, problems: [], notes: [])
        let start = Date()
        do {
            let (runner, naming, chosen) = (self.runner, self.naming, options)
            let result = try await withThrowingTaskGroup(of: ConversionResult.self) { group in
                group.addTask { try await runner.run(request, options: chosen, naming: naming) { _ in } }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    throw BenchTimeout()
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            outcome.seconds = Date().timeIntervalSince(start)
            outcome.message = result.note
            outcome.outputs = result.outputs.map(\.lastPathComponent)
            outcome.outputBytes = result.outputs.reduce(0) { $0 + Inspect.bytes($1) }
            outcome.megabytes = memory(for: result.outputs.first)
            if result.skipped {
                outcome.status = .skipped
            } else {
                let check = Check(job: job, outputs: result.outputs, options: options)
                await check.run()
                outcome.problems = check.problems
                outcome.notes = check.notes
            }
            if job.shouldFail && !result.skipped { outcome.problems.append("A broken or locked file made something instead of failing") }
            if ["damaged cut short.jpg", "cut short.flac"].contains(name), !result.skipped, result.note?.contains("cut short") != true,
               ![.tool(.extractText), .tool(.editMedia), .tool(.visualize), .tool(.stripMetadata), .tool(.editInfo)].contains(job.action) {
                outcome.problems.append("No word that the picture is cut short")
            }
        } catch {
            outcome.seconds = Date().timeIntervalSince(start)
            outcome.status = .failed
            outcome.message = error is BenchTimeout ? "Took over 5 minutes" : error.localizedDescription
            if job.label == "Remove BG", AnimatedPicture.isAnimated(job.sources[0]), outcome.message?.contains("works on still pictures") == true {
                outcome.status = .ok
                outcome.notes.append("Refused as it should: \(outcome.message ?? "")")
            } else if job.shouldFail, let message = outcome.message, !Expectations.isTechnical(message) {
                outcome.status = .ok
                outcome.notes.append("Failed as it should: \(message)")
            } else if let message = outcome.message, Expectations.isTechnical(message) {
                outcome.problems.append("The message isn't in plain words: \(message)")
            }
        }
        return outcome
    }

    /// The worker's peak memory for the job that wrote `output`, in MB.
    func memory(for output: URL?) -> Double? {
        guard let output, let log = try? String(contentsOf: memoryLog, encoding: .utf8) else { return nil }
        for line in log.split(separator: "\n").reversed() {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let bytes = Double(parts[1]) else { continue }
            let path = String(parts[0]).replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? ""
            if !path.isEmpty, output.path.hasPrefix(path.hasSuffix("/") ? String(path.dropLast()) : path) || path.hasPrefix(output.path) {
                return bytes / 1_048_576
            }
        }
        return nil
    }
}

struct BenchTimeout: Error {}

// MARK: - What each hard file should keep

enum Expectations {
    /// Files that can't be converted: the message is checked instead.
    static let broken: Set<String> = [
        "empty.jpg", "not a video.mp4", "damaged cut short.mp4", "damaged cut short.pdf", "password secret.pdf",
        "password.zip", "damaged.tar.gz",
    ]

    /// Words a converted document must still have; words it must not.
    static let keeps: [String: [String]] = [
        "tracked changes comments.docx": ["Bench Report", "Κεφάλαιο", "INSERTED-KEEP", "FOOTNOTE-TEXT", "Pinwheel link", "Bullet nested", "Step two",
                                          "Merged header", "Τιμή 12,50 €", "Nested cell", "TEXTBOX-CONTENT", "SDT-CONTENT", "😀", "Landscape section", "Τέλος"],
        "web page.html": ["Web Page Heading", "bold", "a link", "Ελληνικά με τόνους", "Merged head", "1.234,56 €", "Inner item", "Fourth", "Παράθεση", "<kept>", "End of page"],
        "notes.md": ["Setext Title", "Επικεφαλίδα", "both", "struck", "Ελλάδα", "Done task", "Nested level three", "Starts at three", "Quote level two", "<not html>", "MD-FOOTNOTE"],
        "book chapters.epub": ["EPUB-CHAPTER-ONE", "EPUB-CHAPTER-TWO", "EPUB-NOTE", "3,14", "List in a book"],
        "greek windows-1253.txt": ["Γειά σου κόσμε", "12,50 €"],
        "greek iso-8859-7.txt": ["Γειά σου κόσμε", "ISO-8859-7 κείμενο"],
        "russian windows-1251.txt": ["Привет, мир"],
        "western windows-1252.txt": ["façade", "“quotes”"],
        "utf-16 crlf.txt": ["UTF-16 Ελληνικά", "😀", "Second line"],
        "old mac line ends.txt": ["Line one", "Old Mac line ends", "Third"],
        "greek windows-1253.html": ["Ελληνικά σε Windows-1253", "Καλημέρα κόσμε"],
        "legacy word.doc": ["Web Page Heading", "Merged head", "Inner item", "Παράθεση"],
        "rich text.rtf": ["Web Page Heading", "Merged head", "Inner item", "Παράθεση"],
        "open document.odt": ["Web Page Heading", "Merged head", "Inner item", "Παράθεση"],
        "saved page.webarchive": ["Web Page Heading", "Merged head", "Inner item", "Παράθεση"],
        "with attachments.rtfd": ["Web Page Heading", "Merged head", "Inner item", "Παράθεση"],
        "word picture.rtf": ["RTF from Word", "Γειά", "After the picture"],
        "invoice tables.pdf": ["INVOICE 2026-117", "Υπηρεσία συντήρησης", "Grand total"],
        "two column article.pdf": ["Two Columns and a Picture", "Introduction", "Αποτελέσματα", "footnote"],
        "scanned no text.pdf": ["SCANNED", "order", "4471", "shipped", "ΣΑΡΩΜΕΝΗ", "παραγγελία"],
        "slides 16x9.pdf": ["Quarterly Review", "Τριμηνιαία", "What went well", "Δύο νέοι πελάτες", "Numbers"],
        "mixed sizes.pdf": ["A4 portrait", "US Letter landscape", "Card", "A3"],
        "form and notes.pdf": ["Application form", "Highlighted sentence"],
        "no copying allowed.pdf": ["Locked document"],
        "from pinwheel.pptx": ["Quarterly Review", "Τριμηνιαία", "What went well", "Δύο νέοι πελάτες", "Numbers"],
        "bom crlf tags.srt": ["Καλημέρα", "Yellow line", "On top", "underlined", "😀"],
        "greek windows-1253.srt": ["Γειά σου", "Όλα καλά"],
        "utf-16.srt": ["UTF-16 Ελληνικά", "Second"],
        "styled.vtt": ["Γεια σου", "κίτρινο", "Karaoke", "words", "not a tag", "& done"],
        "text to read.png": ["Invoice number 2026-117", "1.234,56", "Καλημέρα", "quick brown fox"],
        "every kind of cell.xlsx": ["Προϊόν", "Καφές", "1234.5", "Bold and normal", "007", "Line1", "Inline string", "Merged across", "Far away", "Total 6", "#DIV/0!"],
        "mac 1904 dates.xlsx": ["2026"],
        "libreoffice repeats.ods": ["Ποσοστό", "ODS-MERGED", "9.99", "spaces"],
        "european semicolons.csv": ["Smith; John", "Μαρία", "007", "He said"],
        "greek excel windows-1253.csv": ["Όνομα", "Καφές", "Τυρί"],
        "japanese shift-jis.csv": ["東京", "価格"],
        "tabs.tsv": ["quoted"],
    ]
    static let loses: [String: [String]] = [
        "tracked changes comments.docx": ["DELETED-GONE"],
        "web page.html": ["SCRIPT-SHOULD-NOT-SHOW", "HTML-COMMENT-HIDDEN"],
        "styled.vtt": ["NOTE This is a comment", "::cue", "&amp;"],
        "bom crlf tags.srt": ["<font", "{\\an8}"],
    ]
    /// Said exactly once.
    static let once: [String: [String]] = ["tracked changes comments.docx": ["TEXTBOX-CONTENT"]]
    /// How many cues each subtitle file has.
    static let cues: [String: Int] = ["bom crlf tags.srt": 3, "greek windows-1253.srt": 2, "utf-16.srt": 2, "styled.vtt": 3]
    /// Pictures a document has, which a converted one should keep.
    static let pictures: [String: Int] = [
        "tracked changes comments.docx": 1, "web page.html": 2, "notes.md": 1, "book chapters.epub": 1, "word picture.rtf": 1,
        "two column article.pdf": 1, "invoice tables.pdf": 1,
    ]

    /// Error text meant for programmers, not people.
    static func isTechnical(_ message: String) -> Bool {
        let signs = ["Error Domain=", "(null)", "NSCocoaErrorDomain", "OSStatus", "error -", "Code=", "nil", "Optional(", "The operation couldn’t be completed"]
        return signs.contains { message.contains($0) } || message.count < 12
    }
}

// MARK: - Looking at results

final class Check: @unchecked Sendable {
    let job: BenchJob
    let outputs: [URL]
    let options: ConversionOptions
    var problems: [String] = []
    var notes: [String] = []
    /// Which page of the original a file in a folder of pages is.
    var pageIndex = 0

    init(job: BenchJob, outputs: [URL], options: ConversionOptions) {
        self.job = job
        self.outputs = outputs
        self.options = options
    }

    var source: URL { job.sources[0] }
    var name: String { source.lastPathComponent }

    func run() async {
        for output in outputs {
            guard FileManager.default.fileExists(atPath: output.path) else {
                problems.append("\(output.lastPathComponent) wasn't written")
                continue
            }
            if Inspect.isFolder(output) {
                let inside = Inspect.allFiles(in: output)
                if inside.isEmpty && job.action != .tool(.extract) { problems.append("The folder \(output.lastPathComponent) is empty") }
                if job.action == .tool(.extract) || job.label == "ZIP a picture, a note and a folder" {
                    checkArchive(output, folder: true)
                } else if output.lastPathComponent.hasSuffix(" pictures") {
                    continue  // a Markdown file's pictures
                } else if inside.allSatisfy({ ["csv", "tsv"].contains($0.pathExtension.lowercased()) }) {
                    checkSheet(inside)
                } else {
                    for (index, file) in inside.prefix(3).enumerated() {
                        pageIndex = index
                        await look(file, partOfFolder: inside.count)
                    }
                    pageIndex = 0
                    checkPageCount(folderItems: inside.count)
                }
            } else {
                await look(output, partOfFolder: nil)
            }
        }
    }

    func look(_ output: URL, partOfFolder: Int?) async {
        guard Inspect.bytes(output) > 0 else { problems.append("\(output.lastPathComponent) is empty"); return }
        let ext = output.lastPathComponent.lowercased().hasSuffix(".tar.gz") ? "tar.gz" : output.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "heic", "tiff", "gif", "webp", "avif", "bmp", "ico", "icns":
            if job.category == "video" || job.category == "audio" { await checkFrameFromVideo(output) } else { checkImage(output) }
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4a", "mp3", "wav", "aiff", "flac", "ogg", "opus", "wma":
            await checkMedia(output)
        case "pdf":
            checkPDF(output)
        case "docx", "pages", "rtf", "odt", "md", "txt", "html", "epub", "pptx":
            checkText(output)
        case "xlsx", "ods", "csv", "tsv":
            checkSheet([output])
        case "srt", "vtt":
            checkSubtitles(output)
        case "zip", "tar", "tar.gz", "7z":
            checkArchive(output, folder: false)
        default:
            notes.append("Not looked at: .\(ext)")
        }
    }

    // MARK: Pictures

    func checkImage(_ output: URL) {
        guard let src = CGImageSourceCreateWithURL(output as CFURL, nil), let type = CGImageSourceGetType(src) as String?,
              let picture = Inspect.thumbnail(src) else {
            problems.append("\(output.lastPathComponent) doesn't open as a picture")
            return
        }
        let expected = OutputFormat.allCases.first { $0.fileExtension == output.pathExtension.lowercased() }
        if let expected, expected.kind == .image, expected.utType.identifier != type, !(type == "public.heics" && expected == .heic) {
            problems.append("\(output.lastPathComponent) is really \(type)")
        }
        let changesLook: Set<String> = ["Crop and turn", "Adjust light and color", "Background and corners", "Markup", "Watermark (tiled)", "Remove BG", "Blur Faces & Text", "Collage (grid)", "Collage (contact sheet)"]
        if source.pathExtension.lowercased() == "svg", let shape = Inspect.svgShape(source), !["ico", "icns"].contains(output.pathExtension.lowercased()),
           !changesLook.contains(job.label),
           abs(shape - Double(picture.width) / Double(picture.height)) / shape > 0.03 {
            problems.append(String(format: "SVG shape %.2f became %d×%d", shape, picture.width, picture.height))
        }
        // Compared with the original, for conversions and the tools that keep the look.
        guard let reference = Inspect.reference(for: source, page: pageIndex) else { return }
        guard !changesLook.contains(job.label), job.sources.count == 1 else { return }
        let icon = ["ico", "icns"].contains(output.pathExtension.lowercased())
        let shapeA = Double(reference.width) / Double(reference.height), shapeB = Double(picture.width) / Double(picture.height)
        if !icon, max(shapeA, 1 / shapeA) < 20, abs(shapeA - shapeB) / shapeA > 0.03 {
            problems.append("Shape changed: \(reference.width)×\(reference.height) look became \(picture.width)×\(picture.height)")
            return
        }
        if !icon, max(shapeA, 1 / shapeA) < 20 {
            let difference = Inspect.difference(reference, picture)
            let allowed = job.category == "pdf" ? 18.0 : (output.pathExtension == "gif" ? 14 : 10)
            if difference > allowed { problems.append(String(format: "Looks different from the original (%.0f of 255)", difference)) }
        }
        let clearBefore = Inspect.clearShare(reference), clearAfter = Inspect.clearShare(picture)
        let keepsClear = ["png", "tiff", "heic", "webp", "avif", "gif", "ico", "icns"].contains(output.pathExtension.lowercased())
        if keepsClear, clearBefore > 0.05, clearAfter < clearBefore * 0.5 {
            problems.append(String(format: "See-through parts lost (%.0f%% → %.0f%%)", clearBefore * 100, clearAfter * 100))
        }
        // Animations keep their frames.
        if job.category == "images", let before = CGImageSourceCreateWithURL(source as CFURL, nil) {
            let framesBefore = CGImageSourceGetCount(before), framesAfter = CGImageSourceGetCount(src)
            let moves = ["gif", "png", "webp", "heic"].contains(output.pathExtension.lowercased())
            if framesBefore > 1, AnimatedPicture.isAnimated(source), moves, framesAfter < framesBefore, job.label.hasPrefix("→") {
                problems.append("Animation lost frames (\(framesBefore) → \(framesAfter))")
            }
        }
        if job.label == "Resize" || job.label.hasPrefix("Resize") {
            if let size = Inspect.pixelSize(source), let after = Inspect.pixelSize(output), max(after.0, after.1) * 2 > max(size.0, size.1) + 2 {
                problems.append("Resize didn't halve it: \(size) → \(after)")
            }
        }
        if job.label.hasPrefix("Info") || job.label == "Strip Info" {
            let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            if properties[kCGImagePropertyGPSDictionary] != nil { problems.append("The place is still in the picture") }
        }
    }

    // MARK: Video and sound

    func checkMedia(_ output: URL) async {
        guard let after = await Probe.of(output) else { problems.append("\(output.lastPathComponent) doesn't open"); return }
        let before = await Probe.of(source)
        let isAudioOut = ["m4a", "mp3", "wav", "aiff", "flac", "ogg", "opus", "wma"].contains(output.pathExtension.lowercased())
        if isAudioOut {
            if after.audio == nil { problems.append("No sound in \(output.lastPathComponent)") }
        } else {
            if after.video == nil && before?.video != nil && job.label != "Visualizer" { problems.append("No picture in \(output.lastPathComponent)") }
            if job.label == "Visualizer" && after.video == nil { problems.append("The visualizer made no picture") }
            if let sound = before?.audio, sound.channels > 0, after.audio == nil, job.label != "Mute", job.category == "video" {
                problems.append("The sound was lost")
            }
            if job.label == "Mute", after.audio != nil { problems.append("Still has sound after Mute") }
        }
        // Length.
        if let duration = before?.duration, let length = after.duration {
            var expected = duration
            if job.label.hasPrefix("Trim") || job.label.hasPrefix("GIF of") { expected = min(duration, 2) - 0.5 }
            if job.label == "Turn and double speed" { expected = duration / 2 }
            if job.label.hasPrefix("→ GIF") || job.label.hasPrefix("→ WebP") { expected = min(duration, 15) }
            if job.category == "images" { expected = Inspect.animationLength(source) ?? length }
            if name == "cut short.flac" { expected = length }  // only what's there can be read (and the note says so)
            let tolerance = max(0.35, expected * 0.05)
            if abs(length - expected) > tolerance, duration >= 2 {
                problems.append(String(format: "Length %.2f s, expected %.2f s", length, expected))
            }
        }
        // Size of the picture, as shown.
        if let shown = before?.video?.shown, let made = after.video?.shown, job.category == "video",
           !job.label.hasPrefix("Turn"), !job.label.hasPrefix("→ GIF"), !job.label.hasPrefix("→ WebP"), !job.label.hasPrefix("GIF"),
           !job.label.hasPrefix("Compress"), !job.label.hasPrefix("Size Limit") {
            if abs(Double(shown.0) / Double(shown.1) - Double(made.0) / Double(made.1)) > 0.03 {
                problems.append("Picture shape changed: \(shown.0)×\(shown.1) → \(made.0)×\(made.1)")
            } else if abs(made.0 - shown.0) > 2 {
                notes.append("Size \(shown.0)×\(shown.1) → \(made.0)×\(made.1)")
            }
        }
        // The picture itself, at one second (half way in short clips).
        if job.category == "video", after.video != nil, before?.video != nil, !job.label.hasPrefix("Turn"), !job.label.hasPrefix("Trim"), !job.label.hasPrefix("GIF"),
           !(name == "prores alpha.mov" && ["webm", "mov"].contains(output.pathExtension.lowercased())) {
            let moment = min(1, (before?.duration ?? 2) / 2)
            if let a = await Probe.frame(of: source, at: moment), let b = await Probe.frame(of: output, at: moment) {
                let difference = Inspect.difference(a, b, on: 0)
                if difference > 16 { problems.append(String(format: "Picture looks different at %.1f s (%.0f of 255)", moment, difference)) }
            }
        }
        // Sound level.
        if before?.audio != nil, after.audio != nil, job.label != "Normalize", !job.label.hasPrefix("Trim"), let a = await Probe.loudness(source), let b = await Probe.loudness(output) {
            if b < a - 8 { problems.append(String(format: "Much quieter: %.0f dB → %.0f dB", a, b)) }
            if b > a + 8 { problems.append(String(format: "Much louder: %.0f dB → %.0f dB", a, b)) }
        }
        if job.label == "Normalize", let level = await Probe.integratedLoudness(output), abs(level + 16) > 2.5, (before?.duration ?? 0) > 1 {
            problems.append(String(format: "Normalized to %.1f LUFS, not −16", level))
        }
        // Tags and cover.
        if let title = before?.title, !title.isEmpty, !job.label.hasPrefix("Strip"), !job.label.hasPrefix("Info"), job.label != "Visualizer" {
            let tagged = ["mp3", "m4a", "flac", "ogg", "opus", "wma", "mp4", "mov", "mkv", "aiff"].contains(output.pathExtension.lowercased())
            if tagged, after.title != title { problems.append("Title \"\(title)\" lost (now \(after.title.map { "\"\($0)\"" } ?? "none"))") }
        }
        if job.label.hasPrefix("Strip"), after.title != nil { problems.append("Still has a title after Strip Info") }
        if job.label.hasPrefix("Info"), after.title != "Bench Τίτλος" { problems.append("The new title didn't stick (\(after.title ?? "none"))") }
        if before?.cover == true, ["mp3", "m4a", "flac"].contains(output.pathExtension.lowercased()), !after.cover, !job.label.hasPrefix("Strip") {
            problems.append("Cover picture lost")
        }
        if let rate = before?.audio?.sampleRate, let made = after.audio?.sampleRate, rate > 48_000, made < rate,
           ["flac", "wav", "aiff"].contains(output.pathExtension.lowercased()) {
            problems.append("Lossless copy dropped \(rate) Hz to \(made) Hz")
        }
        if let channels = before?.audio?.channels, let made = after.audio?.channels, channels > 2, made < channels,
           ["flac", "wav", "aiff", "mkv", "mov", "mp4"].contains(output.pathExtension.lowercased()), job.label.hasPrefix("→") {
            notes.append("\(channels) channels became \(made)")
        }
        // Several sound tracks and subtitles, kept in MKV.
        if let before, before.audioTracks > 1, output.pathExtension.lowercased() == "mkv", after.audioTracks < before.audioTracks, job.label != "Mute" {
            problems.append("Sound tracks \(before.audioTracks) → \(after.audioTracks)")
        }
        if let before, before.subtitleTracks > 0, ["mkv", "mp4", "mov"].contains(output.pathExtension.lowercased()), after.subtitleTracks == 0, job.label.hasPrefix("→") {
            problems.append("Subtitles inside were lost")
        }
    }

    func checkFrameFromVideo(_ output: URL) async {
        guard let src = CGImageSourceCreateWithURL(output as CFURL, nil), let first = Inspect.thumbnail(src) else {
            problems.append("\(output.lastPathComponent) doesn't open as a picture")
            return
        }
        let frames = CGImageSourceGetCount(src)
        if ["gif", "webp"].contains(output.pathExtension.lowercased()), job.label.hasPrefix("→") || job.label.hasPrefix("GIF") {
            if frames < 5, (await Probe.of(source)?.duration ?? 0) > 1 { problems.append("Only \(frames) frames") }
            if let length = Inspect.animationLength(output), let duration = await Probe.of(source)?.duration {
                let expected = job.label.hasPrefix("GIF of") ? 1.5 : min(duration, 15)
                if abs(length - expected) > max(0.4, expected * 0.08) { problems.append(String(format: "Animation is %.2f s, expected %.2f s", length, expected)) }
            }
            if let reference = await Probe.frame(of: source, at: job.label.hasPrefix("GIF of") ? 0.5 : 0) {
                let difference = Inspect.difference(reference, first)
                if difference > 18 { problems.append(String(format: "First frame looks different (%.0f of 255)", difference)) }
                if abs(Double(reference.width) / Double(reference.height) - Double(first.width) / Double(first.height)) > 0.04 {
                    problems.append("Shape changed: \(reference.width)×\(reference.height) → \(first.width)×\(first.height)")
                }
            }
        } else if job.label.hasPrefix("Save frame"), let reference = await Probe.frame(of: source, at: 1) {
            let difference = Inspect.difference(reference, first)
            if difference > 18 { problems.append(String(format: "The frame looks different (%.0f of 255)", difference)) }
        }
    }

    // MARK: PDFs

    func checkPDF(_ output: URL) {
        guard let document = PDFDocument(url: output) else { problems.append("\(output.lastPathComponent) doesn't open as a PDF"); return }
        if job.label == "Add password" {
            if !document.isEncrypted || document.unlock(withPassword: "wrong") { problems.append("No password asked") }
            if !document.unlock(withPassword: "pass word") { problems.append("The password doesn't open it") }
            return
        }
        guard document.pageCount > 0 else { problems.append("No pages"); return }
        let sourcePages = job.category == "pdf" ? PDFDocument(url: source)?.pageCount : nil
        switch job.label {
        case "Merge 3 PDFs": if document.pageCount != 9 { problems.append("Merged into \(document.pageCount) pages, not 9") }
        case "Organize pages from 3 PDFs": if document.pageCount != 4 { problems.append("\(document.pageCount) pages, not 4") }
        case "3 pictures → one PDF":
            if document.pageCount != 3 { problems.append("\(document.pageCount) pages, not 3") }
            if let page = document.page(at: 0)?.bounds(for: .mediaBox), page.width > page.height { problems.append("The upright photo's page is sideways") }
        default:
            if let sourcePages, sourcePages != document.pageCount, !job.label.hasPrefix("Size Limit"), job.label != "Split Pages" {
                problems.append("\(sourcePages) pages became \(document.pageCount)")
            }
        }
        if job.label.hasPrefix("Organize:"), let first = document.page(at: 0)?.string, let last = PDFDocument(url: source)?.page(at: (sourcePages ?? 1) - 1)?.string,
           first.prefix(20) != last.prefix(20) {
            problems.append("Pages weren't reversed")
        }
        if job.label == "Strip Info" {
            let attributes = document.documentAttributes ?? [:]
            if attributes[PDFDocumentAttribute.authorAttribute] != nil { problems.append("The author is still there") }
        }
        if job.category == "images" || ["Organize pages from 3 PDFs", "Merge 3 PDFs"].contains(job.label)
            || (output.pathExtension == "pptx" && ["scanned no text.pdf"].contains(name))
            || (name == "scanned no text.pdf" && job.label == "Compress") {
            return  // a picture in a PDF has no text; pages from several files have some of each
        }
        if job.label == "Searchable", name == "scanned no text.pdf" {
            checkWords(document.string ?? "", in: output)
        } else if job.category != "pdf" || job.label == "Compress" {
            checkWords(document.string ?? "", in: output, recall: job.category == "pdf")
        }
    }

    func checkPageCount(folderItems: Int) {
        if job.category == "pdf", job.label.hasPrefix("→") || job.label == "Split Pages", let pages = PDFDocument(url: source)?.pageCount, pages != folderItems {
            problems.append("\(pages) pages became \(folderItems) files")
        }
        if job.category == "slides", job.label.hasPrefix("→"), name == "from pinwheel.pptx", folderItems != 3 {
            problems.append("3 slides became \(folderItems) pictures")
        }
    }

    // MARK: Text

    func checkText(_ output: URL) {
        if output.pathExtension == "pages" {
            if (try? ZipReader(url: output))?.contains("Index/Document.iwa") != true { problems.append("Not a Pages document inside") }
            return
        }
        guard let text = Inspect.text(of: output) else { problems.append("\(output.lastPathComponent) can't be read back"); return }
        if output.pathExtension == "pptx", name == "scanned no text.pdf" { return }  // scanned pages are pictures on slides
        checkWords(text, in: output, recall: true)
        if let count = Expectations.pictures[name], job.label.hasPrefix("→"), !["txt", "md", "pptx"].contains(output.pathExtension.lowercased()) {
            let kept = Inspect.pictureCount(output)
            if kept < count { problems.append("Pictures: \(count) → \(kept)") }
        }
        if output.pathExtension == "md", let count = Expectations.pictures[name], job.label.hasPrefix("→") {
            let folder = output.deletingPathExtension().appendingPathExtension("").deletingPathExtension()
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.path + " pictures").count) ?? 0
            if kept < count, name != "notes.md" { problems.append("Pictures: \(count) → \(kept) (Markdown)") }
        }
    }

    /// The words that matter are there; the hidden ones aren't; and most of the original's words.
    func checkWords(_ text: String, in output: URL, recall: Bool = false) {
        let flat = text.replacingOccurrences(of: "\r", with: "\n")
        for word in Expectations.keeps[name] ?? [] where !Inspect.contains(flat, word) {
            problems.append("Missing \"\(word)\"")
        }
        for word in Expectations.loses[name] ?? [] where flat.contains(word) {
            problems.append("Shouldn't show \"\(word)\"")
        }
        for word in Expectations.once[name] ?? [] where flat.components(separatedBy: word).count > 2 {
            problems.append("\"\(word)\" shown twice")
        }
        if flat.contains("\u{FFFD}") { problems.append("Has � (letters that couldn't be read)") }
        if Inspect.looksGarbled(flat) { problems.append("Letters look garbled (wrong text encoding)") }
        if recall, let original = Inspect.sourceText(of: source) {
            let share = Inspect.recall(original, in: flat)
            if share < (source.pathExtension == "md" ? 0.85 : 0.9) { problems.append(String(format: "Only %.0f%% of the original's words", share * 100)) }
        }
        if name == "styled.vtt", output.pathExtension == "txt", !flat.contains("<not a tag>") {
            problems.append("&lt;not a tag&gt; wasn't turned back into <not a tag>")
        }
        if name == "old mac line ends.txt", flat.contains("Line one") , !flat.contains("\n"), output.pathExtension != "pdf" {
            problems.append("Old Mac line ends weren't seen as lines")
        }
    }

    // MARK: Spreadsheets

    func checkSheet(_ files: [URL]) {
        var workbook = Workbook(sheets: [])
        for output in files {
            let ext = output.pathExtension.lowercased()
            guard let read = try? (ext == "xlsx" ? ExcelWorkbook.read(output) : ext == "ods" ? OpenDocumentSheet.read(output) : DelimitedText.read(output, tabs: ext == "tsv")) else {
                problems.append("\(output.lastPathComponent) can't be read back")
                return
            }
            workbook.sheets += read.sheets
            if ["csv", "tsv"].contains(ext), String(data: (try? Data(contentsOf: output)) ?? Data(), encoding: .utf8) == nil {
                problems.append("Not saved as UTF-8")
            }
        }
        guard let output = files.first else { return }
        let cells = workbook.sheets.flatMap { $0.rows.flatMap { $0 } }.map(\.text)
        let flat = cells.joined(separator: "\n")
        checkWords(flat, in: output)
        switch name {
        case "every kind of cell.xlsx":
            if cells.contains("46319") { problems.append("A date came out as the number 46319") }
            if !cells.contains(where: { $0.contains("2026") && ($0.contains("10") || $0.contains("Oct")) }) { problems.append("The date 24 Oct 2026 is missing") }
            if !cells.contains(where: { $0 == "0.125" || $0.contains("12.5") || $0.contains("12,5") }) { problems.append("12.5% is missing") }
        case "mac 1904 dates.xlsx":
            if cells.contains(where: { $0.contains("2022") }) { problems.append("Read with the wrong date system (2022 instead of 2026)") }
        case "libreoffice repeats.ods":
            let widest = workbook.sheets.map { $0.rows.map(\.count).max() ?? 0 }.max() ?? 0
            let longest = workbook.sheets.map(\.rows.count).max() ?? 0
            if widest > 20 || longest > 50 { problems.append("Empty repeated cells kept: \(longest) rows × \(widest) columns") }
            if Inspect.bytes(output) > 200_000 { problems.append("Huge file from a tiny sheet: \(Inspect.bytes(output) / 1000) KB") }
        case "hundred thousand rows.xlsx":
            let rows = workbook.sheets.first?.rows.count ?? 0
            if rows < 100_001 { problems.append("\(rows) rows, not 100001") }
        default: break
        }
        if job.category == "pdf", name == "invoice tables.pdf" {
            let numbers = workbook.sheets.flatMap { $0.rows.flatMap { $0 } }.filter { if case .number = $0 { true } else { false } }
            if numbers.count < 60 { problems.append("Only \(numbers.count) cells became numbers") }
            if !workbook.sheets.flatMap({ $0.rows.flatMap { $0 } }).contains(where: { if case .number(let value) = $0 { value == -25 } else { false } }) {
                problems.append("(25,00) € didn't become −25")
            }
        }
    }

    // MARK: Subtitles and archives

    func checkSubtitles(_ output: URL) {
        guard let cues = try? Subtitles.read(output) else { problems.append("Can't be read back"); return }
        if let count = Expectations.cues[name], cues.count != count { problems.append("\(count) subtitles became \(cues.count)") }
        checkWords(cues.map(\.text).joined(separator: "\n"), in: output)
    }

    func checkArchive(_ output: URL, folder: Bool) {
        let made = folder
            ? Inspect.allFiles(in: output).map { $0.path.replacingOccurrences(of: output.path + "/", with: "").precomposedStringWithCanonicalMapping }
            : Inspect.archiveEntries(output)
        if job.label == "ZIP a picture, a note and a folder" {
            if !made.contains(where: { $0.hasSuffix("Ελληνικό όνομα 😀.png") }) { problems.append("The Greek-named picture is missing") }
            if made.count < 10 { problems.append("Only \(made.count) files in the ZIP") }
            return
        }
        if name == "escape attempt.zip" {
            if FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appendingPathComponent("evil.txt").path) { problems.append("A file escaped the folder!") }
            return
        }
        if name.hasSuffix(".txt.gz") || name.hasSuffix(".txt.bz2") {
            if !made.contains(where: { $0.hasSuffix("numbers.txt") }) { problems.append("numbers.txt is missing") }
            return
        }
        let expected = Inspect.archiveEntries(source).filter { !$0.hasPrefix("__MACOSX") && !$0.contains("/._") && !$0.hasPrefix("._") }
        let normalize = { (paths: [String]) in Set(paths.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }.filter { !$0.isEmpty && !$0.hasSuffix("/") }) }
        let missing = normalize(expected).subtracting(normalize(made))
        if !missing.isEmpty { problems.append("Missing \(missing.count): \(missing.sorted().prefix(4).joined(separator: ", "))") }
        if made.contains(where: { $0.contains("__MACOSX") || $0.hasPrefix("._") || $0.contains("/._") }) { problems.append("Mac extras (__MACOSX, ._) left in") }
    }
}

// MARK: - Tools for looking

enum Inspect {
    static func bytes(_ url: URL) -> Int64 {
        if isFolder(url) { return allFiles(in: url).reduce(0) { $0 + bytes($1) } }
        return FileSize.of(url) ?? 0
    }

    static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
            && !["rtfd", "pages", "key", "numbers"].contains(url.pathExtension.lowercased())
    }

    static func allFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func thumbnail(_ src: CGImageSource, index: Int = 0) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, index, nil)
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return turned ? (height, width) : (width, height)
    }

    /// How the original looks (upright), drawn independently of Pinwheel.
    static func reference(for url: URL, page index: Int = 0) -> CGImage? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
            let image = page.thumbnail(of: CGSize(width: 256, height: 256), for: .mediaBox)
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case "svg":
            return nil  // Quick Look's SVG thumbnails are blank: see `svgShape`
        default:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return thumbnail(src, index: CGImageSourceGetPrimaryImageIndex(src))
        }
    }

    /// Width over height, as an SVG declares it (its size, else its viewBox).
    static func svgShape(_ url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let root = text.firstMatch(of: /<svg[^>]*>/) else { return nil }
        let tag = String(root.0)
        func number(_ name: String) -> Double? {
            tag.firstMatch(of: try! Regex("\\s\(name)=\"([0-9.]+)")).flatMap { Double($0.output[1].substring ?? "") }
        }
        if let width = number("width"), let height = number("height"), height > 0 { return width / height }
        if let box = tag.firstMatch(of: /viewBox="[-0-9.]+[ ,]+[-0-9.]+[ ,]+([0-9.]+)[ ,]+([0-9.]+)"/), let width = Double(box.1), let height = Double(box.2), height > 0 {
            return width / height
        }
        return nil
    }

    /// 32×32 RGBA, premultiplied, in sRGB.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let ctx = CGContext(data: &data, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        return data
    }

    /// Mean difference (0…255) of two pictures, both laid on white (or on `background`).
    static func difference(_ a: CGImage, _ b: CGImage, on background: Double = 255) -> Double {
        let p = pixels(a), q = pixels(b)
        var total = 0.0
        for i in stride(from: 0, to: p.count, by: 4) {
            for c in 0..<3 {
                let x = Double(p[i + c]) + background * (1 - Double(p[i + 3]) / 255), y = Double(q[i + c]) + background * (1 - Double(q[i + 3]) / 255)
                total += abs(x - y)
            }
        }
        return total / Double(32 * 32 * 3)
    }

    /// The share of see-through pixels.
    static func clearShare(_ image: CGImage) -> Double {
        let p = pixels(image)
        return Double(stride(from: 3, to: p.count, by: 4).filter { p[$0] < 128 }.count) / Double(32 * 32)
    }

    static func animationLength(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 1 else { return nil }
        return (0..<CGImageSourceGetCount(src)).reduce(0) { $0 + (AnimatedPicture.delay(src, at: $1) ?? 0.1) }
    }

    // MARK: Text

    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func textutil(_ url: URL) -> String? {
        run("/usr/bin/textutil", ["-convert", "txt", "-stdout", "-encoding", "UTF-8", url.path]).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A converted file's text, read with something other than Pinwheel where possible.
    static func text(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "srt", "vtt", "csv", "tsv":
            return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        case "docx", "odt", "rtf", "html", "doc":
            return textutil(url)
        case "epub":
            guard let zip = try? ZipReader(url: url) else { return nil }
            return zip.names.filter { $0.hasSuffix("html") }.compactMap { zip.text($0) }.map(stripTags).joined(separator: "\n")
        case "pptx":
            guard let zip = try? ZipReader(url: url) else { return nil }
            let slides = zip.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            return slides.compactMap { zip.text($0) }.map(stripTags).joined(separator: "\n")
        case "pdf":
            return PDFDocument(url: url)?.string
        default:
            return nil
        }
    }

    /// The original's text, read without Pinwheel.
    static func sourceText(of url: URL) -> String? {
        let name = url.lastPathComponent
        func legacy(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        let encodings: [String: String.Encoding] = [
            "greek windows-1253.txt": legacy(.windowsGreek), "greek iso-8859-7.txt": legacy(.isoLatinGreek),
            "russian windows-1251.txt": .windowsCP1251, "western windows-1252.txt": .windowsCP1252,
        ]
        if let encoding = encodings[name], let data = try? Data(contentsOf: url) {
            return String(data: data, encoding: encoding)
        }
        switch url.pathExtension.lowercased() {
        case "docx", "dotx", "doc", "rtf", "rtfd", "odt", "webarchive":
            return textutil(url)
        case "html":
            return name.contains("1253") ? nil : textutil(url)
        case "txt", "md":
            return try? String(contentsOf: url, encoding: .utf8)
        case "epub", "pdf":
            return text(of: url)
        default:
            return nil
        }
    }

    static func stripTags(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#160;", with: " ")
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) })
    }

    /// The share of the original's words found in the result.
    static func recall(_ original: String, in result: String) -> Double {
        let wanted = words(original)
        guard wanted.count >= 5 else { return 1 }
        return Double(wanted.intersection(words(result)).count) / Double(wanted.count)
    }

    /// Ignores differences in spaces, line breaks and letter case.
    static func contains(_ text: String, _ word: String) -> Bool {
        let squeeze = { (string: String) in string.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        return squeeze(text).contains(squeeze(word))
    }

    /// UTF-8 read as Latin-1, or Greek read as Latin-1.
    static func looksGarbled(_ text: String) -> Bool {
        let signs = ["Ã©", "Ã¨", "Î±", "Îµ", "Ï„", "Ï€", "Ã", "Ç", "Ýå", "ÃÅ", "ÊáëÞ", "Ãåé", "ÔéìÞ"]
        return signs.contains { text.contains($0) }
    }

    static func pictureCount(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "docx", "odt", "epub", "pages":
            guard let zip = try? ZipReader(url: url) else { return 0 }
            return zip.names.filter { ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic"].contains(($0 as NSString).pathExtension.lowercased()) && !$0.contains("preview") }.count
        case "html":
            let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return html.components(separatedBy: "<img").count - 1
        case "rtf":
            let rtf = (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            return rtf.components(separatedBy: "\\pict").count - 1
        case "pdf":
            guard let document = PDFDocument(url: url) else { return 0 }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.pageRef }.reduce(0) { $0 + PDFPictures.frames(on: $1).count }
        default:
            return 0
        }
    }

    static func archiveEntries(_ url: URL) -> [String] {
        guard let data = run("/usr/bin/tar", ["-tf", url.path], environment: ["LANG": "en_US.UTF-8"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { String($0).precomposedStringWithCanonicalMapping }
    }
}

/// What ffprobe says about a video or sound file.
struct Probe: Sendable {
    struct Video: Sendable {
        var width: Int
        var height: Int
        var rotation: Int
        var shown: (Int, Int) { abs(rotation) % 180 == 90 ? (height, width) : (width, height) }
    }

    struct Audio: Sendable {
        var channels: Int
        var sampleRate: Int
    }

    var duration: Double?
    var video: Video?
    var audio: Audio?
    var audioTracks = 0
    var subtitleTracks = 0
    var title: String?
    var cover = false

    static func of(_ url: URL) async -> Probe? {
        guard let ffprobe = ExternalTool.ffmpeg.locate()?.deletingLastPathComponent().appendingPathComponent("ffprobe"),
              let data = Inspect.run(ffprobe.path, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var probe = Probe()
        let format = json["format"] as? [String: Any] ?? [:]
        probe.duration = (format["duration"] as? String).flatMap(Double.init)
        let tags = (format["tags"] as? [String: String] ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        probe.title = tags["title"] ?? tags.first { $0.key.hasSuffix(".title") }?.value
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let disposition = stream["disposition"] as? [String: Int] ?? [:]
            switch stream["codec_type"] as? String {
            case "video" where disposition["attached_pic"] == 1:
                probe.cover = true
            case "video":
                guard probe.video == nil else { continue }
                var rotation = 0
                for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
                    if let value = side["rotation"] as? Int { rotation = value } else if let value = side["rotation"] as? Double { rotation = Int(value) }
                }
                probe.video = Video(width: stream["width"] as? Int ?? 0, height: stream["height"] as? Int ?? 0, rotation: rotation)
            case "audio":
                probe.audioTracks += 1
                if probe.audio == nil {
                    probe.audio = Audio(channels: stream["channels"] as? Int ?? 0, sampleRate: Int(stream["sample_rate"] as? String ?? "") ?? 0)
                }
                if probe.title == nil, let streamTags = stream["tags"] as? [String: String] {
                    probe.title = streamTags.first { $0.key.lowercased() == "title" }?.value
                }
            case "subtitle":
                probe.subtitleTracks += 1
            default:
                break
            }
        }
        return probe
    }

    /// One frame, upright, as a picture.
    static func frame(of url: URL, at seconds: Double) async -> CGImage? {
        guard let ffmpeg = ExternalTool.ffmpeg.locate(),
              let data = Inspect.run(ffmpeg.path, ["-v", "error", "-ss", String(format: "%.3f", seconds), "-i", url.path, "-frames:v", "1", "-vf", "scale=256:-2", "-f", "image2pipe", "-c:v", "png", "-"]),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// The mean volume, in dB.
    static func loudness(_ url: URL) async -> Double? {
        guard let ffmpeg = ExternalTool.ffmpeg.locate() else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "info", "-nostats", "-i", url.path, "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let match = text.firstMatch(of: /mean_volume: (-?[0-9.]+) dB/) else { return nil }
        return Double(match.1)
    }

    /// The loudness streaming services measure, in LUFS.
    static func integratedLoudness(_ url: URL) async -> Double? {
        guard let ffmpeg = ExternalTool.ffmpeg.locate() else { return nil }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "info", "-nostats", "-i", url.path, "-map", "0:a:0", "-af", "ebur128", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let match = text.matches(of: /I:\s+(-?[0-9.]+) LUFS/).last else { return nil }
        return Double(match.1)
    }
}

// MARK: - The report

enum BenchReport {
    static func write(_ outcomes: [BenchOutcome], to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(outcomes).write(to: folder.appendingPathComponent("results.json"))

        var lines = ["# Bench results", ""]
        let bad = outcomes.filter { !$0.problems.isEmpty || $0.status == .failed }
        lines.append("\(outcomes.count) jobs: \(outcomes.filter { $0.status == .ok && $0.problems.isEmpty }.count) fine, \(outcomes.filter { $0.status == .skipped }.count) skipped, \(bad.count) with problems.")
        lines.append("")
        lines.append("## Problems")
        lines.append("")
        lines.append("| File | Job | Result | Problems |")
        lines.append("|---|---|---|---|")
        for outcome in bad.sorted(by: { ($0.category, $0.source, $0.label) < ($1.category, $1.source, $1.label) }) {
            let what = outcome.status == .failed ? "failed: \(outcome.message ?? "")" : outcome.status.rawValue
            lines.append("| \(outcome.category)/\(outcome.source) | \(outcome.label) | \(cell(what)) | \(cell(outcome.problems.joined(separator: "; "))) |")
        }
        lines.append("")
        lines.append("## Skipped")
        lines.append("")
        for outcome in outcomes.filter({ $0.status == .skipped }).sorted(by: { ($0.source, $0.label) < ($1.source, $1.label) }) {
            lines.append("- \(outcome.category)/\(outcome.source) · \(outcome.label): \(outcome.message ?? "")")
        }
        lines.append("")
        lines.append("## Slowest")
        lines.append("")
        for outcome in outcomes.sorted(by: { $0.seconds > $1.seconds }).prefix(25) {
            lines.append(String(format: "- %.1f s · %@ · %@", outcome.seconds, outcome.source, outcome.label))
        }
        lines.append("")
        lines.append("## Most memory (worker's peak)")
        lines.append("")
        for outcome in outcomes.filter({ $0.megabytes != nil }).sorted(by: { $0.megabytes! > $1.megabytes! }).prefix(25) {
            lines.append(String(format: "- %.0f MB · %@ · %@", outcome.megabytes!, outcome.source, outcome.label))
        }
        let memories = outcomes.compactMap(\.megabytes).sorted()
        if !memories.isEmpty {
            lines.append("")
            lines.append(String(format: "Median worker peak: %.0f MB; 90th percentile: %.0f MB; most: %.0f MB.", memories[memories.count / 2], memories[memories.count * 9 / 10], memories.last!))
        }
        lines.append("")
        lines.append("## Notes")
        lines.append("")
        for outcome in outcomes where !outcome.notes.isEmpty {
            lines.append("- \(outcome.category)/\(outcome.source) · \(outcome.label): \(outcome.notes.joined(separator: "; "))")
        }
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
