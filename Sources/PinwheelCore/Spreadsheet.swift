import Foundation

/// A spreadsheet as Pinwheel reads and writes it: sheets of rows of cells.
public struct Workbook: Sendable, Equatable {
    public var sheets: [Sheet]

    public init(sheets: [Sheet]) {
        self.sheets = sheets
    }

    public struct Sheet: Sendable, Equatable {
        public var name: String
        public var rows: [[Cell]]

        public init(name: String, rows: [[Cell]]) {
            self.name = name
            self.rows = rows
        }

        /// Without the empty rows and columns at the end.
        var trimmed: Sheet {
            var rows = rows.map { row in Array(row.reversed().drop { $0 == .empty }.reversed()) }
            while let last = rows.last, last.isEmpty { rows.removeLast() }
            return Sheet(name: name, rows: rows)
        }

        var width: Int { rows.map(\.count).max() ?? 0 }
    }

    public enum Cell: Sendable, Equatable {
        case empty
        case text(String)
        case number(Double)
        case bool(Bool)

        public var text: String {
            switch self {
            case .empty: ""
            case .text(let text): text
            case .number(let number): Self.format(number)
            case .bool(let value): value ? "TRUE" : "FALSE"
            }
        }

        /// 3 → "3", 2.5 → "2.5", without float noise.
        static func format(_ number: Double) -> String {
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(format: "%.15g", number)
        }

        /// What a piece of text most likely is: a number (with a decimal
        /// point, or a comma when `decimalComma`), TRUE/FALSE, or text.
        /// Numbers with a leading zero ("007", postcodes) stay text.
        static func guess(_ text: String, decimalComma: Bool = false) -> Cell {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .empty }
            switch trimmed.uppercased() {
            case "TRUE": return .bool(true)
            case "FALSE": return .bool(false)
            default: break
            }
            guard trimmed.wholeMatch(of: /[-+]?\d[\d.,]*([eE][-+]?\d+)?/) != nil else { return .text(text) }
            if trimmed.count > 1, trimmed.first == "0", trimmed.dropFirst().first?.isNumber == true { return .text(text) }
            var plain = trimmed
            if decimalComma {
                plain = plain.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                plain = plain.replacingOccurrences(of: ",", with: "")
            }
            return Double(plain).map(Cell.number) ?? .text(text)
        }
    }

    /// The first sheet with anything in it.
    var firstSheet: Sheet? {
        sheets.map(\.trimmed).first { !$0.rows.isEmpty } ?? sheets.first?.trimmed
    }
}

// MARK: - CSV and TSV

enum DelimitedText {
    static func read(_ url: URL, tabs: Bool) throws -> Workbook {
        guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        let text = TextFile.decode(data)
        let delimiter: Character = tabs ? "\t" : guessDelimiter(text)
        let rows = parse(text, delimiter: delimiter).map { row in
            row.map { Workbook.Cell.guess($0, decimalComma: delimiter == ";") }
        }
        return Workbook(sheets: [Workbook.Sheet(name: url.deletingPathExtension().lastPathComponent, rows: rows)])
    }

    /// Commas, or semicolons (what Excel uses where a comma is the decimal mark).
    static func guessDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        return firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
    }

    /// RFC 4180: quoted fields may hold the delimiter, quotes ("") and line breaks.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func write(_ sheet: Workbook.Sheet, to url: URL, tabs: Bool) throws {
        let delimiter = tabs ? "\t" : ","
        let lines = sheet.trimmed.rows.map { row in
            row.map { cell -> String in
                let text = cell.text
                guard text.contains(delimiter) || text.contains("\"") || text.contains("\n") || text.contains("\r") else { return text }
                return tabs ? text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                    : "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: delimiter)
        }
        do {
            try Data((lines.joined(separator: "\r\n") + "\r\n").utf8).write(to: url)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }
}

/// Text files in whatever encoding they came in.
enum TextFile {
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Older Windows and Mac files.
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }

    static func read(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        return decode(data)
    }
}

// MARK: - Excel

