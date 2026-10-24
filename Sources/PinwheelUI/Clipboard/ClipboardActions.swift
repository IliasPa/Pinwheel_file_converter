import AppKit
import PinwheelCore
import SwiftUI
import UniformTypeIdentifiers

/// The small buttons under a copy in the clipboard history: each pastes the
/// copy changed a little (plain text, links without tracking, the text in a
/// picture…). A button shows only when it would change something.
enum ClipAction: String, CaseIterable, Identifiable {
    case plainText, cleanLinks, bareLink, oneLine, tidySpaces
    case uppercase, lowercase, titleCase, sentenceCase
    case textInImage, readCode
    case filePath, fileName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .cleanLinks: "Clean Links"
        case .bareLink: "Bare Link"
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
        case .bareLink: "scissors"
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
        case .bareLink: "Pastes the link with nothing after ? or # (check it still opens: some links need those)"
        case .oneLine: "Pastes its lines joined into one"
        case .tidySpaces: "Pastes it without doubled spaces, spaces at line ends or extra blank lines (indents stay)"
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
    /// How much of a long text is looked at to choose its buttons (the
    /// button then changes all of it).
    static let lookLimit = 50_000

    /// The buttons for a copy: only those that would change something. A
    /// picture's show once it's been looked at, and only for what's in it.
    static func available(for item: ClipItem, store: ClipboardStore) -> [ClipAction] {
        switch item.kind {
        case .text, .link:
            guard let whole = store.text(of: item) else { return [] }
            let text = whole.count > lookLimit ? String(whole.prefix(lookLimit)) : whole
            var actions: [ClipAction] = []
            if isFormatted(item) { actions.append(.plainText) }
            let cleaned = cleanLinks(text)
            if cleaned != text { actions.append(.cleanLinks) }
            // What no list knows about: everything after "?" or "#".
            if item.kind == .link, bareLink(text) != cleaned.trimmingCharacters(in: .whitespacesAndNewlines) { actions.append(.bareLink) }
            if item.kind == .text {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline) { actions.append(.oneLine) }
                if tidySpaces(text) != text { actions.append(.tidySpaces) }
                if text.contains(where: \.isLetter) { actions += ClipAction.cases }
            }
            return actions
        case .image:
            return pictureActions(item)
        case .file:
            return (store.picture(of: item) != nil ? pictureActions(item) : []) + [.filePath, .fileName]
        }
    }

    private static func pictureActions(_ item: ClipItem) -> [ClipAction] {
        (item.pictureHasText == true ? [.textInImage] : []) + (item.pictureHasCode == true ? [.readCode] : [])
    }

    /// How pictures are looked at: 2 reads photos with Apple's text
    /// recognition too, so pictures looked at before are looked at again.
    static let lookVersion = 2

    /// Whether a picture still needs looking at for words and codes.
    static func needsLook(_ item: ClipItem, store: ClipboardStore) -> Bool {
        item.pictureLook != lookVersion && (item.kind == .image || item.kind == .file) && store.picture(of: item) != nil
    }

    /// The words and codes in a picture, read on this Mac (by the reader,
    /// which is stopped a minute after it was last used); nil when it
    /// couldn't be read, so it's looked at again another time.
    static func look(at picture: URL, recognition: TextRecognition) async -> (text: String, codes: [String])? {
        guard let text = try? await PictureReader.shared.text(in: picture, recognition: recognition) else { return nil }
        let codes = (try? await PictureReader.shared.codes(in: picture).map(\.text)) ?? []
        return (text, codes)
    }

    /// What the button pastes; nil or empty when there's nothing (a picture without text).
    static func text(of action: ClipAction, for item: ClipItem, store: ClipboardStore, recognition: TextRecognition) async throws -> String? {
        let text = store.text(of: item)
        switch action {
        case .plainText: return text
        case .cleanLinks: return text.map(cleanLinks)
        case .bareLink: return text.map(bareLink)
        case .oneLine: return text.map(oneLine)
        case .tidySpaces: return text.map(tidySpaces)
        case .uppercase: return text?.localizedUppercase
        case .lowercase: return text?.localizedLowercase
        case .titleCase: return text?.localizedCapitalized
        case .sentenceCase: return text.map(sentenceCase)
        // Read when it was copied; read now only if that hasn't happened.
        case .textInImage:
            if let found = store.pictureText(of: item) { return found }
            guard let picture = store.picture(of: item) else { return nil }
            return try await PictureReader.shared.text(in: picture, recognition: recognition)
        case .readCode:
            if let found = store.pictureCodes(of: item) { return found }
            guard let picture = store.picture(of: item) else { return nil }
            return try await PictureReader.shared.codes(in: picture).map(\.text).joined(separator: "\n")
        case .filePath: return store.files(of: item).map(\.path).joined(separator: "\n")
        case .fileName: return store.files(of: item).map(\.lastPathComponent).joined(separator: "\n")
        }
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

    /// Query parameters that only say where a link was shared from, or by
    /// whom: on any site.
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id",
        "vero_conv", "wickedid", "ref_src", "ref_url", "_ga", "_gl", "_ke", "_kx", "srsltid", "epik", "sc_cid",
        "ck_subscriber_id", "rb_clickid", "s_cid", "ef_id", "irclickid", "irgwc", "ranmid", "raneaid", "ransiteid",
        "at_medium", "at_campaign", "cmpid", "_openstat", "mbid", "nr_email_referer", "sr_share", "__s", "spm", "scm",
    ]
    /// Names starting like these, on any site (Google's utm_source…, Matomo's pk_…).
    static let trackingPrefixes = ["utm_", "pk_", "mtm_", "piwik_", "hsa_", "ga_", "oly_"]

    /// …and ones that do on these sites (elsewhere they may mean something).
    /// "amazon." stands for every Amazon (amazon.com, amazon.de…).
    static let siteTrackingParameters: [String: Set<String>] = [
        "youtube.com": ["si", "feature", "pp", "ab_channel"], "youtu.be": ["si", "feature"],
        "spotify.com": ["si", "context", "nd", "dlsi"],
        "instagram.com": ["igsh", "img_index"], "threads.net": ["xmt", "slof"], "threads.com": ["xmt", "slof"],
        "twitter.com": ["s", "t"], "x.com": ["s", "t"],
        "facebook.com": ["mibextid", "rdid", "share_url", "__tn__", "__cft__", "ref", "fref", "hc_ref", "sfnsn", "extid"],
        "fb.watch": ["mibextid"],
        "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device", "sender_web_id", "share_app_id", "share_item_id",
                       "share_link_id", "social_sharing", "u_code", "tt_from", "timestamp", "source"],
        "linkedin.com": ["trk", "trkinfo", "lipi", "licu", "lici", "midtoken", "midsig", "trackingid", "refid", "eid",
                         "isselfprofile", "originalsubdomain", "original_referer", "sessionredirect", "rcm"],
        "reddit.com": ["share_id", "rdt", "ref", "ref_source", "ref_campaign", "correlation_id"],
        "amazon.": ["ref", "ref_", "pd_rd_w", "pd_rd_wg", "pd_rd_r", "pd_rd_i", "pf_rd_p", "pf_rd_r", "pf_rd_s", "pf_rd_t",
                    "pf_rd_i", "pf_rd_m", "content-id", "crid", "sprefix", "sr", "qid", "dib", "dib_tag", "linkcode", "tag", "linkid"],
        "google.": ["ved", "ei", "sa", "usg", "gs_lcp", "sclient", "oq", "aqs", "sourceid", "gs_lp", "uact", "bih", "biw",
                    "rlz", "sxsrf", "iflsig", "gws_rd", "sca_esv", "sca_upv", "sei", "fbs", "gs_ssp"],
        "bing.com": ["form", "sp", "ghc", "lq", "pq", "sc", "qs", "sk", "cvid", "ghsh", "ghacc", "ghpl"],
        "ebay.": ["_trkparms", "_trksid", "amdata", "mkcid", "mkrid", "campid", "toolid", "customid", "mkevt"],
        "aliexpress.": ["pvid", "algo_pvid", "algo_expid", "aff_fcid", "aff_fsk", "aff_platform", "aff_trace_key",
                        "terminal_id", "afsmartredirect", "gatewayadapt", "sk"],
        "substack.com": ["r", "s", "triedredirect", "showwelcomeonshare"],
        "medium.com": ["source", "sk"],
        "quora.com": ["share", "ch", "oid", "srid", "target_type"],
    ]

    /// The site-only tracking names for this host.
    static func siteTracking(for host: String) -> Set<String> {
        siteTrackingParameters.reduce(into: Set<String>()) { names, site in
            let matches = site.key.hasSuffix(".")
                ? host.hasPrefix(site.key) || host.contains("." + site.key)
                : host == site.key || host.hasSuffix("." + site.key)
            if matches { names.formUnion(site.value) }
        }
    }

    static func isTracking(_ name: String, site: Set<String>) -> Bool {
        let name = name.lowercased()
        return trackingParameters.contains(name) || site.contains(name) || trackingPrefixes.contains { name.hasPrefix($0) }
    }

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
        // "www.example.com/?utm_source=…" too: read with a scheme, given back without.
        // (A scheme is "https:" or "mailto:", not the "example.com:" of a port.)
        let hasScheme = link.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(?![0-9])", options: .regularExpression) != nil
        guard !hasScheme || link.lowercased().hasPrefix("http") else { return nil }
        guard let cleaned = cleanWebLink(hasScheme ? link : "http://" + link) else { return nil }
        return hasScheme ? cleaned : String(cleaned.dropFirst("http://".count))
    }

    private static func cleanWebLink(_ link: String) -> String? {
        guard var components = URLComponents(string: link), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let items = components.percentEncodedQueryItems else { return nil }
        let site = siteTracking(for: components.host?.lowercased() ?? "")
        let kept = items.filter { !isTracking($0.name, site: site) }
        guard kept.count != items.count else { return link }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string
    }

    /// The link with nothing after "?" or "#".
    static func bareLink(_ link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return trimmed }
        return String(trimmed[..<cut])
    }

    /// Its lines joined into one, with single spaces.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacing(/[ \t]{2,}/, with: " ")
    }

    /// No doubled spaces, no spaces at the ends of lines, at most one blank
    /// line in a row. Indents stay, and so do tabs (cells copied from a
    /// spreadsheet are kept apart by them).
    static func tidySpaces(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" || last == "\u{00A0}" { line.removeLast() }
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                return String(indent) + String(line.dropFirst(indent.count)).replacing(/[ \u{00A0}]{2,}/, with: " ")
            }
            .joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
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
                chip(action.title, symbol: action.symbol, working: model.working == ClipWork(item: item.id, action: action))
                    .overlay { ClickArea(label: action.title, help: action.help) { _ in model.onAction(item, action) } }
            }
            if actions.contains(where: \.isCase) {
                chip("Aa", symbol: nil, working: model.working.map { $0.item == item.id && $0.action.isCase } ?? false)
                    .overlay {
                        ClickArea(label: "Aa", help: ClipAction.uppercase.help) { view in
                            Self.caseMenu(for: item, model: model).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
                        }
                    }
            }
        }
        .opacity(model.working == nil || model.working?.item == item.id ? 1 : 0.5)
    }

    /// UPPERCASE, lowercase, Title Case, Sentence case.
    static func caseMenu(for item: ClipItem, model: ClipboardPanelModel) -> NSMenu {
        let menu = NSMenu()
        for action in ClipAction.cases {
            menu.addItem(actionMenuItem(action.title) { model.onAction(item, action) })
        }
        return menu
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
        .foregroundStyle(Color.primary.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }
}

