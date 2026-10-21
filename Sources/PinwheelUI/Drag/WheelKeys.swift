import AppKit
import PinwheelCore

/// Modifier keys held together, e.g. ⌥⇧.
struct ModifierKeys: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let control = ModifierKeys(rawValue: 1 << 0)
    static let option = ModifierKeys(rawValue: 1 << 1)
    static let shift = ModifierKeys(rawValue: 1 << 2)
    static let command = ModifierKeys(rawValue: 1 << 3)

    /// The four keys, in the order macOS writes them: ⌃⌥⇧⌘.
    static let each: [ModifierKeys] = [.control, .option, .shift, .command]

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The four keys in what macOS reports (Caps Lock and fn don't count).
    init(_ flags: NSEvent.ModifierFlags) {
        var keys: ModifierKeys = []
        if flags.contains(.control) { keys.insert(.control) }
        if flags.contains(.option) { keys.insert(.option) }
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.command) { keys.insert(.command) }
        self = keys
    }

    /// "⌥⇧"
    var symbols: String {
        Self.each.filter(contains).map(\.symbol).joined()
    }

    /// "⌥ Option + ⇧ Shift"
    var title: String {
        Self.each.filter(contains).map { "\($0.symbol) \($0.name)" }.joined(separator: " + ")
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        default: symbols
        }
    }

    var name: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        default: title
        }
    }
}

/// Which keys open which wheel while dragging files.
struct WheelKeys: Equatable, Sendable {
    var keys: [WheelMode: ModifierKeys]

    static let standard = WheelKeys(keys: [.convert: [.shift], .tools: [.option, .shift], .actions: [.control, .shift]])

    subscript(mode: WheelMode) -> ModifierKeys {
        get { keys[mode] ?? Self.standard.keys[mode]! }
        set { keys[mode] = newValue }
    }

    /// The wheel these keys open: only exactly its keys, so ⇧ and ⌥⇧ don't
    /// get mixed up. When two wheels have the same keys, the first wins.
    func mode(for pressed: ModifierKeys) -> WheelMode? {
        guard !pressed.isEmpty else { return nil }
        return WheelMode.allCases.first { self[$0] == pressed }
    }

    /// Wheels whose keys another wheel already uses (shown as a warning).
    var clashes: Set<WheelMode> {
        var seen: [ModifierKeys: WheelMode] = [:]
        var clashing: Set<WheelMode> = []
        for mode in WheelMode.allCases {
            if let first = seen[self[mode]] {
                clashing.formUnion([first, mode])
            } else {
                seen[self[mode]] = mode
            }
        }
        return clashing
    }
}

extension WheelMode {
    /// "Formats", "Tools", "File actions"
    var wheelTitle: String {
        switch self {
        case .convert: "Formats"
        case .tools: "Tools"
        case .actions: "File actions"
        }
    }

    var wheelSymbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .tools: "wrench.and.screwdriver"
        case .actions: "folder"
        }
    }
}
