import Compression
import Foundation

/// The ZIP files inside documents (Word, Excel, PowerPoint, EPUB, OpenDocument):
/// small and made here, so the order of the files and how each is stored
/// can be exact (an EPUB starts with "mimetype", stored as it is).
struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private(set) var data = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ text: String, compress: Bool = true) {
        add(name, Data(text.utf8), compress: compress)
    }

    mutating func add(_ name: String, _ content: Data, compress: Bool = true) {
        let squeezed = compress ? Deflate.compress(content) : nil
        let stored = squeezed ?? content
        let entry = Entry(
            name: Data(name.utf8), crc: CRC32.of(content), compressedSize: UInt32(stored.count), size: UInt32(content.count),
            method: squeezed == nil ? 0 : 8, offset: UInt32(data.count)
        )
        data.append(le32(0x0403_4b50))
        data.append(le16(20))  // version needed
        data.append(le16(0x0800))  // names are UTF-8
        data.append(le16(entry.method))
        data.append(le16(Self.time))
        data.append(le16(Self.date))
        data.append(le32(entry.crc))
        data.append(le32(entry.compressedSize))
        data.append(le32(entry.size))
        data.append(le16(UInt16(entry.name.count)))
        data.append(le16(0))
        data.append(entry.name)
        data.append(stored)
        entries.append(entry)
    }

    /// The archive, with its table of contents at the end.
    func finished() -> Data {
        var result = data
        let start = UInt32(result.count)
        for entry in entries {
            result.append(le32(0x0201_4b50))
            result.append(le16(20))  // made by
            result.append(le16(20))  // needed
            result.append(le16(0x0800))
            result.append(le16(entry.method))
            result.append(le16(Self.time))
            result.append(le16(Self.date))
            result.append(le32(entry.crc))
            result.append(le32(entry.compressedSize))
            result.append(le32(entry.size))
            result.append(le16(UInt16(entry.name.count)))
            result.append(le16(0))  // extra
            result.append(le16(0))  // comment
            result.append(le16(0))  // disk
            result.append(le16(0))  // internal attributes
            result.append(le32(0))  // external attributes
            result.append(le32(entry.offset))
            result.append(entry.name)
        }
        let size = UInt32(result.count) - start
        result.append(le32(0x0605_4b50))
        result.append(le16(0))
        result.append(le16(0))
        result.append(le16(UInt16(entries.count)))
        result.append(le16(UInt16(entries.count)))
        result.append(le32(size))
        result.append(le32(start))
        result.append(le16(0))
        return result
    }

    func write(to url: URL) throws {
        do {
            try finished().write(to: url)
        } catch {
            throw ConversionError.cannotWrite(url.lastPathComponent)
        }
    }

    /// Times are written as now, in the file's own (DOS) format.
    private static let (time, date): (UInt16, UInt16) = {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let date = UInt16(max((parts.year ?? 1980) - 1980, 0) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, date)
    }()
}

/// Reads the files inside a ZIP (only stored and deflated ones: what
/// documents use).
struct ZipReader {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let offset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]
    /// The names in the order they're listed.
    private(set) var names: [String] = []

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        try self.init(data: data, name: url.lastPathComponent)
    }

    init(data: Data, name: String = "The file") throws {
        self.data = data
        // The end record is within the last 64 KB (it may have a comment).
        var end: Int?
        var index = data.count - 22
        while index >= max(0, data.count - 65_557) {
            if data.le32(at: index) == 0x0605_4b50 { end = index; break }
            index -= 1
        }
        guard let end else { throw ConversionError.unreadable(name) }
        let count = Int(data.le16(at: end + 10))
        var position = Int(data.le32(at: end + 16))
        for _ in 0..<count {
            guard position + 46 <= data.count, data.le32(at: position) == 0x0201_4b50 else { throw ConversionError.unreadable(name) }
            let nameLength = Int(data.le16(at: position + 28))
            let extraLength = Int(data.le16(at: position + 30))
            let commentLength = Int(data.le16(at: position + 32))
            guard position + 46 + nameLength <= data.count else { throw ConversionError.unreadable(name) }
            let entryName = String(decoding: data[(data.startIndex + position + 46)..<(data.startIndex + position + 46 + nameLength)], as: UTF8.self)
            entries[entryName] = Entry(
                method: data.le16(at: position + 10), compressedSize: Int(data.le32(at: position + 20)),
                size: Int(data.le32(at: position + 24)), offset: Int(data.le32(at: position + 42))
            )
            names.append(entryName)
            position += 46 + nameLength + extraLength + commentLength
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// A file's contents, or nil when there's no such file (or it can't be read).
    func data(_ name: String) -> Data? {
        guard let entry = entries[name], entry.offset + 30 <= data.count,
              data.le32(at: entry.offset) == 0x0403_4b50 else { return nil }
        let start = entry.offset + 30 + Int(data.le16(at: entry.offset + 26)) + Int(data.le16(at: entry.offset + 28))
        guard start + entry.compressedSize <= data.count else { return nil }
        let stored = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0: return Data(stored)
        case 8: return Deflate.decompress(Data(stored), size: entry.size)
        default: return nil
        }
    }

    func text(_ name: String) -> String? {
        data(name).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Raw DEFLATE (what ZIP uses), with Apple's Compression.
enum Deflate {
    /// nil when squeezing doesn't help (then the file is stored as it is).
    static func compress(_ input: Data) -> Data? {
        guard input.count > 64 else { return nil }
        let capacity = input.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { source in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < input.count else { return nil }
        return output.prefix(written)
    }

    static func decompress(_ input: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { source in
                compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == size ? output : nil
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func of(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

private extension Data {
    func le16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
