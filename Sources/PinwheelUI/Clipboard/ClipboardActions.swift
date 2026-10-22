import AppKit
import PinwheelCore
import SwiftUI
import UniformTypeIdentifiers

/// The small buttons under a copy in the clipboard history: each pastes the
/// copy changed a little (plain text, links without tracking, the text in a
/// picture…). A button shows only when it would change something.
enum ClipAction: String, CaseIterable, Identifiable {
    case plainText, cleanLinks, oneLine, tidySpaces
    case uppercase, lowercase, titleCase, sentenceCase
    case textInImage, readCode
    case filePath, fileName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .cleanLinks: "Clean Links"
        case .oneLine: "One Line"
        case .tidySpaces: "Tidy Spaces"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .sentenceCase: "Sentence case"
        case .textInImage: "Text in Image"
        case .readCode: "Read Code"
        case .filePath: "Path"
        case .fileName: "Name"
        }
    }

    var symbol: String {
        switch self {
        case .plainText: "doc.plaintext"
        case .cleanLinks: "sparkles"
        case .oneLine: "arrow.right.to.line"
        case .tidySpaces: "eraser"
        case .uppercase, .lowercase, .titleCase, .sentenceCase: "textformat.size"
        case .textInImage: "text.viewfinder"
        case .readCode: "qrcode.viewfinder"
        case .filePath: "folder"
        case .fileName: "textformat.abc"
        }
    }

    var help: String {
        switch self {
        case .plainText: "Pastes it without its formatting"
        case .cleanLinks: "Pastes it with the tracking taken out of its links (utm_source, fbclid…)"
        case .oneLine: "Pastes its lines joined into one"
        case .tidySpaces: "Pastes it without doubled spaces, spaces at line ends or extra blank lines"
        case .uppercase, .lowercase, .titleCase, .sentenceCase: "Pastes it in other capitals"
        case .textInImage: "Reads the text in the picture and pastes it"
        case .readCode: "Reads the QR code or barcode in the picture and pastes what it says"
        case .filePath: "Pastes where the file is, as text"
        case .fileName: "Pastes the file's name, as text"
        }
    }

    /// UPPERCASE, lowercase… share one button, with a menu.
    var isCase: Bool { [.uppercase, .lowercase, .titleCase, .sentenceCase].contains(self) }
    static let cases: [ClipAction] = [.uppercase, .lowercase, .titleCase, .sentenceCase]

    /// Shown on the row when there was nothing to paste.
    var nothingFound: String {
        switch self {
        case .textInImage: "No text found"
        case .readCode: "No code found"
        default: "Nothing to paste"
        }
    }
}

enum ClipActions {
    /// The buttons for a copy: only those that would change something.
    static func available(for item: ClipItem, store: ClipboardStore) -> [ClipAction] {
        switch item.kind {
        case .text, .link:
            guard let text = store.text(of: item) else { return [] }
            var actions: [ClipAction] = []
            if isFormatted(item) { actions.append(.plainText) }
            if cleanLinks(text) != text { actions.append(.cleanLinks) }
            if item.kind == .text {
                if oneLine(text) != text && text.contains(where: \.isNewline) { actions.append(.oneLine) }
                if tidySpaces(text) != text { actions.append(.tidySpaces) }
                if text.contains(where: \.isLetter) { actions += ClipAction.cases }
            }
            return actions
        case .image:
            return [.textInImage, .readCode]
        case .file:
            let files = store.files(of: item)
            let picture = files.count == 1 && UTType(filenameExtension: files[0].pathExtension)?.conforms(to: .image) == true
            return (picture ? [.textInImage, .readCode] : []) + [.filePath, .fileName]
        }
    }

    /// What the button pastes; nil or empty when there's nothing (a picture without text).
    static func text(of action: ClipAction, for item: ClipItem, store: ClipboardStore, recognition: TextRecognition) async throws -> String? {
        let text = store.text(of: item)
        switch action {
        case .plainText: return text
        case .cleanLinks: return text.map(cleanLinks)
        case .oneLine: return text.map(oneLine)
        case .tidySpaces: return text.map(tidySpaces)
        case .uppercase: return text?.localizedUppercase
        case .lowercase: return text?.localizedLowercase
        case .titleCase: return text?.localizedCapitalized
        case .sentenceCase: return text.map(sentenceCase)
        case .textInImage:
            guard let picture = picture(of: item, store: store) else { return nil }
            return try await PictureText.read(picture, recognition: recognition)
        case .readCode:
            guard let picture = picture(of: item, store: store) else { return nil }
            return try await CodeReader.read(picture).map(\.text).joined(separator: "\n")
        case .filePath: return store.files(of: item).map(\.path).joined(separator: "\n")
        case .fileName: return store.files(of: item).map(\.lastPathComponent).joined(separator: "\n")
        }
    }

