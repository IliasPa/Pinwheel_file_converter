import AppKit

@main
@MainActor
enum PinwheelApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar only: no Dock icon (Info.plist also sets LSUIElement).
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
