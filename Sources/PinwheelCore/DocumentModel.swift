import Foundation
import ImageIO

/// A document as Pinwheel reads and writes it: headings, paragraphs, lists,
/// quotes, code, tables and pictures, in order. Every document format is
/// read into this and written out of it, so any can become any other.
public struct Document: Sendable, Equatable {
    public var title: String?
    public var blocks: [Block]

    public init(title: String? = nil, blocks: [Block] = []) {
        self.title = title
        self.blocks = blocks
    }

    public enum Block: Sendable, Equatable {
        /// Level 1 (the biggest) to 6.
        case heading(Int, [Run])
        case paragraph([Run])
        case listItem(ordered: Bool, level: Int, [Run])
        case quote([Run])
        case code(String)
        /// Rows of cells; the first row is the header.
        case table([[String]])
        case image(Picture)
        case pageBreak
        case rule
    }

    /// Text with one look all along.
    public struct Run: Sendable, Equatable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var link: String?

        public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.link = link
        }

        func sameLook(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && code == other.code && link == other.link
        }
    }

    public struct Picture: Sendable, Equatable {
        /// PNG or JPEG.
        public var data: Data
        public var isJPEG: Bool
        /// Size on the page, in points.
        public var width: Double
        public var height: Double
        public var description: String?

        public init(data: Data, isJPEG: Bool, width: Double, height: Double, description: String? = nil) {
            self.data = data
            self.isJPEG = isJPEG
            self.width = width
            self.height = height
            self.description = description
        }

        var fileExtension: String { isJPEG ? "jpg" : "png" }
        var mimeType: String { isJPEG ? "image/jpeg" : "image/png" }
    }

    var isEmpty: Bool {
        blocks.allSatisfy { block in
            switch block {
            case .pageBreak, .rule: true
            case .paragraph(let runs), .heading(_, let runs), .quote(let runs), .listItem(_, _, let runs): runs.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .code(let text): text.isEmpty
            case .table(let rows): rows.isEmpty
            case .image: false
            }
        }
    }

    /// The title, or the first heading's text.
    var displayTitle: String? {
        if let title, !title.isEmpty { return title }
        for case .heading(_, let runs) in blocks { return runs.text }
        return nil
    }
}

extension Array where Element == Document.Run {
    var text: String { map(\.text).joined() }

