import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// How Pinwheel reads text in pictures and scanned pages: with Apple's
/// Vision (built in, many languages but no Greek), or with Tesseract from
/// Homebrew (Greek and many more, with the right language files).
public struct TextRecognition: Codable, Sendable, Equatable {
    public enum Engine: String, Codable, Sendable {
        case vision, tesseract
    }

    public var engine = Engine.vision
    /// Tesseract's program, when `engine` is `.tesseract`.
    public var tesseractURL: URL?
    /// The folder with the language files, when it isn't Tesseract's own.
    public var dataFolder: URL?
    /// Tesseract's language codes, e.g. ["ell", "eng"] for Greek and English.
    public var languages: [String] = ["eng"]
    /// Automatic: a picture read with Tesseract is read with Vision too,
    /// and the better reading is kept (see `TextRecognizer.recognizePicture`).
    public var checksWithVision = false

    public init() {}

    public static let languageNames = [
        "ell": "Greek", "eng": "English", "deu": "German", "fra": "French", "spa": "Spanish", "ita": "Italian",
        "por": "Portuguese", "nld": "Dutch", "rus": "Russian", "tur": "Turkish", "ara": "Arabic", "grc": "Ancient Greek",
    ]
}

/// One word and where it is: `box` is a share (0…1) of the picture, from
/// its top left corner.
struct RecognizedWord: Sendable, Equatable {
    var text: String
    var box: CGRect
    /// How sure the engine is (0…1).
    var confidence = 1.0

    init(text: String, box: CGRect, confidence: Double = 1) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

struct RecognizedLine: Sendable, Equatable {
    var words: [RecognizedWord]
    /// A new paragraph starts here (plain text gets a blank line before it).
    var startsParagraph = false

    var text: String { words.map(\.text).joined(separator: " ") }
}

struct RecognizedText: Sendable, Equatable {
    var lines: [RecognizedLine] = []

    /// The lines in reading order, with blank lines between paragraphs.
    var string: String {
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 { result += line.startsParagraph ? "\n\n" : "\n" }
            result += line.text
        }
        return result
    }

    var isEmpty: Bool { lines.allSatisfy { $0.words.isEmpty } }
}

enum TextRecognizer {
    static func recognize(_ image: CGImage, settings: TextRecognition) async throws -> RecognizedText {
        switch settings.engine {
        case .vision:
            return try await Blocking.run { _ in try vision(image) }
        case .tesseract:
            guard let program = settings.tesseractURL else {
                throw ConversionError.failed("Tesseract isn't installed. Install it with: brew install tesseract")
            }
            return try await tesseract(image, program: program, settings: settings)
        }
    }

    /// One picture (not a PDF page). With `checksWithVision`, Vision reads it
    /// too, and the better reading is kept: Tesseract reads Greek, which
    /// Vision can't, but finds little in photos, which Vision reads well.
    static func recognizePicture(_ image: CGImage, settings: TextRecognition) async throws -> RecognizedText {
        guard settings.engine == .tesseract, settings.checksWithVision else { return try await recognize(image, settings: settings) }
        async let byVision = Blocking.run { _ in try vision(image) }
        let tesseract: RecognizedText
        do {
            tesseract = try await recognize(image, settings: settings)
        } catch {
            if let read = try? await byVision, !read.isEmpty { return read }
            throw error
        }
        guard let read = try? await byVision else { return tesseract }
        return better(tesseract: tesseract, vision: read)
    }

