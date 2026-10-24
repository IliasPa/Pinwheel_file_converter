// Makes the bench's hard PDFs: tables, two columns, scans, mixed page
// sizes and turns, passwords, forms, notes, slides, many pages, damage.
// Usage: swift scripts/bench/make-pdfs.swift <folder>
import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("pdf")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

func font(_ size: CGFloat, bold: Bool = false, name: String = "Helvetica") -> NSFont {
    NSFont(name: bold ? "\(name)-Bold" : name, size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
}

func text(_ string: String, _ size: CGFloat, bold: Bool = false, color: NSColor = .black, align: NSTextAlignment = .left, name: String = "Helvetica") -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineSpacing = size * 0.2
    return NSAttributedString(string: string, attributes: [.font: font(size, bold: bold, name: name), .foregroundColor: color, .paragraphStyle: paragraph])
}

/// Draws as much of `string` from `start` as fits in `rect`; returns where it stopped.
@discardableResult
func draw(_ string: NSAttributedString, in rect: CGRect, _ ctx: CGContext, from start: Int = 0) -> Int {
    let setter = CTFramesetterCreateWithAttributedString(string)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    let visible = CTFrameGetVisibleStringRange(frame)
    return visible.location + visible.length
}

func line(_ string: String, at point: CGPoint, _ size: CGFloat, _ ctx: CGContext, bold: Bool = false, color: NSColor = .black) {
    ctx.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(text(string, size, bold: bold, color: color)), ctx)
}

