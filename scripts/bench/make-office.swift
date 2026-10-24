// Makes the bench's hard documents, spreadsheets and slides: Word with
// tracked changes, comments, footnotes, merged and nested tables, text
// boxes and right-to-left text; Excel with every kind of cell; an ODS that
// repeats empty columns a million times; EPUB, HTML, Markdown, RTF, ODT,
// .doc and web archives; real files from Apple's and Microsoft's apps.
// Usage: swift scripts/bench/make-office.swift <folder>
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let documents = root.appendingPathComponent("documents"), sheets = root.appendingPathComponent("sheets"), slides = root.appendingPathComponent("slides")
for folder in [documents, sheets, slides] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
}
let work = FileManager.default.temporaryDirectory.appendingPathComponent("bench-office-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }

func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let folder { process.currentDirectoryURL = folder }
    try! process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { print("failed: \(tool) \(arguments.joined(separator: " "))") }
}

/// Writes `files` (path → contents) and zips them into `destination`.
/// `stored` goes first, uncompressed (EPUB's mimetype).
func pack(_ files: [String: Data], to destination: URL, stored: String? = nil) {
    let folder = work.appendingPathComponent(UUID().uuidString)
    for (path, data) in files {
        let url = folder.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }
    try? FileManager.default.removeItem(at: destination)
    if let stored { run("/usr/bin/zip", ["-q", "-X", "-0", destination.path, stored], in: folder) }
    let rest = files.keys.filter { $0 != stored }.sorted()
    run("/usr/bin/zip", ["-q", "-X", "-9", destination.path] + rest, in: folder)
}

func xml(_ text: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + text).utf8) }

func png(_ width: Int, _ height: Int, _ color: NSColor) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let picture = png(200, 120, .systemTeal)

// MARK: - Word

let wordNamespaces = """
xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" \
xmlns:v="urn:schemas-microsoft-com:vml" \
xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" \
mc:Ignorable="wps"
"""

func run(_ text: String, _ properties: String = "") -> String {
    "<w:r>\(properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
}

func paragraph(_ content: String, style: String? = nil, numbering: (Int, Int)? = nil, extra: String = "") -> String {
    var properties = ""
    if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
    if let (id, level) = numbering { properties += "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(id)\"/></w:numPr>" }
    properties += extra
    return "<w:p>\(properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")\(content)</w:p>"
}

func cell(_ content: String, width: Int = 2400, extra: String = "") -> String {
    "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(extra)</w:tcPr>\(content)</w:tc>"
}

let inlinePicture = """
<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="1905000" cy="1143000"/><wp:docPr id="1" name="Picture 1" descr="A teal picture"/>\
<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="image1.png"/><pic:cNvPicPr/></pic:nvPicPr>\
<pic:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1905000" cy="1143000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
"""

let textBox = """
<w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:anchor distT="0" distB="0" distL="114300" distR="114300" simplePos="0" relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">\
<wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="column"><wp:posOffset>3000000</wp:posOffset></wp:positionH><wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>\
<wp:extent cx="1800000" cy="600000"/><wp:wrapSquare wrapText="bothSides"/><wp:docPr id="2" name="Text Box 2"/>\
<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:wsp><wps:cNvSpPr txBox="1"/><wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1800000" cy="600000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr>\
<wps:txbx><w:txbxContent><w:p><w:r><w:t>TEXTBOX-CONTENT once</w:t></w:r></w:p></w:txbxContent></wps:txbx><wps:bodyPr/></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice>\
<mc:Fallback><w:pict><v:shape style="width:140pt;height:47pt"><v:textbox><w:txbxContent><w:p><w:r><w:t>TEXTBOX-CONTENT once</w:t></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r>
"""

let nested = """
<w:tbl><w:tblPr><w:tblW w:w="2000" w:type="dxa"/><w:tblBorders><w:top w:val="single" w:sz="4"/><w:bottom w:val="single" w:sz="4"/><w:insideH w:val="single" w:sz="4"/></w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="2000"/></w:tblGrid>\
<w:tr>\(cell(paragraph(run("Nested cell")), width: 2000))</w:tr></w:tbl>\(paragraph(""))
"""

