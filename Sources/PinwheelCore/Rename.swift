import CoreServices
import Foundation
import ImageIO

/// A file name in two parts: "Holiday 01" and "jpg" (no dot). Folders and
/// files without an extension have an empty `ext`.
public struct FileName: Sendable, Equatable, Hashable {
    public var base: String
    public var ext: String

    public init(base: String, ext: String) {
        self.base = base
        self.ext = ext
    }

    public init(_ url: URL) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let name = url.lastPathComponent
        let ext = isFolder ? "" : (name as NSString).pathExtension
        self.init(base: ext.isEmpty ? name : String(name.dropLast(ext.count + 1)), ext: ext)
    }

    public var full: String { ext.isEmpty ? base : "\(base).\(ext)" }
}

/// What a rename rule may want to know about a file besides its name.
public struct RenameFileInfo: Sendable, Equatable {
    public var created: Date?
    public var modified: Date?
    /// When the photo or video was taken (falls back to `created`).
    public var taken: Date?
    public var width: Int?
    public var height: Int?
    public var camera: String?
    public var duration: Double?
    public var size: Int64?
    public var folder: String

    public init(created: Date? = nil, modified: Date? = nil, taken: Date? = nil, width: Int? = nil, height: Int? = nil,
                camera: String? = nil, duration: Double? = nil, size: Int64? = nil, folder: String = "") {
        self.created = created
        self.modified = modified
        self.taken = taken
        self.width = width
        self.height = height
        self.camera = camera
        self.duration = duration
        self.size = size
        self.folder = folder
    }

    /// Reads the dates, size and (for photos and videos) when they were
    /// taken, their size in pixels and the camera. Spotlight knows most of
    /// it; the picture's own EXIF fills in when Spotlight doesn't.
    public static func read(_ url: URL) -> RenameFileInfo {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        var info = RenameFileInfo(
            created: values?.creationDate, modified: values?.contentModificationDate,
            size: values?.fileSize.map(Int64.init), folder: url.deletingLastPathComponent().lastPathComponent
        )
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            func value<T>(_ key: CFString) -> T? { MDItemCopyAttribute(item, key) as? T }
            info.taken = value(kMDItemContentCreationDate)
            info.width = value(kMDItemPixelWidth)
            info.height = value(kMDItemPixelHeight)
            info.camera = value(kMDItemAcquisitionModel)
            info.duration = value(kMDItemDurationSeconds)
        }
        if info.width == nil || info.camera == nil || info.taken == nil,
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(src) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] {
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if info.width == nil, let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
                (info.width, info.height) = turned ? (height, width) : (width, height)
            }
            if info.camera == nil { info.camera = tiff[kCGImagePropertyTIFFModel] as? String }
            if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = exifDate.date(from: text) {
                info.taken = date
            }
        }
        if info.taken == nil { info.taken = info.created }
        return info
    }

    private static let exifDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