    private static func picture(of item: ClipItem, store: ClipboardStore) -> URL? {
        store.imageFile(of: item) ?? store.files(of: item).first
    }

    /// Copied with formatting (or as a rich link), not just as plain text.
    static func isFormatted(_ item: ClipItem) -> Bool {
        let rich: Set<String> = [
            UTType.rtf.identifier, UTType.html.identifier, UTType.flatRTFD.identifier, UTType.rtfd.identifier,
            UTType.webArchive.identifier, UTType.url.identifier, "Apple HTML pasteboard type",
            "NeXT Rich Text Format v1.0 pasteboard type", "Apple Web Archive pasteboard type",
        ]
        return !(item.contents.first.map { Set($0).isDisjoint(with: rich) } ?? true)
    }

    // MARK: - Changing text

    /// Query parameters that only say where a link was shared from.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh", "yclid",
        "twclid", "ttclid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "wickedid",
        "ref_src", "ref_url", "_ga", "_gl", "srsltid",
    ]
    /// …and ones that do on these sites (elsewhere they may mean something).
    static let siteTrackingParameters: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp"], "youtu.be": ["si", "feature"], "spotify.com": ["si"],
        "instagram.com": ["igsh", "img_index"], "twitter.com": ["s", "t"], "x.com": ["s", "t"],
    ]

    /// The text with the tracking taken out of its web links.
    static func cleanLinks(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let whole = NSRange(text.startIndex..., in: text)
        var result = text
        // From the end, so earlier ranges stay right.
        for match in detector.matches(in: text, range: whole).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let link = String(text[range])
            if let cleaned = cleanLink(link), cleaned != link, let target = Range(match.range, in: result) {
                result.replaceSubrange(target, with: cleaned)
            }
        }
        return result
    }

    private static func cleanLink(_ link: String) -> String? {
        guard var components = URLComponents(string: link), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let items = components.percentEncodedQueryItems else { return nil }
        let host = components.host?.lowercased() ?? ""
        let sites = siteTrackingParameters.filter { host == $0.key || host.hasSuffix("." + $0.key) }.values.reduce(Set()) { $0.union($1) }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name) && !sites.contains(name)
        }
        guard kept.count != items.count else { return link }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string
    }

    /// Its lines joined into one, with single spaces.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacing(/[ \t]{2,}/, with: " ")
    }

    /// No doubled spaces or tabs, no spaces at the ends of lines, at most one blank line in a row.
    static func tidySpaces(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.replacing(/[ \t\u{00A0}]+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase, with a capital starting each sentence (and each line).
    static func sentenceCase(_ text: String) -> String {
        // In Greek, ";" ends a question (Swift counts the Greek question
        // mark as the same character); elsewhere it's a semicolon.
        let isGreek = text.unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) }
        let endings: Set<Character> = isGreek ? [".", "!", "?", ";"] : [".", "!", "?"]
        var result = ""
        var startsSentence = true
        var endedSentence = false
        for character in text.localizedLowercase {
            if character.isNewline {
                startsSentence = true
            } else if character.isWhitespace {
                if endedSentence { startsSentence = true }
            } else if startsSentence && character.isLetter {
                result += String(character).localizedUppercase
                startsSentence = false
                endedSentence = false
                continue
            } else if !character.isWhitespace {
                startsSentence = startsSentence && !character.isLetter && !character.isNumber
            }
            endedSentence = endings.contains(character)
            result.append(character)
        }
        return result
    }
}

/// A button under a copy, at work.
struct ClipWork: Equatable {
    let item: ClipItem.ID
    let action: ClipAction
}

/// A short note on a copy's row, such as "No text found".
struct ClipNotice: Equatable {
    let item: ClipItem.ID
    let text: String
    var isProblem = true
}

/// The small buttons under a copy. A click pastes the copy changed that way.
struct ClipActionBar: View {
    let item: ClipItem
    let actions: [ClipAction]
    var model: ClipboardPanelModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(actions.filter { !$0.isCase }) { action in
                Button { model.onAction(item, action) } label: {
                    chip(action.title, symbol: action.symbol, working: model.working == ClipWork(item: item.id, action: action))
                }
                .buttonStyle(.plain)
                .help(action.help)
            }
            if actions.contains(where: \.isCase) {
                Menu {
                    ForEach(ClipAction.cases) { action in
                        Button(action.title) { model.onAction(item, action) }
                    }
                } label: {
                    chip("Aa", symbol: nil, working: model.working.map { $0.item == item.id && $0.action.isCase } ?? false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(ClipAction.uppercase.help)
            }
        }
        .disabled(model.working != nil)
    }

    private func chip(_ title: String, symbol: String?, working: Bool) -> some View {
        HStack(spacing: 3) {
            if working {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(title).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .contentShape(Capsule())
    }
}
