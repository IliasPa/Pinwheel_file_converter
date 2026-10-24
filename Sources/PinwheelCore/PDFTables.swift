import CoreGraphics
import Foundation
import PDFKit

/// Tables on PDF pages. Ruled tables are read from the lines the page
/// draws (exact rows and columns, cells that wrap included); the rest from
/// how their words line up (see `PDFStructure.layout`).
enum PDFTables {
    /// A straight line the page draws: across (`horizontal`) at `position`
    /// from `start` to `end`, or down.
    struct Rule: Equatable {
        var horizontal: Bool
        var position: CGFloat
        var start: CGFloat
        var end: CGFloat
    }

    /// The page's tables, top to bottom: ruled ones, then (outside them)
    /// those found by how their words line up.
    static func tables(on page: PDFPage) -> [PDFStructure.Block] {
        let words = PDFStructure.words(of: page)
        guard !words.isEmpty else { return [] }
        let ruled = page.pageRef.map { grids(rules(on: $0)) } ?? []
        var tables: [PDFStructure.Block] = []
        var rest = words
        for grid in ruled {
            let inside = rest.filter { grid.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            guard !inside.isEmpty else { continue }
            rest.removeAll { word in inside.contains { $0.frame == word.frame && $0.text == word.text } }
            let rows = grid.cells(inside)
            if rows.count > 1 { tables.append(PDFStructure.Block(rows: rows, frame: grid.frame, isTable: true)) }
        }
        tables += PDFStructure.layout(rest).filter(\.isTable)
        return tables.sorted { $0.frame.maxY > $1.frame.maxY }
    }

    // MARK: - The lines a page draws

    /// Every straight across-or-down line the page strokes, and every thin
    /// filled box (how many PDFs draw their rules), forms within forms too.
    static func rules(on page: CGPDFPage) -> [Rule] {
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        for name in ["q", "Q", "cm", "m", "l", "re", "h", "c", "v", "y", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n", "Do"] {
            CGPDFOperatorTableSetCallback(table, name, ruleCallbacks[name]!)
        }
        let state = PDFRuleScan(table: table)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return withExtendedLifetime(state) { merged(state.rules) }
    }

    /// Pieces of one line (drawn cell by cell) joined.
    static func merged(_ rules: [Rule]) -> [Rule] {
        var result: [Rule] = []
        for rule in rules.sorted(by: { ($0.horizontal ? 0 : 1, $0.position, $0.start) < ($1.horizontal ? 0 : 1, $1.position, $1.start) }) {
            if let last = result.last, last.horizontal == rule.horizontal, abs(last.position - rule.position) < 1.5, rule.start <= last.end + 2 {
                result[result.count - 1].end = max(last.end, rule.end)
            } else {
                result.append(rule)
            }
        }
        return result
    }

    // MARK: - Grids

    /// Rules that cross each other, as a table's grid.
    struct Grid {
        /// Where columns meet, left to right.
        var columns: [CGFloat]
        /// Where rows meet, top to bottom (y goes up).
        var rows: [CGFloat]

        var frame: CGRect {
            CGRect(x: columns[0], y: rows[rows.count - 1], width: columns[columns.count - 1] - columns[0], height: rows[0] - rows[rows.count - 1])
        }

        /// The words in their cells, read in order; empty rows and columns left out.
        func cells(_ words: [PDFStructure.Word]) -> [[String]] {
            var grid = Array(repeating: Array(repeating: [PDFStructure.Word](), count: columns.count - 1), count: rows.count - 1)
            for word in words {
                let x = word.frame.midX, y = word.frame.midY
                guard let column = columns.indices.dropLast().last(where: { columns[$0] <= x }),
                      let row = rows.indices.dropLast().last(where: { rows[$0] >= y }) else { continue }
                grid[row][column].append(word)
            }
            var text = grid.map { row in
                row.map { words in
                    // Lines top to bottom, words left to right.
                    words.sorted { abs($0.frame.midY - $1.frame.midY) > 2 ? $0.frame.midY > $1.frame.midY : $0.frame.minX < $1.frame.minX }
                        .map(\.text).joined(separator: " ")
                }
            }
            text.removeAll { $0.allSatisfy(\.isEmpty) }
            let used = (0..<(columns.count - 1)).filter { column in text.contains { !$0[column].isEmpty } }
            return text.map { row in used.map { row[$0] } }
        }
    }

    /// Groups of rules that cross; a group with at least two columns and
    /// two rows of cells is a table.
    static func grids(_ rules: [Rule]) -> [Grid] {
        let across = rules.filter { $0.horizontal && $0.end - $0.start >= 12 }, down = rules.filter { !$0.horizontal && $0.end - $0.start >= 8 }
        func crosses(_ h: Rule, _ v: Rule) -> Bool {
            v.position >= h.start - 2 && v.position <= h.end + 2 && h.position >= v.start - 2 && h.position <= v.end + 2
        }
        // Connected groups of crossing rules.
        var groupOfAcross = Array(repeating: -1, count: across.count), groupOfDown = Array(repeating: -1, count: down.count)
        var groups = 0
        for start in across.indices where groupOfAcross[start] < 0 {
            var queue = [(true, start)]
            groupOfAcross[start] = groups
            while let (isAcross, index) = queue.popLast() {
                if isAcross {
                    for other in down.indices where groupOfDown[other] < 0 && crosses(across[index], down[other]) {
                        groupOfDown[other] = groups
                        queue.append((false, other))
                    }
                } else {
                    for other in across.indices where groupOfAcross[other] < 0 && crosses(across[other], down[index]) {
                        groupOfAcross[other] = groups
                        queue.append((true, other))
                    }
                }
            }
            groups += 1
        }
        func positions(_ values: [CGFloat]) -> [CGFloat] {
            var result: [CGFloat] = []
            for value in values.sorted() where result.last.map({ value - $0 > 2 }) ?? true { result.append(value) }
            return result
        }
        return (0..<groups).compactMap { group in
            let h = across.indices.filter { groupOfAcross[$0] == group }.map { across[$0] }
            let v = down.indices.filter { groupOfDown[$0] == group }.map { down[$0] }
            let columns = positions(v.map(\.position)), rows = Array(positions(h.map(\.position)).reversed())
            guard columns.count >= 3, rows.count >= 3 else { return nil }  // two columns and two rows of cells, at least
            return Grid(columns: columns, rows: rows)
        }
    }

    // MARK: - Numbers

    /// A table's cells, with its numbers as numbers: "1.250,00" or
    /// "1,250.00" (the table's own way decides which), "€ 1 250",
    /// "(300)" for -300. Codes with leading zeros, percentages and dates
    /// stay text.
    static func cells(_ rows: [[String]]) -> [[Workbook.Cell]] {
        let all = rows.flatMap { $0 }
        let commaDecimals = all.count { $0.contains(/\d,\d{1,2}(?!\d)/) && !$0.contains(/\d,\d{1,2}\./) } + all.count { $0.contains(/\d\.\d{3},/) }
        let dotDecimals = all.count { $0.contains(/\d\.\d{1,2}(?!\d)/) && !$0.contains(/\d\.\d{1,2},/) } + all.count { $0.contains(/\d,\d{3}\./) }
        let decimalComma = commaDecimals > dotDecimals
        return rows.map { $0.map { cell($0, decimalComma: decimalComma) } }
    }

    static func cell(_ text: String, decimalComma: Bool) -> Workbook.Cell {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        var plain = trimmed.replacing(/[€$£¥₹]|\b(EUR|USD|GBP|CHF|JPY)\b/, with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: " ", with: "")
        var negative = false
        if plain.hasPrefix("("), plain.hasSuffix(")") {
            negative = true
            plain = String(plain.dropFirst().dropLast())
        }
        if plain.hasPrefix("−") { plain = "-" + plain.dropFirst() }  // a minus sign, not a hyphen
        guard plain.wholeMatch(of: /[-+]?\d[\d.,]*/) != nil else { return Workbook.Cell.guess(text) }
        let digits = plain.drop { $0 == "-" || $0 == "+" }
        if digits.count > 1, digits.first == "0", digits.dropFirst().first?.isNumber == true { return .text(text) }  // 007
        plain = decimalComma
            ? plain.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            : plain.replacingOccurrences(of: ",", with: "")
        guard plain.filter({ $0 == "." }).count <= 1, let value = Double(plain) else { return .text(text) }
        return .number(negative ? -value : value)
    }
}

// MARK: - Following the drawing

/// The lines found so far, the path being drawn, and the transforms in force.
private final class PDFRuleScan {
    var transforms: [CGAffineTransform] = [.identity]
    var rules: [PDFTables.Rule] = []
    var segments: [(CGPoint, CGPoint)] = []
    var boxes: [CGRect] = []
    var point = CGPoint.zero
    var subpathStart = CGPoint.zero
    var depth = 0
    let table: CGPDFOperatorTableRef

