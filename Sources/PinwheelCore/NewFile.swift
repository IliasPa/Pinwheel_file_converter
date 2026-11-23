import Foundation

/// The kinds of new, empty file that Finder's right-click › New File can make.
public enum NewFileKind: String, CaseIterable, Codable, Sendable {
    case word, excel, powerpoint, pages, numbers, keynote
    case text, markdown, richText, html, csv, json, python, shell, openDocumentText

    public var title: String {
        switch self {
        case .word: "Word Document"
        case .excel: "Excel Workbook"
        case .powerpoint: "PowerPoint Presentation"
        case .pages: "Pages Document"
        case .numbers: "Numbers Spreadsheet"
        case .keynote: "Keynote Presentation"
        case .text: "Text File"
        case .markdown: "Markdown File"
        case .richText: "Rich Text Document"
        case .html: "Web Page"
        case .csv: "CSV Table"
        case .json: "JSON File"
        case .python: "Python Script"
        case .shell: "Shell Script"
        case .openDocumentText: "OpenDocument Text"
        }
    }

    public var fileExtension: String {
        switch self {
        case .word: "docx"
        case .excel: "xlsx"
        case .powerpoint: "pptx"
        case .pages: "pages"
        case .numbers: "numbers"
        case .keynote: "key"
        case .text: "txt"
        case .markdown: "md"
        case .richText: "rtf"
        case .html: "html"
        case .csv: "csv"
        case .json: "json"
        case .python: "py"
        case .shell: "sh"
        case .openDocumentText: "odt"
        }
    }

    /// The new file's name, before a number is added to tell it apart.
    public var baseName: String { "New \(title)" }

    /// Pages, Numbers and Keynote make their own files: the app has to be on
    /// this Mac. Its bundle identifiers: today's, then the older App Store one.
    public var makingApps: [String] {
        switch self {
        case .pages: ["com.apple.Pages", "com.apple.iWork.Pages"]
        case .numbers: ["com.apple.Numbers", "com.apple.iWork.Numbers"]
        case .keynote: ["com.apple.Keynote", "com.apple.iWork.Keynote"]
        default: []
        }
    }

    public var needsApp: Bool { !makingApps.isEmpty }

    /// On in a new menu, in this order (Settings can change both).
    public static let startingMenu: [NewFileKind] = [.word, .excel, .powerpoint, .pages, .numbers, .keynote, .text, .markdown]
}

/// Writes the empty files (all but Pages, Numbers and Keynote, which their
/// apps make), and finds a free name for them.
public enum NewFileMaker {
    /// "New Word Document.docx", or "New Word Document 2.docx" and so on when
    /// that's taken. `exists` is asked about each name (tests give their own).
    public static func freeURL(in folder: URL, baseName: String, fileExtension: String,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        func named(_ name: String) -> URL {
            folder.appendingPathComponent(fileExtension.isEmpty ? name : "\(name).\(fileExtension)")
        }
        var url = named(baseName)
        var number = 2
        while exists(url) {
            url = named("\(baseName) \(number)")
            number += 1
        }
        return url
    }

    /// The words a name for new files can use: the Rename window's pattern
    /// words that mean something for a file that's only being made.
    public static let nameTokens: [(token: String, title: String)] = [
        ("{name}", "Usual Name"), ("{today}", "Today"), ("{folder}", "Folder"),
    ]

