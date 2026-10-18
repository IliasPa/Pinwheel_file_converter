import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI
import PinwheelCore

/// What the Info window shows and remembers: each file's details, and the
/// changes typed in (kept per file while you page through them).
@Observable
final class InfoModel {
    let files: [SourceFile]
    var index = 0 {
        didSet { if index != oldValue { load() } }
    }
    private(set) var details: FileDetails?
    private(set) var thumbnail: NSImage?
    private(set) var isLoading = false

    var onSave: ((SourceFile, MetadataEdit) -> Void)?
    var onRemoveAll: (([SourceFile]) -> Void)?
    var onClose: (() -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    /// Typed values per file, and each file's values before any typing.
    private var typed: [Int: [MetadataField: String]] = [:]
    private var originals: [Int: [MetadataField: String]] = [:]
    private var removeLocation: [Int: Bool] = [:]
    @ObservationIgnored private var generation = 0

    init(files: [SourceFile], settings: SettingsStore) {
        self.files = files
        self.settings = settings
        load()
    }

    var file: SourceFile { files[index] }

    func load() {
        generation += 1
        let current = generation
        details = nil
        thumbnail = NSWorkspace.shared.icon(forFile: file.url.path)
        isLoading = true
        let file = self.file
        let ffmpeg = settings.ffmpegURL
        let index = self.index
        Task {
            let loaded = await FileInspector.details(of: file, ffmpegURL: ffmpeg)
            guard current == generation else { return }
            details = loaded
            originals[index] = loaded.values
            isLoading = false
        }
        Task {
            let request = QLThumbnailGenerator.Request(
                fileAt: file.url, size: CGSize(width: 128, height: 128),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail
            )
            guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage,
                  current == generation else { return }
            thumbnail = image
        }
    }

    func value(_ field: MetadataField) -> String {
        typed[index]?[field] ?? details?.values[field] ?? ""
    }

    func setValue(_ field: MetadataField, _ text: String) {
        typed[index, default: [:]][field] = text
    }

    var removesLocation: Bool {
        get { removeLocation[index] ?? false }
        set { removeLocation[index] = newValue }
    }

    /// What changed in one file (typing a value back to what it was isn't a change).
    func edit(for index: Int) -> MetadataEdit {
        let before = originals[index] ?? [:]
        let changes = (typed[index] ?? [:]).filter { field, text in
            text.trimmingCharacters(in: .whitespacesAndNewlines) != (before[field] ?? "")
        }
        return MetadataEdit(changes: changes, removeLocation: removeLocation[index] ?? false)
    }

    /// How many files have changes to save.
    var changedCount: Int {
        files.indices.filter { !edit(for: $0).isEmpty }.count
    }

    var canEdit: Bool { details != nil && details?.readOnlyReason == nil }

    func save() {
        for index in files.indices {
            let edit = edit(for: index)
            if !edit.isEmpty { onSave?(files[index], edit) }
        }
        onClose?()
    }

    func removeAllInfo() {
        onRemoveAll?(files)
        onClose?()
    }

    func cancel() {
        onClose?()
    }
}

struct InfoView: View {
    var model: InfoModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            Form {
                if let details = model.details {
                    if !details.fields.isEmpty { editableSection(details) }
                    if let location = details.location { locationSection(location, details: details) }
                    ForEach(details.sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                LabeledContent(row.label) {
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
                .padding(14)
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.file.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let kind = model.details?.sections.last?.rows.first(where: { $0.label == "Kind" })?.value,
                   let size = model.details?.sections.last?.rows.first(where: { $0.label == "Size" })?.value {
                    Text("\(kind) · \(size)").foregroundStyle(.secondary)
                }
                if model.files.count > 1 {
                    HStack(spacing: 4) {
                        Button { model.index -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(model.index == 0)
                        Text("\(model.index + 1) of \(model.files.count)").monospacedDigit()
                        Button { model.index += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(model.index == model.files.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            Spacer()
        }
    }

    private func editableSection(_ details: FileDetails) -> some View {
        Section {
            ForEach(details.fields, id: \.self) { field in
                TextField(field.label, text: Binding(get: { model.value(field) }, set: { model.setValue(field, $0) }), prompt: Text(field.prompt))
                    .disabled(!model.canEdit)
            }
        } header: {
            Text("Details")
        } footer: {
            if let reason = details.readOnlyReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func locationSection(_ location: GeoLocation, details: FileDetails) -> some View {
        Section("Location") {
            LabeledContent("Taken at") {
                Text(location.description).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Show in Maps") { NSWorkspace.shared.open(location.mapsURL) }
            }
            Toggle("Remove the location from the copy", isOn: Binding(get: { model.removesLocation }, set: { model.removesLocation = $0 }))
                .disabled(!model.canEdit)
        }
    }

    private var footer: some View {
        HStack {
            Button("Save Copy Without Info", action: model.removeAllInfo)
                .help("Removes location, camera, dates, names and other hidden details, in a copy of every file.")
            Spacer()
            Button("Cancel", action: model.cancel)
                .keyboardShortcut(.cancelAction)
            Button(model.changedCount > 1 ? "Save \(model.changedCount) Copies" : "Save Copy", action: model.save)
                .keyboardShortcut(.defaultAction)
                .disabled(model.changedCount == 0)
                .help("Saves a copy with the new details, named “… (edited)”. The picture or sound itself isn't changed.")
        }
    }
}

final class InfoWindowController: EditorWindowController {
    let model: InfoModel

    init(model: InfoModel) {
        self.model = model
        let title = model.files.count == 1 ? "Info: \(model.files[0].url.lastPathComponent)" : "Info: \(model.files.count) Files"
        super.init(title: title, size: NSSize(width: 560, height: 680), content: InfoView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
