import AppKit
import Observation
import PinwheelCore
import SwiftUI
import UniformTypeIdentifiers

/// Whether Finder's New File extension is switched on (asked again each time
/// Pinwheel comes to the front: it's switched in System Settings).
@Observable
final class NewFileExtensionStatus {
    static let shared = NewFileExtensionStatus()
    private(set) var isOn = NewFileService.isExtensionOn

    func refresh() { isOn = NewFileService.isExtensionOn }
}

/// Settings › Finder & Shortcuts › New File menu: what Finder's right-click
/// › New File offers, in which order, and your own templates.
struct NewFileMenuSettings: View {
    @Bindable var settings: SettingsStore
    private let status = NewFileExtensionStatus.shared
    private var isOn: Bool { status.isOn }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isOn ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOn ? "On in Finder" : "Off in Finder")
                        .font(.body.weight(.semibold))
                    Text(isOn
                         ? "Right-click an empty part of a Finder window (or a folder) › New File."
                         : "Switch on \u{201C}Pinwheel New File\u{201D} in System Settings › General › Login Items & Extensions › File Providers & Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(isOn ? "Extension Settings…" : "Turn On…") { NewFileService.showExtensionSettings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                status.refresh()
            }

            ForEach(Array(settings.newFileMenu.enumerated()), id: \.element.id) { index, entry in
                row(entry, at: index)
            }

            HStack {
                Button("Add Your Own Template…", action: addTemplate)
                Spacer()
                Button("Use the Usual Menu") {
                    let custom = settings.newFileMenu.filter(\.isCustom)
                    settings.newFileMenu = NewFileEntry.starting + custom
                }
            }
        } header: {
            Text("New File menu")
        } footer: {
            Footnote("Like Windows' right-click › New: makes an empty file in that folder, selected and ready to name. Switch items on or off and move them up or down; the menu follows at once. Your own template is any file (a letterhead, an invoice, a form): New File makes a copy of it. Pages, Numbers and Keynote make their first empty file themselves (the app opens for a moment); after that it's instant. Items for apps that aren't on this Mac are left out.")
        }
    }

    private func row(_ entry: NewFileEntry, at index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { entry.isOn },
                set: { on in settings.newFileMenu[index].isOn = on }
            )) {
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(for: entry))
                        .resizable()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.menuTitle)
                        Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if entry.isCustom {
                Button { settings.newFileMenu.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Take this template out of the menu (the file stays)")
            }
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == settings.newFileMenu.count - 1)
                .help("Move down")
        }
        .accessibilityElement(children: .contain)
    }

    private func subtitle(_ entry: NewFileEntry) -> String {
        if let path = entry.path {
            return FileManager.default.fileExists(atPath: path) ? "Your template · .\(entry.fileExtension)" : "Your template is missing"
        }
        if let kind = entry.kind, kind.needsApp, kind.installedApp == nil {
            return ".\(entry.fileExtension) · needs \(kind.appName)"
        }
        return ".\(entry.fileExtension)"
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard settings.newFileMenu.indices.contains(target) else { return }
        settings.newFileMenu.swapAt(index, target)
    }

    private func addTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose files to copy with New File (your letterhead, an invoice, a form…)."
        guard panel.runModal() == .OK else { return }
        settings.newFileMenu.insert(contentsOf: panel.urls.map(NewFileEntry.custom), at: 0)
    }

    static func icon(for entry: NewFileEntry) -> NSImage {
        if let path = entry.path, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.fileExtension) ?? .data)
    }
}