    /// Neighbours with the same look become one run.
    var merged: [Document.Run] {
        var result: [Document.Run] = []
        for run in self where !run.text.isEmpty {
            if let last = result.last, last.sameLook(as: run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}

// MARK: - Plain text

/// Numbers for list items, by level: a deeper list starts again at 1, and so
/// does a list of the other kind (bullets, then numbers).
struct ListNumbers {
    private var levels: [(ordered: Bool, count: Int)] = []

    mutating func next(ordered: Bool, level: Int) -> Int {
        if levels.count > level + 1 { levels.removeLast(levels.count - level - 1) }
        while levels.count < level + 1 { levels.append((ordered, 0)) }
        if levels[level].ordered != ordered { levels[level] = (ordered, 0) }
        levels[level].count += 1
        return levels[level].count
    }
}

extension Document {
    /// Plain text: blank lines between paragraphs, "•" before list items,
    /// tables as tab-separated lines.
    public var plainText: String {
        var parts: [String] = []
        var numbers = ListNumbers()
        for block in blocks {
            if case .listItem = block {} else { numbers = ListNumbers() }
            switch block {
            case .heading(_, let runs), .paragraph(let runs): parts.append(runs.text)
            case .quote(let runs): parts.append(runs.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n"))
            case .listItem(let ordered, let level, let runs):
                let number = numbers.next(ordered: ordered, level: level)
                let marker = ordered ? "\(number)." : "•"
                parts.append(String(repeating: "  ", count: level) + "\(marker) \(runs.text)")
            case .code(let text): parts.append(text)
            case .table(let rows): parts.append(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
            case .image(let picture): if let description = picture.description { parts.append("[\(description)]") }
            case .pageBreak: parts.append("\u{0C}")
            case .rule: parts.append("———")
            }
        }
        // List items stay together; everything else gets a blank line.
        var text = ""
        for (index, part) in parts.enumerated() {
            if index > 0 {
                let together = { () -> Bool in
                    if case .listItem = blocks[index], case .listItem = blocks[index - 1] { return true }
                    return false
                }()
                text += together ? "\n" : "\n\n"
            }
            text += part
        }
        return text + "\n"
    }

    /// Plain text: paragraphs are separated by blank lines; single line
    /// breaks stay line breaks.
    public init(plainText text: String, title: String? = nil) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [Block] = []
        for chunk in normalized.components(separatedBy: "\u{0C}").enumerated() {
            if chunk.offset > 0 { blocks.append(.pageBreak) }
            for paragraph in chunk.element.components(separatedBy: "\n\n") {
                let trimmed = paragraph.trimmingCharacters(in: .newlines)
                guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                blocks.append(.paragraph([Run(trimmed)]))
            }
        }
        self.init(title: title, blocks: blocks)
    }
}

// MARK: - Markdown

extension Document {
    public var markdown: String {
        var lines: [String] = []
        var numbers = ListNumbers()
        var previousWasList = false
        for block in blocks {
            var isList = false
            switch block {
            case .heading(let level, let runs):
                lines.append(String(repeating: "#", count: min(max(level, 1), 6)) + " " + Self.markdownInline(runs))
            case .paragraph(let runs):
                lines.append(Self.escapingBlockStart(Self.markdownInline(runs)).replacingOccurrences(of: "\n", with: "  \n"))
            case .listItem(let ordered, let level, let runs):
                isList = true
                if !previousWasList { numbers = ListNumbers() }
                let number = numbers.next(ordered: ordered, level: level)
                let marker = ordered ? "\(number)." : "-"
                let line = String(repeating: "    ", count: level) + "\(marker) " + Self.markdownInline(runs)
                if previousWasList { lines[lines.count - 1] += "\n" + line } else { lines.append(line) }
            case .quote(let runs):
                lines.append(Self.markdownInline(runs).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"))
            case .code(let text):
                lines.append("```\n\(text)\n```")
            case .table(let rows):
                guard let header = rows.first else { continue }
                let width = rows.map(\.count).max() ?? 0
                func row(_ cells: [String]) -> String {
                    "| " + (cells + Array(repeating: "", count: width - cells.count))
                        .map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: " | ") + " |"
                }
                var table = [row(header), "|" + Array(repeating: " --- |", count: width).joined()]
                table += rows.dropFirst().map(row)
                lines.append(table.joined(separator: "\n"))
            case .image(let picture):
                // Kept in the file itself, so the Markdown stays one file.
                lines.append("![\(picture.description ?? "")](data:\(picture.mimeType);base64,\(picture.data.base64EncodedString()))")
            case .pageBreak, .rule:
                lines.append("---")
            }
            previousWasList = isList
        }
        return lines.joined(separator: "\n\n") + "\n"
    }

    static func markdownInline(_ runs: [Run]) -> String {
        runs.merged.map { run in
            var text = run.code ? "`\(run.text)`" : escapeMarkdown(run.text)
            guard !run.text.trimmingCharacters(in: .whitespaces).isEmpty else { return run.text }
            // Emphasis can't start or end with a space: keep those outside.
            let leading = String(text.prefix { $0 == " " }), trailing = String(text.reversed().prefix { $0 == " " })
            text = String(text.dropFirst(leading.count).dropLast(trailing.count))
            if run.bold && run.italic { text = "***\(text)***" } else if run.bold { text = "**\(text)**" } else if run.italic { text = "*\(text)*" }
            if let link = run.link { text = "[\(text)](\(link))" }
            return leading + text + trailing
        }.joined()
    }

    static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A paragraph starting like a heading, quote or list item ("#", ">",
    /// "- ", "1. ") would turn into one.
    static func escapingBlockStart(_ text: String) -> String {
        if let first = text.first, "#>".contains(first) { return "\\" + text }
        if text.hasPrefix("- ") || text.hasPrefix("+ ") { return "\\" + text }
        if let number = text.prefixMatch(of: /\d{1,9}(?=[.)] )/) {
            return text[..<number.range.upperBound] + "\\" + text[number.range.upperBound...]
        }
        return text
    }

    /// Markdown: headings, paragraphs, lists, quotes, code, tables, rules
    /// and pictures (in the file, or next to it in `folder`).
    public init(markdown text: String, folder: URL? = nil) {
        var blocks: [Block] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraph: [String] = []
        var index = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if let picture = Self.markdownPicture(joined, folder: folder) {
                blocks.append(.image(picture))
            } else {
                blocks.append(.paragraph(Self.inlineMarkdown(joined)))
            }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.*?)\s*#*$/) {
                flush()
                blocks.append(.heading(heading.1.count, Self.inlineMarkdown(String(heading.2))))
                continue
            }
            // "Title" underlined with === or ---.
            if !paragraph.isEmpty, paragraph.count == 1, trimmed.wholeMatch(of: /=+|-+/) != nil {
                let title = paragraph.removeFirst()
                blocks.append(.heading(trimmed.hasPrefix("=") ? 1 : 2, Self.inlineMarkdown(title.trimmingCharacters(in: .whitespaces))))
                continue
            }
            if trimmed.wholeMatch(of: /(\*\s*){3,}|(-\s*){3,}|(_\s*){3,}/) != nil {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                index -= 1
                blocks.append(.quote(Self.inlineMarkdown(quote.joined(separator: " "))))
                continue
            }
            if let item = line.firstMatch(of: /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/) {
                flush()
                let indent = item.1.replacingOccurrences(of: "\t", with: "    ").count
                let ordered = item.2.first?.isNumber == true
                blocks.append(.listItem(ordered: ordered, level: min(indent / 2, 8), Self.inlineMarkdown(String(item.3))))
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               lines[index + 1].trimmingCharacters(in: .whitespaces).wholeMatch(of: /\|?(\s*:?-+:?\s*\|)+\s*:?-*:?\s*\|?/) != nil {
                flush()
                var rows = [Self.tableCells(trimmed)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(Self.tableCells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                index -= 1
                blocks.append(.table(rows))
                continue
            }
            paragraph.append(line)
        }
        flush()
        self.init(blocks: blocks)
    }

    static func tableCells(_ line: String) -> [String] {
        var inner = line.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") && !inner.hasSuffix("\\|") { inner.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in inner {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" } else { current.append(character) }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// A paragraph that's only a picture: ![words](where).
    static func markdownPicture(_ text: String, folder: URL?) -> Picture? {
        guard let match = text.wholeMatch(of: /!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/) else { return nil }
        let source = String(match.2)
        var data: Data?
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
            data = Data(base64Encoded: String(source[source.index(after: comma)...]))
        } else if let folder, !source.contains("://") {
            data = try? Data(contentsOf: folder.appendingPathComponent(source.removingPercentEncoding ?? source))
        }
        guard let data, let picture = Picture.from(data, description: String(match.1)) else { return nil }
        return picture
    }

    /// Bold, italics, code and links, read by Apple's own Markdown reader.
    static func inlineMarkdown(_ text: String) -> [Run] {
        guard let attributed = try? AttributedString(
            markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return [Run(text)] }
        var runs: [Run] = []
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            runs.append(Run(
                String(attributed[run.range].characters),
                bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized), code: intent.contains(.code),
                link: run.link?.absoluteString
            ))
        }
        return runs.merged
    }
}

// MARK: - HTML

extension Document {
    /// One HTML page, pictures inside it, with a little style to read well.
    public var html: String {
        let body = htmlBody(xhtml: false) { "data:\($0.mimeType);base64,\($0.data.base64EncodedString())" }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(Self.escapeHTML(displayTitle ?? ""))</title>
        <style>
        \(Self.css)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
    }