    init(table: CGPDFOperatorTableRef) {
        self.table = table
    }

    var current: CGAffineTransform { transforms.last ?? .identity }

    /// The path drawn: stroked lines (and boxes' sides), or thin filled boxes.
    func paint(stroke: Bool, fill: Bool) {
        if stroke {
            var lines = segments
            for box in boxes {
                lines += [(CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY)), (CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)),
                          (CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.minX, y: box.maxY)), (CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY))]
            }
            for (from, to) in lines { add(from.applying(current), to.applying(current)) }
        }
        if fill {
            for box in boxes {
                let frame = box.applying(current).standardized
                if frame.height <= 2.5 && frame.width >= 6 {
                    rules.append(PDFTables.Rule(horizontal: true, position: frame.midY, start: frame.minX, end: frame.maxX))
                } else if frame.width <= 2.5 && frame.height >= 6 {
                    rules.append(PDFTables.Rule(horizontal: false, position: frame.midX, start: frame.minY, end: frame.maxY))
                }
            }
        }
        segments = []
        boxes = []
    }

    private func add(_ from: CGPoint, _ to: CGPoint) {
        if abs(from.y - to.y) < 1, abs(from.x - to.x) >= 6 {
            rules.append(PDFTables.Rule(horizontal: true, position: (from.y + to.y) / 2, start: min(from.x, to.x), end: max(from.x, to.x)))
        } else if abs(from.x - to.x) < 1, abs(from.y - to.y) >= 6 {
            rules.append(PDFTables.Rule(horizontal: false, position: (from.x + to.x) / 2, start: min(from.y, to.y), end: max(from.y, to.y)))
        }
    }
}