    /// A new file's name, without its extension: `usual` ("New Word Document",
    /// or your template's name), or one name for every new file
    /// (Settings › New File menu). That name is a pattern, as in the Rename
    /// window: {name} is the usual name, {today} today's date (2026-11-23),
    /// {folder} the folder's name. / and : (not allowed in names) become -,
    /// a dot at the start (it would hide the file) goes; nothing left gives
    /// the usual name.
    public static func baseName(pattern: String, usual: String, fileExtension: String, folder: URL, now: Date = Date()) -> String {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return usual }
        var rule = RenameRule(.pattern)
        rule.text = pattern
        var name = FileName(base: usual, ext: fileExtension)
        let info = RenameFileInfo(created: now, modified: now, folder: folder.lastPathComponent)
        rule.apply(to: &name, context: RenameContext(index: 0, original: name, info: info, now: now))
        var base = name.base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base = String(base.dropFirst()).trimmingCharacters(in: .whitespaces) }
        // Room for " 99" and the extension, inside the 255-byte limit.
        while base.utf8.count > 255 - fileExtension.utf8.count - 8 { base.removeLast() }
        return base.isEmpty ? usual : base
    }

    /// Writes an empty file of this kind. Never replaces a file that's there.
    public static func write(_ kind: NewFileKind, to url: URL) throws {
        guard !kind.needsApp else { throw ConversionError.failed("\(kind.title)s are made by their own app.") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ConversionError.cannotWrite(url.lastPathComponent) }
        let data: Data
        switch kind {
        case .word: data = emptyWord()
        case .excel: data = emptyExcel()
        case .powerpoint: data = emptyPowerPoint()
        case .openDocumentText: data = emptyOpenDocumentText()
        case .richText: data = Data(#"{\rtf1\ansi\ansicpg1252\cocoartf2822{\fonttbl\f0\fswiss\fcharset0 Helvetica;}\f0\fs24 }"#.utf8)
        case .html:
            let title = xmlEscape(url.deletingPathExtension().lastPathComponent)
            data = Data("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>\(title)</title>\n</head>\n<body>\n\n</body>\n</html>\n".utf8)
        case .json: data = Data("{\n}\n".utf8)
        case .python: data = Data("#!/usr/bin/env python3\n\n".utf8)
        case .shell: data = Data("#!/bin/zsh\n\n".utf8)
        case .text, .markdown, .csv: data = Data()
        case .pages, .numbers, .keynote: return
        }
        try data.write(to: url, options: .withoutOverwriting)
        if kind == .shell {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - Office files

    private static let xmlHead = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    private static func relations(_ items: [(id: String, type: String, target: String)]) -> String {
        xmlHead + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items.map { #"<Relationship Id="\#($0.id)" Type="\#($0.type)" Target="\#($0.target)"/>"# }.joined()
            + "</Relationships>"
    }

    private static let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    private static let relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    static func emptyWord() -> Data {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", xmlHead + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#)
        zip.add("_rels/.rels", relations([("rId1", officeDocument, "word/document.xml")]))
        let size = PaperSize.current
        let (width, height) = (Int((size.width * 20).rounded()), Int((size.height * 20).rounded()))
        zip.add("word/document.xml", xmlHead + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/><w:sectPr><w:pgSz w:w="\#(width)" w:h="\#(height)"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>"#)
        return zip.finished()
    }

    static func emptyExcel() -> Data {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", xmlHead + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#)
        zip.add("_rels/.rels", relations([("rId1", officeDocument, "xl/workbook.xml")]))
        zip.add("xl/_rels/workbook.xml.rels", relations([
            ("rId1", relationship + "worksheet", "worksheets/sheet1.xml"),
            ("rId2", relationship + "styles", "styles.xml"),
        ]))
        zip.add("xl/workbook.xml", xmlHead + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
        zip.add("xl/worksheets/sheet1.xml", xmlHead + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>"#)
        zip.add("xl/styles.xml", xmlHead + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="12"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#)
        return zip.finished()
    }

    /// One empty 16:9 slide, with the master, layout and theme PowerPoint needs.
    static func emptyPowerPoint() -> Data {
        let p = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let emptyTree = #"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"#
        let mapping = #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", xmlHead + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>"#)
        zip.add("_rels/.rels", relations([("rId1", officeDocument, "ppt/presentation.xml")]))
        zip.add("ppt/_rels/presentation.xml.rels", relations([
            ("rId1", relationship + "slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId2", relationship + "slide", "slides/slide1.xml"),
            ("rId3", relationship + "theme", "theme/theme1.xml"),
        ]))
        zip.add("ppt/presentation.xml", xmlHead + #"<p:presentation \#(p)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", relations([
            ("rId1", relationship + "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", relationship + "theme", "../theme/theme1.xml"),
        ]))
        let masterTree = emptyTree.replacingOccurrences(of: "<p:cSld>", with: #"<p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"#)
        zip.add("ppt/slideMasters/slideMaster1.xml", xmlHead + #"<p:sldMaster \#(p)>\#(masterTree)\#(mapping)<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>"#)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relations([("rId1", relationship + "slideMaster", "../slideMasters/slideMaster1.xml")]))
        zip.add("ppt/slideLayouts/slideLayout1.xml", xmlHead + #"<p:sldLayout \#(p) type="blank" preserve="1">\#(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#)
        zip.add("ppt/slides/_rels/slide1.xml.rels", relations([("rId1", relationship + "slideLayout", "../slideLayouts/slideLayout1.xml")]))
        zip.add("ppt/slides/slide1.xml", xmlHead + #"<p:sld \#(p)>\#(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#)
        zip.add("ppt/theme/theme1.xml", xmlHead + theme)
        return zip.finished()
    }

    /// Office's own colors and fonts, in the shortest form PowerPoint accepts.
    private static let theme: String = {
        func color(_ name: String, _ hex: String) -> String { "<a:\(name)><a:srgbClr val=\"\(hex)\"/></a:\(name)>" }
        let colors = color("dk1", "000000") + color("lt1", "FFFFFF") + color("dk2", "0E2841") + color("lt2", "E8E8E8")
            + color("accent1", "156082") + color("accent2", "E97132") + color("accent3", "196B24") + color("accent4", "0F9ED5")
            + color("accent5", "A02B93") + color("accent6", "4EA72E") + color("hlink", "467886") + color("folHlink", "96607D")
        let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        let line = #"<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#
        return #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office">"#
            + colors
            + #"</a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst>"#
            + fill + fill + fill
            + "</a:fillStyleLst><a:lnStyleLst>" + line + line + line
            + "</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>"
            + fill + fill + fill
            + "</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    }()

    static func emptyOpenDocumentText() -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", "application/vnd.oasis.opendocument.text", compress: false)
        zip.add("META-INF/manifest.xml", #"<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>"#)
        zip.add("content.xml", #"<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:text><text:p/></office:text></office:body></office:document-content>"#)
        return zip.finished()
    }
}
