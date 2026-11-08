// Draws the sample files for recording Pinwheel's demo video: three photos,
// the picture the video pans across, a PDF with tables, a spreadsheet and a
// Word document. The pictures are the same drawings the website's demo uses
// (read from docs/index.html), so the video and the page look alike.
// Usage: make-files <docs/index.html> <out folder> <work folder>
// (scripts/demo/make-files.sh compiles and runs it, then does the rest.)

import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-files <docs/index.html> <out folder> <work folder>\n".utf8))
    exit(2)
}
let page = try String(contentsOfFile: arguments[1], encoding: .utf8)
let out = URL(fileURLWithPath: arguments[2])
let work = URL(fileURLWithPath: arguments[3])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - The drawings, from the page's <template id="scenes">

func scene(_ name: String) -> NSImage {
    guard let range = page.range(of: "<svg data-scene=\"\(name)\"[\\s\\S]*?</svg>", options: .regularExpression) else {
        fail("no scene \"\(name)\" in docs/index.html")
    }
    let file = work.appendingPathComponent("\(name).svg")
    try? String(page[range]).write(to: file, atomically: true, encoding: .utf8)
    guard let image = NSImage(contentsOf: file), image.size.width > 0 else { fail("macOS couldn't draw the \(name) scene") }
    return image
}

/// The drawing at `width` × `height`, with a little film grain so it
/// compresses like a photo rather than like a flat drawing.
func render(_ image: NSImage, width: Int, height: Int, grain: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("not enough memory for a \(width)×\(height) picture") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    if grain > 0, let data = ctx.data {
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let span = UInt64(grain * 2 + 1)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            let n = Int(seed % span) - grain
            for c in 0..<3 { pixels[i + c] = UInt8(clamping: Int(pixels[i + c]) + n) }
        }
    }
    guard let picture = ctx.makeImage() else { fail("couldn't draw a picture") }
    return picture
}

// MARK: - Photos: like an iPhone's, with the date taken and the place

struct Photo { let name, scene, taken: String; let latitude, longitude: Double }
let photos = [
    Photo(name: "IMG_4021.HEIC", scene: "santorini", taken: "2026:06:14 19:42:10", latitude: 36.4618, longitude: 25.3753),
    Photo(name: "IMG_4022.HEIC", scene: "lighthouse", taken: "2026:06:15 11:08:33", latitude: 36.3567, longitude: 25.3571),
    Photo(name: "IMG_4023.HEIC", scene: "sunset", taken: "2026:06:15 20:31:05", latitude: 36.4612, longitude: 25.3725),
]
for photo in photos {
    let picture = render(scene(photo.scene), width: 4032, height: 3024, grain: 7)
    let url = out.appendingPathComponent(photo.name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
        fail("this Mac can't write HEIC")
    }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.85,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: photo.taken,
            kCGImagePropertyExifDateTimeDigitized: photo.taken,
        ],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: photo.taken],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: photo.latitude, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: photo.longitude, kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]
    CGImageDestinationAddImage(dest, picture, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("couldn't write \(photo.name)") }
}

