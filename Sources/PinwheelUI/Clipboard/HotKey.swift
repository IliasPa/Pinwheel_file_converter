import AppKit
import Carbon.HIToolbox

/// A key with modifiers, such as ⌥⌘V.
struct KeyShortcut: Equatable, Sendable {
    /// The key's place on the keyboard (whatever letter it types).
    var keyCode: UInt16
    var modifiers: ModifierKeys
    /// What's printed on the key: "V", "Space", "F5".
    var key: String

    /// The clipboard history's: ⌥⌘V.
    static let clipboard = KeyShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.option, .command], key: "V")

    /// "⌥⌘V"
    var title: String { modifiers.symbols + key }

    /// Without ⌘, ⌥ or ⌃ it would get in the way of typing.
    var isUsable: Bool { !modifiers.isDisjoint(with: [.command, .option, .control]) }

    /// Shortcuts that would take over something everyone uses.
    var isReserved: Bool {
        modifiers == [.command] && [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_Tab, kVK_Space]
            .map(UInt16.init).contains(keyCode)
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }

    /// The key pressed while recording a new shortcut.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let name = Self.keyNames[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: ModifierKeys(event.modifierFlags), key: name)
    }

    init(keyCode: UInt16, modifiers: ModifierKeys, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Keys whose name isn't the character they type.
    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// As saved in the preferences.
    var stored: [String: Any] { ["keyCode": Int(keyCode), "modifiers": modifiers.rawValue, "key": key] }

    init?(stored: [String: Any]?) {
        guard let stored, let code = stored["keyCode"] as? Int, let raw = stored["modifiers"] as? Int, let key = stored["key"] as? String else {
            return nil
        }
        self.init(keyCode: UInt16(code), modifiers: ModifierKeys(rawValue: raw), key: key)
    }
}

/// A shortcut that works in every app. It's registered with macOS, so the
/// app in front doesn't also get the keys (⌥⌘V is "Move here" in Finder).
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private let id: UInt32

    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    /// False when macOS said no (another app already uses the shortcut).
    @discardableResult
    func register(_ shortcut: KeyShortcut, action: @escaping () -> Void) -> Bool {
        unregister()
        Self.installHandler()
        var made: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x504E_574C /* "PNWL" */, id: id)
        // Exclusive: if another app has these keys, say so instead of both answering.
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &made
        )
        guard status == noErr, let made else { return false }
        reference = made
        Self.actions[id] = action
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.actions[id] = nil
    }

    var isRegistered: Bool { reference != nil }

    private static func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // macOS calls this on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}
