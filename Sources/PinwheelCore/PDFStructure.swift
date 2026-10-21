import AppKit
import ImageIO
import PDFKit

/// What's on a PDF's pages, as a document whose text flows again
/// (headings, paragraphs, lists) or as tables; scanned pages are read with
/// text recognition.
enum PDFStructure {
    /// One line of text on a page.
    struct Line {
        var runs: [Document.Run]
        /// The size most of its letters have.
        var size: CGFloat
        var bold: Bool
        var mono: Bool
        /// Where it is on the page (y goes up, as in PDFs).
        var frame: CGRect
        var page: Int
        var pageSize: CGSize
        /// From text recognition: a new paragraph starts here.
        var startsParagraph = false
        /// A table found on the page, standing in for its lines.
        var table: [[String]]?

        var text: String { runs.text }
    }

    // MARK: - Text that flows again

    /// Returns the document and how many pages were scans.
    static func document(
        _ url: URL, recognition: TextRecognition, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Document, Int) {
        let pdf = try PDFConverter.open(url)
        let count = pdf.pageCount
        var lines: [Line] = []
        var scans: [Int] = []
        var sizes: [Int: CGSize] = [:]
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            sizes[index] = page.bounds(for: .mediaBox).size
            let found = Self.lines(of: page, index: index)
            if found.isEmpty { scans.append(index) } else { lines += inReadingOrder(withTables(joiningPieces(found), on: page)) }
            progress(0.6 * Double(index + 1) / Double(max(count, 1)))
        }
        let scanCount = scans.count
        let recognized = try await ScannedPages.read(url, pages: scans, recognition: recognition) { done in
            progress(0.6 + 0.35 * Double(done) / Double(max(scanCount, 1)))
        }
        for (index, text) in recognized {
            lines += Self.lines(of: text, page: index, size: sizes[index] ?? PaperSize.current)
        }
        lines.sort { $0.page < $1.page }  // stable: each page keeps its own order
        let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return (Document(title: title?.isEmpty == false ? title : nil, blocks: assemble(lines)), recognized.values.filter { !$0.isEmpty }.count)
    }

    /// The lines of a page with text, with their fonts. (Line by line as
    /// they're drawn: the page's text sometimes runs several into one.)
    static func lines(of page: PDFPage, index: Int) -> [Line] {
        let pageSize = page.bounds(for: .mediaBox).size
        // The fonts come from the page's text (asking each line for its own
        // is slow, and fills the log), unless its pieces are out of order
        // there, as right-to-left lines can be.
        guard let pageText = page.attributedString, pageText.length > 0,
              let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return all.selectionsByLine().compactMap { selection -> Line? in
            var pieces = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            var attributed = pageText
            if pieces.contains(where: { $0.location == NSNotFound || NSMaxRange($0) > pageText.length })
                || pieces.map({ pageText.attributedSubstring(from: $0).string }).joined().trimmingCharacters(in: .newlines) != selection.string {
                guard let own = selection.attributedString else { return nil }
                attributed = own
                pieces = [NSRange(location: 0, length: own.length)]
            }
            let string = attributed.string as NSString
            var runs: [Document.Run] = []
            var sizes: [CGFloat: Int] = [:]
            var bold = 0, mono = 0, total = 0
            for range in pieces {
                attributed.enumerateAttribute(.font, in: range) { value, runRange, _ in
                    let text = withoutLigatures(string.substring(with: runRange)).filter { !$0.isNewline }
                    let font = value as? NSFont
                    let look = Self.look(of: font)
                    let letters = text.filter { !$0.isWhitespace }.count
                    sizes[((font?.pointSize ?? 0) * 2).rounded() / 2, default: 0] += letters
                    if look.bold { bold += letters }
                    if look.mono { mono += letters }
                    total += letters
                    runs.append(Document.Run(text, bold: look.bold, italic: look.italic, code: look.mono))
                }
            }
            guard total > 0 else { return nil }
            // A line in one look throughout carries it as the line's, not the run's.
            var merged = runs.merged.filter { !$0.text.isEmpty }
            if bold == total { merged = merged.map { var run = $0; run.bold = false; return run } }
            if mono == total { merged = merged.map { var run = $0; run.code = false; return run } }
            merged[0].text = String(merged[0].text.drop { $0 == " " })
            while let last = merged.last?.text, last.hasSuffix(" ") { merged[merged.count - 1].text.removeLast() }
            return Line(
                runs: merged.filter { !$0.text.isEmpty }, size: sizes.max { $0.value < $1.value }?.key ?? 0,
                bold: bold == total, mono: mono == total, frame: selection.bounds(for: page), page: index, pageSize: pageSize
            )
        }
    }

    /// "ﬁ" and its kind, as the letters they join.
    static func withoutLigatures(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) }) else { return text }
        let letters: [Character: String] = ["ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"]
        return text.map { letters[$0] ?? String($0) }.joined()
    }

    /// Pieces of one line the PDF keeps apart, joined: a list marker and
    /// its text ("1." on its own, then the text), or text set close by.
    static func joiningPieces(_ lines: [Line]) -> [Line] {
        var result = lines
        var markers = lines.map { isMarker($0.text) }
        var index = 0
        while index < result.count {
            let line = result[index]
            let marker = markers[index]
            let piece = result.indices.filter { candidate in
                let other = result[candidate]
                let gap = other.frame.minX - line.frame.maxX
                return candidate != index && !markers[candidate] && other.page == line.page
                    && abs(other.frame.midY - line.frame.midY) < max(other.frame.height, line.frame.height) * 0.4
                    && gap > -1 && gap < max(other.size, line.size) * (marker ? 4 : 1)
            }.min { result[$0].frame.minX < result[$1].frame.minX }
            guard let piece else {
                index += 1
                continue
            }
            let other = result[piece]
            var joined = line
            joined.runs = line.runs + [Document.Run(" ")] + other.runs
            joined.frame = line.frame.union(other.frame)
            joined.bold = line.bold && other.bold
            joined.mono = line.mono && other.mono
            // The size of most of it (a marker's own doesn't count).
            joined.size = marker || other.text.count > line.text.count ? other.size : line.size
            result[index] = joined
            markers[index] = false
            result.remove(at: piece)
            markers.remove(at: piece)
            if piece < index { index -= 1 }
        }
        return result
    }

    /// "•", "1.", "a)" alone.
    static func isMarker(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count == 1, let only = text.first { return "•●◦▪‣∙·■□–—*-".contains(only) }
        guard let last = text.last, last == "." || last == ")" else { return false }
        let body = text.dropLast()
        if body.count == 1, let only = body.first, only.isASCII, only.isLetter { return true }
        return (1...3).contains(body.count) && body.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Top to bottom, when the page has one column of text: PDFs don't
    /// always keep their text in order. (With lines side by side, such as
    /// columns, the order the PDF gives is better.)
    static func inReadingOrder(_ lines: [Line]) -> [Line] {
        let sorted = lines.sorted { $0.frame.midY > $1.frame.midY }
        for (above, below) in zip(sorted, sorted.dropFirst())
        where above.frame.midY - below.frame.midY < min(above.frame.height, below.frame.height) * 0.5 {
            return lines
        }
        return sorted
    }

    /// The page's lines, with each table found among them as one line
    /// standing in for its lines, where the table is.
    static func withTables(_ lines: [Line], on page: PDFPage) -> [Line] {
        guard let first = lines.first else { return lines }
        var result = lines
        for table in layout(words(of: page)) where table.isTable {
            let area = table.frame.insetBy(dx: -2, dy: -2)
            result.removeAll { $0.table == nil && area.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            let line = Line(runs: [], size: 0, bold: false, mono: false, frame: table.frame, page: first.page, pageSize: first.pageSize, table: table.rows)
            // Before the first line below it.
            let position = result.firstIndex { $0.table == nil && $0.frame.maxY < table.frame.minY + 1 } ?? result.endIndex
            result.insert(line, at: position)
        }
        return result
    }

    static func look(of font: NSFont?) -> (bold: Bool, italic: Bool, mono: Bool) {
        guard let font else { return (false, false, false) }
        let traits = font.fontDescriptor.symbolicTraits
        let name = font.fontName.lowercased()
        let bold = traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains(where: name.contains)
        let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
        let mono = traits.contains(.monoSpace) || ["mono", "courier", "menlo", "consolas", "monaco"].contains(where: name.contains)
        return (bold, italic, mono)
    }

    /// Lines read from a scanned page (sizes from how tall the words are).
    static func lines(of text: RecognizedText, page: Int, size: CGSize) -> [Line] {
        text.lines.compactMap { line in
            guard !line.words.isEmpty else { return nil }
            let box = line.words.map(\.box).reduce(line.words[0].box) { $0.union($1) }
            let frame = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
            return Line(
                runs: [Document.Run(line.text)], size: (frame.height * 0.7 * 2).rounded() / 2, bold: false, mono: false,
                frame: frame, page: page, pageSize: size, startsParagraph: line.startsParagraph
            )
        }
    }

    /// Lines into headings, paragraphs, list items and code.
    static func assemble(_ all: [Line]) -> [Document.Block] {
        let lines = withoutFurniture(all)
        guard !lines.isEmpty else { return [] }
        var sizeCounts: [CGFloat: Int] = [:]
        // The size most text has is the body's (code, set smaller, aside).
        for line in lines where !line.mono || lines.allSatisfy(\.mono) { sizeCounts[line.size, default: 0] += line.text.count }
        let body = sizeCounts.max { $0.value < $1.value }?.key ?? 11
        let headingSizes = sizeCounts.keys.filter { $0 >= body * 1.15 && $0 >= body + 1 }.sorted(by: >)
        // Where body text starts on each page (where most of it does), to
        // tell indented lines.
        var left: [Int: CGFloat] = [:]
        for page in Set(lines.map(\.page)) {
            var letters: [CGFloat: Int] = [:]
            for line in lines where line.page == page && line.size == body {
                letters[(line.frame.minX / 2).rounded() * 2, default: 0] += line.text.count
            }
            left[page] = letters.max { $0.value < $1.value }?.key ?? lines.first { $0.page == page }?.frame.minX ?? 0
        }

        var blocks: [Document.Block] = []
        var previous: Line?
        var open: (kind: OpenKind, runs: [Document.Run])?
        /// What numbered items had before them ("2."), and where list
        /// items' markers are, by block.
        var numbers: [Int: String] = [:]
        var openNumber = ""
        var markers: [Int: CGFloat] = [:]
        /// Where the open list item's marker is.
        var markerX: CGFloat = 0

        func close() {
            guard let current = open else { return }
            let runs = current.runs.merged
            switch current.kind {
            case .paragraph: blocks.append(.paragraph(runs))
            case .listItem(let ordered, let level):
                if ordered { numbers[blocks.count] = openNumber }
                markers[blocks.count] = markerX
                blocks.append(.listItem(ordered: ordered, level: level, runs))
            case .heading(let level): blocks.append(.heading(level, runs))
            case .code: blocks.append(.code(runs.text))
            }
            open = nil
        }

        func append(_ line: Line, to runs: inout [Document.Run], joinedWith separator: String = " ") {
            var newRuns = line.runs
            if let last = runs.last?.text, last.hasSuffix("-"), last.dropLast().last?.isLetter == true,
               line.text.first?.isLowercase == true {
                // A word broken at the end of the line, joined again.
                runs[runs.count - 1].text.removeLast()
            } else if separator == "\n" {
                newRuns.insert(Document.Run("\n"), at: 0)
            } else if let last = runs.last?.text, !last.hasSuffix(" ") {
                newRuns[0].text = " " + newRuns[0].text.drop { $0 == " " }
            }
            runs += newRuns
        }

        for (index, line) in lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            defer { previous = line }

            if let table = line.table {
                close()
                blocks.append(.table(table))
                continue
            }

            // Headings: bigger than the body, or a short line all in bold.
            if let rank = headingSizes.firstIndex(of: line.size), text.count < 150 {
                let level = min(rank + 1, 6)
                // A heading goes on to the next line only from a full one.
                if case .heading(level)? = open?.kind, let previous, sameBlock(previous, line, gapFactor: 0.9),
                   !isShort(previous, left: left[line.page] ?? 0), listMarker(text) == nil {
                    append(line, to: &open!.runs)
                } else {
                    close()
                    open = (.heading(level), line.runs)
                }
                continue
            }
            if line.bold && text.count < 80 && !text.hasSuffix(".") && !text.hasSuffix(",") && next.map({ !$0.bold }) ?? true {
                close()
                blocks.append(.heading(min(headingSizes.count + 1, 6), line.runs))
                continue
            }
            if let (ordered, rest) = listMarker(text) {
                close()
                openNumber = String(text.dropLast(rest.count)).trimmingCharacters(in: .whitespaces)
                var runs = line.runs
                runs[0].text = String(runs[0].text.drop { $0 == " " }.dropFirst(text.count - rest.count))
                open = (.listItem(ordered, 0), runs.filter { !$0.text.isEmpty })  // levels come with the whole list
                markerX = line.frame.minX
                continue
            }
            if line.mono {
                if open?.kind == .code { append(line, to: &open!.runs, joinedWith: "\n") } else { close(); open = (.code, line.runs) }
                continue
            }
            // The paragraph (or list item) before goes on, or a new one starts.
            // A list item's next lines are set in, past its marker.
            let isItem = if case .listItem? = open?.kind { true } else { false }
            if let current = open, let previous, previous.table == nil, current.kind != .code, !current.kind.isHeading,
               !isItem || line.frame.minX > markerX + line.size * 0.5,
               continues(previous, line, left: left[line.page] ?? 0, body: body, inItem: isItem) {
                append(line, to: &open!.runs)
            } else {
                close()
                open = (.paragraph, line.runs)
            }
        }
        close()
        return finishingLists(blocks, numbers: numbers, markers: markers)
    }

    /// Each list's levels, from how far in its markers are (the first
    /// level is the one furthest left). And lists are numbered from 1 again,
    /// so a numbered line on its own (a numbered section, say) or a list
    /// that doesn't start at 1 keeps its numbers as text.
    private static func finishingLists(_ blocks: [Document.Block], numbers: [Int: String], markers: [Int: CGFloat]) -> [Document.Block] {
        var blocks = blocks
        var index = 0
        while index < blocks.count {
            guard case .listItem = blocks[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < blocks.count, case .listItem = blocks[end + 1] { end += 1 }
            var indents: [CGFloat] = []
            for x in (index...end).compactMap({ markers[$0] }).sorted() where indents.last.map({ x - $0 > 6 }) ?? true { indents.append(x) }
            for item in index...end {
                guard case .listItem(let ordered, _, let runs) = blocks[item] else { continue }
                let level = indents.lastIndex { $0 <= (markers[item] ?? 0) + 6 } ?? 0
                blocks[item] = .listItem(ordered: ordered, level: min(level, 8), runs)
            }
            if case .listItem(true, _, _) = blocks[index], let first = numbers[index],
               end == index || !["1", "a", "A", "i"].contains(String(first.dropLast())) {
                for item in index...end {
                    if case .listItem(true, _, let runs) = blocks[item], let number = numbers[item] {
                        blocks[item] = .paragraph(([Document.Run(number + " ")] + runs).merged)
                    }
                }
            }
            index = end + 1
        }
        return blocks
    }

    /// The block being put together from lines.
    private enum OpenKind: Equatable {
        case paragraph, listItem(Bool, Int), heading(Int), code

        var isHeading: Bool {
            if case .heading = self { return true }
            return false
        }
    }

    /// Whether `line` goes on the paragraph `previous` was in.
    static func continues(_ previous: Line, _ line: Line, left: CGFloat, body: CGFloat, inItem: Bool = false) -> Bool {
        if line.startsParagraph { return false }
        let lastText = previous.text.trimmingCharacters(in: .whitespaces)
        let endsSentence = [".", "!", "?", ":", "”", "\""].contains { lastText.hasSuffix($0) }
        if line.page != previous.page {
            // Across a page: only an unfinished sentence goes on.
            return line.page == previous.page + 1 && !endsSentence
        }
        if abs(line.size - previous.size) > 1 { return false }
        guard sameBlock(previous, line, gapFactor: 0.75) else { return false }
        // A first line set in (indented) starts a paragraph (a list item's
        // next lines are set in past its marker).
        if !inItem && line.frame.minX > max(previous.frame.minX, left) + line.size * 0.9 { return false }
        // A short line ending a sentence ended its paragraph; a list item
        // only goes on from a full line.
        if isShort(previous, left: left) && (endsSentence || inItem) { return false }
        return true
    }

    /// Ends well before the right margin (taken to be as wide as the left).
    static func isShort(_ line: Line, left: CGFloat) -> Bool {
        line.frame.maxX < line.pageSize.width - left - line.pageSize.width * 0.18
    }

    /// Close enough above to be the line before in the same block.
    static func sameBlock(_ previous: Line, _ line: Line, gapFactor: CGFloat) -> Bool {
        guard previous.page == line.page else { return false }
        let gap = previous.frame.minY - line.frame.maxY
        let height = max(previous.frame.height, line.frame.height, 1)
        return gap > -height * 0.5 && gap < height * gapFactor
    }

    /// "• Item", "- Item", "1. Item", "a) Item": whether it's numbered, and the text after the marker.
    static func listMarker(_ text: String) -> (ordered: Bool, rest: String)? {
        if let match = text.firstMatch(of: /^[•●◦▪‣∙·■□–—*-]\s+(.+)$/) { return (false, String(match.1)) }
        if let match = text.firstMatch(of: /^(\d{1,3}|[a-z])[.)]\s+(.+)$/) { return (true, String(match.2)) }
        return nil
    }

    /// Without page numbers and the headers and footers repeated on most pages.
    static func withoutFurniture(_ lines: [Line]) -> [Line] {
        let pages = Set(lines.map(\.page)).count
        func isEdge(_ line: Line) -> Bool {
            line.frame.minY > line.pageSize.height * 0.9 || line.frame.maxY < line.pageSize.height * 0.1
        }
        func key(_ line: Line) -> String {
            line.text.trimmingCharacters(in: .whitespaces).replacing(/\d+/, with: "#").lowercased()
        }
        var counts: [String: Set<Int>] = [:]
        for line in lines where isEdge(line) { counts[key(line), default: []].insert(line.page) }
        return lines.filter { line in
            guard isEdge(line), line.table == nil else { return true }
            let text = line.text.trimmingCharacters(in: .whitespaces).lowercased()
            if text.wholeMatch(of: /(page\s*)?\d+(\s*(\/|of)\s*\d+)?/) != nil { return false }
            return pages < 3 || (counts[key(line)]?.count ?? 0) < max(3, pages / 2)
        }
    }

    // MARK: - Pages as pictures

    /// Each page as a JPEG, for documents and slides that must look the same.
    static func pagePictures(_ url: URL, dpi: Double = 150, progress: @escaping @Sendable (Double) -> Void) throws -> [(data: Data, size: CGSize)] {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url.lastPathComponent) }
        if !document.isUnlocked { _ = document.unlockWithPassword("") }
        guard document.isUnlocked else { throw ConversionError.failed("\(url.lastPathComponent) is password-protected.") }
        var pictures: [(Data, CGSize)] = []
        for number in 1...max(document.numberOfPages, 1) {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            let image = try PDFConverter.render(page, dpi: dpi)
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
            let box = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            pictures.append((data as Data, turned ? CGSize(width: box.height, height: box.width) : box.size))
            progress(Double(number) / Double(document.numberOfPages))
        }
        return pictures
    }

    // MARK: - Tables

    /// A word and where it is (y goes up).
    struct Word {
        var text: String
        var frame: CGRect
    }

    /// Each page as a sheet: lines become rows, and words lined up under
    /// each other become columns.
    static func workbook(_ url: URL, recognition: TextRecognition, progress: @escaping @Sendable (Double) -> Void) async throws -> Workbook {
        let pdf = try PDFConverter.open(url)
        var words: [Int: [Word]] = [:]
        var scans: [Int] = []
        var sizes: [Int: CGSize] = [:]
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            sizes[index] = page.bounds(for: .mediaBox).size
            let found = Self.words(of: page)
            if found.isEmpty { scans.append(index) } else { words[index] = found }
            progress(0.5 * Double(index + 1) / Double(max(pdf.pageCount, 1)))
        }
        let scanCount = scans.count
        let recognized = try await ScannedPages.read(url, pages: scans, recognition: recognition) { done in
            progress(0.5 + 0.45 * Double(done) / Double(max(scanCount, 1)))
        }
        for (index, text) in recognized {
            let size = sizes[index] ?? PaperSize.current
            words[index] = text.lines.flatMap(\.words).map { word in
                Word(text: word.text, frame: CGRect(x: word.box.minX * size.width, y: (1 - word.box.maxY) * size.height,
                                                    width: word.box.width * size.width, height: word.box.height * size.height))
            }
        }
        let sheets = words.keys.sorted().map { page in
            Workbook.Sheet(name: "Page \(page + 1)", rows: grid(words[page] ?? []))
        }
        return Workbook(sheets: sheets.filter { !$0.rows.isEmpty })
    }

    /// The words of a page: what's between spaces, placed by selecting it
    /// (`characterBounds(at:)` drifts by one after each line break).
    static func words(of page: PDFPage) -> [Word] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        return wordPattern.matches(in: string, range: NSRange(location: 0, length: text.length)).compactMap { match in
            guard let frame = page.selection(for: match.range)?.bounds(for: page), !frame.isEmpty else { return nil }
            return Word(text: withoutLigatures(text.substring(with: match.range)), frame: frame)
        }
    }

    private static var wordPattern: NSRegularExpression { try! NSRegularExpression(pattern: #"\S+"#) }

    /// Words into rows and columns, for a sheet: the page's tables when it
    /// has some (a row apart), or else every line.
    static func grid(_ words: [Word]) -> [[Workbook.Cell]] {
        let blocks = layout(words)
        let tables = blocks.filter(\.isTable)
        var rows: [[String]] = []
        if tables.isEmpty {
            rows = blocks.flatMap(\.rows)
        } else {
            for (index, table) in tables.enumerated() {
                if index > 0 { rows.append([""]) }
                rows += table.rows
            }
        }
        return rows.map { $0.map { $0.isEmpty ? .empty : Workbook.Cell.guess($0) } }
    }

    /// Lines on a page, or lines with gaps lined up in columns.
    struct Block {
        /// One cell each for a line; as many as there are columns otherwise ("" when empty).
        var rows: [[String]]
        var frame: CGRect
        /// Rows and columns of short cells: a table in a document too.
        var isTable: Bool
    }

    /// Words into lines, top to bottom, split into cells where the gaps are
    /// wide; lines with several cells, one after another, line up in columns.
    static func layout(_ words: [Word]) -> [Block] {
        guard !words.isEmpty else { return [] }
        let heights = words.map(\.frame.height).sorted()
        let height = max(heights[heights.count / 2], 1)
        // Lines: words at the same height, top to bottom.
        var lines: [[Word]] = []
        for word in words.sorted(by: { $0.frame.midY > $1.frame.midY }) {
            if let last = lines.last?.first, abs(last.frame.midY - word.frame.midY) < height * 0.5 {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }
        // Cells: words close together on a line (about a space apart).
        let rows: [[Word]] = lines.map { line in
            var cells: [Word] = []
            for word in line.sorted(by: { $0.frame.minX < $1.frame.minX }) {
                if var last = cells.last, word.frame.minX - last.frame.maxX < height * 0.5 {
                    last.text += " " + word.text
                    last.frame = last.frame.union(word.frame)
                    cells[cells.count - 1] = last
                } else {
                    cells.append(word)
                }
            }
            return cells
        }
        // Lines with several cells go together while their cells fit the
        // same columns: cells that overlap from one line to the next.
        let slack = height * 0.2
        var blocks: [Block] = []
        var run: [[Word]] = []
        var columns: [ClosedRange<CGFloat>] = []
        func finishRun() {
            if !run.isEmpty { blocks.append(block(run, columns: columns)) }
            run = []
            columns = []
        }
        for row in rows {
            guard row.count > 1 else {
                finishRun()
                blocks.append(Block(rows: [[row[0].text]], frame: row[0].frame, isTable: false))
                continue
            }
            if !fits(row, columns, slack: slack) { finishRun() }
            run.append(row)
            columns = merged(columns, row.map(\.frame), slack: slack)
        }
        finishRun()
        return blocks
    }

    /// Whether no two of the line's cells are in one column, and none spans two.
    private static func fits(_ row: [Word], _ columns: [ClosedRange<CGFloat>], slack: CGFloat) -> Bool {
        var used = Set<Int>()
        for cell in row {
            let touching = columns.indices.filter { columns[$0].lowerBound - slack <= cell.frame.maxX && cell.frame.minX <= columns[$0].upperBound + slack }
            if touching.count > 1 { return false }
            if let column = touching.first, !used.insert(column).inserted { return false }
        }
        return true
    }

    /// Columns with the cells added: those that overlap become one.
    private static func merged(_ columns: [ClosedRange<CGFloat>], _ frames: [CGRect], slack: CGFloat) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for range in (columns + frames.map { $0.minX...$0.maxX }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + slack {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Lines with several cells, in their columns.
    private static func block(_ rows: [[Word]], columns: [ClosedRange<CGFloat>]) -> Block {
        let frames = rows.flatMap { $0.map(\.frame) }
        let cells = rows.map { row in
            var result = Array(repeating: "", count: columns.count)
            for cell in row {
                let column = columns.firstIndex { $0.contains(cell.frame.midX) } ?? columns.lastIndex { $0.lowerBound <= cell.frame.midX } ?? 0
                result[column] = result[column].isEmpty ? cell.text : result[column] + " " + cell.text
            }
            return result
        }
        // Not a table: list markers before text, or columns of running text.
        let markers = rows.allSatisfy { isMarker($0[0].text) }
        let wordCounts = rows.flatMap { $0.map { $0.text.split(separator: " ").count } }.sorted()
        let isTable = rows.count > 1 && columns.count > 1 && !markers && wordCounts[wordCounts.count / 2] <= 5
        return Block(rows: cells, frame: frames.dropFirst().reduce(frames[0]) { $0.union($1) }, isTable: isTable)
    }
}
