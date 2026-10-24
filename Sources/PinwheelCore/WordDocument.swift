import Foundation

/// Escapes text for XML.
func xmlEscape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        // Characters XML can't hold at all (most control characters).
        case "\u{9}", "\u{A}", "\u{D}": result.unicodeScalars.append(scalar)
        default: if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
        }
    }
    return result
}

/// Page sizes in points: Letter in the US and Canada, A4 everywhere else.
enum PaperSize {
    static var current: CGSize {
        ["US", "CA", "MX", "PH"].contains(Locale.current.region?.identifier ?? "") ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }
}

/// Word documents (.docx), written and read here: headings, paragraphs,
/// lists, quotes, code, tables, pictures, links and page breaks.
enum WordDocument {
    static let emuPerPoint = 12_700.0

    // MARK: - Writing

    static func write(_ document: Document, to url: URL) throws {
        var zip = ZipWriter()
        var relations: [(id: String, type: String, target: String, external: Bool)] = [
            ("rId1", "styles", "styles.xml", false), ("rId2", "numbering", "numbering.xml", false),
        ]
        var media: [(name: String, data: Data)] = []
        var numbering = Numbering()
        var body = ""
        var pictureNumber = 0
        var previousList: Bool?  // the kind of list the paragraph before was in

        func relation(_ type: String, _ target: String, external: Bool = false) -> String {
            let id = "rId\(relations.count + 1)"
            relations.append((id, type, target, external))
            return id
        }

        func runs(_ runs: [Document.Run], bold: Bool = false) -> String {
            runs.merged.map { run in
                // In the order Word's schema has them.
                var properties = ""
                if run.link != nil { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
                if run.code { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>" }
                if run.bold || bold { properties += "<w:b/>" }
                if run.italic { properties += "<w:i/>" }
                if let color = run.color, run.link == nil { properties += "<w:color w:val=\"\(color.replacingOccurrences(of: "#", with: ""))\"/>" }
                if let size = run.size {
                    let halfPoints = Int((size * 2).rounded())
                    properties += "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>"
                }
                var parts: [String] = []
                for (index, line) in run.text.components(separatedBy: "\n").enumerated() {
                    if index > 0 { parts.append("<w:br/>") }
                    for (tabIndex, piece) in line.components(separatedBy: "\t").enumerated() {
                        if tabIndex > 0 { parts.append("<w:tab/>") }
                        if !piece.isEmpty { parts.append("<w:t xml:space=\"preserve\">\(xmlEscape(piece))</w:t>") }
                    }
                }
                let element = "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + parts.joined() + "</w:r>"
                if let link = run.link {
                    return "<w:hyperlink r:id=\"\(relation("hyperlink", xmlEscape(link), external: true))\">\(element)</w:hyperlink>"
                }
                return element
            }.joined()
        }

        func paragraph(_ style: String?, _ content: String, extra: String = "") -> String {
            let styleXML = style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
            let properties = styleXML + extra
            return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + content + "</w:p>"
        }

        // A page's look, ending each section; columns start a new one.
        let page = PaperSize.current
        func section(columns: Int, continuous: Bool) -> String {
            "<w:sectPr>" + (continuous ? "<w:type w:val=\"continuous\"/>" : "")
                + "<w:pgSz w:w=\"\(Int(page.width * 20))\" w:h=\"\(Int(page.height * 20))\"/>"
                + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/>"
                + "<w:cols w:num=\"\(columns)\" w:space=\"720\"/></w:sectPr>"
        }
        var columns = 1
        var sectionStarted = false

        for block in document.blocks {
            var listKind: Bool?
            if case .columns = block {} else { sectionStarted = true }
            switch block {
            case .heading(let level, let content):
                body += paragraph("Heading\(min(max(level, 1), 6))", runs(content))
            case .paragraph(let content):
                body += paragraph(nil, runs(content))
            case .listItem(let ordered, let level, let content):
                listKind = ordered
                let id = previousList == ordered ? numbering.current(ordered) : numbering.start(ordered)
                body += paragraph("ListParagraph", runs(content), extra: "<w:numPr><w:ilvl w:val=\"\(min(level, 8))\"/><w:numId w:val=\"\(id)\"/></w:numPr>")
            case .quote(let content):
                body += paragraph("Quote", runs(content))
            case .code(let text):
                for line in text.components(separatedBy: "\n") {
                    body += paragraph("Code", runs([Document.Run(line)]))
                }
            case .table(let rows):
                body += table(rows)
            case .image(let picture):
                pictureNumber += 1
                let name = "image\(pictureNumber).\(picture.fileExtension)"
                media.append((name, picture.data))
                let id = relation("image", "media/\(name)")
                body += paragraph(nil, drawing(picture, relation: id, number: pictureNumber))
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            case .rule:
                body += paragraph(nil, "", extra: "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"999999\"/></w:pBdr>")
            case .columns(let count):
                // The section so far ends here (a paragraph with its settings);
                // the next goes on the same page, in `count` columns.
                let count = min(max(count, 1), 4)
                if sectionStarted && count != columns {
                    body += paragraph(nil, "", extra: section(columns: columns, continuous: true))
                }
                columns = count
            }
            previousList = listKind
        }

        let lastSection = section(columns: columns, continuous: body.contains("<w:sectPr>"))
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\(lastSection)</w:body></w:document>
        """

        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """)
        zip.add("_rels/.rels", packageRelations(main: "word/document.xml"))
        zip.add("docProps/core.xml", coreProperties(title: document.displayTitle))
        zip.add("docProps/app.xml", appProperties)
        zip.add("word/document.xml", documentXML)
        zip.add("word/styles.xml", styles)
        zip.add("word/numbering.xml", numbering.xml)
        zip.add("word/_rels/document.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relations.map { relation in
            "<Relationship Id=\"\(relation.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(relation.type)\" Target=\"\(relation.target)\"\(relation.external ? " TargetMode=\"External\"" : "")/>"
        }.joined())</Relationships>
        """)
        for (name, data) in media {
            zip.add("word/media/\(name)", data, compress: false)
        }
        try zip.write(to: url)
    }

    private static func table(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        let textWidth = Int((PaperSize.current.width - 144) * 20)
        let column = textWidth / width
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(textWidth)\" w:type=\"dxa\"/></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(column)\"/>", count: width) + "</w:tblGrid>"
        for (index, row) in rows.enumerated() {
            xml += "<w:tr>"
            for cell in row + Array(repeating: "", count: width - row.count) {
                let bold = index == 0 && rows.count > 1 ? "<w:rPr><w:b/></w:rPr>" : ""
                let text = cell.isEmpty ? "" : "<w:r>\(bold)<w:t xml:space=\"preserve\">\(xmlEscape(cell))</w:t></w:r>"
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(column)\" w:type=\"dxa\"/></w:tcPr><w:p>\(text)</w:p></w:tc>"
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p/>"
    }

    private static func drawing(_ picture: Document.Picture, relation: String, number: Int) -> String {
        let cx = Int(picture.width * emuPerPoint), cy = Int(picture.height * emuPerPoint)
        let name = xmlEscape(picture.description ?? "Picture \(number)")
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(number)\" name=\"\(name)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(number)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"\(relation)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    /// Bulleted and numbered lists; each numbered list starts again at 1.
    private struct Numbering {
        private(set) var lists: [Bool] = []  // ordered or not, by number - 1

        mutating func start(_ ordered: Bool) -> Int {
            lists.append(ordered)
            return lists.count
        }

        func current(_ ordered: Bool) -> Int {
            lists.lastIndex(of: ordered).map { $0 + 1 } ?? 1
        }

        var xml: String {
            let bullets = ["•", "◦", "▪"]
            func levels(ordered: Bool) -> String {
                (0..<9).map { level in
                    let format = ordered ? "decimal" : "bullet"
                    let text = ordered ? "%\(level + 1)." : bullets[level % 3]
                    return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/>"
                        + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (level + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }.joined()
            }
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:abstractNum w:abstractNumId="0">\(levels(ordered: false))</w:abstractNum>\
            <w:abstractNum w:abstractNumId="1">\(levels(ordered: true))</w:abstractNum>
            """
            for (index, ordered) in lists.enumerated() {
                xml += "<w:num w:numId=\"\(index + 1)\"><w:abstractNumId w:val=\"\(ordered ? 1 : 0)\"/>"
                if ordered { xml += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" }
                xml += "</w:num>"
            }
            if lists.isEmpty { xml += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>" }
            return xml + "</w:numbering>"
        }
    }

    private static let styles: String = {
        func heading(_ level: Int, _ size: Int) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/>"
                + "<w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/>"
                + "<w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Arial" w:eastAsia="Helvetica Neue"/>\
        <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        \(heading(1, 36))\(heading(2, 30))\(heading(3, 26))\(heading(4, 24))\(heading(5, 22))\(heading(6, 22))\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="0"/><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/><w:left w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/><w:right w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="AAAAAA"/>\
        </w:tblBorders><w:tblCellMar><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        </w:styles>
        """
    }()

    // MARK: - Reading

    static func read(_ url: URL) throws -> Document {
        let zip = try ZipReader(url: url)
        guard let body = zip.data("word/document.xml") else { throw ConversionError.unreadable(url.lastPathComponent) }
        var relations: [String: String] = [:]
        if let rels = zip.data("word/_rels/document.xml.rels") {
            for element in XMLElements.read(rels) where element.name.hasSuffix("Relationship") {
                if let id = element.attributes["Id"], let target = element.attributes["Target"] { relations[id] = target }
            }
        }
        var styleNames: [String: String] = [:]
        if let styles = zip.data("word/styles.xml") {
            var current: String?
            for element in XMLElements.read(styles) {
                if element.name == "w:style" { current = element.attributes["w:styleId"] }
                if element.name == "w:name", let current, let name = element.attributes["w:val"] { styleNames[current] = name.lowercased() }
            }
        }
        var bulletLists: Set<String> = []  // numIds that are bulleted
        if let numbering = zip.data("word/numbering.xml") {
            var abstract: String?
            var bulletAbstracts: Set<String> = []
            var num: String?
            for element in XMLElements.read(numbering) {
                switch element.name {
                case "w:abstractNum": abstract = element.attributes["w:abstractNumId"]
                case "w:numFmt": if element.attributes["w:val"] == "bullet", let abstract { bulletAbstracts.insert(abstract) }
                case "w:num": num = element.attributes["w:numId"]
                case "w:abstractNumId": if let num, let id = element.attributes["w:val"], bulletAbstracts.contains(id) { bulletLists.insert(num) }
                default: break
                }
            }
        }
        let picture: (String) -> Data? = { id in
            guard let target = relations[id] else { return nil }
            return zip.data(target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target)
        }
        let reader = WordReader(relations: relations, styleNames: styleNames, bulletLists: bulletLists, picture: picture)
        reader.footnotes = zip.data("word/footnotes.xml").map { notes($0, kind: "w:footnote") } ?? [:]
        reader.endnotes = zip.data("word/endnotes.xml").map { notes($0, kind: "w:endnote") } ?? [:]
        let parser = XMLParser(data: body)
        parser.delegate = reader
        parser.parse()
        var blocks = reader.blocks
        // Footnotes and endnotes, numbered as their marks in the text.
        if !reader.usedNotes.isEmpty {
            blocks.append(.rule)
            blocks += reader.usedNotes.map { .listItem(ordered: true, level: 0, [Document.Run($0)]) }
        }
        let title = zip.data("docProps/core.xml").flatMap { XMLElements.read($0, keepText: true).first { $0.name == "dc:title" }?.text }
        return Document(title: title?.isEmpty == false ? title : nil, blocks: blocks)
    }

    /// Each footnote's (or endnote's) text, by its number; the separator lines aren't notes.
    static func notes(_ data: Data, kind: String) -> [String: String] {
        var notes: [String: String] = [:]
        var current: String?
        var inText = false
        var paragraphs: [String] = []
        final class Reader: NSObject, XMLParserDelegate {
            var onStart: (String, [String: String]) -> Void = { _, _ in }
            var onEnd: (String) -> Void = { _ in }
            var onText: (String) -> Void = { _ in }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { onStart(name, attributes) }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { onEnd(name) }
            func parser(_ parser: XMLParser, foundCharacters string: String) { onText(string) }
        }
        let reader = Reader()
        reader.onStart = { name, attributes in
            switch name {
            case kind:
                let type = attributes["w:type"] ?? ""
                current = type.isEmpty || type == "normal" ? attributes["w:id"] : nil
                paragraphs = []
            case "w:p": if current != nil { paragraphs.append("") }
            case "w:t": inText = true
            default: break
            }
        }
        reader.onEnd = { name in
            switch name {
            case kind:
                if let id = current {
                    notes[id] = paragraphs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                }
                current = nil
            case "w:t": inText = false
            default: break
            }
        }
        reader.onText = { text in
            if inText, current != nil, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1] += text }
        }
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return notes
    }

    static func packageRelations(main: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="\(main)"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """
    }

    static func coreProperties(title: String?) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(xmlEscape(title ?? ""))</dc:title><dc:creator>Pinwheel</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }

