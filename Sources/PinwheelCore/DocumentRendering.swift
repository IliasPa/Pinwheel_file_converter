import AppKit

/// Documents through macOS's own text system: reading RTF, Word 97, ODT and
/// web archives; writing RTF and ODT; and laying documents and spreadsheets
/// out on PDF pages.
enum AttributedDocument {
    /// Formats macOS reads well itself.
    static let cocoaTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "rtfd": .rtfd, "doc": .docFormat, "odt": .openDocument, "webarchive": .webArchive,
    ]

    static func read(_ url: URL) throws -> Document {
        let ext = url.pathExtension.lowercased()
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type = cocoaTypes[ext] { options[.documentType] = type }
        let attributed: NSAttributedString
        var pictures: [Document.Picture] = []
        do {
            if ext == "rtf" {
                // macOS skips the pictures in RTF: they're taken out first and put back after.
                let lifted = RTFPictures.lift(try Data(contentsOf: url))
                pictures = lifted.pictures
                attributed = try NSAttributedString(data: lifted.rtf, options: options, documentAttributes: nil)
            } else {
                attributed = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            }
        } catch {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return RTFPictures.place(pictures, in: document(from: attributed))
    }

    // MARK: - Attributed text → document

    static func document(from text: NSAttributedString) -> Document {
        let string = text.string as NSString
        // The size most of the text has is the body size; bigger is a heading.
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        let headingSizes = sizes.keys.filter { $0 >= body + 2 }.sorted(by: >)

        var blocks: [Document.Block] = []
        var table: (NSTextTable, [[String]])?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            // Table cells come one paragraph each.
            if let block = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                let cellText = string.substring(with: range)
                if table?.0 !== block.table {
                    if let finished = table { blocks.append(.table(finished.1)) }
                    table = (block.table, [])
                }
                while table!.1.count <= block.startingRow { table!.1.append([]) }
                while table!.1[block.startingRow].count <= block.startingColumn { table!.1[block.startingRow].append("") }
                table!.1[block.startingRow][block.startingColumn] = cellText
                return
            }
            if let finished = table {
                blocks.append(.table(finished.1))
                table = nil
            }
            var runs: [Document.Run] = []
            var size: CGFloat = 0
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    if let picture = picture(attachment) { blocks.append(.image(picture)) }
                    return
                }
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                size = max(size, font?.pointSize ?? 0)
                let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
                runs.append(Document.Run(
                    string.substring(with: runRange), bold: traits.contains(.bold), italic: traits.contains(.italic),
                    code: traits.contains(.monoSpace), link: link
                ))
            }
            let merged = runs.merged
            let plain = merged.text.trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { return }
            if let list = style?.textLists.last {
                let ordered = ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .diamond, .box, .check].contains(list.markerFormat)
                // Drop the marker macOS keeps in the text ("•\tItem", "\t1.\tItem").
                var item = merged
                if let first = item.first, let match = first.text.prefixMatch(of: /\t?[^\t]{1,8}\t/) {
                    item[0].text = String(first.text[match.range.upperBound...])
                }
                blocks.append(.listItem(ordered: ordered, level: max((style?.textLists.count ?? 1) - 1, 0), item.filter { !$0.text.isEmpty }.merged))
            } else if let level = headingSizes.firstIndex(of: size.rounded()), plain.count < 200 {
                blocks.append(.heading(min(level + 1, 6), merged.map { var run = $0; run.bold = false; return run }))
            } else if merged.allSatisfy(\.code) {
                if case .code(let previous)? = blocks.last { blocks[blocks.count - 1] = .code(previous + "\n" + merged.text) } else { blocks.append(.code(merged.text)) }
            } else {
                blocks.append(.paragraph(merged))
            }
        }
        if let finished = table { blocks.append(.table(finished.1)) }
        return Document(blocks: blocks)
    }

    private static func picture(_ attachment: NSTextAttachment) -> Document.Picture? {
        if let data = attachment.fileWrapper?.regularFileContents, let picture = Document.Picture.from(data) { return picture }
        if let data = attachment.contents, let picture = Document.Picture.from(data) { return picture }
        guard let image = attachment.image, let tiff = image.tiffRepresentation else { return nil }
        return Document.Picture.from(tiff)
    }

    // MARK: - Document → attributed text

    /// Fonts are found one at a time: found on many threads at once (the
    /// tests convert side by side), AppKit's font cache once waited forever
    /// on the font server.
    private static let fontLock = NSLock()

    /// Helvetica Neue, which other apps have too (the system font is saved
    /// in RTF and PDFs by a name only Macs know, and read back as Times).
    static func font(ofSize size: CGFloat, bold: Bool = false) -> NSFont {
        fontLock.withLock {
            NSFont(name: bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size) ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        }
    }

    static var bodyFont: NSFont { font(ofSize: 11) }

    /// Menlo for code, for the same reason.
    static func codeFont(ofSize size: CGFloat) -> NSFont {
        fontLock.withLock { NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) }
    }

    /// The font at another size.
    private static func resized(_ font: NSFont, to size: CGFloat) -> NSFont {
        fontLock.withLock { NSFont(descriptor: font.fontDescriptor, size: size) ?? font }
    }

    /// The font in bold or italic too.
    private static func font(_ font: NSFont, with traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        fontLock.withLock { NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
    }
    static let headingSizes: [CGFloat] = [22, 18, 15, 13, 12, 11]

    static func attributed(_ document: Document) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previousList: NSTextList?
        var previousOrdered: Bool?
        for block in document.blocks {
            var list: NSTextList?
            var listKind: Bool?
            switch block {
            case .heading(let level, let runs):
                let style = paragraphStyle(before: level <= 2 ? 14 : 10, after: 6)
                append(runs, to: result, font: Self.font(ofSize: headingSizes[min(max(level, 1), 6) - 1], bold: true), style: style)
            case .paragraph(let runs):
                append(runs, to: result, font: bodyFont, style: paragraphStyle(after: 8))
            case .listItem(let ordered, let level, let runs):
                // One list object per list, so numbering restarts with each.
                let current = previousOrdered == ordered ? previousList : nil
                // "1." as TextEdit writes it (the plain decimal format is just "1").
                let textList = current ?? NSTextList(markerFormat: ordered ? NSTextList.MarkerFormat("{decimal}.") : .disc, options: 0)
                list = textList
                listKind = ordered
                let style = paragraphStyle(after: 3)
                style.textLists = Array(repeating: textList, count: level + 1)
                let indent = CGFloat(level + 1) * 18
                style.headIndent = indent + 14
                style.firstLineHeadIndent = indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 14)]
                let number = result.itemNumber(in: textList, at: result.length)
                let marker = NSAttributedString(string: "\(textList.marker(forItemNumber: number))\t", attributes: [.font: bodyFont, .paragraphStyle: style])
                result.append(marker)
                append(runs, to: result, font: bodyFont, style: style)
            case .quote(let runs):
                let style = paragraphStyle(after: 8)
                style.headIndent = 24
                style.firstLineHeadIndent = 24
                append(runs.map { var run = $0; run.italic = true; return run }, to: result, font: bodyFont, style: style, color: .secondaryLabelColor)
            case .code(let text):
                let style = paragraphStyle(after: 8)
                result.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: codeFont(ofSize: 9.5), .paragraphStyle: style,
                    .backgroundColor: NSColor(white: 0.95, alpha: 1),
                ]))
            case .table(let rows):
                appendTable(rows, to: result)
            case .image(let picture):
                guard let image = NSImage(data: picture.data) else { continue }
                image.size = NSSize(width: picture.width, height: picture.height)
                let attachment = NSTextAttachment()
                attachment.image = image
                let line = NSMutableAttributedString(attachment: attachment)
                line.append(NSAttributedString(string: "\n"))
                line.addAttribute(.paragraphStyle, value: paragraphStyle(after: 8), range: NSRange(location: 0, length: line.length))
                result.append(line)
            case .pageBreak:
                result.append(NSAttributedString(string: "\u{0C}"))
            case .columns:
                break
            case .rule:
                result.append(NSAttributedString(string: String(repeating: "─", count: 40) + "\n", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraphStyle(after: 8),
                ]))
            }
            previousList = list
            previousOrdered = listKind
        }
        return result
    }

    private static func paragraphStyle(before: CGFloat = 0, after: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.15
        return style
    }

    private static func append(
        _ runs: [Document.Run], to result: NSMutableAttributedString, font: NSFont, style: NSParagraphStyle, color: NSColor = .black
    ) {
        for run in runs.merged {
            let size = run.size.map { CGFloat($0) } ?? font.pointSize
            var runFont = run.code ? codeFont(ofSize: size * 0.92) : (run.size == nil ? font : resized(font, to: size))
            var traits: NSFontDescriptor.SymbolicTraits = runFont.fontDescriptor.symbolicTraits
            if run.bold { traits.insert(.bold) }
            if run.italic { traits.insert(.italic) }
            if traits != runFont.fontDescriptor.symbolicTraits { runFont = Self.font(runFont, with: traits) }
            let runColor = run.color.flatMap { ImageConverter.color(hex: $0) }.flatMap { NSColor(cgColor: $0) } ?? color
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .paragraphStyle: style, .foregroundColor: runColor]
            if let link = run.link, let url = URL(string: link) {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
    }

    private static func appendTable(_ rows: [[String]], to result: NSMutableAttributedString) {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = width
        table.collapsesBorders = true
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<width {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(NSColor(white: 0.7, alpha: 1))
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                block.setValue(100 / CGFloat(width), type: .percentageValueType, for: .width)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let font = Self.font(ofSize: 10, bold: rowIndex == 0 && rows.count > 1)
                let text = column < row.count ? row[column] : ""
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
    }

    // MARK: - Writing with macOS

    static func write(_ document: Document, to url: URL, type: NSAttributedString.DocumentType) throws {
        let text = attributed(document)
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if let title = document.displayTitle { attributes[.title] = title }
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: url)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }

    /// RTF with its pictures (see `RTFPictures`): each goes in as a mark,
    /// and the mark is swapped for the picture.
    static func writeRTF(_ document: Document, to url: URL) throws {
        var pictures: [Document.Picture] = []
        var marked = document
        marked.blocks = document.blocks.map { block in
            guard case .image(let picture) = block else { return block }
            pictures.append(picture)
            return .paragraph([Document.Run(RTFPictures.mark(pictures.count - 1))])
        }
        let text = attributed(marked)
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        if let title = document.displayTitle { attributes[.title] = title }
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            var rtf = String(decoding: data, as: UTF8.self)  // RTF is plain ASCII
            for (index, picture) in pictures.enumerated() {
                rtf = rtf.replacingOccurrences(of: RTFPictures.mark(index), with: RTFPictures.group(picture))
            }
            try Data(rtf.utf8).write(to: url)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }

    // MARK: - PDF pages

    static let margin: CGFloat = 64

    /// Lays the document out on pages (page breaks start a new one).
    static func writePDF(_ document: Document, to url: URL) throws {
        let text = attributed(document)
        // Each part between page breaks starts on a new page.
        var parts: [NSAttributedString] = []
        var start = 0
        let string = text.string as NSString
        while start <= string.length {
            let rest = NSRange(location: start, length: string.length - start)
            let pageBreak = string.range(of: "\u{0C}", options: [], range: rest)
            let end = pageBreak.location == NSNotFound ? string.length : pageBreak.location
            parts.append(text.attributedSubstring(from: NSRange(location: start, length: end - start)))
            if pageBreak.location == NSNotFound { break }
            start = end + 1
        }
        try PDFPages.write(to: url, title: document.displayTitle) { page in
            for part in parts where part.length > 0 || parts.count == 1 {
                lay(part, on: page)
            }
        }
    }

    /// Fills pages with the text, as many as it takes.
    private static func lay(_ text: NSAttributedString, on pages: PDFPages) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: pages.size.width - 2 * margin, height: pages.size.height - 2 * margin)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 5000
        for container in containers {
            let range = layout.glyphRange(for: container)
            pages.draw { _ in
                layout.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
                layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            }
        }
    }

    // MARK: - Spreadsheets on PDF pages

    /// Each sheet as a grid, as many pages as it takes; wide sheets lie on
    /// their side, and the text gets smaller (down to 6 points) to fit.
    static func writePDF(_ workbook: Workbook, to url: URL) throws {
        let sheets = workbook.sheets.map(\.trimmed).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw NothingToDo(reason: "The spreadsheet is empty, so nothing was saved.") }
        let portrait = PaperSize.current
        try PDFPages.write(to: url, title: nil, size: portrait) { pages in
            for sheet in sheets { drawSheet(sheet, on: pages, showName: sheets.count > 1) }
        }
    }

    private static func drawSheet(_ sheet: Workbook.Sheet, on pages: PDFPages, showName: Bool) {
        let columns = sheet.width
        let padding: CGFloat = 4
        func natural(_ size: CGFloat) -> [CGFloat] {
            let font = Self.font(ofSize: size), bold = Self.font(ofSize: size, bold: true)
            return (0..<columns).map { column in
                // The first row is drawn in bold, so it's measured in bold.
                let widest = sheet.rows.prefix(500).enumerated().map { index, row -> CGFloat in
                    guard column < row.count else { return 0 }
                    let attributes: [NSAttributedString.Key: Any] = [.font: index == 0 ? bold : font]
                    return row[column].text.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
                }.max() ?? 0
                return ceil(min(widest, 220)) + 1 + 2 * padding
            }
        }
        var landscape = false
        var fontSize: CGFloat = 9
        var widths = natural(fontSize)
        let portrait = pages.size
        var available = portrait.width - 2 * margin
        if widths.reduce(0, +) > available {
            landscape = true
            available = portrait.height - 2 * margin
        }
        while widths.reduce(0, +) > available && fontSize > 6 {
            fontSize -= 0.5
            widths = natural(fontSize)
        }
        let total = widths.reduce(0, +)
        if total > available { widths = widths.map { $0 * available / total } }
        let pageSize = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let font = Self.font(ofSize: fontSize), bold = Self.font(ofSize: fontSize, bold: true)

        // Most cells are one short line: measured without laying the text out.
        let oneLine = ceil(font.ascender - font.descender + font.leading) + 2 * padding
        func height(of row: [Workbook.Cell], font: NSFont) -> CGFloat {
            (0..<columns).map { column -> CGFloat in
                let text = column < row.count ? row[column].text : ""
                if CGFloat(text.utf16.count) * fontSize * 0.9 < widths[column] - 2 * padding, !text.contains("\n"),
                   text.unicodeScalars.allSatisfy({ $0.value < 0x0530 }) {
                    return oneLine
                }
                let rect = (text as NSString).boundingRect(
                    with: CGSize(width: widths[column] - 2 * padding, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], attributes: [.font: font]
                )
                return ceil(rect.height) + 2 * padding
            }.max() ?? fontSize + 2 * padding
        }

        func draw(_ row: [Workbook.Cell], header: Bool, at y: CGFloat, height rowHeight: CGFloat) {
            var x = margin
            for column in 0..<columns {
                let cell = CGRect(x: x, y: y, width: widths[column], height: rowHeight)
                if header { NSColor(white: 0.93, alpha: 1).setFill(); cell.fill() }
                NSColor(white: 0.75, alpha: 1).setStroke()
                let border = NSBezierPath(rect: cell)
                border.lineWidth = 0.5
                border.stroke()
                if column < row.count {
                    let value = row[column]
                    let style = NSMutableParagraphStyle()
                    if case .number = value { style.alignment = .right }
                    (value.text as NSString).draw(
                        with: cell.insetBy(dx: padding, dy: padding), options: [.usesLineFragmentOrigin],
                        attributes: [.font: header ? bold : font, .paragraphStyle: style, .foregroundColor: NSColor.black]
                    )
                }
                x += widths[column]
            }
        }

        var index = 0
        while index < sheet.rows.count {
            pages.draw(size: pageSize) { _ in
                var y = margin
                if showName {
                    (sheet.name as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: Self.font(ofSize: 12, bold: true)])
                    y += 20
                }
                // The first row again at the top of each later page, as a header.
                if index > 0 {
                    let headerHeight = height(of: sheet.rows[0], font: bold)
                    draw(sheet.rows[0], header: true, at: y, height: headerHeight)
                    y += headerHeight
                }
                var drawn = 0
                while index < sheet.rows.count {
                    let row = sheet.rows[index]
                    let rowHeight = height(of: row, font: index == 0 ? bold : font)
                    if y + rowHeight > pageSize.height - margin && drawn > 0 { break }
                    draw(row, header: index == 0, at: y, height: rowHeight)
                    y += rowHeight
                    index += 1
                    drawn += 1
                }
            }
        }
    }
}