    static let css = """
    body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; line-height: 1.5; max-width: 42em; margin: 2em auto; padding: 0 1em; }
    img { max-width: 100%; height: auto; }
    table { border-collapse: collapse; } th, td { border: 1px solid #bbb; padding: 0.3em 0.6em; text-align: left; }
    blockquote { margin-left: 1em; padding-left: 1em; border-left: 3px solid #ccc; color: #555; }
    pre { background: #f4f4f4; padding: 0.8em; overflow-x: auto; white-space: pre-wrap; }
    .page-break { page-break-after: always; }
    """

    /// The blocks as HTML (or, `xhtml`, the stricter kind EPUBs use);
    /// `image` says where each picture's file is.
    func htmlBody(xhtml: Bool, image: (Picture) -> String) -> String {
        let lineBreak = xhtml ? "<br/>" : "<br>"
        var body: [String] = []
        var openLists: [Bool] = []
        func closeLists(to depth: Int) {
            while openLists.count > depth { body.append(openLists.removeLast() ? "</ol>" : "</ul>") }
        }
        for block in blocks {
            if case .listItem(let ordered, let level, let runs) = block {
                closeLists(to: level + 1)
                if openLists.count == level + 1, openLists[level] != ordered { closeLists(to: level) }
                while openLists.count < level + 1 {
                    body.append(ordered ? "<ol>" : "<ul>")
                    openLists.append(ordered)
                }
                body.append("<li>\(Self.htmlInline(runs))</li>")
                continue
            }
            closeLists(to: 0)
            switch block {
            case .heading(let level, let runs): body.append("<h\(level)>\(Self.htmlInline(runs))</h\(level)>")
            case .paragraph(let runs): body.append("<p>\(Self.htmlInline(runs).replacingOccurrences(of: "\n", with: lineBreak))</p>")
            case .quote(let runs): body.append("<blockquote><p>\(Self.htmlInline(runs))</p></blockquote>")
            case .code(let text): body.append("<pre><code>\(Self.escapeHTML(text))</code></pre>")
            case .table(let rows):
                var table = ["<table>"]
                for (index, row) in rows.enumerated() {
                    let tag = index == 0 && rows.count > 1 ? "th" : "td"
                    table.append("<tr>" + row.map { "<\(tag)>\(Self.escapeHTML($0))</\(tag)>" }.joined() + "</tr>")
                }
                table.append("</table>")
                body.append(table.joined(separator: "\n"))
            case .image(let picture):
                let alt = Self.escapeHTML(picture.description ?? "")
                body.append("<p><img src=\"\(image(picture))\" alt=\"\(alt)\" width=\"\(Int(picture.width))\"\(xhtml ? "/" : "")></p>")
            case .pageBreak: body.append("<div class=\"page-break\"></div>")
            case .rule: body.append(xhtml ? "<hr/>" : "<hr>")
            case .listItem: break
            }
        }
        closeLists(to: 0)
        return body.joined(separator: "\n")
    }

