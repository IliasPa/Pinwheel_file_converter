import Foundation
import PDFKit

/// When macOS writes a PDF it works out each letter from the font's shapes,
/// and Greek μ often shares its shape with the micro sign µ: the text then
/// said "τεµπέλη" or "Αποτελέσµατα", which looks the same but isn't found
/// when searching for the word. When a micro sign sits inside a Greek
/// word, the file's letter maps (ToUnicode) are put right. Best effort:
/// anything unusual leaves the file as macOS wrote it.
enum PDFTextRepair {
    static func fixGreekMu(in output: URL) {
        // First a quick look at the fonts (reading all the text of a long
        // PDF takes a while): only a µ in them can be a mistaken μ.
        guard let data = try? Data(contentsOf: output, options: .mappedIfSafe), mayShowMicro(data),
              let document = PDFDocument(url: output), let text = document.string, hasGreekMicro(text),
              let repaired = repaired(data) else { return }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".pinwheel-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? repaired.write(to: temporary)) != nil,
              let check = PDFDocument(url: temporary), check.pageCount == document.pageCount,
              let fixed = check.string, !hasGreekMicro(fixed) else { return }
        _ = try? FileManager.default.replaceItemAt(output, withItemAt: temporary)
    }

    /// A letter map that says µ, or a font in Mac Roman or Windows encoding
    /// (where code B5 is µ) that uses that code (a width for it) without a map.
    static func mayShowMicro(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        for match in text.matches(of: /\/ToUnicode (\d+) 0 R/) {
            guard let start = data.range(of: Data("\n\(match.1) 0 obj".utf8)), let map = mapText(data[start.upperBound...]) else { continue }
            if map.range(of: "<00b5>", options: .caseInsensitive) != nil { return true }
        }
        for font in text.matches(of: /<<[^<>]*\/Type \/Font[^<>]*>>/) {
            let dictionary = String(font.0)
            guard !dictionary.contains("/ToUnicode"), dictionary.contains("/MacRomanEncoding") || dictionary.contains("/WinAnsiEncoding"),
                  let first = dictionary.firstMatch(of: /\/FirstChar\s+(\d+)/).flatMap({ Int($0.1) }),
                  let widths = dictionary.firstMatch(of: /\/Widths\s*\[([^\]]*)\]/) else { continue }
            let values = widths.1.split(whereSeparator: \.isWhitespace)
            if (first...(first + values.count - 1)).contains(0xB5), values[0xB5 - first] != "0" { return true }
        }
        return false
    }

    /// The text of the stream that starts in `object` (deflated or not).
    private static func mapText(_ object: Data.SubSequence) -> String? {
        guard let stream = object.range(of: Data("stream".utf8)) else { return nil }
        let head = String(decoding: object[..<stream.lowerBound].prefix(400), as: UTF8.self)
        guard let length = head.firstMatch(of: /\/Length (\d+)/).flatMap({ Int($0.1) }) else { return nil }
        var body = stream.upperBound
        if object[body] == 0x0D { body += 1 }
        if object[body] == 0x0A { body += 1 }
        guard body + length <= object.endIndex else { return nil }
        let bytes = Data(object[body..<(body + length)])
        guard head.contains("/FlateDecode") else { return String(decoding: bytes, as: UTF8.self) }
        return (try? (Data(bytes.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A micro sign next to a Greek letter: a μ with the wrong code.
    static func hasGreekMicro(_ text: String) -> Bool {
        text.contains(/\p{Script=Greek}\u{00B5}|\u{00B5}\p{Script=Greek}/)
    }

    /// The file with µ mapped to μ in its letter maps, or nil when it isn't
    /// laid out as expected (one plain cross-reference table, direct lengths).
    static func repaired(_ data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("/ObjStm"), !text.contains("/XRef"), !text.contains("/Prev"),
              text.components(separatedBy: "startxref").count == 2,
              let startRange = data.range(of: Data("startxref".utf8), options: .backwards) else { return nil }
        let afterStart = String(decoding: data[startRange.upperBound...], as: UTF8.self)
        guard let xrefOffset = Int(afterStart.split(whereSeparator: \.isWhitespace).first ?? ""),
              xrefOffset < data.count else { return nil }

        // The cross-reference table: where each object starts.
        let table = String(decoding: data[(data.startIndex + xrefOffset)...], as: UTF8.self)
        guard table.hasPrefix("xref"), let trailerAt = table.range(of: "trailer") else { return nil }
        var offsets: [(number: Int, offset: Int)] = []
        var lines = table[..<trailerAt.lowerBound].split(whereSeparator: \.isNewline).dropFirst().makeIterator()
        while let header = lines.next() {
            let parts = header.split(separator: " ")
            guard parts.count == 2, let first = Int(parts[0]), let count = Int(parts[1]) else { return nil }
            for number in first..<(first + count) {
                guard let entry = lines.next() else { return nil }
                let fields = entry.split(separator: " ")
                guard fields.count >= 3, let offset = Int(fields[0]) else { return nil }
                // macOS lists some unused numbers as "in use" at 0: they're free.
                if fields[2].hasPrefix("n"), offset > 0 { offsets.append((number, offset)) }
            }
        }
        let trailer = table[trailerAt.lowerBound...].components(separatedBy: "startxref")[0]
        let maps = Set(text.matches(of: /\/ToUnicode (\d+) 0 R/).compactMap { Int($0.1) })
        guard !offsets.isEmpty else { return nil }

        // The objects in file order, the letter maps put right; fonts in an
        // old encoding without a map get one (as new objects at the end).
        let sorted = offsets.sorted { $0.offset < $1.offset }
        var result = Data(data[data.startIndex..<(data.startIndex + sorted[0].offset)])
        var newOffsets: [Int: Int] = [:]
        var added: [Data] = []
        var size = (offsets.map(\.number).max() ?? 0) + 1
        var changed = false
        for (index, object) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].offset : xrefOffset
            guard object.offset < end, end <= data.count else { return nil }
            var bytes = Data(data[(data.startIndex + object.offset)..<(data.startIndex + end)])
            if maps.contains(object.number), let fixed = fixedMap(bytes) {
                bytes = fixed
                changed = true
            } else if let (font, map) = mappedFont(bytes, mapNumber: size) {
                bytes = font
                added.append(Data("\(size) 0 obj\n".utf8) + map + Data("\nendobj\n".utf8))
                size += 1
                changed = true
            }
            newOffsets[object.number] = result.count
            result.append(bytes)
        }
        guard changed else { return nil }
        let firstAdded = size - added.count
        for (number, object) in added.enumerated() {
            newOffsets[firstAdded + number] = result.count
            result.append(object)
        }
        let xrefAt = result.count
        var xref = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1..<size {
            xref += newOffsets[number].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 65535 f \n"
        }
        result.append(Data(xref.utf8))
        let newTrailer = trailer.replacing(/\/Size\s+\d+/, with: "/Size \(size)")
        result.append(Data((newTrailer + "startxref\n\(xrefAt)\n%%EOF\n").utf8))
        return result
    }

    /// A simple font in Mac Roman or Windows encoding with no letter map,
    /// whose code B5 (µ there) is used: the font with a map added (every
    /// code as the encoding has it, B5 as μ), and the map's stream.
    private static func mappedFont(_ object: Data, mapNumber: Int) -> (Data, Data)? {
        let text = String(decoding: object.prefix(4096), as: UTF8.self)
        guard text.contains("/Type /Font"), !text.contains("/ToUnicode"), !text.contains("stream"),
              let encoding = text.firstMatch(of: /\/Encoding\s*\/(MacRomanEncoding|WinAnsiEncoding)/),
              let first = text.firstMatch(of: /\/FirstChar\s+(\d+)/).flatMap({ Int($0.1) }),
              let last = text.firstMatch(of: /\/LastChar\s+(\d+)/).flatMap({ Int($0.1) }),
              first <= 0xB5, last >= 0xB5, last <= 255,
              let open = object.range(of: Data("<<".utf8)) else { return nil }
        let cfEncoding = encoding.1 == "MacRomanEncoding" ? CFStringBuiltInEncodings.macRoman : .windowsLatin1
        var entries: [String] = []
        for code in first...last {
            let letter = code == 0xB5 ? "\u{03BC}" : CFStringCreateWithBytes(nil, [UInt8(code)], 1, cfEncoding.rawValue, false).map { $0 as String } ?? ""
            guard let scalar = letter.unicodeScalars.first, scalar.value <= 0xFFFF else { continue }
            entries.append(String(format: "<%02X> <%04X>", code, scalar.value))
        }
        var map = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
            + "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
        for start in stride(from: 0, to: entries.count, by: 100) {
            let chunk = entries[start..<min(start + 100, entries.count)]
            map += "\(chunk.count) beginbfchar\n" + chunk.joined(separator: "\n") + "\nendbfchar\n"
        }
        map += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        let stream = Data("<< /Length \(map.utf8.count) >>\nstream\n".utf8) + Data(map.utf8) + Data("\nendstream".utf8)
        var font = object
        font.replaceSubrange(open, with: Data("<< /ToUnicode \(mapNumber) 0 R ".utf8))
        return (font, stream)
    }

    /// One letter-map object with µ (00B5) mapped to μ (03BC), or nil when
    /// there's nothing to change or it can't be read.
    private static func fixedMap(_ object: Data) -> Data? {
        guard let streamStart = object.range(of: Data("stream".utf8)),
              let dictionaryEnd = object[..<streamStart.lowerBound].range(of: Data(">>".utf8), options: .backwards) else { return nil }
        let head = String(decoding: object[..<streamStart.lowerBound], as: UTF8.self)
        // A length given directly (not "/Length 12 0 R", stored elsewhere).
        guard head.contains("/FlateDecode"), let lengthMatch = head.firstMatch(of: /\/Length (\d+)(\s+\d+\s+R)?/),
              lengthMatch.2 == nil, let length = Int(lengthMatch.1) else { return nil }
        var bodyStart = streamStart.upperBound
        if object[bodyStart] == 0x0D { bodyStart += 1 }
        if object[bodyStart] == 0x0A { bodyStart += 1 }
        guard bodyStart + length <= object.endIndex, length > 6 else { return nil }
        let compressed = object[bodyStart..<(bodyStart + length)]
        guard let plain = try? (Data(compressed.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let map = String(decoding: plain, as: UTF8.self)
        let fixed = map.replacing(/<(00[bB]5)>/, with: "<03bc>")
        guard fixed != map, let deflated = try? (Data(fixed.utf8) as NSData).compressed(using: .zlib) as Data else { return nil }
        var stream = Data([0x78, 0x9C])
        stream.append(deflated)
        var adler = adler32(Data(fixed.utf8)).bigEndian
        stream.append(Data(bytes: &adler, count: 4))

        let dictionary = String(decoding: object[..<dictionaryEnd.upperBound], as: UTF8.self)
            .replacingOccurrences(of: "/Length \(length)", with: "/Length \(stream.count)")
        var result = Data(dictionary.utf8)
        result.append(Data("\nstream\n".utf8))
        result.append(stream)
        result.append(Data("\nendstream\nendobj\n".utf8))
        return result
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }
}