/// A PDF being written page by page, drawn with AppKit (y goes down).
final class PDFPages {
    let size: CGSize
    private let context: CGContext

    private init(context: CGContext, size: CGSize) {
        self.context = context
        self.size = size
    }

    static func write(to url: URL, title: String?, size: CGSize = PaperSize.current, _ body: (PDFPages) throws -> Void) throws {
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "Pinwheel"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
        let pages = PDFPages(context: context, size: size)
        try body(pages)
        context.closePDF()
        PDFTextRepair.fixGreekMu(in: url)
    }

    func draw(size pageSize: CGSize? = nil, _ content: (CGContext) -> Void) {
        let size = pageSize ?? size
        var box = CGRect(origin: .zero, size: size)
        let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
        // Each page lets go of what drawing it took: a 2,000-page sheet
        // used to need almost a gigabyte.
        autoreleasepool {
            context.beginPDFPage(info)
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            content(context)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
    }
}

private extension NSAttributedString {
    /// The number the next item of `list` gets, counting the items before it.
    func itemNumber(in list: NSTextList, at location: Int) -> Int {
        guard location > 0 else { return list.startingItemNumber }
        var count = 0
        (string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: location), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0, let style = self.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  style.textLists.last === list else { return }
            count += 1
        }
        return list.startingItemNumber + count
    }
}