    static func htmlInline(_ runs: [Run]) -> String {
        runs.merged.map { run in
            var text = escapeHTML(run.text)
            if run.code { text = "<code>\(text)</code>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if let link = run.link { text = "<a href=\"\(escapeHTML(link))\">\(text)</a>" }
            return text
        }.joined()
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// HTML (and the XHTML inside EPUBs), read without a web browser: a
    /// forgiving reader for the common tags. `picture` finds an <img>'s file.
    public init(html: String, picture: @escaping (String) -> Data? = { _ in nil }) {
        var reader = HTMLReader(picture: picture)
        reader.read(html)
        self.init(title: reader.title, blocks: reader.blocks)
    }
}

extension Document.Picture {
    /// A picture from PNG or JPEG data (others are turned into PNG), sized
    /// at 72 pixels to the inch, but never wider than a page's text.
    static func from(_ data: Data, description: String? = nil, maxWidth: Double = 451) -> Document.Picture? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let type = CGImageSourceGetType(src) as String? ?? ""
        var bytes = data
        var isJPEG = type == "public.jpeg"
        if type != "public.png" && !isJPEG {
            let png = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            bytes = png as Data
            isJPEG = false
        }
        var width = Double(image.width), height = Double(image.height)
        if width > maxWidth {
            height *= maxWidth / width
            width = maxWidth
        }
        return Document.Picture(data: bytes, isJPEG: isJPEG, width: width, height: height, description: description)
    }
}

/// A forgiving HTML reader: it walks the tags it knows (headings,
/// paragraphs, lists, quotes, code, tables, pictures, bold, italics, links)
/// and keeps the text of the rest.
struct HTMLReader {
    var blocks: [Document.Block] = []
    var title: String?
    let picture: (String) -> Data?

    private var runs: [Document.Run] = []
    private var bold = 0, italic = 0, code = 0
    private var links: [String?] = []
    private var heading: Int?
    private var lists: [Bool] = []
    private var inListItem = false
    private var quote = 0
    private var pre = 0
    private var preText = ""
    private var table: [[String]]?
    private var row: [String]?
    private var cell: String?
    private var skip = 0  // inside <script>, <style>, <head>
    private var inTitle = false

    init(picture: @escaping (String) -> Data?) {
        self.picture = picture
    }

