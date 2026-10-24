import Foundation

/// OpenDocument text (.odt, for LibreOffice), written from Pinwheel's model:
/// headings, paragraphs, nested lists, quotes, code, tables, pictures,
/// links, columns and page breaks. macOS's own writer made lists inside
/// lists into XML that doesn't close properly (LibreOffice couldn't open
/// the file) and left the pictures out.
enum OpenDocumentText {
    static let mimeType = "application/vnd.oasis.opendocument.text"

    static func write(_ document: Document, to url: URL) throws {
        var writer = Writer()
        for block in document.blocks { writer.add(block) }
        writer.closeList()
        writer.closeSection()

        var zip = ZipWriter()
        zip.add("mimetype", mimeType, compress: false)
        zip.add("META-INF/manifest.xml", OpenDocument.manifest(
            mimeType: mimeType,
            files: [(path: "styles.xml", type: "text/xml")] + writer.pictures.map { (path: "Pictures/\($0.name)", type: $0.type) }
        ))
        zip.add("content.xml", writer.content)
        zip.add("styles.xml", styles)
        zip.add("meta.xml", meta(title: document.displayTitle))
        for picture in writer.pictures { zip.add("Pictures/\(picture.name)", picture.data, compress: false) }
        do {
            try zip.write(to: url)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }

    private struct Writer {
        var body = ""
        var textStyles: [String: String] = [:]  // the look → its style's name
        /// Each list's kind at each level (numbered or not), as its first item there says.
        var listStyles: [[Int: Bool]] = []
        var sectionStyles: [Int] = []
        var pictures: [(name: String, type: String, data: Data)] = []
        var tables = 0
        /// The open lists, outermost first: whether each has an item open.
        var lists: [Bool] = []
        var inSection = false

        mutating func add(_ block: Document.Block) {
            if case .listItem = block {} else { closeList() }
            switch block {
            case .heading(let level, let runs):
                let level = min(max(level, 1), 6)
                body += "<text:h text:style-name=\"Heading_20_\(level)\" text:outline-level=\"\(level)\">\(spans(runs))</text:h>"
            case .paragraph(let runs):
                body += "<text:p text:style-name=\"Text_20_body\">\(spans(runs))</text:p>"
            case .listItem(let ordered, let level, let runs):
                let level = min(max(level, 0), 9)
                if lists.isEmpty {
                    listStyles.append([:])
                    body += "<text:list text:style-name=\"L\(listStyles.count)\">"
                    lists = [false]
                }
                while lists.count > level + 1 {
                    if lists.removeLast() { body += "</text:list-item>" }
                    body += "</text:list>"
                }
                while lists.count < level + 1 {
                    // A list inside a list sits in one of its items.
                    if !lists[lists.count - 1] { body += "<text:list-item>" }
                    lists[lists.count - 1] = true
                    body += "<text:list>"
                    lists.append(false)
                }
                if lists[lists.count - 1] { body += "</text:list-item>" }
                lists[lists.count - 1] = true
                if listStyles[listStyles.count - 1][level] == nil { listStyles[listStyles.count - 1][level] = ordered }
                body += "<text:list-item><text:p text:style-name=\"List_20_Contents\">\(spans(runs))</text:p>"
            case .quote(let runs):
                body += "<text:p text:style-name=\"Quotations\">\(spans(runs))</text:p>"
            case .code(let text):
                for line in text.components(separatedBy: "\n") {
                    body += "<text:p text:style-name=\"Preformatted_20_Text\">\(OpenDocumentText.characters(line))</text:p>"
                }
            case .table(let rows):
                guard let width = rows.map(\.count).max(), width > 0 else { return }
                tables += 1
                body += "<table:table table:name=\"Table\(tables)\" table:style-name=\"Table\"><table:table-column table:number-columns-repeated=\"\(width)\"/>"
                for (index, row) in rows.enumerated() {
                    if index == 0 { body += "<table:table-header-rows>" }
                    body += "<table:table-row>"
                    for column in 0..<width {
                        let text = column < row.count ? row[column] : ""
                        let paragraphs = text.components(separatedBy: "\n").map {
                            "<text:p text:style-name=\"\(index == 0 ? "Table_20_Heading" : "Table_20_Contents")\">\(OpenDocumentText.characters($0))</text:p>"
                        }.joined()
                        body += "<table:table-cell table:style-name=\"Cell\" office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    }
                    body += "</table:table-row>"
                    if index == 0 { body += "</table:table-header-rows>" }
                }
                body += "</table:table>"
            case .image(let picture):
                let name = "\(pictures.count + 1).\(picture.fileExtension)"
                pictures.append((name, picture.mimeType, picture.data))
                let description = picture.description.map { "<svg:desc>\(xmlEscape($0))</svg:desc>" } ?? ""
                body += "<text:p text:style-name=\"Text_20_body\"><draw:frame draw:style-name=\"Picture\" draw:name=\"Picture \(pictures.count)\" "
                    + "text:anchor-type=\"as-char\" svg:width=\"\(OpenDocumentText.points(picture.width))\" svg:height=\"\(OpenDocumentText.points(picture.height))\" draw:z-index=\"0\">"
                    + "<draw:image xlink:href=\"Pictures/\(name)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>\(description)</draw:frame></text:p>"
            case .pageBreak:
                body += "<text:p text:style-name=\"Page_20_Break\"/>"
            case .rule:
                body += "<text:p text:style-name=\"Horizontal_20_Line\"/>"
            case .columns(let count):
                closeSection()
                if count > 1 {
                    if !sectionStyles.contains(count) { sectionStyles.append(count) }
                    body += "<text:section text:style-name=\"Columns\(count)\" text:name=\"Section\(sectionStyles.count)\">"
                    inSection = true
                }
            }
        }

        mutating func closeList() {
            while let itemOpen = lists.popLast() {
                if itemOpen { body += "</text:list-item>" }
                body += "</text:list>"
            }
        }

        mutating func closeSection() {
            if inSection { body += "</text:section>" }
            inSection = false
        }

        mutating func spans(_ runs: [Document.Run]) -> String {
            runs.merged.map { run in
                var look: [String] = []
                if run.bold { look.append("fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"") }
                if run.italic { look.append("fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\"") }
                if run.code { look.append("style:font-name=\"Menlo\"") }
                if let color = run.color, run.link == nil { look.append("fo:color=\"\(color)\"") }
                if let size = run.size { look.append("fo:font-size=\"\(OpenDocumentText.points(size))\"") }
                var text = OpenDocumentText.characters(run.text)
                if !look.isEmpty {
                    let key = look.joined(separator: " ")
                    let name = textStyles[key] ?? "T\(textStyles.count + 1)"
                    textStyles[key] = name
                    text = "<text:span text:style-name=\"\(name)\">\(text)</text:span>"
                }
                if let link = run.link {
                    text = "<text:a xlink:type=\"simple\" xlink:href=\"\(xmlEscape(link))\">\(text)</text:a>"
                }
                return text
            }.joined()
        }

        var content: String {
            var automatic = textStyles.sorted { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.value < $1.value }.map { look, name in
                "<style:style style:name=\"\(name)\" style:family=\"text\"><style:text-properties \(look)/></style:style>"
            }.joined()
            for (index, levels) in listStyles.enumerated() {
                automatic += "<text:list-style style:name=\"L\(index + 1)\">"
                for level in 1...10 {
                    // Deeper levels than the list has are like its deepest.
                    let ordered = levels[level - 1] ?? levels[levels.keys.filter { $0 < level - 1 }.max() ?? -1] ?? false
                    let indent = String(format: "%.2fcm", 0.635 * Double(level))
                    let properties = "<style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment "
                        + "text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(indent)\" fo:text-indent=\"-0.635cm\" fo:margin-left=\"\(indent)\"/></style:list-level-properties>"
                    automatic += ordered
                        ? "<text:list-level-style-number text:level=\"\(level)\" style:num-suffix=\".\" style:num-format=\"1\">\(properties)</text:list-level-style-number>"
                        : "<text:list-level-style-bullet text:level=\"\(level)\" text:bullet-char=\"\(["•", "◦", "▪"][(level - 1) % 3])\">\(properties)</text:list-level-style-bullet>"
                }
                automatic += "</text:list-style>"
            }
            for count in sectionStyles {
                automatic += "<style:style style:name=\"Columns\(count)\" style:family=\"section\"><style:section-properties text:dont-balance-text-columns=\"false\">"
                    + "<style:columns fo:column-count=\"\(count)\" fo:column-gap=\"0.6cm\"/></style:section-properties></style:style>"
            }
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <office:document-content \(OpenDocumentText.namespaces) office:version="1.3"><office:font-face-decls>\
            <style:font-face style:name="Menlo" svg:font-family="Menlo" style:font-family-generic="modern" style:font-pitch="fixed"/></office:font-face-decls>\
            <office:automatic-styles>\
            <style:style style:name="Table" style:family="table"><style:table-properties table:align="margins"/></style:style>\
            <style:style style:name="Cell" style:family="table-cell"><style:table-cell-properties fo:padding="0.1cm" fo:border="0.5pt solid #999999"/></style:style>\
            <style:style style:name="Picture" style:family="graphic" style:parent-style-name="Graphics"><style:graphic-properties style:vertical-pos="top" style:vertical-rel="baseline"/></style:style>\
            \(automatic)</office:automatic-styles><office:body><office:text>\(body)</office:text></office:body></office:document-content>
            """
        }
    }

    static func points(_ value: Double) -> String { String(format: "%.2fpt", value) }

    /// Text with ODF's spaces, tabs and line breaks (more than one space in a row needs <text:s/>).
    static func characters(_ text: String) -> String {
        var result = ""
        var spaces = 0
        func flushSpaces() {
            guard spaces > 0 else { return }
            result += " "
            if spaces > 1 { result += "<text:s text:c=\"\(spaces - 1)\"/>" }
            spaces = 0
        }
        for character in text {
            switch character {
            case " ": spaces += 1
            case "\t": flushSpaces(); result += "<text:tab/>"
            case "\n": flushSpaces(); result += "<text:line-break/>"
            default:
                flushSpaces()
                result += xmlEscape(String(character))
            }
        }
        flushSpaces()
        return result
    }

    static let namespaces = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
    xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
    xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
    """

    /// The named styles LibreOffice knows, so the document's parts look and behave as its own do.
    static let styles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-styles \(namespaces) office:version="1.3"><office:font-face-decls>\
    <style:font-face style:name="Helvetica" svg:font-family="Helvetica" style:font-family-generic="swiss"/>\
    <style:font-face style:name="Menlo" svg:font-family="Menlo" style:font-family-generic="modern" style:font-pitch="fixed"/></office:font-face-decls>\
    <office:styles>\
    <style:default-style style:family="paragraph"><style:paragraph-properties fo:orphans="2" fo:widows="2"/>\
    <style:text-properties style:font-name="Helvetica" fo:font-size="11pt" fo:language="en" fo:country="US"/></style:default-style>\
    <style:style style:name="Standard" style:family="paragraph" style:class="text"/>\
    <style:style style:name="Text_20_body" style:display-name="Text body" style:family="paragraph" style:parent-style-name="Standard" style:class="text">\
    <style:paragraph-properties fo:margin-top="0cm" fo:margin-bottom="0.25cm" fo:line-height="115%"/></style:style>\
    \((1...6).map { level in
        let size = [24, 18, 15, 13, 12, 11][level - 1]
        return "<style:style style:name=\"Heading_20_\(level)\" style:display-name=\"Heading \(level)\" style:family=\"paragraph\" style:parent-style-name=\"Standard\" "
            + "style:next-style-name=\"Text_20_body\" style:default-outline-level=\"\(level)\" style:class=\"text\"><style:paragraph-properties fo:margin-top=\"0.42cm\" "
            + "fo:margin-bottom=\"0.21cm\" fo:keep-with-next=\"always\"/><style:text-properties fo:font-size=\"\(size)pt\" fo:font-weight=\"bold\" "
            + "style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"/></style:style>"
    }.joined())\
    <style:style style:name="List_20_Contents" style:display-name="List Contents" style:family="paragraph" style:parent-style-name="Text_20_body" style:class="list">\
    <style:paragraph-properties fo:margin-bottom="0.1cm"/></style:style>\
    <style:style style:name="Quotations" style:family="paragraph" style:parent-style-name="Standard" style:class="html">\
    <style:paragraph-properties fo:margin-left="1cm" fo:margin-right="1cm" fo:margin-bottom="0.25cm"/><style:text-properties fo:font-style="italic"/></style:style>\
    <style:style style:name="Preformatted_20_Text" style:display-name="Preformatted Text" style:family="paragraph" style:parent-style-name="Standard" style:class="html">\
    <style:text-properties style:font-name="Menlo" fo:font-size="10pt"/></style:style>\
    <style:style style:name="Table_20_Contents" style:display-name="Table Contents" style:family="paragraph" style:parent-style-name="Standard" style:class="extra"/>\
    <style:style style:name="Table_20_Heading" style:display-name="Table Heading" style:family="paragraph" style:parent-style-name="Table_20_Contents" style:class="extra">\
    <style:text-properties fo:font-weight="bold"/></style:style>\
    <style:style style:name="Horizontal_20_Line" style:display-name="Horizontal Line" style:family="paragraph" style:parent-style-name="Standard" style:class="html">\
    <style:paragraph-properties fo:margin-bottom="0.25cm" fo:border-bottom="0.75pt solid #808080" fo:padding="0cm"/></style:style>\
    <style:style style:name="Page_20_Break" style:display-name="Page Break" style:family="paragraph" style:parent-style-name="Standard">\
    <style:paragraph-properties fo:break-before="page"/></style:style>\
    <style:style style:name="Graphics" style:family="graphic"><style:graphic-properties text:anchor-type="as-char" svg:y="0cm" style:wrap="none"/></style:style>\
    </office:styles><office:automatic-styles><style:page-layout style:name="Page"><style:page-layout-properties fo:page-width="\(points(PaperSize.current.width))" \
    fo:page-height="\(points(PaperSize.current.height))" fo:margin-top="2cm" fo:margin-bottom="2cm" fo:margin-left="2cm" fo:margin-right="2cm"/></style:page-layout>\
    </office:automatic-styles><office:master-styles><style:master-page style:name="Standard" style:page-layout-name="Page"/></office:master-styles></office:document-styles>
    """

    static func meta(title: String?) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta \(namespaces) office:version="1.3"><office:meta><meta:generator>Pinwheel</meta:generator>\
        \(title.map { "<dc:title>\(xmlEscape($0))</dc:title>" } ?? "")</office:meta></office:document-meta>
        """
    }
}