func pdf(_ name: String, info: [CFString: Any] = [:], pages: [(CGRect, (CGContext) -> Void)]) {
    var box = pages.first?.0 ?? a4
    var auxiliary = info
    if auxiliary[kCGPDFContextTitle] == nil { auxiliary[kCGPDFContextTitle] = name }
    let ctx = CGContext(out.appendingPathComponent(name) as CFURL, mediaBox: &box, auxiliary as CFDictionary)!
    for (rect, drawPage) in pages {
        var media = rect
        let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
        ctx.beginPDFPage(pageInfo)
        drawPage(ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func photo(_ width: Int, _ height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let sky = CGGradient(colorsSpace: nil, colors: [NSColor.systemBlue.cgColor, NSColor.systemOrange.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: .zero, options: [])
    ctx.setFillColor(NSColor.systemGreen.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 3))
    ctx.setFillColor(NSColor.systemYellow.cgColor)
    ctx.fillEllipse(in: CGRect(x: width * 6 / 10, y: height * 6 / 10, width: width / 5, height: width / 5))
    return ctx.makeImage()!
}

let greek = "Η γρήγορη καφέ αλεπού πηδά πάνω από τον τεμπέλη σκύλο. Αυτό το κείμενο δοκιμάζει τα ελληνικά με τόνους: άέήίόύώ ϊϋ ΐΰ. "
let english = "The quick brown fox jumps over the lazy dog, and this sentence keeps going so that paragraphs wrap over several lines in each column. "
let body = String(repeating: english + greek, count: 9)

// 1. An invoice: a logo, a ruled table across two pages (the header row
// repeated), European numbers, page numbers.
do {
    let items = (1...38).map { index -> [String] in
        let price = Double(index) * 13.75 + 0.5
        return ["\(index)", index % 3 == 0 ? "Υπηρεσία συντήρησης \(index)" : "Product item \(index)", "\(index % 4 + 1)",
                String(format: "%.2f", price).replacingOccurrences(of: ".", with: ",") + " €",
                index == 7 ? "(25,00) €" : String(format: "%.2f", price * Double(index % 4 + 1)).replacingOccurrences(of: ".", with: ",") + " €"]
    }
    let widths: [CGFloat] = [40, 230, 50, 90, 95]
    func table(_ rows: [[String]], top: CGFloat, _ ctx: CGContext) {
        let header = ["#", "Description / Περιγραφή", "Qty", "Price", "Total"]
        let all = [header] + rows
        let left: CGFloat = 45, height: CGFloat = 20
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(0.7)
        for (r, row) in all.enumerated() {
            let y = top - CGFloat(r + 1) * height
            if r == 0 {
                ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
                ctx.fill(CGRect(x: left, y: y, width: widths.reduce(0, +), height: height))
            }
            var x = left
            for (c, cell) in row.enumerated() {
                let attributed = text(cell, 9, bold: r == 0, align: c >= 2 ? .right : .left)
                draw(attributed, in: CGRect(x: x + 4, y: y + 3, width: widths[c] - 8, height: height - 4), ctx)
                x += widths[c]
            }
        }
        // The rules: every row and column.
        let bottom = top - CGFloat(all.count) * height
        for r in 0...all.count {
            ctx.move(to: CGPoint(x: left, y: top - CGFloat(r) * height))
            ctx.addLine(to: CGPoint(x: left + widths.reduce(0, +), y: top - CGFloat(r) * height))
        }
        var x = left
        for width in [0] + widths {
            x += width
            ctx.move(to: CGPoint(x: x, y: top))
            ctx.addLine(to: CGPoint(x: x, y: bottom))
        }
        ctx.strokePath()
    }
    pdf("invoice tables.pdf", info: [kCGPDFContextAuthor: "Bench Ltd", kCGPDFContextSubject: "Τιμολόγιο"], pages: [
        (a4, { ctx in
            ctx.draw(photo(240, 120), in: CGRect(x: 45, y: 742, width: 120, height: 60))
            line("INVOICE 2026-117", at: CGPoint(x: 360, y: 780), 18, ctx, bold: true)
            line("Bench Ltd · Οδός Ερμού 12, Αθήνα", at: CGPoint(x: 360, y: 760), 9, ctx)
            table(Array(items.prefix(28)), top: 720, ctx)
            line("Page 1 of 2", at: CGPoint(x: 270, y: 30), 8, ctx)
        }),
        (a4, { ctx in
            table(Array(items.dropFirst(28)), top: 800, ctx)
            line("Grand total: 12.345,67 €", at: CGPoint(x: 380, y: 540), 12, ctx, bold: true)
            line("Page 2 of 2", at: CGPoint(x: 270, y: 30), 8, ctx)
        }),
    ])
}

// 2. An article: a title across the page, two columns, a picture in the
// second, a footnote, a running header and page numbers.
do {
    let story = NSMutableAttributedString()
    story.append(text("Introduction · Εισαγωγή\n", 14, bold: true, name: "Times New Roman"))
    story.append(text(body + "\n", 10.5, name: "Times New Roman"))
    story.append(text("Results · Αποτελέσματα\n", 14, bold: true, name: "Times New Roman"))
    story.append(text(body + "\n", 10.5, name: "Times New Roman"))
    var position = 0
    var pages: [(CGRect, (CGContext) -> Void)] = []
    for number in 1...2 {
        pages.append((a4, { ctx in
            line("Bench Journal · Vol. 7", at: CGPoint(x: 50, y: 810), 8, ctx, color: .darkGray)
            if number == 1 {
                draw(text("Two Columns and a Picture: Δύο στήλες", 22, bold: true, align: .center, name: "Times New Roman"), in: CGRect(x: 50, y: 720, width: 495, height: 70), ctx)
            }
            let top: CGFloat = number == 1 ? 715 : 790
            position = draw(story, in: CGRect(x: 50, y: 80, width: 235, height: top - 80), ctx, from: position)
            if number == 1 {
                ctx.draw(photo(470, 300), in: CGRect(x: 310, y: top - 150, width: 235, height: 150))
                position = draw(story, in: CGRect(x: 310, y: 80, width: 235, height: top - 245), ctx, from: position)
                line("¹ A footnote at the bottom of the page.", at: CGPoint(x: 50, y: 60), 7, ctx)
            } else {
                position = draw(story, in: CGRect(x: 310, y: 80, width: 235, height: top - 80), ctx, from: position)
            }
            line("\(number)", at: CGPoint(x: 294, y: 30), 9, ctx)
        }))
    }
    pdf("two column article.pdf", info: [kCGPDFContextAuthor: "Μαρία Παπαδοπούλου"], pages: pages)
}

// 3. Pages of every shape: A4, Letter across, a business card, A3; one
// page turned with /Rotate (added with PDFKit below).
do {
    let shapes: [(String, CGRect)] = [
        ("A4 portrait", a4), ("US Letter landscape", CGRect(x: 0, y: 0, width: 792, height: 612)),
        ("Turned page", a4), ("Card", CGRect(x: 0, y: 0, width: 252, height: 144)), ("A3", CGRect(x: 0, y: 0, width: 842, height: 1191)),
    ]
    pdf("mixed sizes.pdf", pages: shapes.map { name, rect in
        (rect, { ctx in
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(4)
            ctx.stroke(rect.insetBy(dx: 10, dy: 10))
            draw(text("\(name) — \(Int(rect.width))×\(Int(rect.height)) pt. " + english, rect.width < 300 ? 10 : 16), in: rect.insetBy(dx: 24, dy: 24), ctx)
        })
    })
    let document = PDFDocument(url: out.appendingPathComponent("mixed sizes.pdf"))!
    document.page(at: 2)!.rotation = 90
    document.write(to: out.appendingPathComponent("mixed sizes.pdf"))
}

// 4. A scan: pictures of pages, slightly crooked, with grain; no text.
do {
    func scanned(_ lines: [String]) -> CGImage {
        let width = 1654, height = 2339  // A4 at 200 dpi
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: 1.2 * .pi / 180)
        ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        for (index, string) in lines.enumerated() {
            ctx.textPosition = CGPoint(x: 160, y: 2100 - index * 90)
            CTLineDraw(CTLineCreateWithAttributedString(text(string, 44, name: "Times New Roman")), ctx)
        }
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for i in stride(from: 0, to: ctx.bytesPerRow * height, by: 3) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            data[i] = UInt8(clamping: Int(data[i]) + Int(seed >> 29) - 4)
        }
        return ctx.makeImage()!
    }
    let first = scanned(["SCANNED LETTER", "Dear customer,", "Your order number 4471 has shipped.", "The total was 89,90 euros.", "Kind regards, the shop"])
    let second = scanned(["ΣΑΡΩΜΕΝΗ ΣΕΛΙΔΑ", "Αγαπητέ πελάτη,", "Η παραγγελία σας στάλθηκε σήμερα.", "Ευχαριστούμε πολύ!"])
    pdf("scanned no text.pdf", pages: [first, second].map { image in
        (a4, { ctx in ctx.draw(image, in: a4) })
    })
}

// 5. Slides: 16:9 pages with colored backgrounds, big titles, bullets, a photo, a chart.
do {
    let wide = CGRect(x: 0, y: 0, width: 960, height: 540)
    pdf("slides 16x9.pdf", pages: [
        (wide, { ctx in
            ctx.setFillColor(NSColor(red: 0.08, green: 0.15, blue: 0.35, alpha: 1).cgColor)
            ctx.fill(wide)
            draw(text("Quarterly Review · Τριμηνιαία", 48, bold: true, color: .white, align: .center), in: CGRect(x: 60, y: 250, width: 840, height: 120), ctx)
            draw(text("October 2026", 24, color: NSColor(white: 0.85, alpha: 1), align: .center), in: CGRect(x: 60, y: 190, width: 840, height: 50), ctx)
        }),
        (wide, { ctx in
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(wide)
            line("What went well", at: CGPoint(x: 60, y: 450), 36, ctx, bold: true)
            for (index, bullet) in ["• Sales grew 12%", "• Δύο νέοι πελάτες", "• The app shipped on time"].enumerated() {
                line(bullet, at: CGPoint(x: 70, y: 370 - CGFloat(index) * 50), 26, ctx)
            }
            ctx.draw(photo(720, 540), in: CGRect(x: 560, y: 120, width: 340, height: 255))
        }),
        (wide, { ctx in
            ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
            ctx.fill(wide)
            line("Numbers", at: CGPoint(x: 60, y: 460), 36, ctx, bold: true)
            for (index, value) in [120.0, 180, 150, 240].enumerated() {
                ctx.setFillColor(NSColor.systemTeal.cgColor)
                ctx.fill(CGRect(x: 120 + CGFloat(index) * 170, y: 80, width: 100, height: value * 1.4))
                line("Q\(index + 1)", at: CGPoint(x: 155 + CGFloat(index) * 170, y: 55), 18, ctx)
            }
        }),
    ])
}

// 6. Many pages; 7. only drawings; 8. damaged.
do {
    pdf("300 pages.pdf", pages: (1...300).map { number in
        (a4, { ctx in
            line("Page \(number) heading", at: CGPoint(x: 60, y: 770), 20, ctx, bold: true)
            draw(text(String(repeating: english, count: 6), 11), in: CGRect(x: 60, y: 400, width: 475, height: 340), ctx)
            line("\(number)", at: CGPoint(x: 290, y: 30), 9, ctx)
        })
    })
    pdf("only drawings.pdf", pages: [(a4, { ctx in
        for index in 0..<40 {
            ctx.setStrokeColor(NSColor(hue: CGFloat(index) / 40, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: 100 + index * 5, y: 200 + index * 8, width: 300, height: 300))
        }
    })])
    let whole = try Data(contentsOf: out.appendingPathComponent("invoice tables.pdf"))
    try whole.prefix(whole.count / 2).write(to: out.appendingPathComponent("damaged cut short.pdf"))
}

// 9. Passwords: one to open ("secret"), one only stopping printing and copying.
do {
    let page: [(CGRect, (CGContext) -> Void)] = [(a4, { ctx in
        draw(text("Locked document · Κλειδωμένο\n" + english, 16), in: a4.insetBy(dx: 60, dy: 80), ctx)
    })]
    pdf("password secret.pdf", info: [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"], pages: page)
    pdf("no copying allowed.pdf", info: [kCGPDFContextOwnerPassword: "owner", kCGPDFContextAllowsCopying: false, kCGPDFContextAllowsPrinting: false], pages: page)
}

// 10. A form to fill in, and notes on a page.
do {
    pdf("form and notes.pdf", pages: [(a4, { ctx in
        line("Application form · Αίτηση", at: CGPoint(x: 60, y: 770), 22, ctx, bold: true)
        line("Name:", at: CGPoint(x: 60, y: 700), 12, ctx)
        line("Agree:", at: CGPoint(x: 60, y: 650), 12, ctx)
        draw(text("Highlighted sentence here. " + english, 12), in: CGRect(x: 60, y: 450, width: 475, height: 150), ctx)
    })])
    let url = out.appendingPathComponent("form and notes.pdf")
    let document = PDFDocument(url: url)!
    let page = document.page(at: 0)!
    let name = PDFAnnotation(bounds: CGRect(x: 120, y: 692, width: 250, height: 22), forType: .widget, withProperties: nil)
    name.widgetFieldType = .text
    name.fieldName = "name"
    name.widgetStringValue = "Ηλίας"
    page.addAnnotation(name)
    let agree = PDFAnnotation(bounds: CGRect(x: 120, y: 645, width: 18, height: 18), forType: .widget, withProperties: nil)
    agree.widgetFieldType = .button
    agree.widgetControlType = .checkBoxControl
    agree.fieldName = "agree"
    agree.buttonWidgetState = .onState
    page.addAnnotation(agree)
    let highlight = PDFAnnotation(bounds: CGRect(x: 58, y: 580, width: 200, height: 18), forType: .highlight, withProperties: nil)
    highlight.color = .yellow
    page.addAnnotation(highlight)
    let note = PDFAnnotation(bounds: CGRect(x: 500, y: 760, width: 24, height: 24), forType: .text, withProperties: nil)
    note.contents = "A sticky note · Σημείωση"
    page.addAnnotation(note)
    let free = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 220, height: 40), forType: .freeText, withProperties: nil)
    free.contents = "Typed on top"
    free.font = NSFont.systemFont(ofSize: 14)
    page.addAnnotation(free)
    document.write(to: url)
}
print("pdfs done")