let wordBody = [
    paragraph(run("Bench Report · Αναφορά"), style: "Title"),
    paragraph(run("Chapter One · Κεφάλαιο"), style: "Heading1"),
    paragraph(run("Plain then ") + run("bold", "<w:b/>") + run(" then ") + run("italic", "<w:i/>") + run(" then ") + run("red underlined", "<w:color w:val=\"C00000\"/><w:u w:val=\"single\"/>") + run(".")),
    paragraph(run("Tracked: ") + "<w:ins w:id=\"1\" w:author=\"Bench\" w:date=\"2026-10-01T10:00:00Z\">" + run("INSERTED-KEEP") + "</w:ins>"
        + "<w:del w:id=\"2\" w:author=\"Bench\" w:date=\"2026-10-01T10:00:00Z\"><w:r><w:delText>DELETED-GONE</w:delText></w:r></w:del>" + run(" end of tracked.")),
    paragraph("<w:commentRangeStart w:id=\"0\"/>" + run("Commented words") + "<w:commentRangeEnd w:id=\"0\"/><w:r><w:commentReference w:id=\"0\"/></w:r>" + run(" and a footnote")
        + "<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteReference w:id=\"1\"/></w:r>" + run(".")),
    paragraph("<w:hyperlink r:id=\"rIdLink\">" + run("Pinwheel link", "<w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/>") + "</w:hyperlink>" + run(" and a field: ")
        + "<w:fldSimple w:instr=\" DATE \">" + run("24/10/2026") + "</w:fldSimple>"),
    paragraph(run("Before tab") + "<w:r><w:tab/></w:r>" + run("after tab") + "<w:r><w:br/></w:r>" + run("after line break, soft") + "<w:r><w:softHyphen/></w:r>" + run("hyphen, non") + "<w:r><w:noBreakHyphen/></w:r>" + run("breaking.")),
    paragraph(run("Bullet one"), style: "ListParagraph", numbering: (1, 0)),
    paragraph(run("Bullet nested"), style: "ListParagraph", numbering: (1, 1)),
    paragraph(run("Bullet back out"), style: "ListParagraph", numbering: (1, 0)),
    paragraph(run("Step one"), style: "ListParagraph", numbering: (2, 0)),
    paragraph(run("Step two"), style: "ListParagraph", numbering: (2, 0)),
    "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"7200\" w:type=\"dxa\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\"/><w:left w:val=\"single\" w:sz=\"4\"/><w:bottom w:val=\"single\" w:sz=\"4\"/><w:right w:val=\"single\" w:sz=\"4\"/><w:insideH w:val=\"single\" w:sz=\"4\"/><w:insideV w:val=\"single\" w:sz=\"4\"/></w:tblBorders></w:tblPr>"
        + "<w:tblGrid><w:gridCol w:w=\"2400\"/><w:gridCol w:w=\"2400\"/><w:gridCol w:w=\"2400\"/></w:tblGrid>"
        + "<w:tr>" + cell(paragraph(run("Merged header", "<w:b/>")), width: 4800, extra: "<w:gridSpan w:val=\"2\"/>") + cell(paragraph(run("Third", "<w:b/>"))) + "</w:tr>"
        + "<w:tr>" + cell(paragraph(run("Tall cell")), extra: "<w:vMerge w:val=\"restart\"/>") + cell(paragraph(run("Cell B2"))) + cell(paragraph(run("Τιμή 12,50 €"))) + "</w:tr>"
        + "<w:tr>" + cell(paragraph(""), extra: "<w:vMerge/>") + cell(nested) + cell(paragraph(run("Cell C3"))) + "</w:tr></w:tbl>",
    paragraph(inlinePicture),
    paragraph(run("A text box sits beside this paragraph.") + textBox),
    "<w:sdt><w:sdtPr><w:alias w:val=\"Field\"/></w:sdtPr><w:sdtContent>" + paragraph(run("SDT-CONTENT in a content control")) + "</w:sdtContent></w:sdt>",
    paragraph(run("שלום עולם — Hebrew from the right", "<w:rtl/>"), extra: "<w:bidi/>"),
    paragraph("<m:oMathPara><m:oMath><m:r><m:t>E=mc</m:t></m:r><m:sSup><m:e><m:r><m:t>x</m:t></m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup></m:oMath></m:oMathPara>"),
    paragraph(run("Emoji 😀 and Greek: Καλημέρα, «εισαγωγικά» and “smart quotes”.")),
    paragraph("<w:r><w:br w:type=\"page\"/></w:r>"),
    paragraph(run("Landscape section"), style: "Heading1", extra: "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\"/></w:sectPr>"),
    paragraph(run("This last part is landscape. The end · Τέλος.")),
].joined()