    /// Tesseract's reading when it has Greek, or about as much as Vision
    /// found (its order of blocks suits screenshots); Vision's otherwise.
    static func better(tesseract: RecognizedText, vision: RecognizedText) -> RecognizedText {
        // The words an engine is sure of, with two letters or digits or more.
        func sure(_ text: RecognizedText, from least: Double) -> [String] {
            text.lines.flatMap(\.words).filter { $0.confidence >= least && $0.text.count(where: { $0.isLetter || $0.isNumber }) >= 2 }.map(\.text)
        }
        let tesseractWords = sure(tesseract, from: 0.6)
        if tesseractWords.count(where: { $0.count(where: \.isGreekLetter) >= 2 }) >= 2 { return tesseract }
        func characters(_ words: [String]) -> Int { words.reduce(0) { $0 + $1.count(where: { $0.isLetter || $0.isNumber }) } }
        return characters(tesseractWords) * 10 >= characters(sure(vision, from: 0.3)) * 8 ? tesseract : vision
    }

    // MARK: - Vision

    /// Apple's text recognition, the one Live Text uses.
    static func vision(_ image: CGImage) throws -> RecognizedText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VisionTurns.perform([request], on: image)
        } catch {
            throw ConversionError.failed("Couldn't read the text: \(error.localizedDescription)")
        }
        // Vision's y points up; sort into reading order by rows, then left to right.
        let observations = (request.results ?? []).sorted { a, b in
            let rowA = (a.boundingBox.midY * 60).rounded(), rowB = (b.boundingBox.midY * 60).rounded()
            return rowA != rowB ? rowA > rowB : a.boundingBox.minX < b.boundingBox.minX
        }
        var text = RecognizedText()
        var previous: CGRect?
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            var words: [RecognizedWord] = []
            var tokenStart: String.Index?
            func addWord(upTo end: String.Index) {
                guard let start = tokenStart else { return }
                let range = start..<end
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                words.append(RecognizedWord(text: String(string[range]), box: topLeft(box), confidence: Double(candidate.confidence)))
                tokenStart = nil
            }
            for index in string.indices {
                if string[index].isWhitespace {
                    addWord(upTo: index)
                } else if tokenStart == nil {
                    tokenStart = index
                }
            }
            addWord(upTo: string.endIndex)
            let box = topLeft(observation.boundingBox)
            // A gap taller than a line between two lines starts a paragraph.
            let paragraph = previous.map { box.minY - $0.maxY > $0.height * 0.9 } ?? false
            text.lines.append(RecognizedLine(words: words, startsParagraph: paragraph))
            previous = box
        }
        return text
    }

    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    // MARK: - Tesseract

    static func tesseract(_ image: CGImage, program: URL, settings: TextRecognition) async throws -> RecognizedText {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pinwheel-OCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let picture = folder.appendingPathComponent("page.png")
        guard let destination = CGImageDestinationCreateWithURL(picture as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.failed("Couldn't prepare the picture for Tesseract.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("Couldn't prepare the picture for Tesseract.") }

        let output = folder.appendingPathComponent("text")
        var arguments = [
            picture.path, output.path, "-l", settings.languages.joined(separator: "+"), "--psm", "3",
            // Words with their boxes (the tsv config file may not be in a custom folder).
            "-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=0",
        ]
        if let data = settings.dataFolder { arguments += ["--tessdata-dir", data.path] }
        let result = try await ProcessRunner.run(program, arguments)
        let tsv = output.appendingPathExtension("tsv")
        guard result.status == 0, let table = try? String(contentsOf: tsv, encoding: .utf8) else {
            throw ConversionError.failed(tesseractError(result.stderr, languages: settings.languages))
        }
        return parseTSV(table, width: image.width, height: image.height)
    }

    /// Tesseract's word table: level 5 rows are words, grouped into lines by
    /// block, paragraph and line number.
    static func parseTSV(_ table: String, width: Int, height: Int) -> RecognizedText {
        var text = RecognizedText()
        var currentKey: [Int]?
        var lastParagraph: [Int]?
        for row in table.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = row.split(separator: "\t", maxSplits: 11, omittingEmptySubsequences: false)
            guard columns.count == 12, columns[0] == "5" else { continue }
            let numbers = columns[1...9].map { Int($0) ?? 0 }
            let word = fixGreek(String(columns[11]).trimmingCharacters(in: .whitespaces))
            guard !word.isEmpty else { continue }
            let (page, block, paragraph, line) = (numbers[0], numbers[1], numbers[2], numbers[3])
            let box = CGRect(
                x: Double(numbers[5]) / Double(max(width, 1)), y: Double(numbers[6]) / Double(max(height, 1)),
                width: Double(numbers[7]) / Double(max(width, 1)), height: Double(numbers[8]) / Double(max(height, 1))
            )
            let key = [page, block, paragraph, line]
            if key != currentKey {
                let paragraphKey = [page, block, paragraph]
                text.lines.append(RecognizedLine(words: [], startsParagraph: lastParagraph != nil && paragraphKey != lastParagraph))
                currentKey = key
                lastParagraph = paragraphKey
            }
            let confidence = (Double(columns[10]) ?? 0) / 100
            text.lines[text.lines.count - 1].words.append(RecognizedWord(text: word, box: box, confidence: confidence))
        }
        return text
    }

    /// Tesseract sometimes reads Greek μ as the look-alike micro sign µ.
    static func fixGreek(_ word: String) -> String {
        guard word.contains("\u{00B5}"), word.contains(where: \.isGreekLetter) else { return word }
        return word.replacingOccurrences(of: "\u{00B5}", with: "\u{03BC}")
    }

    private static func tesseractError(_ stderr: String, languages: [String]) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        if let missing = lines.first(where: { $0.hasPrefix("Failed loading language") }),
           let code = languages.first(where: { missing.contains("'\($0)'") }) {
            let name = TextRecognition.languageNames[code] ?? code
            return "Tesseract doesn't have the \(name) language file. Add it in Pinwheel's Settings › Text Recognition."
        }
        let reason = lines.last { !$0.contains("grc") && !$0.contains("TESSDATA_PREFIX") } ?? "it stopped with an error"
        return "Tesseract couldn't read the text: \(reason)"
    }
}

