import AppKit
import SwiftUI
import PinwheelCore

/// The image editor: tabs on top, the picture, its controls, and Save.
struct StudioView: View {
    @Bindable var model: StudioModel

    static let sidebarWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                StudioCanvas(model: model)
                Divider()
                StudioSidebar(model: model)
                    .frame(width: Self.sidebarWidth)
                    .background(.background)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))

            Spacer()
            Picker("Tool", selection: $model.tab) {
                ForEach(StudioModel.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()

            CompareButton(model: model)
            Button("Revert All", action: model.revertAll)
                .disabled(model.edit.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.files.count > 1 {
                HStack(spacing: 4) {
                    Button { model.index -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(model.index == 0)
                    Text("\(model.index + 1) of \(model.files.count)")
                        .monospacedDigit()
                        .frame(minWidth: 52)
                    Button { model.index += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(model.index == model.files.count - 1)
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.file.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeLine)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let error = model.renderError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Picker("Save as", selection: Binding(get: { model.format }, set: { model.setFormat($0) })) {
                Text("Automatic (\(model.automaticFormat.title))").tag(OutputFormat?.none)
                Divider()
                ForEach([OutputFormat.jpeg, .png, .heic, .tiff], id: \.self) { format in
                    Text(format.title).tag(Optional(format))
                }
            }
            .fixedSize()
            .help("JPEG has no see-through parts: they become white.")
            Button("Cancel", action: model.cancel)
                .keyboardShortcut(.cancelAction)
            Button(model.files.count > 1 ? "Save \(model.files.count) Copies" : "Save Copy", action: model.save)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .help(model.files.count > 1 ? "Applies the same edit to every picture and saves each next to its original." : "Saves a new file next to the original.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// "4032 × 3024 → 1080 × 1080 px"
    private var sizeLine: String {
        let original = model.originalSize
        let result = model.finalSize
        guard original.width > 0 else { return " " }
        if original == result { return "\(original.width) × \(original.height) px" }
        return "\(original.width) × \(original.height) → \(result.width) × \(result.height) px"
    }
}

/// Shows the original picture while it's held down.
private struct CompareButton: View {
    var model: StudioModel

    var body: some View {
        Label("Compare", systemImage: model.showOriginal ? "eye.fill" : "eye")
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.showOriginal ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
            )
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 50) {
            } onPressingChanged: { pressing in
                model.showOriginal = pressing
            }
            .help("Hold to see the original (or hold Space)")
    }
}

/// The image editor's window. Holding Space shows the original, as the
/// Compare button does (but not while typing, where Space is a space).
final class StudioWindowController: EditorWindowController {
    let model: StudioModel
    private var keyMonitor: Any?

    init(model: StudioModel) {
        self.model = model
        let title = model.files.count == 1 ? "Edit \(model.files[0].url.lastPathComponent)" : "Edit \(model.files.count) Pictures"
        super.init(
            title: title, size: NSSize(width: 1120, height: 760),
            undoManager: model.undoManager, content: StudioView(model: model)
        )
        model.onClose = { [weak self] in self?.window?.close() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.handleSpace(event) else { return event }
            return nil
        }
        onClose = { [weak self] in self?.stopWatchingKeys() }
    }

    /// True when the key was Space for comparing (and so is used up).
    func handleSpace(_ event: NSEvent) -> Bool {
        guard let window, event.windowNumber == window.windowNumber, event.keyCode == 49,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(window.firstResponder is NSText) else { return false }
        if event.type == .keyDown {
            if !event.isARepeat { model.showOriginal = true }
        } else {
            model.showOriginal = false
        }
        return true
    }

    /// Letting go of Space in another window must not leave the original showing.
    @objc func windowDidResignKey(_ notification: Notification) {
        model.showOriginal = false
    }

    private func stopWatchingKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