    mutating func read(_ html: String) {
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                if html[index...].hasPrefix("<!--") {
                    index = html[index...].range(of: "-->")?.upperBound ?? html.endIndex
                    continue
                }
                guard let close = html[index...].firstIndex(of: ">") else { break }
                tag(String(html[html.index(after: index)..<close]))
                index = html.index(after: close)
            } else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                text(String(html[index..<next]))
                index = next
            }
        }
        finishParagraph()
    }

    private mutating func tag(_ raw: String) {
        let isClosing = raw.hasPrefix("/")
        let body = isClosing ? String(raw.dropFirst()) : raw
        let name = String(body.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
        let attributes = Self.attributes(body)
        if isClosing { close(name) } else { open(name, attributes, selfClosing: raw.hasSuffix("/")) }
    }

    private mutating func open(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
        if ["script", "style", "head"].contains(name) && !selfClosing { skip += 1; return }
        if name == "title" { inTitle = true; return }
        guard skip == 0 else { return }
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            finishParagraph()
            heading = Int(String(name.dropFirst()))
        case "p", "div", "section", "article", "header", "footer", "figure", "figcaption", "dd", "dt":
            if cell == nil && !inListItem { finishParagraph() }
        case "br": cell != nil ? cell?.append(" ") : runs.append(Document.Run("\n"))
        case "b", "strong": bold += 1
        case "i", "em", "cite": italic += 1
        case "code", "tt", "kbd": code += 1
        case "a": links.append(attributes["href"])
        case "ul", "ol":
            finishParagraph()
            lists.append(name == "ol")
        case "li":
            finishParagraph()
            inListItem = true
        case "blockquote":
            finishParagraph()
            quote += 1
        case "pre":
            finishParagraph()
            pre += 1
            preText = ""
        case "table":
            finishParagraph()
            table = []
        case "tr": row = []
        case "td", "th": cell = ""
        case "hr":
            finishParagraph()
            blocks.append(.rule)
        case "img":
            if let source = attributes["src"], let picture = image(source, description: attributes["alt"]) {
                finishParagraph()
                blocks.append(.image(picture))
            }
        default: break
        }
    }

    private mutating func close(_ name: String) {
        if ["script", "style", "head"].contains(name) { skip = max(0, skip - 1); return }
        if name == "title" { inTitle = false; return }
        guard skip == 0 else { return }
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "section", "article", "header", "footer", "figure", "figcaption", "dd", "dt":
            if cell == nil && !inListItem { finishParagraph() }
        case "b", "strong": bold = max(0, bold - 1)
        case "i", "em", "cite": italic = max(0, italic - 1)
        case "code", "tt", "kbd": code = max(0, code - 1)
        case "a": if !links.isEmpty { links.removeLast() }
        case "li":
            finishParagraph()
            inListItem = false
        case "ul", "ol":
            finishParagraph()
            if !lists.isEmpty { lists.removeLast() }
        case "blockquote":
            finishParagraph()
            quote = max(0, quote - 1)
        case "pre":
            pre = max(0, pre - 1)
            if pre == 0 {
                blocks.append(.code(preText.trimmingCharacters(in: .newlines)))
                preText = ""
            }
        case "td", "th":
            if let cell { row?.append(cell.trimmingCharacters(in: .whitespacesAndNewlines)) }
            cell = nil
        case "tr":
            if let row, !row.isEmpty { table?.append(row) }
            row = nil
        case "table":
            if let table, !table.isEmpty { blocks.append(.table(table)) }
            table = nil
        default: break
        }
    }

    private mutating func text(_ raw: String) {
        let decoded = Self.decodeEntities(raw)
        if inTitle { title = (title ?? "") + decoded.trimmingCharacters(in: .whitespacesAndNewlines); return }
        guard skip == 0 else { return }
        if pre > 0 { preText += decoded; return }
        let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if cell != nil { cell! += collapsed; return }
        guard !collapsed.isEmpty else { return }
        if runs.isEmpty && collapsed.trimmingCharacters(in: .whitespaces).isEmpty { return }
        runs.append(Document.Run(collapsed, bold: bold > 0, italic: italic > 0, code: code > 0, link: links.last ?? nil))
    }

    private mutating func finishParagraph() {
        var finished = runs.merged
        runs.removeAll()
        // Spaces at the ends come from the line breaks around tags.
        if !finished.isEmpty { finished[0].text = String(finished[0].text.drop { $0 == " " }) }
        if let last = finished.indices.last { finished[last].text = String(finished[last].text.reversed().drop { $0 == " " }.reversed()) }
        finished = finished.filter { !$0.text.isEmpty }
        defer { heading = nil }
        guard !finished.isEmpty, !finished.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let heading {
            blocks.append(.heading(heading, finished))
        } else if inListItem {
            blocks.append(.listItem(ordered: lists.last ?? false, level: max(lists.count - 1, 0), finished))
        } else if quote > 0 {
            blocks.append(.quote(finished))
        } else {
            blocks.append(.paragraph(finished))
        }
    }

    private func image(_ source: String, description: String?) -> Document.Picture? {
        var data: Data?
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
            data = Data(base64Encoded: String(source[source.index(after: comma)...]))
        } else {
            data = picture(Self.decodeEntities(source).removingPercentEncoding ?? source)
        }
        return data.flatMap { Document.Picture.from($0, description: description?.isEmpty == false ? description : nil) }
    }

    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in tag.matches(of: /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))/) {
            let value = match.3 ?? match.4 ?? match.5 ?? ""
            result[match.1.lowercased()] = String(value)
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&mdash;": "—", "&ndash;": "–",
                     "&hellip;": "…", "&copy;": "©", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&euro;": "€"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        result = result.replacing(/&#(x?)([0-9a-fA-F]+);/) { match in
            let number = UInt32(match.2, radix: match.1.isEmpty ? 10 : 16)
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