let word: [String: Data] = [
    "[Content_Types].xml": xml("""
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
    <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>\
    <Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>\
    <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>\
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
    """),
    "_rels/.rels": xml("""
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
    """),
    "docProps/core.xml": xml("""
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Bench Report</dc:title><dc:creator>Μαρία</dc:creator></cp:coreProperties>
    """),
    "word/_rels/document.xml.rels": xml("""
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
    <Relationship Id="rIdFootnotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>\
    <Relationship Id="rIdComments" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="comments.xml"/>\
    <Relationship Id="rIdHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>\
    <Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>\
    <Relationship Id="rIdImage" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>\
    <Relationship Id="rIdLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://github.com/IliasPa/Pinwheel_file_converter" TargetMode="External"/></Relationships>
    """),
    "word/document.xml": xml("""
    <w:document \(wordNamespaces)><w:body>\(wordBody)<w:sectPr><w:headerReference w:type="default" r:id="rIdHeader"/><w:footerReference w:type="default" r:id="rIdFooter"/>\
    <w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708"/></w:sectPr></w:body></w:document>
    """),
    "word/styles.xml": xml("""
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Arial"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="56"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>\
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/></w:style></w:styles>
    """),
    "word/numbering.xml": xml("""
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>\
    <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="o"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
    <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>
    """),
    "word/footnotes.xml": xml("""
    <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>\
    <w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> FOOTNOTE-TEXT at the bottom.</w:t></w:r></w:p></w:footnote></w:footnotes>
    """),
    "word/comments.xml": xml("""
    <w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:comment w:id="0" w:author="Bench" w:date="2026-10-01T10:00:00Z" w:initials="B"><w:p><w:r><w:t>COMMENT-NOTE</w:t></w:r></w:p></w:comment></w:comments>
    """),
    "word/header1.xml": xml("<w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>HEADER-TEXT</w:t></w:r></w:p></w:hdr>"),
    "word/footer1.xml": xml("<w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t xml:space=\"preserve\">FOOTER-TEXT page </w:t></w:r><w:fldSimple w:instr=\" PAGE \"><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p></w:ftr>"),
    "word/media/image1.png": picture,
]
pack(word, to: documents.appendingPathComponent("tracked changes comments.docx"))

// Real Word files from Microsoft's own templates.
let wordElements = URL(fileURLWithPath: "/Applications/Microsoft Word.app/Contents/Resources/en.lproj/Document Elements")
for name in ["Tables", "Equations", "Cover Pages", "Table of Contents"] {
    let source = wordElements.appendingPathComponent("\(name).dotx")
    let target = documents.appendingPathComponent("word \(name.lowercased()).dotx")
    try? FileManager.default.removeItem(at: target)
    try? FileManager.default.copyItem(at: source, to: target)
}

// MARK: - HTML, and what textutil makes of it (doc, rtf, odt, webarchive, rtfd)