/// Tesseract's language files: which are there, and getting Greek.
public enum TesseractData {
    /// The folder Tesseract uses on its own, e.g. /opt/homebrew/share/tessdata.
    public static func builtInFolder(for program: URL) -> URL {
        // Homebrew keeps the files in ../share/tessdata next to bin.
        program.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/tessdata", isDirectory: true)
    }

    /// Language codes with a file in `folder` ("eng", "ell"…).
    public static func languages(in folder: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".traineddata") }.map { String($0.dropLast(".traineddata".count)) })
            .subtracting(["osd", "equ"])
    }

    /// Where a downloaded language file goes: Pinwheel's own folder, with
    /// links to Tesseract's own files so both can be used together.
    public static var ownFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinwheel/tessdata", isDirectory: true)
    }

    /// The best-quality model for a language, from the Tesseract project.
    public static func downloadURL(for code: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/main/\(code).traineddata")!
    }

    /// Puts a downloaded language file in `folder` and links Tesseract's own
    /// languages next to it.
    public static func install(_ downloaded: URL, code: String, into folder: URL = ownFolder, linking builtIn: URL?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(code).traineddata")
        // A real file is at least a few hundred kilobytes; an error page is not.
        let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 200_000 else { throw ConversionError.failed("The download didn't finish. Check the internet connection and try again.") }
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: downloaded, to: target)
        try linkBuiltIn(builtIn, into: folder)
    }

    /// Links Tesseract's own language files into `folder` (missing ones only).
    public static func linkBuiltIn(_ builtIn: URL?, into folder: URL) throws {
        guard let builtIn else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: builtIn.path)) ?? []
        for file in files where file.hasSuffix(".traineddata") {
            let link = folder.appendingPathComponent(file)
            guard (try? link.checkResourceIsReachable()) != true else { continue }
            try? FileManager.default.removeItem(at: link)  // a broken link from an older Tesseract
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: builtIn.appendingPathComponent(file))
        }
    }
}
