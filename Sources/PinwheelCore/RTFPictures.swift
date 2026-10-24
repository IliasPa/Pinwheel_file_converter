import Foundation
import ImageIO

/// Pictures in RTF, which macOS's text system neither writes nor reads
/// (it keeps pictures only in RTFD). Word and most others keep them as a
/// PNG or JPEG in a \pict group; here they're swapped for a mark on the
/// way in and out, and the mark for the picture.
enum RTFPictures {
    private static let openBrace = UInt16(UInt8(ascii: "{")), closeBrace = UInt16(UInt8(ascii: "}"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))

    /// Letters only, so RTF keeps it as it is ("…1Here" can't be part of "…10Here").
    static func mark(_ index: Int) -> String { "PinwheelPicture\(index)Here" }

    // MARK: - Writing

    /// A picture as RTF: its pixels, its size on the page in twips (1/20
    /// point), and the bytes as hexadecimal.
    static func group(_ picture: Document.Picture) -> String {
        let properties = CGImageSourceCreateWithData(picture.data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let pixelsWide = properties?[kCGImagePropertyPixelWidth] as? Int ?? Int(picture.width)
        let pixelsHigh = properties?[kCGImagePropertyPixelHeight] as? Int ?? Int(picture.height)
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(picture.data.count * 2 + picture.data.count / 64 + 1)
        for (offset, byte) in picture.data.enumerated() {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
            if offset % 64 == 63 { hex.append(UInt8(ascii: "\n")) }
        }
        return "{\\pict\\\(picture.isJPEG ? "jpegblip" : "pngblip")\\picw\(pixelsWide)\\pich\(pixelsHigh)"
            + "\\picwgoal\(Int((picture.width * 20).rounded()))\\pichgoal\(Int((picture.height * 20).rounded()))\n"
            + String(decoding: hex, as: UTF8.self) + "}"
    }

    // MARK: - Reading

    /// The RTF with each PNG or JPEG picture swapped for a mark (Word's
    /// {\*\shppict…} wrapper too, and its {\nonshppict…} stand-in dropped),
    /// and the pictures in order. Other kinds (Windows metafiles) are left
    /// as they are, for macOS to skip.
    static func lift(_ data: Data) -> (rtf: Data, pictures: [Document.Picture]) {
        // Latin-1 keeps every byte as it is, whatever the RTF's code page.
        guard let text = String(data: data, encoding: .isoLatin1), text.contains("\\pict") else { return (data, []) }
        let characters = Array(text.utf16)
        var output = String.UnicodeScalarView()
        var pictures: [Document.Picture] = []
        var index = 0
        func starts(_ word: String, at position: Int) -> Bool {
            let utf16 = Array(word.utf16)
            return position + utf16.count <= characters.count && Array(characters[position..<position + utf16.count]) == utf16
        }
        while index < characters.count {
            guard characters[index] == openBrace else {
                output.append(UnicodeScalar(characters[index])!)
                index += 1
                continue
            }
            let wrapped = starts("{\\*\\shppict", at: index)
            let stand = starts("{\\nonshppict", at: index)
            guard wrapped || stand || starts("{\\pict", at: index), let end = groupEnd(characters, from: index) else {
                output.append(UnicodeScalar(characters[index])!)
                index += 1
                continue
            }
            let group = String(decoding: characters[index...end], as: UTF16.self)
            if stand {
                index = end + 1  // a copy for old readers
                continue
            }
            if let picture = picture(in: group) {
                output.append(contentsOf: mark(pictures.count).unicodeScalars)
                pictures.append(picture)
            } else {
                output.append(contentsOf: group.unicodeScalars)
            }
            index = end + 1
        }
        return (String(output).data(using: .isoLatin1) ?? data, pictures)
    }

    /// Where the group starting at `start` ("{") closes.
    private static func groupEnd(_ characters: [UInt16], from start: Int) -> Int? {
        var depth = 0, index = start
        while index < characters.count {
            switch characters[index] {
            case backslash: index += 1  // \{ and \} are text
            case openBrace: depth += 1
            case closeBrace:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// The PNG or JPEG in a \pict group, at its size on the page.
    static func picture(in group: String) -> Document.Picture? {
        guard group.contains("\\pngblip") || group.contains("\\jpegblip") else { return nil }
        // The innermost \pict group, without its own inner groups ({\*\blipuid …}).
        guard let pict = group.range(of: "{\\pict") else { return nil }
        var body = String(group[pict.lowerBound...])
        while let inner = body.dropFirst().firstMatch(of: /\{[^{}]*\}/), inner.range.upperBound < body.endIndex {
            body.removeSubrange(inner.range)
        }
        func number(_ word: String) -> Double? {
            body.firstMatch(of: try! Regex("\\\\\(word)(-?\\d+)")).flatMap { Double($0.output[1].substring ?? "") }
        }
        let hex = body.replacing(/\\[a-z]+-?\d* ?/, with: "").filter(\.isHexDigit)
        var data = Data(capacity: hex.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let value = character <= 57 ? character - 48 : (character | 0x20) - 87
            if let first = high {
                data.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        guard var picture = Document.Picture.from(data) else { return nil }
        if let goalWidth = number("picwgoal"), let goalHeight = number("pichgoal"), goalWidth > 0, goalHeight > 0 {
            let scale = (x: (number("picscalex") ?? 100) / 100, y: (number("picscaley") ?? 100) / 100)
            var width = goalWidth / 20 * scale.x, height = goalHeight / 20 * scale.y
            if width > 451 { (width, height) = (451, height * 451 / width) }
            picture.width = width
            picture.height = height
        }
        return picture
    }

    /// The document with each mark swapped for its picture; a paragraph
    /// with words around a mark is split there, and keeps their look.
    static func place(_ pictures: [Document.Picture], in document: Document) -> Document {
        guard !pictures.isEmpty else { return document }
        var result = document
        result.blocks = document.blocks.flatMap { block -> [Document.Block] in
            guard case .paragraph(let runs) = block, runs.text.contains("PinwheelPicture") else { return [block] }
            var blocks: [Document.Block] = []
            var current: [Document.Run] = []
            func finishParagraph() {
                if !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.paragraph(current)) }
                current = []
            }
            for run in runs {
                var rest = run.text
                while let match = rest.firstMatch(of: /PinwheelPicture(\d+)Here/) {
                    var before = run
                    before.text = String(rest[..<match.range.lowerBound])
                    if !before.text.isEmpty { current.append(before) }
                    finishParagraph()
                    if let number = Int(match.1), number < pictures.count { blocks.append(.image(pictures[number])) }
                    rest = String(rest[match.range.upperBound...])
                }
                var after = run
                after.text = rest
                if !rest.isEmpty { current.append(after) }
            }
            finishParagraph()
            return blocks
        }
        return result
    }
}