private func ruleScan(_ info: UnsafeMutableRawPointer?) -> PDFRuleScan {
    Unmanaged<PDFRuleScan>.fromOpaque(info!).takeUnretainedValue()
}

/// Pops `count` numbers, in the order they were written.
private func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values = [CGPDFReal](repeating: 0, count: count)
    for index in (0..<count).reversed() {
        guard CGPDFScannerPopNumber(scanner, &values[index]) else { return nil }
    }
    return values.map { CGFloat($0) }
}

private let ruleCallbacks: [String: CGPDFOperatorCallback] = [
    "q": { _, info in let scan = ruleScan(info); scan.transforms.append(scan.current) },
    "Q": { _, info in let scan = ruleScan(info); if scan.transforms.count > 1 { scan.transforms.removeLast() } },
    "cm": { scanner, info in
        guard let v = numbers(scanner, 6) else { return }
        let scan = ruleScan(info)
        scan.transforms[scan.transforms.count - 1] = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(scan.current)
    },
    "m": { scanner, info in
        guard let v = numbers(scanner, 2) else { return }
        let scan = ruleScan(info)
        scan.point = CGPoint(x: v[0], y: v[1])
        scan.subpathStart = scan.point
    },
    "l": { scanner, info in
        guard let v = numbers(scanner, 2) else { return }
        let scan = ruleScan(info)
        let to = CGPoint(x: v[0], y: v[1])
        scan.segments.append((scan.point, to))
        scan.point = to
    },
    "re": { scanner, info in
        guard let v = numbers(scanner, 4) else { return }
        ruleScan(info).boxes.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
    },
    "h": { _, info in
        let scan = ruleScan(info)
        scan.segments.append((scan.point, scan.subpathStart))
        scan.point = scan.subpathStart
    },
    // Curves aren't rules: the pen just moves on.
    "c": { scanner, info in if let v = numbers(scanner, 6) { ruleScan(info).point = CGPoint(x: v[4], y: v[5]) } },
    "v": { scanner, info in if let v = numbers(scanner, 4) { ruleScan(info).point = CGPoint(x: v[2], y: v[3]) } },
    "y": { scanner, info in if let v = numbers(scanner, 4) { ruleScan(info).point = CGPoint(x: v[2], y: v[3]) } },
    "S": { _, info in ruleScan(info).paint(stroke: true, fill: false) },
    "s": { _, info in ruleScan(info).paint(stroke: true, fill: false) },
    "f": { _, info in ruleScan(info).paint(stroke: false, fill: true) },
    "F": { _, info in ruleScan(info).paint(stroke: false, fill: true) },
    "f*": { _, info in ruleScan(info).paint(stroke: false, fill: true) },
    "B": { _, info in ruleScan(info).paint(stroke: true, fill: true) },
    "B*": { _, info in ruleScan(info).paint(stroke: true, fill: true) },
    "b": { _, info in ruleScan(info).paint(stroke: true, fill: true) },
    "b*": { _, info in ruleScan(info).paint(stroke: true, fill: true) },
    "n": { _, info in ruleScan(info).paint(stroke: false, fill: false) },
    "Do": { scanner, info in
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let stream = CGPDFScannerGetContentStream(scanner)
        var xobject: CGPDFStreamRef?
        guard let object = CGPDFContentStreamGetResource(stream, "XObject", name),
              CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
              let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
        var subtype: UnsafePointer<CChar>?
        let scan = ruleScan(info)
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form", scan.depth < 6 else { return }
        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in 0..<6 { _ = CGPDFArrayGetNumber(array, index, &values[index]) }
            matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
        let form = CGPDFContentStreamCreateWithStream(xobject, resources, stream)
        scan.transforms.append(matrix.concatenating(scan.current))
        scan.depth += 1
        let inner = CGPDFScannerCreate(form, scan.table, info)
        CGPDFScannerScan(inner)
        CGPDFScannerRelease(inner)
        CGPDFContentStreamRelease(form)
        scan.depth -= 1
        scan.transforms.removeLast()
    },
]