    static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Pinwheel</Application></Properties>
    """
}

/// Elements of an XML file in order, with their attributes (and, if asked,
/// their text): enough for the small files around a document's text.
enum XMLElements {
    struct Element {
        let name: String
        let attributes: [String: String]
        var text = ""
    }

    static func read(_ data: Data, keepText: Bool = false) -> [Element] {
        let delegate = Collector(keepText: keepText)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.elements
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [Element] = []
        private var open: [Int] = []
        private let keepText: Bool

        init(keepText: Bool) {
            self.keepText = keepText
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            elements.append(Element(name: elementName, attributes: attributeDict))
            open.append(elements.count - 1)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = open.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if keepText, let index = open.last { elements[index].text += string }
        }
    }
}

/// Walks word/document.xml.
private final class WordReader: NSObject, XMLParserDelegate {
    var blocks: [Document.Block] = []
    private let relations: [String: String]
    private let styleNames: [String: String]
    private let bulletLists: Set<String>
    private let picture: (String) -> Data?

    // The paragraph being read.
    private var runs: [Document.Run] = []
    private var style: String?
    private var listLevel: Int?
    private var listID: String?
    private var pictures: [Document.Picture] = []
    private var pageBreakAfter = false
    // The run being read.
    private var bold = false, italic = false, code = false
    private var link: String?
    private var inText = false
    private var inRunProperties = false
    private var extent: (Double, Double)?
    // Tables (nested ones are read as text).
    private var tableDepth = 0
    private var table: [[String]] = []
    private var row: [String] = []
    private var cell: [String] = []
    // Footnotes and endnotes: their texts, and those marked so far, in order.
    var footnotes: [String: String] = [:]
    var endnotes: [String: String] = [:]
    private(set) var usedNotes: [String] = []
    /// Inside mc:Fallback: the same content again, for older apps (skipped).
    private var skipping = 0
    /// Text boxes: the paragraph they sit in waits; their own paragraphs
    /// come after it.
    private var outerParagraphs: [(runs: [Document.Run], style: String?, listLevel: Int?, listID: String?, pictures: [Document.Picture], start: Int)] = []
    private var textBoxBlocks: [Document.Block] = []

    init(relations: [String: String], styleNames: [String: String], bulletLists: Set<String>, picture: @escaping (String) -> Data?) {
        self.relations = relations
        self.styleNames = styleNames
        self.bulletLists = bulletLists
        self.picture = picture
    }

    private func isOn(_ attributes: [String: String]) -> Bool {
        !["0", "false", "off"].contains(attributes["w:val"] ?? "")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "mc:Fallback" { skipping += 1 }
        guard skipping == 0 else { return }
        switch name {
        case "w:txbxContent":
            outerParagraphs.append((runs, style, listLevel, listID, pictures, blocks.count))
            runs = []
            pictures = []
        case "w:footnoteReference", "w:endnoteReference":
            let notes = name == "w:footnoteReference" ? footnotes : endnotes
            if let id = attributes["w:id"], let text = notes[id], !text.isEmpty {
                usedNotes.append(text)
                runs.append(Document.Run("[\(usedNotes.count)]"))
            }
        case "w:noBreakHyphen": runs.append(Document.Run("-", bold: bold, italic: italic, code: code, link: link))
        case "m:t": inText = true  // an equation's letters, as text
        case "w:p":
            runs = []
            style = nil
            listLevel = nil
            listID = nil
            pictures = []
        case "w:pStyle": style = attributes["w:val"]
        case "w:ilvl": listLevel = Int(attributes["w:val"] ?? "0") ?? 0
        case "w:numId": listID = attributes["w:val"]
        case "w:r":
            bold = false
            italic = false
            code = false
        case "w:rPr": inRunProperties = true
        case "w:b": if inRunProperties { bold = isOn(attributes) }
        case "w:i": if inRunProperties { italic = isOn(attributes) }
        case "w:rFonts":
            let font = (attributes["w:ascii"] ?? "").lowercased()
            if inRunProperties, ["courier", "menlo", "consolas", "monaco", "mono"].contains(where: font.contains) { code = true }
        case "w:t": inText = true
        case "w:tab": runs.append(Document.Run("\t", bold: bold, italic: italic, code: code, link: link))
        case "w:br", "w:cr":
            if attributes["w:type"] == "page" { pageBreakAfter = true } else { runs.append(Document.Run("\n")) }
        case "w:hyperlink": link = attributes["r:id"].flatMap { relations[$0] } ?? attributes["w:anchor"].map { "#\($0)" }
        case "wp:extent":
            if let cx = Double(attributes["cx"] ?? ""), let cy = Double(attributes["cy"] ?? "") {
                extent = (cx / WordDocument.emuPerPoint, cy / WordDocument.emuPerPoint)
            }
        case "a:blip":
            if let id = attributes["r:embed"], let data = picture(id), var found = Document.Picture.from(data) {
                if let (width, height) = extent, width > 0, height > 0 {
                    found.width = min(width, 451)
                    found.height = height * found.width / width
                }
                pictures.append(found)
            }
        case "w:tbl":
            if tableDepth == 0 { flushParagraph(); table = [] }
            tableDepth += 1
        case "w:tr": if tableDepth == 1 { row = [] }
        case "w:tc": if tableDepth == 1 { cell = [] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "mc:Fallback" {
            skipping = max(0, skipping - 1)
            return
        }
        guard skipping == 0 else { return }
        switch name {
        case "w:txbxContent":
            guard let outer = outerParagraphs.popLast() else { break }
            textBoxBlocks += blocks[outer.start...]
            blocks.removeSubrange(outer.start...)
            (runs, style, listLevel, listID, pictures) = (outer.runs, outer.style, outer.listLevel, outer.listID, outer.pictures)
        case "w:t", "m:t": inText = false
        case "w:rPr": inRunProperties = false
        case "w:hyperlink": link = nil
        case "w:p": flushParagraph()
        case "w:tc": if tableDepth == 1 { row.append(cell.joined(separator: "\n")) }
        case "w:tr": if tableDepth == 1 { table.append(row) }
        case "w:tbl":
            tableDepth -= 1
            if tableDepth == 0, !table.isEmpty { blocks.append(.table(table)) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText, skipping == 0 else { return }
        runs.append(Document.Run(string, bold: bold, italic: italic, code: code, link: link))
    }

    private func flushParagraph() {
        defer {
            runs = []
            pictures = []
            if outerParagraphs.isEmpty, tableDepth == 0, !textBoxBlocks.isEmpty {
                blocks += textBoxBlocks
                textBoxBlocks = []
            }
            if pageBreakAfter && tableDepth == 0 { blocks.append(.pageBreak) }
            pageBreakAfter = false
        }
        let merged = runs.merged
        if tableDepth > 0 {
            cell.append(merged.text)
            return
        }
        let name = style.flatMap { styleNames[$0] } ?? style?.lowercased() ?? ""
        let hasText = !merged.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            if name == "title" {
                blocks.append(.heading(1, merged.map { var run = $0; run.bold = false; return run }))
            } else if let level = name.firstMatch(of: /heading\s*(\d)/).flatMap({ Int($0.1) }) {
                blocks.append(.heading(min(max(level, 1), 6), merged.map { var run = $0; run.bold = false; return run }))
            } else if let listID, listID != "0" {
                blocks.append(.listItem(ordered: !bulletLists.contains(listID), level: listLevel ?? 0, merged))
            } else if name.contains("quote") {
                blocks.append(.quote(merged))
            } else if name == "code" || (!merged.isEmpty && merged.allSatisfy(\.code)) {
                if case .code(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .code(previous + "\n" + merged.text)
                } else {
                    blocks.append(.code(merged.text))
                }
            } else {
                blocks.append(.paragraph(merged))
            }
        }
        for picture in pictures { blocks.append(.image(picture)) }
        extent = nil
    }
}