let pictureBase64 = picture.base64EncodedString()
let html = """
<!DOCTYPE html>
<html lang="el"><head><meta charset="utf-8"><title>Web Page Τίτλος</title>
<style>body { font-family: Georgia; } .note { color: #a00; } table { border-collapse: collapse; } td, th { border: 1px solid #333; padding: 4px; }</style>
<script>document.write("SCRIPT-SHOULD-NOT-SHOW");</script></head>
<body>
<!-- HTML-COMMENT-HIDDEN -->
<h1>Web Page Heading</h1>
<p>A paragraph with <b>bold</b>, <i>italic</i>, <a href="https://example.com/page?a=1&amp;b=2">a link</a>, H<sub>2</sub>O and x<sup>2</sup>. Entities: &euro; &nbsp;&copy; &#x1F600; &lt;tag&gt;.</p>
<p class="note">Ελληνικά με τόνους: άέήίόύώ.<br>After a line break.</p>
<img src="web-picture.png" alt="Local picture" width="200"> <img src="data:image/png;base64,\(pictureBase64)" alt="Inline picture"> <img src="https://example.com/remote.png" alt="Remote picture">
<table><thead><tr><th colspan="2">Merged head</th><th>Price</th></tr></thead>
<tbody><tr><td>Row one</td><td>A</td><td>1.234,56 €</td></tr><tr><td>Row two</td><td>B</td><td>-7,00 €</td></tr></tbody></table>
<ul><li>Outer item<ul><li>Inner item</li></ul></li><li>Second outer</li></ul>
<ol start="3"><li>Third</li><li>Fourth</li></ol>
<blockquote>A quotation · Παράθεση</blockquote>
<pre><code>func code() { print("&lt;kept&gt;   spaces") }</code></pre>
<hr><p>End of page.</p>
</body></html>
"""
try Data(html.utf8).write(to: documents.appendingPathComponent("web page.html"))
try png(160, 100, .systemOrange).write(to: documents.appendingPathComponent("web-picture.png"))
let legacyHTML = "<html><head><meta charset=\"windows-1253\"><title>Παλιά σελίδα</title></head><body><h1>Ελληνικά σε Windows-1253</h1><p>Καλημέρα κόσμε!</p></body></html>"
try legacyHTML.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsGreek.rawValue))))!
    .write(to: documents.appendingPathComponent("greek windows-1253.html"))

let richSource = work.appendingPathComponent("rich.html")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
try Data(html.replacingOccurrences(of: "<script>document.write(\"SCRIPT-SHOULD-NOT-SHOW\");</script>", with: "").utf8).write(to: richSource)
try png(160, 100, .systemOrange).write(to: work.appendingPathComponent("web-picture.png"))
for (format, name) in [("doc", "legacy word.doc"), ("rtf", "rich text.rtf"), ("odt", "open document.odt"), ("webarchive", "saved page.webarchive"), ("rtfd", "with attachments.rtfd")] {
    let target = documents.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: target)
    run("/usr/bin/textutil", ["-convert", format, richSource.path, "-output", target.path])
}

// An RTF with a picture, the way Word writes them ({\*\shppict} with a fallback).
let hex = picture.map { String(format: "%02x", $0) }.joined()
let rtf = "{\\rtf1\\ansi\\ansicpg1253\\deff0{\\fonttbl{\\f0\\froman\\fcharset161 Times New Roman Greek;}}\\f0\\fs24 RTF from Word: \\'c3\\'e5\\'e9\\'dc picture below\\par "
    + "{\\*\\shppict{\\pict\\pngblip\\picw200\\pich120\\picwgoal3000\\pichgoal1800 \(hex)}}{\\nonshppict{\\pict\\wmetafile8\\picw200\\pich120 0000}}\\par After the picture.\\par}"
try Data(rtf.utf8).write(to: documents.appendingPathComponent("word picture.rtf"))

// MARK: - Markdown

let markdown = """
Setext Title
============

# ATX Heading · Επικεφαλίδα

Some *italic*, **bold**, ***both***, `inline <code>`, ~~struck~~ and an escaped \\*not italic\\*.
A hard line break follows
right here. HTML <kbd>Ctrl</kbd> and &copy; and an autolink <https://example.com>.

| Left | Center | Right |
|:-----|:------:|------:|
| a    | b      | 1,50  |
| Ελλάδα | 😀 | 10 |

- [x] Done task
- [ ] Open task
  - Nested level two
    - Nested level three

3. Starts at three
4. Then four

> Quote level one
>> Quote level two

```swift
let tag = "<not html>"   // spaces kept
```

![Markdown picture](md-picture.png "A title")

Footnote here[^1] and a [link](https://example.com "With title").

---

[^1]: MD-FOOTNOTE text.
"""
try Data(markdown.utf8).write(to: documents.appendingPathComponent("notes.md"))
try png(120, 80, .systemPurple).write(to: documents.appendingPathComponent("md-picture.png"))

// MARK: - EPUB (chapter files named against their order in the spine)

