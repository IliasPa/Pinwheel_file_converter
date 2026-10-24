import Foundation
import ImageIO

/// EPUB books: written as EPUB 3 (chapters start at the top headings,
/// with a table of contents), and read from any EPUB 2 or 3 without DRM.
enum EPUBBook {
    static func write(_ document: Document, to url: URL) throws {
        // Chapters: the document split before its biggest headings.
        let top = document.blocks.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }
            return nil
        }.min()
        var chapters: [[Document.Block]] = [[]]
        for block in document.blocks {
            if case .heading(let level, _) = block, level == top, !(chapters.last?.isEmpty ?? true) { chapters.append([]) }
            if case .pageBreak = block { continue }
            chapters[chapters.count - 1].append(block)
        }
        let title = document.displayTitle ?? url.deletingPathExtension().lastPathComponent
        let language = Locale.current.language.languageCode?.identifier ?? "en"

        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        var manifest: [String] = [
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
            "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
        ]
        var spine: [String] = []
        var contents: [String] = []
        var pictureNumber = 0
        for (index, blocks) in chapters.enumerated() {
            let name = "chapter\(index + 1).xhtml"
            let chapter = Document(blocks: blocks)
            let body = chapter.htmlBody(xhtml: true) { picture in
                pictureNumber += 1
                let file = "images/image\(pictureNumber).\(picture.fileExtension)"
                zip.add("OEBPS/\(file)", picture.data, compress: false)
                manifest.append("<item id=\"image\(pictureNumber)\" href=\"\(file)\" media-type=\"\(picture.mimeType)\"/>")
                return file
            }
            let heading = chapter.displayTitle ?? (chapters.count == 1 ? title : "Part \(index + 1)")
            zip.add("OEBPS/\(name)", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)">
            <head><meta charset="utf-8"/><title>\(xmlEscape(heading))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
            \(body)
            </body>
            </html>
            """)
            manifest.append("<item id=\"chapter\(index + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>")
            spine.append("<itemref idref=\"chapter\(index + 1)\"/>")
            contents.append("<li><a href=\"\(name)\">\(xmlEscape(heading))</a></li>")
        }
        zip.add("OEBPS/style.css", Document.css.replacingOccurrences(of: "max-width: 42em; margin: 2em auto; padding: 0 1em;", with: "margin: 0;"))
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>\(xmlEscape(title))</title></head>
        <body><nav epub:type="toc" id="toc"><h1>\(xmlEscape(title))</h1><ol>\(contents.joined())</ol></nav></body>
        </html>
        """)
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">\
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:identifier id="id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>\
        <dc:title>\(xmlEscape(title))</dc:title><dc:language>\(language)</dc:language><dc:creator>Pinwheel</dc:creator>\
        <meta property="dcterms:modified">\(modified)</meta></metadata>\
        <manifest>\(manifest.joined())</manifest><spine>\(spine.joined())</spine></package>
        """)
        try zip.write(to: url)
    }

    static func read(_ url: URL) throws -> Document {
        let zip = try ZipReader(url: url)
        guard let container = zip.data("META-INF/container.xml"),
              let opfPath = XMLElements.read(container).first(where: { $0.name.hasSuffix("rootfile") })?.attributes["full-path"],
              let opf = zip.data(opfPath) else {
            throw ConversionError.failed("\(url.lastPathComponent) isn't a book Pinwheel can open (it may be protected).")
        }
        if zip.contains("META-INF/encryption.xml") {
            throw ConversionError.failed("\(url.lastPathComponent) is protected (DRM), so it can't be converted.")
        }
        let folder = (opfPath as NSString).deletingLastPathComponent
        var items: [String: String] = [:]
        var order: [String] = []
        var title: String?
        for element in XMLElements.read(opf, keepText: true) {
            switch element.name {
            case let name where name.hasSuffix("item"):
                if let id = element.attributes["id"], let href = element.attributes["href"] { items[id] = href }
            case let name where name.hasSuffix("itemref"):
                if let id = element.attributes["idref"] { order.append(id) }
            case "dc:title":
                if title == nil { title = element.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            default: break
            }
        }
        var blocks: [Document.Block] = []
        for id in order {
            guard let href = items[id] else { continue }
            let path = resolve(href.removingPercentEncoding ?? href, from: folder)
            guard let data = zip.data(path) else { continue }
            let chapterFolder = (path as NSString).deletingLastPathComponent
            let chapter = Document(html: TextFile.decode(data)) { source in
                zip.data(resolve(source, from: chapterFolder))
            }
            if !blocks.isEmpty && !chapter.blocks.isEmpty { blocks.append(.pageBreak) }
            blocks += chapter.blocks
        }
        return Document(title: title, blocks: blocks)
    }

    /// "../images/a.png" from "OEBPS/text" → "OEBPS/images/a.png".
    static func resolve(_ href: String, from folder: String) -> String {
        let path = href.components(separatedBy: "#")[0]
        var parts = folder.isEmpty ? [] : folder.components(separatedBy: "/")
        for part in path.components(separatedBy: "/") {
            switch part {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}

/// PowerPoint presentations made from a PDF's pages: a slide for each,
/// the slides sized like the first one. A slide is the page as a picture,
/// with what can be edited on top: pictures to move, words in text boxes.
enum SlideDeck {
    static let emuPerPoint = 12_700.0

    struct Slide {
        let data: Data
        let isJPEG: Bool
        /// The picture's size in points (its shape decides how it fits).
        let size: CGSize
        /// Pictures set on it, each where it is (in points from the top left).
        var pictures: [Placed] = []
        /// Its words, each block where it is.
        var texts: [TextBox] = []
    }

    struct Placed {
        var data: Data
        var isJPEG: Bool
        var frame: CGRect
    }

    /// Lines of words in one box, as they were on the page.
    struct TextBox {
        struct Line {
            var runs: [Document.Run]
            var bold: Bool
        }

        /// In points from the top left.
        var frame: CGRect
        var lines: [Line]
        /// Of most of its letters, in points (a run's own size wins).
        var size: Double
        var font: String?
        /// From one line to the next, in points; nil for one line.
        var lineSpacing: Double?
        /// "l", "ctr" or "r".
        var alignment = "l"
    }

    static func write(_ slides: [Slide], to url: URL) throws {
        guard let first = slides.first else { throw NothingToDo(reason: "There are no pages to make slides of.") }
        // PowerPoint takes slides between 1 and 56 inches across.
        let scale = min(max(1, 72 / min(first.size.width, first.size.height)), 4032 / max(first.size.width, first.size.height))
        let slideSize = CGSize(width: first.size.width * scale, height: first.size.height * scale)
        let cx = Int(slideSize.width * emuPerPoint), cy = Int(slideSize.height * emuPerPoint)
        let namespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>"
            + "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
            + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
            + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
            + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
            + slides.indices.map { "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined()
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
            + "</Types>")
        zip.add("_rels/.rels", WordDocument.packageRelations(main: "ppt/presentation.xml"))
        zip.add("docProps/core.xml", WordDocument.coreProperties(title: nil))
        zip.add("docProps/app.xml", WordDocument.appProperties)
        zip.add("ppt/presentation.xml", header + "<p:presentation \(namespaces) saveSubsetFonts=\"1\">"
            + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>"
            + slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined()
            + "</p:sldIdLst><p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
            + "<p:defaultTextStyle><a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr></p:defaultTextStyle></p:presentation>")
        zip.add("ppt/_rels/presentation.xml.rels", relations(
            [("rId1", "slideMaster", "slideMasters/slideMaster1.xml")]
                + slides.indices.map { ("rId\($0 + 2)", "slide", "slides/slide\($0 + 1).xml") }
                + [("rId\(slides.count + 2)", "theme", "theme/theme1.xml")]
        ))
        zip.add("ppt/slideMasters/slideMaster1.xml", header + "<p:sldMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>"
            + "<p:spTree>\(emptyTree)</p:spTree></p:cSld>"
            + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>"
            + "<p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", relations([
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml"),
        ]))
        zip.add("ppt/slideLayouts/slideLayout1.xml", header + "<p:sldLayout \(namespaces) type=\"blank\" preserve=\"1\">"
            + "<p:cSld name=\"Blank\"><p:spTree>\(emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relations([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        zip.add("ppt/theme/theme1.xml", header + theme)
        for (index, slide) in slides.enumerated() {
            // The page fills the slide, keeping its shape; what's on it is placed the same way.
            let fit = min(slideSize.width / slide.size.width, slideSize.height / slide.size.height)
            let width = slide.size.width * fit, height = slide.size.height * fit
            let origin = CGPoint(x: (slideSize.width - width) / 2, y: (slideSize.height - height) / 2)
            func place(_ frame: CGRect) -> String {
                "<a:xfrm><a:off x=\"\(Int((origin.x + frame.minX * fit) * emuPerPoint))\" y=\"\(Int((origin.y + frame.minY * fit) * emuPerPoint))\"/>"
                    + "<a:ext cx=\"\(Int(frame.width * fit * emuPerPoint))\" cy=\"\(Int(frame.height * fit * emuPerPoint))\"/></a:xfrm>"
            }
            func picture(id: Int, name: String, relation: String, frame: CGRect) -> String {
                "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
                    + "<p:blipFill><a:blip r:embed=\"\(relation)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
                    + "<p:spPr>\(place(frame))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            }
            let file = "image\(index + 1).\(slide.isJPEG ? "jpg" : "png")"
            zip.add("ppt/media/\(file)", slide.data, compress: false)
            var shapes = picture(id: 2, name: "Page \(index + 1)", relation: "rId2", frame: CGRect(origin: .zero, size: slide.size))
            var slideRelations = [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "image", "../media/\(file)")]
            var id = 3
            for (number, placed) in slide.pictures.enumerated() {
                let name = "image\(index + 1)-\(number + 1).\(placed.isJPEG ? "jpg" : "png")"
                zip.add("ppt/media/\(name)", placed.data, compress: false)
                let relation = "rId\(slideRelations.count + 1)"
                slideRelations.append((relation, "image", "../media/\(name)"))
                shapes += picture(id: id, name: "Picture \(number + 1)", relation: relation, frame: placed.frame)
                id += 1
            }
            for box in slide.texts {
                shapes += textBox(box, id: id, fit: fit, frame: place(box.frame))
                id += 1
            }
            zip.add("ppt/slides/slide\(index + 1).xml", header + "<p:sld \(namespaces)><p:cSld><p:spTree>\(emptyTree)\(shapes)"
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            zip.add("ppt/slides/_rels/slide\(index + 1).xml.rels", relations(slideRelations))
        }
        try zip.write(to: url)
    }

    /// Words that can be edited: each line of the page a paragraph (so the
    /// lines break where they did), in its font, size, color and spacing.
    static func textBox(_ box: TextBox, id: Int, fit: CGFloat, frame: String) -> String {
        let spacing = box.lineSpacing.map { "<a:lnSpc><a:spcPts val=\"\(Int(($0 * Double(fit) * 100).rounded()))\"/></a:lnSpc>" } ?? ""
        let paragraphs = box.lines.map { line in
            let runs = line.runs.merged.map { run -> String in
                var attributes = "lang=\"en-US\" sz=\"\(max(100, Int(((run.size ?? box.size) * Double(fit) * 100).rounded())))\""
                if run.bold || line.bold { attributes += " b=\"1\"" }
                if run.italic { attributes += " i=\"1\"" }
                let color = String((run.color ?? "#000000").dropFirst())
                let font = (run.code ? "Menlo" : box.font).map { "<a:latin typeface=\"\(xmlEscape($0))\"/>" } ?? ""
                return "<a:r><a:rPr \(attributes) dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>\(font)</a:rPr>"
                    + "<a:t>\(xmlEscape(run.text))</a:t></a:r>"
            }.joined()
            return "<a:p><a:pPr algn=\"\(box.alignment)\">\(spacing)</a:pPr>\(runs)</a:p>"
        }.joined()
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr>\(frame)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"
            + "<p:txBody><a:bodyPr wrap=\"none\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"t\"><a:noAutofit/></a:bodyPr>"
            + "<a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
    }

    private static func relations(_ items: [(String, String, String)]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + items.map { "<Relationship Id=\"\($0.0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.1)\" Target=\"\($0.2)\"/>" }.joined()
            + "</Relationships>"
    }

    /// The plainest theme PowerPoint accepts: Office's colors and fonts.
    private static let theme: String = {
        func color(_ name: String, _ value: String) -> String { "<a:\(name)><a:srgbClr val=\"\(value)\"/></a:\(name)>" }
        let colors = color("dk2", "44546A") + color("lt2", "E7E6E6") + color("accent1", "4472C4") + color("accent2", "ED7D31")
            + color("accent3", "A5A5A5") + color("accent4", "FFC000") + color("accent5", "5B9BD5") + color("accent6", "70AD47")
            + color("hlink", "0563C1") + color("folHlink", "954F72")
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        return "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office Theme\"><a:themeElements>"
            + "<a:clrScheme name=\"Office\"><a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>"
            + "<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>\(colors)</a:clrScheme>"
            + "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
            + "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
            + "<a:fmtScheme name=\"Office\"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst>"
            + "<a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
            + "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
            + "<a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme>"
            + "</a:themeElements></a:theme>"
    }()
}
