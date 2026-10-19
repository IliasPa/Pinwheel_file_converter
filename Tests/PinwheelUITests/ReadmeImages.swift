import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PinwheelCore
@testable import PinwheelUI

/// Temporary: draws the README's pictures. Runs only when PINWHEEL_README_IMAGES names a folder.
struct ReadmeImages {
    nonisolated static let folder = ProcessInfo.processInfo.environment["PINWHEEL_README_IMAGES"]

    private func save<V: View>(_ view: V, _ name: String, size: NSSize) async throws {
        let folder = try #require(Self.folder)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    @Test(.enabled(if: folder != nil)) func draw() async throws {
        let defaults = UserDefaults(suiteName: "PinwheelReadme-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        func wheel(_ mode: WheelMode, _ file: String, hovered: Int) -> WheelModel {
            let model = WheelModel()
            model.load(files: [SourceFile(url: URL(fileURLWithPath: "/tmp/\(file)"))], mode: mode, options: settings.conversionOptions,
                       hidden: FormatCatalog.defaultHidden) { _, _ in .available }
            model.isPresented = true
            model.hovered = .wedge(hovered)
            return model
        }
        let backdrop = ZStack {
            LinearGradient(colors: [Brand.teal, Brand.blue, Brand.indigo, Color(red: 0.85, green: 0.3, blue: 0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let hero = ZStack {
            backdrop
            HStack(spacing: 120) {
                VStack(spacing: 14) {
                    WheelView(model: wheel(.convert, "Holiday.heic", hovered: 1), settings: settings, blending: .withinWindow)
                        .frame(width: 330, height: 330)
                    Text("⇧ Shift: formats").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6)
                }
                VStack(spacing: 14) {
                    WheelView(model: wheel(.tools, "Holiday.heic", hovered: 1), settings: settings, blending: .withinWindow)
                        .frame(width: 330, height: 330)
                    Text("⌥ Option + ⇧ Shift: tools").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6)
                }
            }
        }
        settings.glassLevel = .frosted  // Liquid Glass doesn't show in a picture drawn off screen
        try await save(hero, "wheels.png", size: NSSize(width: 1200, height: 480))

        // The Rename window, with a few rules.
        let scratch = try Scratch()
        var urls: [URL] = []
        for name in ["IMG_2041.HEIC", "IMG_2042.HEIC", "IMG_2050 copy.HEIC", "Παραλία Χανιά.jpg", "Σούρουπο.jpg"] {
            urls.append(try scratch.image(name))
        }
        let rename = RenameModel(urls: urls)
        try await Task.sleep(for: .milliseconds(300))
        var copies = RenameRule(.removeKinds)
        copies.removeKinds = [.copyMarks]
        var pattern = RenameRule(.pattern)
        pattern.text = "Crete {n}"
        pattern.digits = 2
        rename.rules = [copies, RenameRule(.transliterate), pattern]
        rename.expanded = rename.rules[2].id
        try await save(RenameView(model: rename).background(Color(nsColor: .windowBackgroundColor)), "rename.png", size: NSSize(width: 1000, height: 560))
    }
}