enum ExcelWorkbook {
    static func columnName(_ index: Int) -> String {
        var name = ""
        var number = index + 1
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            number = (number - 1) / 26
        }
        return name
    }

    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65 && scalar.value <= 90 else { break }
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(index - 1, 0)
    }

    /// Names Excel allows: 31 characters at most, none of []:*?/\, and each its own.
    static func sheetNames(_ sheets: [Workbook.Sheet]) -> [String] {
        var used: Set<String> = []
        return sheets.enumerated().map { index, sheet in
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31)).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Sheet\(index + 1)" }
            var candidate = name
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = String(name.prefix(27)) + " (\(number))"
                number += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    static func write(_ workbook: Workbook, to url: URL) throws {
        let sheets = workbook.sheets.isEmpty ? [Workbook.Sheet(name: "Sheet1", rows: [])] : workbook.sheets.map(\.trimmed)
        let names = sheetNames(sheets)
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """)
        zip.add("_rels/.rels", WordDocument.packageRelations(main: "xl/workbook.xml"))
        zip.add("docProps/core.xml", WordDocument.coreProperties(title: nil))
        zip.add("docProps/app.xml", WordDocument.appProperties)
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
        \(names.enumerated().map { "<sheet name=\"\(xmlEscape($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())\
        </sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
        <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """)
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """)
        for (index, sheet) in sheets.enumerated() {
            zip.add("xl/worksheets/sheet\(index + 1).xml", worksheet(sheet))
        }
        try zip.write(to: url)
    }

    private static func worksheet(_ sheet: Workbook.Sheet) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        // Columns as wide as their longest text (within reason).
        let widths = (0..<sheet.width).map { column in
            sheet.rows.map { $0.indices.contains(column) ? $0[column].text.count : 0 }.max() ?? 0
        }
        if !widths.isEmpty {
            xml += "<cols>" + widths.enumerated().map {
                "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\(min(max(Double($0.element) * 1.1 + 2, 8), 60))\" customWidth=\"1\"/>"
            }.joined() + "</cols>"
        }
        xml += "<sheetData>"
        for (rowIndex, row) in sheet.rows.enumerated() {
            xml += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, cell) in row.enumerated() {
                let reference = columnName(columnIndex) + String(rowIndex + 1)
                switch cell {
                case .empty: continue
                case .text(let text): xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(text))</t></is></c>"
                case .number(let number): xml += "<c r=\"\(reference)\"><v>\(Workbook.Cell.format(number))</v></c>"
                case .bool(let value): xml += "<c r=\"\(reference)\" t=\"b\"><v>\(value ? 1 : 0)</v></c>"
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    static func read(_ url: URL) throws -> Workbook {
        let zip = try ZipReader(url: url)
        guard let workbookXML = zip.data("xl/workbook.xml") else { throw ConversionError.unreadable(url.lastPathComponent) }
        var targets: [String: String] = [:]
        if let rels = zip.data("xl/_rels/workbook.xml.rels") {
            for element in XMLElements.read(rels) where element.name.hasSuffix("Relationship") {
                if let id = element.attributes["Id"], let target = element.attributes["Target"] { targets[id] = target }
            }
        }
        let strings = zip.data("xl/sharedStrings.xml").map(SharedStrings.read) ?? []
        let dates = zip.data("xl/styles.xml").map(dateStyles) ?? []
        var sheets: [Workbook.Sheet] = []
        for element in XMLElements.read(workbookXML) where element.name.hasSuffix("sheet") {
            guard let name = element.attributes["name"],
                  let id = element.attributes["r:id"] ?? element.attributes.first(where: { $0.key.hasSuffix(":id") })?.value,
                  let target = targets[id] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = zip.data(path) else { continue }
            let reader = SheetReader(strings: strings, dates: dates)
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            sheets.append(Workbook.Sheet(name: name, rows: reader.rows).trimmed)
        }
        return Workbook(sheets: sheets)
    }

    /// Which cell styles show dates (their numbers are days since 1900).
    private static func dateStyles(_ data: Data) -> Set<Int> {
        var customDateFormats: Set<Int> = []
        var styles: [Int] = []
        var inCellXfs = false
        for element in XMLElements.read(data) {
            switch element.name {
            case "numFmt":
                let code = (element.attributes["formatCode"] ?? "").replacing(/"[^"]*"/, with: "").lowercased()
                if let id = Int(element.attributes["numFmtId"] ?? ""), code.contains("y") || code.contains("d") || (code.contains("m") && !code.contains("0")) {
                    customDateFormats.insert(id)
                }
            case "cellXfs": inCellXfs = true
            case "cellStyles", "dxfs": inCellXfs = false
            case "xf" where inCellXfs: styles.append(Int(element.attributes["numFmtId"] ?? "0") ?? 0)
            default: break
            }
        }
        let builtIn = Set(14...22).union(45...47)
        return Set(styles.indices.filter { builtIn.contains(styles[$0]) || customDateFormats.contains(styles[$0]) })
    }

    /// "2026-10-21", or "2026-10-21 14:30" when there's a time.
    static func dateText(_ serial: Double) -> String {
        let date = Date(timeIntervalSince1970: (serial - 25_569) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        private var strings: [String] = []
        private var current = ""
        private var inText = false
        private var phonetic = 0

        static func read(_ data: Data) -> [String] {
            let reader = SharedStrings()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "si": current = ""
            case "t": inText = phonetic == 0
            case "rPh": phonetic += 1
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si": strings.append(current)
            case "t": inText = false
            case "rPh": phonetic -= 1
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }
    }

    private final class SheetReader: NSObject, XMLParserDelegate {
        private(set) var rows: [[Workbook.Cell]] = []
        private let strings: [String]
        private let dates: Set<Int>
        private var row = 0
        private var column = 0
        private var type = ""
        private var style = 0
        private var value = ""
        private var reading = false

        init(strings: [String], dates: Set<Int>) {
            self.strings = strings
            self.dates = dates
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                row = (Int(attributes["r"] ?? "") ?? (row + 1)) - 1
            case "c":
                let reference = attributes["r"] ?? ""
                column = reference.isEmpty ? column + 1 : ExcelWorkbook.columnIndex(reference)
                type = attributes["t"] ?? "n"
                style = Int(attributes["s"] ?? "0") ?? 0
                value = ""
            case "v", "t": reading = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": reading = false
            case "c": store()
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if reading { value += string }
        }

        private func store() {
            let cell: Workbook.Cell
            switch type {
            case "s": cell = Int(value).flatMap { strings.indices.contains($0) ? .text(strings[$0]) : nil } ?? .empty
            case "inlineStr", "str", "e": cell = value.isEmpty ? .empty : .text(value)
            case "b": cell = .bool(value == "1")
            default:
                guard let number = Double(value) else { cell = value.isEmpty ? .empty : .text(value); break }
                cell = dates.contains(style) ? .text(ExcelWorkbook.dateText(number)) : .number(number)
            }
            guard cell != .empty, row >= 0, row < 1_048_576, column < 16_384 else { return }
            while rows.count <= row { rows.append([]) }
            while rows[row].count <= column { rows[row].append(.empty) }
            rows[row][column] = cell
        }
    }
}

// MARK: - OpenDocument spreadsheets

enum OpenDocumentSheet {
    static let mimeType = "application/vnd.oasis.opendocument.spreadsheet"

    static func write(_ workbook: Workbook, to url: URL) throws {
        let sheets = workbook.sheets.isEmpty ? [Workbook.Sheet(name: "Sheet1", rows: [])] : workbook.sheets.map(\.trimmed)
        var content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
        office:version="1.2"><office:body><office:spreadsheet>
        """
        for (sheet, name) in zip(sheets, ExcelWorkbook.sheetNames(sheets)) {
            content += "<table:table table:name=\"\(xmlEscape(name))\">"
            for row in sheet.rows {
                content += "<table:table-row>"
                for cell in row {
                    switch cell {
                    case .empty: content += "<table:table-cell/>"
                    case .text(let text):
                        let paragraphs = text.components(separatedBy: "\n").map { "<text:p>\(xmlEscape($0))</text:p>" }.joined()
                        content += "<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    case .number(let number):
                        content += "<table:table-cell office:value-type=\"float\" office:value=\"\(Workbook.Cell.format(number))\"><text:p>\(Workbook.Cell.format(number))</text:p></table:table-cell>"
                    case .bool(let value):
                        content += "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"\(value)\"><text:p>\(value ? "TRUE" : "FALSE")</text:p></table:table-cell>"
                    }
                }
                content += "</table:table-row>"
            }
            if sheet.rows.isEmpty { content += "<table:table-row><table:table-cell/></table:table-row>" }
            content += "</table:table>"
        }
        content += "</office:spreadsheet></office:body></office:document-content>"
        var zip = ZipWriter()
        zip.add("mimetype", mimeType, compress: false)
        zip.add("META-INF/manifest.xml", OpenDocument.manifest(mimeType: mimeType))
        zip.add("content.xml", content)
        zip.add("meta.xml", OpenDocument.meta)
        try zip.write(to: url)
    }

    static func read(_ url: URL) throws -> Workbook {
        let zip = try ZipReader(url: url)
        guard let content = zip.data("content.xml") else { throw ConversionError.unreadable(url.lastPathComponent) }
        let reader = Reader()
        let parser = XMLParser(data: content)
        parser.delegate = reader
        parser.parse()
        return Workbook(sheets: reader.sheets.map(\.trimmed))
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private(set) var sheets: [Workbook.Sheet] = []
        private var rows: [[Workbook.Cell]] = []
        private var row: [Workbook.Cell] = []
        private var rowRepeat = 1
        private var cellRepeat = 1
        private var cellType = ""
        private var cellValue: String?
        private var cellText = ""
        private var paragraphs = 0
        private var inCell = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "table:table":
                rows = []
                sheets.append(Workbook.Sheet(name: attributes["table:name"] ?? "Sheet\(sheets.count + 1)", rows: []))
            case "table:table-row":
                row = []
                rowRepeat = Int(attributes["table:number-rows-repeated"] ?? "1") ?? 1
            case "table:table-cell", "table:covered-table-cell":
                inCell = true
                cellRepeat = Int(attributes["table:number-columns-repeated"] ?? "1") ?? 1
                cellType = attributes["office:value-type"] ?? ""
                cellValue = attributes["office:value"] ?? attributes["office:boolean-value"] ?? attributes["office:date-value"]
                cellText = ""
                paragraphs = 0
            case "text:p":
                if inCell { if paragraphs > 0 { cellText += "\n" }; paragraphs += 1 }
            case "text:s": if inCell { cellText += String(repeating: " ", count: Int(attributes["text:c"] ?? "1") ?? 1) }
            case "text:tab": if inCell { cellText += "\t" }
            case "text:line-break": if inCell { cellText += "\n" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "table:table-cell", "table:covered-table-cell":
                inCell = false
                let cell: Workbook.Cell
                switch cellType {
                case "float", "percentage", "currency": cell = cellValue.flatMap(Double.init).map(Workbook.Cell.number) ?? .text(cellText)
                case "boolean": cell = .bool(cellValue == "true")
                case "date": cell = .text(cellValue.map { String($0.prefix(10)) } ?? cellText)
                default: cell = cellText.isEmpty ? .empty : .text(cellText)
                }
                // Repeats are capped: empty cells can repeat to the sheet's edge.
                row += Array(repeating: cell, count: cell == .empty ? min(cellRepeat, 256) : min(cellRepeat, 16_384))
            case "table:table-row":
                let isEmpty = row.allSatisfy { $0 == .empty }
                rows += Array(repeating: row, count: isEmpty ? min(rowRepeat, 64) : min(rowRepeat, 100_000))
            case "table:table":
                sheets[sheets.count - 1].rows = rows
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCell && paragraphs > 0 { cellText += string }
        }
    }
}

/// What OpenDocument files share.
enum OpenDocument {
    static func manifest(mimeType: String, files: [(path: String, type: String)] = []) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
        <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="\(mimeType)"/>\
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
        <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>\
        \(files.map { "<manifest:file-entry manifest:full-path=\"\($0.path)\" manifest:media-type=\"\($0.type)\"/>" }.joined())\
        </manifest:manifest>
        """
    }

    static let meta = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
    xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" office:version="1.2">\
    <office:meta><meta:generator>Pinwheel</meta:generator></office:meta></office:document-meta>
    """
}