let chapter = { (title: String, content: String) in
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="el"><head><title>\(title)</title><link rel="stylesheet" href="style.css"/></head>
    <body><section epub:type="chapter"><h1>\(title)</h1>\(content)</section></body></html>
    """.utf8)
}
let epub: [String: Data] = [
    "mimetype": Data("application/epub+zip".utf8),
    "META-INF/container.xml": xml("<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"),
    "OEBPS/content.opf": xml("""
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">bench-book</dc:identifier><dc:title>Το Βιβλίο</dc:title><dc:creator>Bench Author</dc:creator><dc:language>el</dc:language><meta property="dcterms:modified">2026-10-24T00:00:00Z</meta></metadata>\
    <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="first" href="z-first.xhtml" media-type="application/xhtml+xml"/><item id="second" href="a-second.xhtml" media-type="application/xhtml+xml"/><item id="css" href="style.css" media-type="text/css"/><item id="pic" href="images/picture.png" media-type="image/png"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>\
    <spine toc="ncx"><itemref idref="first"/><itemref idref="second"/></spine></package>
    """),
    "OEBPS/nav.xhtml": chapter("Contents", "<nav epub:type=\"toc\"><ol><li><a href=\"z-first.xhtml\">One</a></li><li><a href=\"a-second.xhtml\">Two</a></li></ol></nav>"),
    "OEBPS/toc.ncx": xml("<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>Το Βιβλίο</text></docTitle><navMap><navPoint id=\"n1\" playOrder=\"1\"><navLabel><text>One</text></navLabel><content src=\"z-first.xhtml\"/></navPoint></navMap></ncx>"),
    "OEBPS/style.css": Data("body { font-family: serif; } h1 { color: #036; }".utf8),
    "OEBPS/images/picture.png": picture,
    "OEBPS/z-first.xhtml": chapter("EPUB-CHAPTER-ONE Πρώτο", "<p>The first chapter, with a picture:</p><img src=\"images/picture.png\" alt=\"pic\"/><p>And a note<a epub:type=\"noteref\" href=\"#n1\">1</a>.</p><aside epub:type=\"footnote\" id=\"n1\"><p>EPUB-NOTE text.</p></aside>"),
    "OEBPS/a-second.xhtml": chapter("EPUB-CHAPTER-TWO Δεύτερο", "<table><tr><th>Name</th><th>Value</th></tr><tr><td>π</td><td>3,14</td></tr></table><ul><li>List in a book</li></ul><blockquote><p>Quoted.</p></blockquote>"),
]
pack(epub, to: documents.appendingPathComponent("book chapters.epub"), stored: "mimetype")

// Real files: a blank .doc and .odt; a Pages template saved as a document.
for (source, name) in [
    ("/Applications/New File Menu Lite.app/Contents/Resources/FileTemplates/WordDocument.doc", "blank real.doc"),
    ("/Applications/New File Menu Lite.app/Contents/Resources/FileTemplates/ODFTextDocument.odt", "blank real.odt"),
    ("/Applications/Pages.app/Contents/SharedSupport/Templates/00C_Textbook_Portrait/ISO.template", "pages textbook.pages"),
] {
    let target = documents.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: target)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
}

// MARK: - Excel

func sheetXML(_ rows: String, merges: String = "", extra: String = "") -> Data {
    xml("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(extra)<sheetData>\(rows)</sheetData>\(merges)</worksheet>")
}

func workbook(sheets names: [(String, String)], date1904: Bool = false, sheetFiles: [String: Data], sharedStrings: [String], styles: Data) -> [String: Data] {
    var files = sheetFiles
    files["[Content_Types].xml"] = xml("""
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
    <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
    \(names.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())</Types>
    """)
    files["_rels/.rels"] = xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
    files["xl/_rels/workbook.xml.rels"] = xml("""
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    \(names.indices.map { "<Relationship Id=\"rIdS\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
    <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rIdStrings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>
    """)
    files["xl/workbook.xml"] = xml("""
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr\(date1904 ? " date1904=\"1\"" : "")/><sheets>\
    \(names.enumerated().map { index, sheet in "<sheet name=\"\(sheet.0)\" sheetId=\"\(index + 1)\"\(sheet.1) r:id=\"rIdS\(index + 1)\"/>" }.joined())</sheets></workbook>
    """)
    files["xl/sharedStrings.xml"] = xml("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(sharedStrings.count)\" uniqueCount=\"\(sharedStrings.count)\">\(sharedStrings.map { "<si>\($0)</si>" }.joined())</sst>")
    files["xl/styles.xml"] = styles
    return files
}

// Styles: 0 general, 1 date (14), 2 percent (10), 3 euro, 4 date and time, 5 time, 6 thousands 2 decimals, 7 text (@).
let styles = xml("""
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="3"><numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/><numFmt numFmtId="165" formatCode="dd/mm/yyyy\\ hh:mm"/><numFmt numFmtId="166" formatCode="[h]:mm:ss"/></numFmts>\
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders>\
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="8"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/>\
<xf numFmtId="10" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/>\
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/><xf numFmtId="4" fontId="1" fillId="0" borderId="0" applyNumberFormat="1"/><xf numFmtId="49" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/></cellXfs></styleSheet>
""")
let strings = [
    "<t>Προϊόν</t>", "<t>Price</t>", "<t>Share</t>", "<t>Date</t>", "<r><rPr><b/></rPr><t>Bold</t></r><r><t xml:space=\"preserve\"> and normal</t></r>", "<t>Καφές</t>",
    "<t xml:space=\"preserve\">Line1\nLine2</t>", "<t>007</t>", "<t>Merged across</t>", "<t>Far away</t>", "<t>Hidden sheet text</t>", "<t>When</t>", "<t>Formula</t>",
]
let salesRows = """
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c><c r="E1" t="s"><v>11</v></c></row>\
<row r="2"><c r="A2" t="s"><v>5</v></c><c r="B2" s="3"><v>1234.5</v></c><c r="C2" s="2"><v>0.125</v></c><c r="D2" s="1"><v>46319</v></c><c r="E2" s="4"><v>46319.75</v></c></row>\
<row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" s="6"><v>-0.5</v></c><c r="C3" t="b"><v>1</v></c><c r="D3" t="e"><v>#DIV/0!</v></c><c r="E3" s="5"><v>1.5</v></c></row>\
<row r="4"><c r="A4" t="s"><v>6</v></c><c r="B4"><v>1.2345678901234567E+19</v></c><c r="C4" s="7" t="s"><v>7</v></c><c r="D4" t="inlineStr"><is><t>Inline string</t></is></c></row>\
<row r="10"><c r="A10" t="s"><v>8</v></c></row>\
<row r="100"><c r="Z100" t="s"><v>9</v></c></row>
"""
let formulaRows = """
<row r="1"><c r="A1" t="s"><v>12</v></c></row><row r="2"><c r="A2"><v>1</v></c><c r="B2"><f>A2*10</f><v>10</v></c></row>\
<row r="3"><c r="A3"><v>2</v></c><c r="B3"><f t="shared" ref="B3:B4" si="0">A3*10</f><v>20</v></c></row><row r="4"><c r="A4"><v>3</v></c><c r="B4"><f t="shared" si="0"/><v>30</v></c></row>\
<row r="5"><c r="A5"><f>SUM(A2:A4)</f><v>6</v></c><c r="B5" t="str"><f>"Total "&amp;A5</f><v>Total 6</v></c></row>
"""
let excel = workbook(
    sheets: [("Πωλήσεις 2026", ""), ("Formulas", ""), ("Κρυφό", " state=\"hidden\"")],
    sheetFiles: [
        "xl/worksheets/sheet1.xml": sheetXML(salesRows, merges: "<mergeCells count=\"1\"><mergeCell ref=\"A10:C10\"/></mergeCells>", extra: "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" state=\"frozen\"/></sheetView></sheetViews><cols><col min=\"1\" max=\"1\" width=\"30\" customWidth=\"1\"/></cols>"),
        "xl/worksheets/sheet2.xml": sheetXML(formulaRows),
        "xl/worksheets/sheet3.xml": sheetXML("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>10</v></c></row>"),
    ],
    sharedStrings: strings, styles: styles
)
pack(excel, to: sheets.appendingPathComponent("every kind of cell.xlsx"))

// The Mac's old date system: the same serial is four years later.
let mac1904 = workbook(
    sheets: [("Dates", "")], date1904: true,
    sheetFiles: ["xl/worksheets/sheet1.xml": sheetXML("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>3</v></c></row><row r=\"2\"><c r=\"A2\" s=\"1\"><v>44857</v></c></row>")],
    sharedStrings: strings, styles: styles
)
pack(mac1904, to: sheets.appendingPathComponent("mac 1904 dates.xlsx"))

// A hundred thousand rows.
var big = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>ID</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Name</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>Amount</t></is></c><c r=\"D1\" t=\"inlineStr\"><is><t>Date</t></is></c></row>"
big.reserveCapacity(20_000_000)
for row in 2...100_001 {
    big += "<row r=\"\(row)\"><c r=\"A\(row)\"><v>\(row - 1)</v></c><c r=\"B\(row)\" t=\"inlineStr\"><is><t>Customer \(row % 977)</t></is></c><c r=\"C\(row)\"><v>\(Double(row % 10_000) / 7)</v></c><c r=\"D\(row)\" s=\"1\"><v>\(40000 + row % 3000)</v></c></row>"
}
pack(workbook(sheets: [("Big", "")], sheetFiles: ["xl/worksheets/sheet1.xml": sheetXML(big)], sharedStrings: strings, styles: styles), to: sheets.appendingPathComponent("hundred thousand rows.xlsx"))

// MARK: - OpenDocument spreadsheet (empty cells repeated to the edge, like LibreOffice saves)

let odsContent = """
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:office2="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.3"><office:body><office:spreadsheet>\
<table:table table:name="Φύλλο1"><table:table-column table:number-columns-repeated="16384"/>\
<table:table-row><table:table-cell office:value-type="string"><text:p>Name</text:p></table:table-cell><table:table-cell office:value-type="string"><text:p>Value</text:p></table:table-cell><table:table-cell office:value-type="string"><text:p>When</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16381"/></table:table-row>\
<table:table-row><table:table-cell office:value-type="string"><text:p>Ποσοστό</text:p></table:table-cell><table:table-cell office:value-type="percentage" office:value="0.25"><text:p>25%</text:p></table:table-cell><table:table-cell office:value-type="date" office:date-value="2026-10-24"><text:p>24/10/26</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16381"/></table:table-row>\
<table:table-row><table:table-cell office:value-type="string" table:number-columns-spanned="2"><text:p>ODS-MERGED</text:p></table:table-cell><table:covered-table-cell/><table:table-cell office:value-type="currency" office:currency="EUR" office:value="9.99"><text:p>9,99 €</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16381"/></table:table-row>\
<table:table-row><table:table-cell office:value-type="float" office:value="3" table:number-columns-repeated="3"><text:p>3</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16381"/></table:table-row>\
<table:table-row><table:table-cell><text:p>Two</text:p><text:p>paragraphs</text:p></table:table-cell><table:table-cell office:value-type="string"><text:p>tab<text:tab/>and<text:s text:c="3"/>spaces</text:p></table:table-cell></table:table-row>\
<table:table-row table:number-rows-repeated="1048570"><table:table-cell table:number-columns-repeated="16384"/></table:table-row></table:table>\
<table:table table:name="Second"><table:table-row><table:table-cell office:value-type="string"><text:p>ODS-SECOND-SHEET</text:p></table:table-cell></table:table-row></table:table>\
</office:spreadsheet></office:body></office:document-content>
"""
pack([
    "mimetype": Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
    "META-INF/manifest.xml": xml("<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"),
    "content.xml": xml(odsContent),
], to: sheets.appendingPathComponent("libreoffice repeats.ods"), stored: "mimetype")

for (source, name) in [
    ("/Applications/Numbers.app/Contents/Resources/SampleDocument.numbers", "sample real.numbers"),
    ("/Applications/Numbers.app/Contents/SharedSupport/Templates/02_Invoice/Traditional.nmbtemplate", "invoice template.numbers"),
    ("/Applications/Numbers.app/Contents/Resources/BlankDelimited.xls", "blank real.xls"),
    ("/Applications/Numbers.app/Contents/Resources/FontTemplate.xlsx", "numbers fonts real.xlsx"),
] {
    let target = sheets.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: target)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
}

// MARK: - PowerPoint
// (A deck made by Pinwheel from "slides 16x9.pdf" is added by the bench
// itself: Keynote, which reads PowerPoint files for Pinwheel, stopped on an
// alert with every hand-written deck tried here.)

for (source, name) in [
    ("/Applications/New File Menu Lite.app/Contents/Resources/FileTemplates/PowerPointDocument.ppt", "blank real.ppt"),
    ("/Applications/Keynote.app/Contents/SharedSupport/Templates/BrushedCanvas/Wide.kth", "keynote theme.key"),
] {
    let target = slides.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: target)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
}
print("office done")