/// Where a small button takes its click (AppKit, like the rows): the first
/// click counts even when the window isn't in front, and VoiceOver can find
/// and press it.
struct ClickArea: NSViewRepresentable {
    let label: String
    let help: String
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> ClickAreaView {
        let view = ClickAreaView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ClickAreaView, context: Context) {
        view.label = label
        view.toolTip = help
        view.action = action
    }
}

final class ClickAreaView: NSView {
    var label = ""
    var action: (NSView) -> Void = { _ in }
    private(set) var isHovered = false {
        didSet { showState() }
    }
    private(set) var isPressed = false {
        didSet { showState() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // A click that pastes closes the window under the pointer: no
    // "exited" comes, so the button would open lit next time.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    @objc private func windowChanged() {
        if window?.occlusionState.contains(.visible) != true { isHovered = false }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        // Let go outside: not pressed.
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(self) }
    }

    /// Pointed at, it lights up in the accent color like a button;
    /// pressed, a little more. (Drawn here, so pointing at it redraws
    /// nothing else.)
    private func showState() {
        wantsLayer = true
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        layer.cornerRadius = bounds.height / 2
        layer.backgroundColor = isPressed ? accent.withAlphaComponent(0.34).cgColor : isHovered ? accent.withAlphaComponent(0.18).cgColor : nil
        layer.borderColor = accent.withAlphaComponent(0.65).cgColor
        layer.borderWidth = isHovered || isPressed ? 1 : 0
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }

    override func accessibilityPerformPress() -> Bool {
        action(self)
        return true
    }
}
