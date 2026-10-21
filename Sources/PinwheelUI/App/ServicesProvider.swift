import AppKit
import PinwheelCore

/// Pinwheel in Finder's right-click menu (macOS calls these "Services";
/// Info.plist lists them): the wheel opens at the pointer for the chosen
/// files, or the Rename window opens.
final class ServicesProvider: NSObject {
    var showWheel: ([URL], WheelMode) -> Void = { _, _ in }
    var openEditor: (Editor, [URL]) -> Void = { _, _ in }

    @objc func showConvertWheel(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard, error: error) { showWheel($0, .convert) }
    }

    @objc func showToolsWheel(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard, error: error) { showWheel($0, .tools) }
    }

    @objc func showActionsWheel(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard, error: error) { showWheel($0, .actions) }
    }

    @objc func renameFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard, error: error) { openEditor(.rename, $0) }
    }

    private func handle(_ pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>, _ action: ([URL]) -> Void) {
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "Pinwheel didn't get any files." as NSString
            return
        }
        action(urls)
    }

    /// The files on the pasteboard, whichever way Finder put them there.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !objects.isEmpty { return objects.map(\.standardizedFileURL) }
        // Older apps send a list of paths.
        let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}
