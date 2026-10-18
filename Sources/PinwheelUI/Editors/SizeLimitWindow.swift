import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// "Size Limit…": choose how big the files may be (each, or all together,
/// e.g. to fit in one email), then each is made just small enough.
@Observable
final class SizeLimitModel {
    struct Row: Identifiable, Equatable {
        let file: SourceFile
        let size: Int64
        /// What it has to fit in.
        let limit: Int64

        var id: URL { file.url }
        var fits: Bool { size <= limit }
    }

    let files: [SourceFile]
    /// The limit typed or picked, in megabytes.
    private(set) var megabytes: Double
    /// The text field: typing a size changes `megabytes`.
    var text: String {
        didSet { typed() }
    }
    /// One limit for all files together (shared out by size), instead of each.
    var together = false

    var onSave: (([ConversionRequest], Double) -> Void)?
    var onClose: (() -> Void)?

    @ObservationIgnored private let sizes: [URL: Int64]

    init(files: [SourceFile], megabytes: Double = 10) {
        self.files = files
        self.megabytes = megabytes
        text = Self.format(megabytes)
        sizes = Dictionary(uniqueKeysWithValues: files.map { ($0.url, FileSize.of($0.url) ?? 0) })
    }

    /// "10", "2.5", "0.25".
    static func format(_ megabytes: Double) -> String {
        if megabytes.rounded() == megabytes { return String(Int(megabytes)) }
        var text = String(format: megabytes < 1 ? "%.3f" : "%.1f", megabytes)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    func choose(_ value: Double) {
        megabytes = value
        text = Self.format(value)
    }

    /// Takes what's typed ("12", "2,5") whenever it's a size.
    private func typed() {
        let value = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
        if value > 0 { megabytes = min(value, 100_000) }
    }

    /// Shows the size in use again (after typing something that isn't one).
    func tidyText() {
        let shown = Self.format(megabytes)
        if text != shown { text = shown }
    }

    var limit: Int64 { SizeLimit.bytes(megabytes: megabytes) }
    var total: Int64 { files.reduce(0) { $0 + (sizes[$1.url] ?? 0) } }

    /// Each file with what it has to fit in. All together, the limit is
    /// shared in proportion to size, so every file shrinks by the same share.
    var rows: [Row] {
        files.map { file in
            let size = sizes[file.url] ?? 0
            let share = together && total > 0 ? Int64(Double(limit) * Double(size) / Double(total)) : limit
            return Row(file: file, size: size, limit: together && total <= limit ? size : share)
        }
    }

    /// The files that need making smaller.
    var toShrink: [Row] { rows.filter { !$0.fits } }

    func save() {
        let requests = toShrink.map {
            ConversionRequest(file: $0.file, action: .tool(.sizeLimit), parameters: .sizeLimit(bytes: $0.limit))
        }
        guard !requests.isEmpty else { return }
        onSave?(requests, megabytes)
        onClose?()
    }
}

struct SizeLimitView: View {
    @Bindable var model: SizeLimitModel

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("How big may it be?").font(.headline)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(SizeLimit.presets, id: \.megabytes) { preset in
                        let chosen = model.megabytes == preset.megabytes
                        Button { model.choose(preset.megabytes) } label: {
                            VStack(spacing: 2) {
                                Text(SizeLimit.title(megabytes: preset.megabytes)).font(.system(size: 15, weight: .semibold))
                                Text(preset.hint).font(.caption2).foregroundStyle(chosen ? Color.white.opacity(0.85) : .secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(chosen ? Color.white : .primary)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chosen ? Color.accentColor : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    Text("Or exactly")
                    TextField("Size", text: $model.text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit(model.tidyText)
                    Text("MB")
                    Spacer()
                    if model.files.count > 1 {
                        Picker("Limit", selection: $model.together) {
                            Text("Each file").tag(false)
                            Text("All together").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("All together shares the size out, so the files fit in one email.")
                    }
                }
            }
            .padding(16)
            Divider()
            List(model.rows) { row in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.file.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(row.file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(SizeLimit.title(bytes: row.size)).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(row.fits ? "Already fits" : "under \(SizeLimit.title(bytes: row.limit))")
                        .monospacedDigit()
                        .foregroundStyle(row.fits ? Color.secondary : Color.primary)
                        .frame(width: 110, alignment: .leading)
                }
                .font(.system(size: 12))
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Together now \(SizeLimit.title(bytes: model.total))").font(.system(size: 12, weight: .medium))
                    Text("Quality goes down only as far as needed; pictures and videos get smaller in size only when that isn't enough.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: model.save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.toShrink.isEmpty)
                    .help("Saves smaller copies next to the originals, named “… (under 10 MB)”.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 600, minHeight: 480)
    }

    private var saveTitle: String {
        let count = model.toShrink.count
        return count <= 1 ? "Make Smaller" : "Make \(count) Smaller"
    }
}

final class SizeLimitWindowController: EditorWindowController {
    init(model: SizeLimitModel) {
        let title = model.files.count == 1 ? "Size Limit for \(model.files[0].url.lastPathComponent)" : "Size Limit for \(model.files.count) Files"
        super.init(title: title, size: NSSize(width: 660, height: 560), content: SizeLimitView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