/// One step of a batch rename. Every rule has the same settings; each kind
/// uses the ones it needs (that keeps rules easy to store and to edit).
public struct RenameRule: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case replace, remove, removeKinds, insert, changeCase, separators, numbering, pattern, date
        case transliterate, padNumbers, swap, ext

        public var title: String {
            switch self {
            case .replace: "Replace Text"
            case .remove: "Remove Characters"
            case .removeKinds: "Remove Kinds of Text"
            case .insert: "Add Text"
            case .changeCase: "Change Case"
            case .separators: "Spaces and Separators"
            case .numbering: "Numbering"
            case .pattern: "New Name from a Pattern"
            case .date: "Add a Date"
            case .transliterate: "Greek to Latin (Greeklish)"
            case .padNumbers: "Pad Numbers with Zeros"
            case .swap: "Swap Around a Separator"
            case .ext: "Extension"
            }
        }

        public var symbolName: String {
            switch self {
            case .replace: "arrow.left.arrow.right"
            case .remove: "delete.left"
            case .removeKinds: "eraser"
            case .insert: "text.insert"
            case .changeCase: "textformat"
            case .separators: "space"
            case .numbering: "number"
            case .pattern: "curlybraces"
            case .date: "calendar"
            case .transliterate: "character.book.closed"
            case .padNumbers: "00.square"
            case .swap: "arrow.triangle.swap"
            case .ext: "doc.badge.gearshape"
            }
        }
    }

    public enum Occurrence: String, CaseIterable, Codable, Sendable {
        case all, first, last
        public var title: String { rawValue.capitalized }
    }

    public enum RemovePart: String, CaseIterable, Codable, Sendable {
        case first, last, range, keepFirst, keepLast, upTo, from, between

        public var title: String {
            switch self {
            case .first: "The first characters"
            case .last: "The last characters"
            case .range: "Characters from a position"
            case .keepFirst: "All but the first characters"
            case .keepLast: "All but the last characters"
            case .upTo: "Everything up to some text"
            case .from: "Everything from some text on"
            case .between: "Text between two marks"
            }
        }

        public var usesCount: Bool { [.first, .last, .range, .keepFirst, .keepLast].contains(self) }
        public var usesText: Bool { [.upTo, .from, .between].contains(self) }
    }

    public enum RemoveKind: String, CaseIterable, Codable, Sendable {
        case digits, spaces, special, brackets, emoji, accents, copyMarks, latin, greek

        public var title: String {
            switch self {
            case .digits: "Digits (0–9)"
            case .spaces: "Spaces"
            case .special: "Special characters (keeps - and _)"
            case .brackets: "Text in brackets ( ) [ ] { }"
            case .emoji: "Emoji"
            case .accents: "Accents (é → e, ά → α)"
            case .copyMarks: "“copy” and “(1)” added by Finder"
            case .latin: "Latin letters (a–z)"
            case .greek: "Greek letters"
            }
        }

        /// For summaries: "Remove digits, emoji".
        public var shortTitle: String {
            switch self {
            case .digits: "digits"
            case .spaces: "spaces"
            case .special: "special characters"
            case .brackets: "brackets"
            case .emoji: "emoji"
            case .accents: "accents"
            case .copyMarks: "copy marks"
            case .latin: "Latin letters"
            case .greek: "Greek letters"
            }
        }
    }

    public enum InsertPlace: String, CaseIterable, Codable, Sendable {
        case start, end, position, positionFromEnd, before, after

        public var title: String {
            switch self {
            case .start: "At the start"
            case .end: "At the end"
            case .position: "After a number of characters"
            case .positionFromEnd: "Before the last characters"
            case .before: "Before some text"
            case .after: "After some text"
            }
        }
    }

    public enum CaseStyle: String, CaseIterable, Codable, Sendable {
        case lower, upper, title, sentence, camel, pascal, snake, kebab

        public var title: String {
            switch self {
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            case .title: "Title Case"
            case .sentence: "Sentence case"
            case .camel: "camelCase"
            case .pascal: "PascalCase"
            case .snake: "snake_case"
            case .kebab: "kebab-case"
            }
        }
    }

    public enum SeparatorStyle: String, CaseIterable, Codable, Sendable {
        case spacesToUnderscores, spacesToDashes, spacesToDots, removeSpaces, underscoresToSpaces, dashesToSpaces, dotsToSpaces, tidy

        public var title: String {
            switch self {
            case .spacesToUnderscores: "Spaces → _"
            case .spacesToDashes: "Spaces → -"
            case .spacesToDots: "Spaces → ."
            case .removeSpaces: "Remove spaces"
            case .underscoresToSpaces: "_ → spaces"
            case .dashesToSpaces: "- → spaces"
            case .dotsToSpaces: ". → spaces"
            case .tidy: "Tidy: trim, no double spaces"
            }
        }
    }

    public enum NumberStyle: String, CaseIterable, Codable, Sendable {
        case arabic, lowerLetters, upperLetters, roman

        public var title: String {
            switch self {
            case .arabic: "1, 2, 3"
            case .lowerLetters: "a, b, c"
            case .upperLetters: "A, B, C"
            case .roman: "I, II, III"
            }
        }
    }

    public enum Place: String, CaseIterable, Codable, Sendable {
        case start, end, replace

        public var title: String {
            switch self {
            case .start: "Before the name"
            case .end: "After the name"
            case .replace: "Instead of the name"
            }
        }
    }

    public enum DateSource: String, CaseIterable, Codable, Sendable {
        case taken, created, modified, today

        public var title: String {
            switch self {
            case .taken: "Date taken"
            case .created: "Date created"
            case .modified: "Date modified"
            case .today: "Today"
            }
        }
    }

    public enum Transliteration: String, CaseIterable, Codable, Sendable {
        case greeklish, classical, anyScript

        public var title: String {
            switch self {
            case .greeklish: "Greeklish (ELOT 743): Αθήνα → Athina"
            case .classical: "Classical: Αθήνα → Athena"
            case .anyScript: "Any script to Latin (Cyrillic, Arabic…)"
            }
        }
    }

    public enum ExtensionChange: String, CaseIterable, Codable, Sendable {
        case lower, upper, change, remove

        public var title: String {
            switch self {
            case .lower: "lowercase (.jpg)"
            case .upper: "UPPERCASE (.JPG)"
            case .change: "Change to…"
            case .remove: "Remove"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var isOn = true

    /// Find, the text to add, the pattern, a mark or a separator.
    public var text = ""
    /// Replace with, or the closing mark.
    public var text2 = ""
    public var matchCase = false
    public var regex = false
    public var occurrence = Occurrence.all
    /// Also change the extension (Replace, Change Case).
    public var includeExtension = false

    public var count = 1
    public var position = 1
    public var removePart = RemovePart.first
    public var removeKinds: [RemoveKind] = []
    public var insertPlace = InsertPlace.end
    public var caseStyle = CaseStyle.title
    public var separatorStyle = SeparatorStyle.spacesToUnderscores

    public var start = 1
    public var step = 1
    public var digits = 2
    public var numberStyle = NumberStyle.arabic
    public var place = Place.end
    public var separator = " "

    public var dateSource = DateSource.taken
    public var dateFormat = "yyyy-MM-dd"
    public var transliteration = Transliteration.greeklish
    public var extensionChange = ExtensionChange.lower

    public init(_ kind: Kind) {
        self.kind = kind
        switch kind {
        case .numbering: digits = 3
        case .pattern: text = "{name} {n}"
        case .date: place = .start
        case .padNumbers: digits = 3
        case .swap: text = " - "
        case .insert: text = ""
        default: break
        }
    }

    /// Date formats offered, with how today looks in each.
    public static let dateFormats = [
        "yyyy-MM-dd", "yyyyMMdd", "yyyy-MM-dd HH.mm.ss", "yyyyMMdd_HHmmss", "dd-MM-yyyy", "dd.MM.yyyy", "yyyy-MM", "yyyy", "d MMMM yyyy",
    ]

    /// The tokens a pattern can use.
    public static let patternTokens: [(token: String, title: String)] = [
        ("{name}", "Name"), ("{n}", "Number"), ("{date}", "Date taken"), ("{created}", "Created"), ("{modified}", "Modified"),
        ("{today}", "Today"), ("{folder}", "Folder"), ("{width}x{height}", "Size in pixels"), ("{camera}", "Camera"),
        ("{duration}", "Length"), ("{original}", "Original name"), ("{ext}", "Extension"),
    ]

    /// Why the rule can't work as set (a broken regular expression), or nil.
    public var problem: String? {
        guard isOn, kind == .replace, regex, !text.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: text)) == nil ? "The regular expression isn't valid." : nil
    }

    /// A one-line description for lists: "Replace “IMG” with “Photo”".
    public var summary: String {
        switch kind {
        case .replace: text.isEmpty ? "Replace text" : "Replace “\(text)” with “\(text2)”"
        case .remove:
            switch removePart {
            case .first: "Remove the first \(count)"
            case .last: "Remove the last \(count)"
            case .range: "Remove \(count) from position \(position)"
            case .keepFirst: "Keep the first \(count)"
            case .keepLast: "Keep the last \(count)"
            case .upTo: "Remove up to “\(text)”"
            case .from: "Remove from “\(text)” on"
            case .between: "Remove “\(text)…\(text2)”"
            }
        case .removeKinds: removeKinds.isEmpty ? "Remove kinds of text" : "Remove " + removeKinds.map(\.shortTitle).joined(separator: ", ")
        case .insert: text.isEmpty ? "Add text" : "Add “\(text)”"
        case .changeCase: caseStyle.title
        case .separators: separatorStyle.title
        case .numbering: "Number from \(start)"
        case .pattern: text
        case .date: dateSource.title
        case .transliterate: "Greek to Latin"
        case .padNumbers: "Numbers to \(digits) digits"
        case .swap: "Swap around “\(text)”"
        case .ext: "Extension: \(extensionChange == .change ? "." + text : extensionChange.title)"
        }
    }

    // MARK: - Applying

    /// Changes `name` for the file at `index` (counted in the order shown).
    public func apply(to name: inout FileName, context: RenameContext) {
        guard isOn else { return }
        switch kind {
        case .replace:
            name.base = replace(in: name.base)
            if includeExtension { name.ext = replace(in: name.ext) }
        case .remove:
            name.base = remove(from: name.base)
        case .removeKinds:
            name.base = removeKinds(from: name.base)
        case .insert:
            name.base = insert(into: name.base)
        case .changeCase:
            name.base = Self.change(name.base, to: caseStyle)
            if includeExtension { name.ext = Self.change(name.ext, to: caseStyle == .upper ? .upper : .lower) }
        case .separators:
            name.base = separators(in: name.base)
        case .numbering:
            name.base = place(number(at: context.index), in: name.base)
        case .pattern:
            name.base = expand(text, name: name, context: context)
        case .date:
            guard let date = date(context) else { return }
            name.base = place(context.format(date, dateFormat), in: name.base)
        case .transliterate:
            name.base = Self.transliterate(name.base, style: transliteration)
        case .padNumbers:
            name.base = padNumbers(in: name.base)
        case .swap:
            guard !text.isEmpty, let range = name.base.range(of: text) else { return }
            name.base = String(name.base[range.upperBound...]) + text + String(name.base[..<range.lowerBound])
        case .ext:
            switch extensionChange {
            case .lower: name.ext = name.ext.lowercased()
            case .upper: name.ext = name.ext.uppercased()
            case .change: if !name.ext.isEmpty || !context.isFolder { name.ext = text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            case .remove: name.ext = ""
            }
        }
    }

    private func replace(in string: String) -> String {
        guard !text.isEmpty else { return string }
        if regex {
            guard let expression = try? NSRegularExpression(pattern: text, options: matchCase ? [] : [.caseInsensitive]) else { return string }
            let matches = expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
            let chosen: [NSTextCheckingResult] = switch occurrence {
            case .all: matches
            case .first: Array(matches.prefix(1))
            case .last: Array(matches.suffix(1))
            }
            let result = NSMutableString(string: string)
            for match in chosen.reversed() {
                let replacement = expression.replacementString(for: match, in: string, offset: 0, template: text2)
                result.replaceCharacters(in: match.range, with: replacement)
            }
            return result as String
        }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        switch occurrence {
        case .all:
            return string.replacingOccurrences(of: text, with: text2, options: options)
        case .first, .last:
            guard let range = string.range(of: text, options: occurrence == .last ? options.union(.backwards) : options) else { return string }
            return string.replacingCharacters(in: range, with: text2)
        }
    }

    private func remove(from string: String) -> String {
        let characters = Array(string)
        let n = max(count, 0)
        switch removePart {
        case .first: return String(characters.dropFirst(n))
        case .last: return String(characters.dropLast(n))
        case .keepFirst: return String(characters.prefix(n))
        case .keepLast: return String(characters.suffix(n))
        case .range:
            let from = min(max(position - 1, 0), characters.count)
            let to = min(from + n, characters.count)
            return String(characters[..<from] + characters[to...])
        case .upTo:
            guard !text.isEmpty, let range = string.range(of: text, options: matchCase ? [] : .caseInsensitive) else { return string }
            return String(string[range.upperBound...])
        case .from:
            guard !text.isEmpty, let range = string.range(of: text, options: matchCase ? [] : .caseInsensitive) else { return string }
            return String(string[..<range.lowerBound])
        case .between:
            guard !text.isEmpty, !text2.isEmpty else { return string }
            var result = string
            var searchStart = result.startIndex
            while let open = result.range(of: text, range: searchStart..<result.endIndex),
                  let close = result.range(of: text2, range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
                searchStart = open.lowerBound
            }
            return result
        }
    }

    private func removeKinds(from string: String) -> String {
        var result = string
        for kind in removeKinds {
            switch kind {
            case .digits: result.removeAll { $0.isNumber }
            case .spaces: result.removeAll { $0.isWhitespace }
            case .special: result.removeAll { !($0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_") }
            case .brackets: result = result.replacingOccurrences(of: #"\s*(\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\})"#, with: "", options: .regularExpression)
            case .emoji: result.removeAll { $0.isEmoji }
            case .accents: result = result.applyingTransform(.stripDiacritics, reverse: false) ?? result
            case .copyMarks:
                result = result.replacingOccurrences(of: #"( copy( \d+)?| \(\d+\))+$"#, with: "", options: [.regularExpression, .caseInsensitive])
            case .latin: result.removeAll { $0.isASCII && $0.isLetter }
            case .greek: result.removeAll { $0.isGreekLetter }
            }
        }
        return result
    }

    private func insert(into string: String) -> String {
        guard !text.isEmpty else { return string }
        let characters = Array(string)
        switch insertPlace {
        case .start: return text + string
        case .end: return string + text
        case .position:
            let at = min(max(position, 0), characters.count)
            return String(characters[..<at]) + text + String(characters[at...])
        case .positionFromEnd:
            let at = max(characters.count - max(position, 0), 0)
            return String(characters[..<at]) + text + String(characters[at...])
        case .before, .after:
            guard !text2.isEmpty, let range = string.range(of: text2, options: matchCase ? [] : .caseInsensitive) else { return string }
            var result = string
            result.insert(contentsOf: text, at: insertPlace == .before ? range.lowerBound : range.upperBound)
            return result
        }
    }

    private func separators(in string: String) -> String {
        switch separatorStyle {
        case .spacesToUnderscores: string.replacingOccurrences(of: " ", with: "_")
        case .spacesToDashes: string.replacingOccurrences(of: " ", with: "-")
        case .spacesToDots: string.replacingOccurrences(of: " ", with: ".")
        case .removeSpaces: string.replacingOccurrences(of: " ", with: "")
        case .underscoresToSpaces: string.replacingOccurrences(of: "_", with: " ")
        case .dashesToSpaces: string.replacingOccurrences(of: "-", with: " ")
        case .dotsToSpaces: string.replacingOccurrences(of: ".", with: " ")
        case .tidy:
            string
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"([ _-])\1+"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "_-.")))
        }
    }

    private func place(_ value: String, in base: String) -> String {
        switch place {
        case .start: base.isEmpty ? value : value + separator + base
        case .end: base.isEmpty ? value : base + separator + value
        case .replace: value
        }
    }

    func number(at index: Int) -> String {
        let value = start + index * step
        switch numberStyle {
        case .arabic:
            let digitsText = String(abs(value))
            let padded = String(repeating: "0", count: max(0, digits - digitsText.count)) + digitsText
            return value < 0 ? "-" + padded : padded
        case .lowerLetters: return Self.letters(value).lowercased()
        case .upperLetters: return Self.letters(value)
        case .roman: return Self.roman(value)
        }
    }

    private func date(_ context: RenameContext) -> Date? {
        switch dateSource {
        case .taken: context.info.taken ?? context.info.created
        case .created: context.info.created
        case .modified: context.info.modified
        case .today: context.now
        }
    }

    private func expand(_ pattern: String, name: FileName, context: RenameContext) -> String {
        let info = context.info
        func formatted(_ date: Date?) -> String { date.map { context.format($0, dateFormat) } ?? "" }
        let duration = info.duration.map { String(format: "%d-%02d", Int($0) / 60, Int($0) % 60) } ?? ""
        let values: [String: String] = [
            "{name}": name.base, "{original}": context.original.base, "{n}": number(at: context.index),
            "{date}": formatted(info.taken ?? info.created), "{created}": formatted(info.created),
            "{modified}": formatted(info.modified), "{today}": formatted(context.now), "{folder}": info.folder,
            "{ext}": context.original.ext, "{width}": info.width.map(String.init) ?? "", "{height}": info.height.map(String.init) ?? "",
            "{camera}": info.camera ?? "", "{duration}": duration,
        ]
        var result = pattern
        for (token, value) in values {
            result = result.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        return result
    }

    private func padNumbers(in string: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"\d+"#) else { return string }
        let result = NSMutableString(string: string)
        for match in expression.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
            let number = (string as NSString).substring(with: match.range)
            guard number.count < digits else { continue }
            result.replaceCharacters(in: match.range, with: String(repeating: "0", count: digits - number.count) + number)
        }
        return result as String
    }

    // MARK: - Text helpers

    /// Words of a name, split at spaces, separators and lower→Upper steps.
    static func words(_ string: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in string {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func change(_ string: String, to style: CaseStyle) -> String {
        // Greek capitals lose their accents; other text uses the usual rules.
        let locale = string.contains(where: \.isGreekLetter) ? Locale(identifier: "el_GR") : Locale(identifier: "en_US_POSIX")
        func capitalized(_ word: String) -> String {
            guard let first = word.first else { return word }
            return String(first).uppercased(with: locale) + String(word.dropFirst()).lowercased(with: locale)
        }
        switch style {
        case .lower: return string.lowercased(with: locale)
        case .upper: return string.uppercased(with: locale)
        case .title:
            var result = ""
            var atWordStart = true
            for character in string {
                let text = String(character)
                result += atWordStart ? text.uppercased(with: locale) : text.lowercased(with: locale)
                atWordStart = !(character.isLetter || character.isNumber || character == "'" || character == "’")
            }
            return result
        case .sentence:
            let lower = string.lowercased(with: locale)
            guard let index = lower.firstIndex(where: \.isLetter) else { return lower }
            return lower.replacingCharacters(in: index...index, with: String(lower[index]).uppercased(with: locale))
        case .camel:
            let parts = words(string)
            guard let first = parts.first else { return string }
            return first.lowercased(with: locale) + parts.dropFirst().map(capitalized).joined()
        case .pascal: return words(string).map(capitalized).joined()
        case .snake: return words(string).map { $0.lowercased(with: locale) }.joined(separator: "_")
        case .kebab: return words(string).map { $0.lowercased(with: locale) }.joined(separator: "-")
        }
    }

    static func transliterate(_ string: String, style: Transliteration) -> String {
        switch style {
        case .greeklish:
            return greeklish(string)
        case .classical:
            return string.applyingTransform(StringTransform("Greek-Latin; Latin-ASCII"), reverse: false) ?? string
        case .anyScript:
            return string.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? string
        }
    }

    /// ELOT 743, word by word. The system's rules for αυ and ευ (av or af,
    /// ev or ef) only see small letters, so each Greek word goes through in
    /// small letters and gets its capitals back afterwards.
    static func greeklish(_ string: String) -> String {
        let greek = Locale(identifier: "el_GR")
        var result = ""
        var word = ""
        func flush() {
            defer { word = "" }
            guard word.contains(where: \.isGreekLetter) else {
                result += word
                return
            }
            var lower = word.lowercased(with: greek)
            // A word-initial γκ is g ("Γκρέκα" → "Greka"); the transform says nk.
            if lower.hasPrefix("γκ") { lower = "g" + lower.dropFirst(2) }
            var latin = lower.applyingTransform(StringTransform("Greek-Latin/UNGEGN; Latin-ASCII"), reverse: false) ?? lower
            if word.count > 1 && word == word.uppercased(with: greek) {
                latin = latin.uppercased()
            } else if word.first?.isUppercase == true {
                latin = latin.prefix(1).uppercased() + latin.dropFirst()
            }
            result += latin
        }
        for character in string {
            if character.isLetter {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        // Accents left on Latin letters next to Greek ones go too.
        return result.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? result
    }

    /// 1 → A, 26 → Z, 27 → AA.
    static func letters(_ value: Int) -> String {
        guard value > 0 else { return String(value) }
        var number = value
        var result = ""
        while number > 0 {
            number -= 1
            result = String(UnicodeScalar(UInt8(65 + number % 26))) + result
            number /= 26
        }
        return result
    }

    static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else { return String(value) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var number = value
        var result = ""
        for (amount, numeral) in table {
            while number >= amount {
                result += numeral
                number -= amount
            }
        }
        return result
    }
}

extension Character {
    var isEmoji: Bool {
        unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }

    var isGreekLetter: Bool {
        isLetter && unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) }
    }
}

/// Everything a rule may use while renaming one file.
public final class RenameContext {
    public var index: Int
    public var original: FileName
    public var info: RenameFileInfo
    public var isFolder: Bool
    public let now: Date
    private var formatters: [String: DateFormatter] = [:]

    public init(index: Int, original: FileName, info: RenameFileInfo, isFolder: Bool = false, now: Date = Date()) {
        self.index = index
        self.original = original
        self.info = info
        self.isFolder = isFolder
        self.now = now
    }

    func format(_ date: Date, _ format: String) -> String {
        if let formatter = formatters[format] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        // Numbers stay Western digits; month names follow the Mac's language.
        formatter.locale = format.contains("MMM") ? Locale.current : Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatters[format] = formatter
        return formatter.string(from: date)
    }
}

/// The order files are numbered in.
public enum RenameOrder: String, CaseIterable, Codable, Sendable {
    case name, taken, created, modified, size, kind, manual

    public var title: String {
        switch self {
        case .name: "Name"
        case .taken: "Date taken"
        case .created: "Date created"
        case .modified: "Date modified"
        case .size: "Size"
        case .kind: "Kind (extension)"
        case .manual: "As arranged"
        }
    }

    public func sorted(_ urls: [URL], infos: [URL: RenameFileInfo], reversed: Bool) -> [URL] {
        func byName(_ a: URL, _ b: URL) -> Bool { a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
        func by<T: Comparable>(_ key: @escaping (RenameFileInfo) -> T?) -> (URL, URL) -> Bool {
            { a, b in
                let ka = infos[a].flatMap(key), kb = infos[b].flatMap(key)
                switch (ka, kb) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byName(a, b)
                }
            }
        }
        let result: [URL] = switch self {
        case .manual: urls
        case .name: urls.sorted(by: byName)
        case .taken: urls.sorted(by: by { $0.taken ?? $0.created })
        case .created: urls.sorted(by: by(\.created))
        case .modified: urls.sorted(by: by(\.modified))
        case .size: urls.sorted(by: by(\.size))
        case .kind: urls.sorted { a, b in
            let ea = a.pathExtension.lowercased(), eb = b.pathExtension.lowercased()
            return ea != eb ? ea < eb : byName(a, b)
        }
        }
        return reversed ? result.reversed() : result
    }
}

/// One line of the rename preview: the file, its new name, and what (if
/// anything) is wrong with it.
public struct RenamePreview: Sendable, Equatable, Identifiable {
    public enum Problem: Sendable, Equatable {
        case empty
        case invalidCharacters
        case tooLong
        case duplicate
        case exists

        public var message: String {
            switch self {
            case .empty: "The name would be empty"
            case .invalidCharacters: "Names can't contain / or :"
            case .tooLong: "The name would be too long"
            case .duplicate: "Another file gets the same name"
            case .exists: "A file with this name is already there"
            }
        }
    }

    public let url: URL
    public let newName: String
    public let problem: Problem?

    public var id: URL { url }
    public var isChanged: Bool { newName != url.lastPathComponent }
    public var destination: URL { url.deletingLastPathComponent().appendingPathComponent(newName) }
}

public enum RenamePlanner {
    /// The new names, in `ordered` order (which also decides numbering).
    public static func preview(
        _ ordered: [URL], rules: [RenameRule], infos: [URL: RenameFileInfo], now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [RenamePreview] {
        var names: [String] = []
        for (index, url) in ordered.enumerated() {
            let original = FileName(url)
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let context = RenameContext(index: index, original: original, info: infos[url] ?? RenameFileInfo(folder: url.deletingLastPathComponent().lastPathComponent), isFolder: isFolder, now: now)
            var name = original
            for rule in rules { rule.apply(to: &name, context: context) }
            names.append(name.full.precomposedStringWithCanonicalMapping)
        }

        // Names are compared the way macOS disks do: ignoring case.
        func key(_ url: URL, _ name: String) -> String { url.deletingLastPathComponent().appendingPathComponent(name).path.lowercased() }
        var counts: [String: Int] = [:]
        for (url, name) in zip(ordered, names) { counts[key(url, name), default: 0] += 1 }
        let moving = Set(ordered.map { $0.path.lowercased() })

        return zip(ordered, names).map { url, name in
            var problem: RenamePreview.Problem?
            if name.trimmingCharacters(in: .whitespaces).isEmpty || name == "." || name == ".." {
                problem = .empty
            } else if name.contains("/") || name.contains(":") {
                problem = .invalidCharacters
            } else if name.utf8.count > 255 {
                problem = .tooLong
            } else if counts[key(url, name), default: 0] > 1 {
                problem = .duplicate
            } else if name != url.lastPathComponent {
                let target = key(url, name)
                // A file that is itself being renamed frees its name.
                if fileManager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(name).path)
                    && !moving.contains(target) {
                    problem = .exists
                }
            }
            return RenamePreview(url: url, newName: name, problem: problem)
        }
    }
}

/// Renames files all together, or not at all.
public enum Renamer {
    public struct Move: Sendable, Equatable, Codable {
        public let from: URL
        public let to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    /// Renames in two steps (first to a temporary name), so names can swap
    /// and a change of case only works too. If anything fails, everything
    /// renamed so far is put back and the error is thrown.
    @discardableResult
    public static func apply(_ moves: [Move], fileManager: FileManager = .default) throws -> [Move] {
        let moves = moves.filter { $0.from != $0.to }
        var parked: [(move: Move, temp: URL)] = []
        var finished: [Move] = []
        let token = UUID().uuidString.prefix(8)

        func rollBack() {
            for move in finished.reversed() { try? fileManager.moveItem(at: move.to, to: move.from) }
            for (move, temp) in parked where !finished.contains(move) {
                try? fileManager.moveItem(at: temp, to: move.from)
            }
        }

        do {
            for (index, move) in moves.enumerated() {
                let temp = move.from.deletingLastPathComponent().appendingPathComponent(".pinwheel-rename-\(token)-\(index)")
                try fileManager.moveItem(at: move.from, to: temp)
                parked.append((move, temp))
            }
            for (move, temp) in parked {
                try fileManager.moveItem(at: temp, to: move.to)
                finished.append(move)
            }
        } catch {
            rollBack()
            throw error
        }
        return finished
    }
}