// The video pans across this (make-files.sh: 1920×1080 out of 2400×1350).
do {
    let picture = render(scene("boat"), width: 2400, height: 1350, grain: 0)
    let url = work.appendingPathComponent("boat.png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("can't write PNG") }
    CGImageDestinationAddImage(dest, picture, nil)
    guard CGImageDestinationFinalize(dest) else { fail("couldn't write boat.png") }
}

// MARK: - Santorini guide.pdf: headings, a picture and two tables with numbers

let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
var mediaBox = a4
let pdfInfo: [CFString: Any] = [kCGPDFContextTitle: "Santorini in three days", kCGPDFContextCreator: "Pinwheel demo files"]
guard let pdf = CGContext(out.appendingPathComponent("Santorini guide.pdf") as CFURL, mediaBox: &mediaBox, pdfInfo as CFDictionary) else {
    fail("couldn't make the PDF")
}

/// Draws one page with y going down, as on paper.
func pdfPage(_ number: Int, _ draw: () -> Void) {
    pdf.beginPDFPage(nil)
    pdf.saveGState()
    pdf.translateBy(x: 0, y: a4.height)
    pdf.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
    draw()
    text("\(number)", 9, color: .gray, align: .center, in: CGRect(x: 0, y: 800, width: a4.width, height: 14))
    NSGraphicsContext.restoreGraphicsState()
    pdf.restoreGState()
    pdf.endPDFPage()
}

func font(_ size: CGFloat, bold: Bool) -> NSFont {
    NSFont(name: bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
}

/// Draws `string` in `rect`; returns the height it took.
@discardableResult
func text(_ string: String, _ size: CGFloat, bold: Bool = false, color: NSColor = .black, align: NSTextAlignment = .left, in rect: CGRect) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = size * 0.3
    let attributed = NSAttributedString(string: string, attributes: [.font: font(size, bold: bold), .foregroundColor: color, .paragraphStyle: style])
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
    return ceil(attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height)
}

/// A table with lines, a tinted header and numbers on the right; returns its bottom.
func table(x: CGFloat, y: CGFloat, widths: [CGFloat], rows: [[String]], numbers: Set<Int>, boldLast: Bool = false) -> CGFloat {
    let height: CGFloat = 22, total = widths.reduce(0, +)
    NSColor(srgbRed: 0.87, green: 0.92, blue: 0.98, alpha: 1).setFill()
    NSRect(x: x, y: y, width: total, height: height).fill()
    for (r, row) in rows.enumerated() {
        var left = x
        for (c, cell) in row.enumerated() {
            let bold = r == 0 || (boldLast && r == rows.count - 1)
            text(cell, 10, bold: bold, align: numbers.contains(c) ? .right : .left,
                 in: CGRect(x: left + 7, y: y + CGFloat(r) * height + 5.5, width: widths[c] - 14, height: height - 6))
            left += widths[c]
        }
    }
    let lines = NSBezierPath()
    lines.lineWidth = 0.6
    for r in 0...rows.count {
        lines.move(to: NSPoint(x: x, y: y + CGFloat(r) * height))
        lines.line(to: NSPoint(x: x + total, y: y + CGFloat(r) * height))
    }
    var left = x
    for w in [0] + widths {
        left += w
        lines.move(to: NSPoint(x: left, y: y))
        lines.line(to: NSPoint(x: left, y: y + CGFloat(rows.count) * height))
    }
    NSColor(white: 0.7, alpha: 1).setStroke()
    lines.stroke()
    return y + CGFloat(rows.count) * height
}

let margin: CGFloat = 40, width = a4.width - 80
pdfPage(1) {
    var y: CGFloat = 48
    y += text("Santorini in three days", 26, bold: true, in: CGRect(x: margin, y: y, width: width, height: 40)) + 4
    y += text("A short guide for the June trip", 13, color: .darkGray, in: CGRect(x: margin, y: y, width: width, height: 20)) + 14
    y += text("Santorini is a ring of cliffs around a sunken volcano. Ferries arrive at Athinios, the port below Fira; from there, buses and taxis climb the zigzag road to the villages on the rim. Keep the mornings for walks and the evenings for Oia, where everyone gathers to watch the sun go down.",
              11, in: CGRect(x: margin, y: y, width: width, height: 120)) + 16
    // The same picture as IMG_4021, filling a wide box.
    let box = CGRect(x: margin, y: y, width: width, height: 240)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).addClip()
    let tall = box.width * 0.75
    scene("santorini").draw(in: CGRect(x: box.minX, y: box.minY - (tall - box.height) / 2, width: box.width, height: tall),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    y = box.maxY + 26
    y += text("Ferry times from Piraeus", 15, bold: true, in: CGRect(x: margin, y: y, width: width, height: 22)) + 10
    _ = table(x: margin, y: y, widths: [175, 80, 80, 70, 110.28], rows: [
        ["Ferry", "Leaves", "Arrives", "Hours", "Price (€)"],
        ["Morning ferry", "07:25", "15:10", "7.75", "48.50"],
        ["Fast boat", "07:00", "12:05", "5.08", "112.90"],
        ["Afternoon ferry", "13:00", "20:40", "7.67", "46.00"],
        ["Night ferry", "22:00", "07:15", "9.25", "39.50"],
    ], numbers: [3, 4])
}
pdfPage(2) {
    var y: CGFloat = 48
    y += text("Three days", 20, bold: true, in: CGRect(x: margin, y: y, width: width, height: 30)) + 10
    let days = [
        ("Day 1, Fira to Oia.", "Ten kilometres on foot along the rim of the caldera, with stops in Imerovigli. Sunset at the castle in Oia."),
        ("Day 2, Akrotiri.", "The old town kept under the ash, then the lighthouse at the southern tip and a swim at Red Beach."),
        ("Day 3, the caldera by boat.", "The volcano, the hot springs and lunch on Thirassia, back in time for dinner in Ammoudi Bay."),
    ]
    for (title, body) in days {
        text("•", 11, in: CGRect(x: margin, y: y, width: 12, height: 16))
        let line = NSMutableAttributedString(string: title + " ", attributes: [.font: font(11, bold: true)])
        line.append(NSAttributedString(string: body, attributes: [.font: font(11, bold: false)]))
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3.3
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        let rect = CGRect(x: margin + 16, y: y, width: width - 16, height: 60)
        line.draw(with: rect, options: [.usesLineFragmentOrigin])
        y += ceil(line.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height) + 10
    }
    y += 16
    y += text("Budget per person", 15, bold: true, in: CGRect(x: margin, y: y, width: width, height: 22)) + 10
    y = table(x: margin, y: y, widths: [195, 105, 75, 140.28], rows: [
        ["Item", "Per day (€)", "Days", "Total (€)"],
        ["Room in Oia", "95.00", "3", "285.00"],
        ["Food", "45.00", "3", "135.00"],
        ["Buses", "8.00", "3", "24.00"],
        ["Boat trip", "65.00", "1", "65.00"],
        ["Total", "", "", "509.00"],
    ], numbers: [1, 2, 3], boldLast: true) + 22
    text("Prices from June; ferries change their times in the autumn.", 9.5, color: .gray, in: CGRect(x: margin, y: y, width: width, height: 16))
}
pdf.closePDF()

/// Writes `parts` (path in the package → XML) into `folder` and zips them as `file`.
func pack(_ parts: [String: String], in folder: URL, to file: URL) {
    do {
        for (path, body) in parts {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + body).write(to: url, atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-X", "-r", file.path] + Set(parts.keys.map { String($0.split(separator: "/")[0]) }).sorted()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { fail("zip couldn't make \(file.lastPathComponent)") }
    } catch {
        fail("couldn't make \(file.lastPathComponent): \(error.localizedDescription)")
    }
}

// MARK: - Budget.xlsx: words, dates and money as real numbers, and a sum

func excelDate(_ year: Int, _ month: Int, _ day: Int) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
    let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
    return calendar.dateComponents([.day], from: base, to: date).day!
}
func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
let budget: [(item: String, category: String, date: (Int, Int, Int), cost: Double)] = [
    ("Ferry, two people", "Travel", (2026, 6, 14), 97.00),
    ("Hotel in Oia, 3 nights", "Rooms", (2026, 6, 14), 570.00),
    ("Car for a day", "Travel", (2026, 6, 15), 55.00),
    ("Boat around the caldera", "Activities", (2026, 6, 16), 130.00),
    ("Food and drinks", "Food", (2026, 6, 17), 270.00),
    ("Akrotiri tickets", "Activities", (2026, 6, 15), 24.00),
]
var rows = "<row r=\"1\">" + ["Item", "Category", "Date", "Cost (€)"].enumerated().map { i, title in
    "<c r=\"\(["A", "B", "C", "D"][i])1\" t=\"inlineStr\" s=\"1\"><is><t>\(xmlEscape(title))</t></is></c>"
}.joined() + "</row>"
for (i, line) in budget.enumerated() {
    let r = i + 2
    rows += "<row r=\"\(r)\"><c r=\"A\(r)\" t=\"inlineStr\"><is><t>\(xmlEscape(line.item))</t></is></c>"
        + "<c r=\"B\(r)\" t=\"inlineStr\"><is><t>\(line.category)</t></is></c>"
        + "<c r=\"C\(r)\" s=\"2\"><v>\(excelDate(line.date.0, line.date.1, line.date.2))</v></c>"
        + "<c r=\"D\(r)\" s=\"3\"><v>\(line.cost)</v></c></row>"
}
let totalRow = budget.count + 2
let total = budget.reduce(0) { $0 + $1.cost }
rows += "<row r=\"\(totalRow)\"><c r=\"A\(totalRow)\" t=\"inlineStr\" s=\"5\"><is><t>Total</t></is></c>"
    + "<c r=\"D\(totalRow)\" s=\"4\"><f>SUM(D2:D\(totalRow - 1))</f><v>\(total)</v></c></row>"

let xlsx = work.appendingPathComponent("xlsx")
let ns = "http://schemas.openxmlformats.org"
let parts: [String: String] = [
    "[Content_Types].xml": """
        <Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """,
    "_rels/.rels": """
        <Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """,
    "xl/workbook.xml": """
        <workbook xmlns="\(ns)/spreadsheetml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships"><sheets><sheet name="Trip budget" sheetId="1" r:id="rId1"/></sheets></workbook>
        """,
    "xl/_rels/workbook.xml.rels": """
        <Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\(ns)/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """,
    // Styles: 0 plain, 1 header, 2 date, 3 euros, 4 bold euros, 5 bold.
    "xl/styles.xml": """
        <styleSheet xmlns="\(ns)/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/></numFmts><fonts count="2"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCEBFB"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """,
    "xl/worksheets/sheet1.xml": """
        <worksheet xmlns="\(ns)/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="26" customWidth="1"/><col min="2" max="2" width="14" customWidth="1"/><col min="3" max="3" width="12" customWidth="1"/><col min="4" max="4" width="13" customWidth="1"/></cols><sheetData>\(rows)</sheetData></worksheet>
        """,
]
pack(parts, in: xlsx, to: out.appendingPathComponent("Budget.xlsx"))

// MARK: - Trip notes.docx: real headings, a bulleted list and a table

let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
func para(_ text: String, style: String? = nil, bullet: Bool = false) -> String {
    var props = ""
    if let style { props += "<w:pStyle w:val=\"\(style)\"/>" }
    if bullet { props += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>" }
    return "<w:p>\(props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>")<w:r><w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>"
}
func cell(_ text: String, width: Int, header: Bool) -> String {
    let shade = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"DCEBFB\"/>" : ""
    let run = header ? "<w:rPr><w:b/></w:rPr>" : ""
    return "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shade)</w:tcPr><w:p><w:r>\(run)<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p></w:tc>"
}
let widths = [4200, 3000, 1800]
let bookings = [["What", "When", "Booked"], ["Ferry from Piraeus", "14 June, 07:25", "Yes"], ["Hotel in Oia", "14 to 17 June", "Yes"], ["Boat around the caldera", "16 June, 10:00", "Not yet"]]
// Borders and widths on the table itself too: not every app reads table styles.
let tableXML = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"9000\" w:type=\"dxa\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B7BFCC\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B7BFCC\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B7BFCC\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B7BFCC\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B7BFCC\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B7BFCC\"/></w:tblBorders><w:tblLayout w:type=\"fixed\"/></w:tblPr><w:tblGrid>"
    + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
    + bookings.enumerated().map { r, row in
        "<w:tr>" + (r == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "") + row.enumerated().map { c, text in cell(text, width: widths[c], header: r == 0) }.joined() + "</w:tr>"
    }.joined() + "</w:tbl>"
let body = [
    para("Trip notes", style: "Heading1"),
    para("Santorini, 14 to 17 June. Two of us, three nights in Oia."),
    para("To pack", style: "Heading2"),
    para("Walking shoes for the path from Fira to Oia", style: "ListParagraph", bullet: true),
    para("Sun hat and sunscreen", style: "ListParagraph", bullet: true),
    para("Swimsuits for the hot springs", style: "ListParagraph", bullet: true),
    para("A power bank for photos at sunset", style: "ListParagraph", bullet: true),
    para("Bookings", style: "Heading2"),
    tableXML,
    para("Ideas", style: "Heading2"),
    para("Dinner in Ammoudi Bay, below Oia. The wine museum in Vothonas. The lighthouse at Akrotiri for the last evening."),
].joined()
let font = "<w:rFonts w:ascii=\"Helvetica Neue\" w:hAnsi=\"Helvetica Neue\" w:cs=\"Helvetica Neue\"/>"
pack([
    "[Content_Types].xml": """
        <Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>
        """,
    "_rels/.rels": """
        <Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """,
    "word/_rels/document.xml.rels": """
        <Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="\(ns)/officeDocument/2006/relationships/numbering" Target="numbering.xml"/></Relationships>
        """,
    "word/styles.xml": """
        <w:styles xmlns:w="\(w)"><w:docDefaults><w:rPrDefault><w:rPr>\(font)<w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr>\(font)<w:sz w:val="22"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="0" w:after="200"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="1F2A44"/><w:sz w:val="44"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:color w:val="2B6CDF"/><w:sz w:val="28"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="40"/><w:ind w:left="720"/></w:pPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="B7BFCC"/><w:left w:val="single" w:sz="4" w:space="0" w:color="B7BFCC"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="B7BFCC"/><w:right w:val="single" w:sz="4" w:space="0" w:color="B7BFCC"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="B7BFCC"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="B7BFCC"/></w:tblBorders><w:tblCellMar><w:top w:w="60" w:type="dxa"/><w:left w:w="110" w:type="dxa"/><w:bottom w:w="60" w:type="dxa"/><w:right w:w="110" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style></w:styles>
        """,
    "word/numbering.xml": """
        <w:numbering xmlns:w="\(w)"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
        """,
    "word/document.xml": """
        <w:document xmlns:w="\(w)"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """,
], in: work.appendingPathComponent("docx"), to: out.appendingPathComponent("Trip notes.docx"))

print("Drew 3 photos, the video's picture, Santorini guide.pdf, Budget.xlsx and Trip notes.docx")
