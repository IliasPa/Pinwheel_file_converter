import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// The Settings window's own bits of state. (Kept outside the view because
/// SwiftUI's @State is a macro whose plugin only ships with Xcode.)
@Observable
final class SettingsViewState {
    var pane: SettingsPane? = .general
    /// What's typed in the sidebar's search field.
    var search = ""
    var confirmReset = false
    let preview = WheelModel.sample()
    @ObservationIgnored let soundPreview = HoverFeedback()
    /// False while the window is hidden behind others or minimized.
    var isWindowVisible = true
    var isPointerOverPreview = false
    /// Goes up each time the pointer moves onto the preview.
    var previewVisits = 0
    /// The custom action being made or changed.
    var recipeDraft: RecipeDraft?
    let languageDownload = LanguageDownload()
    /// The box of the compatibility table under the pointer.
    var tableSpot: CompatibilityPane.Spot?
    let shortcutRecorder = ShortcutRecorder()
    /// The screenshot shortcut being recorded.
    var recordingScreenshot: ScreenshotMode?
    var confirmClearClipboard = false
    /// The kind of file Wheels and Compatibility show (one at a time: all of
    /// them at once made those pages slow to open).
    var settingsKind: FileKind = .image
    /// Which wheel's settings the Wheels page shows.
    var wheelPage: WheelMode = .convert

    /// Searching for a tool ("crop") or a file action ("airdrop") shows its
    /// wheel on the Wheels page, and a format its formats.
    func showWheel(for search: String) {
        let word = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.count >= 2 else { return }
        if let mode = WheelMode.allCases.first(where: { SettingsPane.keywords(for: $0).contains { $0.lowercased().contains(word) } }) {
            wheelPage = mode
        }
    }

    /// Searching for a format ("webm", "mp3") or a kind ("spread…") shows
    /// that kind on Wheels and Compatibility.
    func showKind(for search: String) {
        let word = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.count >= 2 else { return }
        let kind = Compatibility.sources.first { $0.title.lowercased() == word }?.kind
            ?? FileKind.allCases.first { $0.pluralTitle.lowercased().hasPrefix(word) }
            ?? FileKind.allCases.first { kind in
                FormatCatalog.choices(for: kind, mode: .convert).contains { $0.title(in: .convert).lowercased() == word }
            }
        if let kind { settingsKind = kind }
    }
}

/// Takes the next keys pressed as a new shortcut (Esc gives up).
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    /// Why the keys pressed can't be used.
    private(set) var message: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onRecording: (Bool) -> Void = { _ in }

    func start(onRecorded: @escaping (KeyShortcut) -> Void, onRecording: @escaping (Bool) -> Void) {
        stop()
        isRecording = true
        message = nil
        self.onRecording = onRecording
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {  // Esc
                self.stop()
                return nil
            }
            guard let shortcut = KeyShortcut(event: event) else { return nil }
            if !shortcut.isUsable {
                self.message = "Add ⌘, ⌥ or ⌃, so typing \(shortcut.title) still types."
            } else if shortcut.isReserved {
                self.message = "\(shortcut.title) is used by every app. Try other keys."
            } else {
                self.stop()
                onRecorded(shortcut)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { onRecording(false) }
        isRecording = false
    }
}

/// The pages of the Settings window, in the sidebar's order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, wheel, compatibility, clipboard, screenshots, hotCorners, textRecognition, finderAndShortcuts, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .wheel: "Wheels"
        case .compatibility: "Compatibility"
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .hotCorners: "Hot Corners"
        case .textRecognition: "Text Recognition"
        case .finderAndShortcuts: "Finder & Shortcuts"
        case .advanced: "Advanced"
        }
    }

    /// The sidebar's icon: an SF Symbol, or (Wheels) the menu-bar icon.
    var symbolName: String? {
        switch self {
        case .general: "gearshape"
        case .wheel: nil
        case .compatibility: "tablecells"
        case .clipboard: "list.clipboard"
        case .screenshots: "camera.viewfinder"
        case .hotCorners: "rectangle.inset.topleft.filled"
        case .textRecognition: "text.viewfinder"
        case .finderAndShortcuts: "contextualmenu.and.cursorarrow"
        case .advanced: "gearshape.2"
        }
    }

    /// The tile behind the sidebar icon, as in System Settings.
    var color: Color {
        switch self {
        case .general, .advanced: .gray
        case .wheel: Brand.indigo
        case .compatibility: Brand.teal
        case .clipboard: .pink
        case .screenshots: .blue
        case .hotCorners: .orange
        case .textRecognition: .purple
        case .finderAndShortcuts: .green
        }
    }

    /// Words that find a wheel's settings on the Wheels page.
    static func keywords(for mode: WheelMode) -> [String] {
        switch mode {
        case .convert:
            return OutputFormat.allCases.map(\.title)
                + ["jpg", "formats", "conversions", "convert", "quality", "collage", "combined", "smaller pdf", "dpi", "resolution",
                   "frame rate", "width", "length", "word", "excel", "powerpoint", "keynote", "numbers", "documents",
                   "spreadsheets", "slides", "subtitles", "editable", "pages as pictures", "background", "see-through",
                   "transparent", "subtitle times"]
        case .tools:
            return ToolAction.allCases.map(\.title) + Editor.allCases.map(\.title)
                + ["tools", "bit rate", "video size", "custom actions", "qr", "barcode", "shelf", "visualizer", "waveform", "faces",
                   "blur", "redact", "bleep", "split", "crop video", "mono", "stereo", "channels"]
        case .actions:
            return FileAction.allCases.map(\.title) + ["file actions", "path", "iterm"]
        }
    }

    /// Words that find the page from the sidebar's search field, besides its title.
    private var keywords: [String] {
        let formats = OutputFormat.allCases.map(\.title) + ["jpg"]
        switch self {
        case .general:
            return ["permission", "accessibility", "progress window", "show in finder", "notify", "notification",
                    "trash", "original", "save", "folder", "downloads", "login", "startup", "glass", "appearance", "frosted",
                    "crystal", "preview", "show on desktop", "sound", "click", "volume", "vibration", "haptic", "trackpad", "tap"]
        case .wheel:
            return ["keys", "shortcut", "modifier", "shift", "option", "control", "command", "keyboard", "arrow", "let go", "keep open"]
                + WheelMode.allCases.flatMap(Self.keywords(for:))
        case .compatibility:
            return formats + Compatibility.sources.map(\.title) + ["table", "formats", "supported", "from", "word", "excel",
                                                                     "powerpoint", "keynote", "numbers", "subtitles"]
        case .clipboard:
            return ["clipboard", "history", "paste", "copy", "copied", "favorites", "heart", "shortcut", "keys", "pasta", "beta", "preview", "drag", "plain text", "links", "tracking", "buttons", "collections"]
        case .screenshots:
            return ["screenshot", "screenshots", "capture", "screen", "area", "window", "pin", "ruler", "measure", "spotlight", "blur", "color picker", "eyedropper", "shottr", "annotate", "markup", "arrow", "delay", "timer", "screen recording"]
        case .hotCorners:
            return ["hot corner", "corners", "launch an app", "pointer", "mouse", "cursor"]
        case .textRecognition:
            return ["ocr", "get text", "searchable", "tesseract", "greek", "language", "apple"]
        case .finderAndShortcuts:
            return ["services", "right-click", "quick action", "command", "terminal", "shell", "pinwheel"]
        case .advanced:
            return ["same time", "files at once", "speed", "ffmpeg", "pngquant", "cwebp", "webp", "homebrew", "brew", "reset", "defaults"]
        }
    }

    func matches(_ search: String) -> Bool {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let haystack = ([title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy(haystack.contains)
    }
}

/// Gets a language file for Tesseract (Greek) from the Tesseract project.
@Observable
final class LanguageDownload {
    enum State: Equatable {
        case idle, downloading
        case failed(String)
    }

    private(set) var state = State.idle

    func download(_ code: String, settings: SettingsStore) {
        guard state != .downloading else { return }
        state = .downloading
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: TesseractData.downloadURL(for: code))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ConversionError.failed("The language file isn't available right now. Try again later.")
                }
                try TesseractData.install(file, code: code, linking: settings.tesseractURL.map(TesseractData.builtInFolder))
                settings.languagesChanged += 1
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var launch: LaunchAtLogin
    var permission: AccessibilityPermission
    @Bindable var state: SettingsViewState
    var onShowDemo: () -> Void
    var onShowFFmpegHelp: () -> Void
    /// The clipboard history, for its page.
    var clipboard: ClipboardController? = nil
    /// The screenshot shortcuts, for their page.
    var screenshots: ScreenshotController? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            let pane = state.pane ?? .general
            page(pane)
                .formStyle(.grouped)
                .navigationTitle(pane.title)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 480, idealHeight: 680)
        .onAppear {
            launch.refresh()
            permission.refresh()
        }
        .sheet(item: $state.recipeDraft) { draft in
            RecipeEditor(draft: draft) { recipe in
                settings.saveRecipe(recipe)
                state.recipeDraft = nil
            } onCancel: {
                state.recipeDraft = nil
            }
        }
        .alert("Clear the clipboard history?", isPresented: $state.confirmClearClipboard) {
            Button("Clear", role: .destructive) { clipboard?.store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every copy is removed from Pinwheel's history, except your favorites and the copies in your collections. What's on the clipboard now stays.")
        }
        .onDisappear { state.shortcutRecorder.stop() }
        .alert("Reset the permission?", isPresented: $state.confirmReset) {
            Button("Reset", role: .destructive) { permission.resetAndAskAgain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinwheel's entry is removed from the Accessibility list and macOS asks again. Then switch Pinwheel on once more.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let panes = SettingsPane.allCases.filter { $0.matches(state.search) }
        return List(panes, selection: $state.pane) { pane in
            HStack {
                Label {
                    Text(pane.title)
                } icon: {
                    Group {
                        if let symbol = pane.symbolName {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                        } else {
                            Image(nsImage: StatusIcon.make())
                                .renderingMode(.template)
                                .resizable()
                                .frame(width: 15, height: 15)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(pane.color.gradient))
                }
                if pane == .general && !permission.isTrusted {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .help("Accessibility permission needed")
                }
            }
        }
        // In a window of our own the column width isn't passed on to the
        // split view (it stays at 140 points), so the list asks for room itself.
        .frame(minWidth: 200)
        .navigationSplitViewColumnWidth(210)
        .overlay {
            if panes.isEmpty {
                Text("No results").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.search, placement: .sidebar, prompt: "Search")
        .onChange(of: state.search) {
            state.showKind(for: state.search)
            state.showWheel(for: state.search)
        }
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private func page(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            Form {
                permissionSection
                afterConverting
                saving
                appearance
                feedback
                startup
            }
        case .wheel:
            wheels
        case .compatibility:
            CompatibilityPane(settings: settings, state: state)
        case .clipboard:
            Form { clipboardSection }
        case .screenshots:
            Form { screenshotsSection }
        case .hotCorners:
            Form { hotCornersSection }
        case .textRecognition:
            Form { textRecognition }
        case .finderAndShortcuts:
            Form { finderAndShortcuts }
        case .advanced:
            Form {
                performance
                helperTools
                reset
            }
        }
    }

    // MARK: - General

    /// Status, explanation and steps for the Accessibility permission, all in
    /// one place. It updates by itself the moment the switch is flipped.
    private var permissionSection: some View {
        Section("Permission") {
            HStack(spacing: 12) {
                Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(permission.isTrusted ? .green : .orange)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.isTrusted ? "Accessibility is on" : "Accessibility permission needed")
                        .font(.headline)
                    Text(permission.isTrusted
                         ? "Hold \(settings.wheelKeys[.convert].title) while dragging files and the wheel appears."
                         : "Without it, the wheel can't appear.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !permission.isTrusted {
                    Button("Open System Settings") { permission.openSystemSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .animation(.spring(duration: 0.4), value: permission.isTrusted)

            if !permission.isTrusted {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To know when to show the wheel, Pinwheel notices the Shift key and the mouse while you drag in Finder. It never records what you type, and nothing leaves your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    step(1, "Click **Open System Settings**.")
                    step(2, "Find **Pinwheel** in the list and turn its switch **on**. macOS may ask for your password or Touch ID.")
                    step(3, "Not in the list? Click **+**, open **Applications**, choose **Pinwheel**, and click **Open**.")
                    step(4, "Come back here. This section turns green by itself.")
                }
                .padding(.vertical, 4)
            }

            HStack {
                Text("Switch is on, but the wheel doesn't appear?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Permission…") { state.confirmReset = true }
            }
            if let message = permission.resetMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var afterConverting: some View {
        Section {
            Toggle("Show the progress window", isOn: $settings.showProgressWindow)
            Toggle("Show the new files in Finder", isOn: $settings.revealInFinder)
            Toggle("Notify me when a long conversion finishes, or something isn't saved", isOn: $settings.notifyWhenDone)
            Toggle("Move the original to the Trash", isOn: $settings.moveOriginalToTrash)
        } header: {
            Text("After converting")
        } footer: {
            Footnote("You're notified when a conversion took 10 seconds or more, and whenever a file couldn't be saved or there was nothing to do (with the reason). The original goes to the Trash only after the new file is saved; you can put it back from the Trash.")
        }
    }

    private var saving: some View {
        Section {
            Picker("Save new files", selection: $settings.saveLocation) {
                ForEach(SaveLocationChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if settings.saveLocation == .custom {
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.customFolderPath.isEmpty ? "None chosen" : settings.customFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
        } header: {
            Text("Saving")
        } footer: {
            Footnote("If that place can't be written to (a disk image, a read-only shared drive), files go to Downloads instead and the progress window says so.")
        }
    }

    private var startup: some View {
        Section("Startup") {
            Toggle("Open Pinwheel when you log in", isOn: Binding(
                get: { launch.isEnabled || launch.needsApproval },
                set: { launch.setEnabled($0) }
            ))
            if launch.needsApproval {
                HStack {
                    Text("macOS needs you to allow Pinwheel in Login Items.")
                        .font(.caption)
                    Spacer()
                    Button("Open Login Items") { launch.openLoginItemsSettings() }
                }
            }
            if let error = launch.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        let recorder = state.shortcutRecorder
        let count = clipboard?.store.items.count ?? 0
        return Section {
            Toggle("Keep a clipboard history", isOn: $settings.clipboardEnabled)
            LabeledContent("Open it with") {
                HStack(spacing: 8) {
                    Button {
                        if recorder.isRecording {
                            recorder.stop()
                        } else {
                            recorder.start { settings.clipboardShortcut = $0 } onRecording: { clipboard?.suspendShortcut($0) }
                        }
                    } label: {
                        Text(recorder.isRecording ? "Press the new keys…" : settings.clipboardShortcut.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(minWidth: 130)
                    }
                    .help(recorder.isRecording ? "Press the keys to use, or Esc to keep the ones you have" : "Click, then press the keys you'd like")
                    if settings.clipboardShortcut != .clipboard && !recorder.isRecording {
                        Button("Use \(KeyShortcut.clipboard.title)") { settings.clipboardShortcut = .clipboard }
                    }
                }
            }
            .disabled(!settings.clipboardEnabled)
            if let message = recorder.message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            if let problem = clipboard?.model.shortcutProblem, settings.clipboardEnabled {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            Picker("When you choose a copy", selection: $settings.clipboardPastes) {
                Text("Paste it where you're typing").tag(true)
                Text("Just copy it").tag(false)
            }
            .disabled(!settings.clipboardEnabled)
            if settings.clipboardPastes && settings.clipboardEnabled && !permission.isTrusted {
                Text("Pasting needs the Accessibility permission (General); until then, choosing a copy only copies it.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Picker("Preview a copy with", selection: $settings.clipboardPreview) {
                ForEach(ClipPreviewTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!settings.clipboardEnabled)
            Toggle("Quick buttons", isOn: $settings.clipboardActions)
                .disabled(!settings.clipboardEnabled)
            Picker("Keep the last", selection: $settings.clipboardLimit) {
                ForEach(SettingsStore.clipboardLimits, id: \.self) { limit in
                    Text("\(limit) copies · \(clipboard?.store.estimate(copies: limit) ?? "")").tag(limit)
                }
            }
            .disabled(!settings.clipboardEnabled)
            HStack {
                Button("Show Clipboard History") { clipboard?.show() }
                    .disabled(!settings.clipboardEnabled || clipboard == nil)
                Spacer()
                Text(clipboardUsage(count: count)).foregroundStyle(.secondary).monospacedDigit()
                Button("Clear History…") { state.confirmClearClipboard = true }
                    .disabled(count == 0)
            }
            Label("Password and encryption features will come in a future update.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            HStack(spacing: 6) {
                Text("Clipboard history")
                Text("BETA")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .foregroundStyle(Color.accentColor)
            }
        } footer: {
            Footnote("Press \(settings.clipboardShortcut.title) in any app to see what you copied, by app and by kind (text, links, images, files). Click one, or press Return, and it's pasted where you were typing (or just copied); drag one into any app to drop it there. Press and hold one, or press Space, to see all of it (Space types a space while you search). The quick buttons under a copy paste it changed: as plain text, with clean links (no tracking), on one line, with tidy spaces, in other capitals, the text or QR code in a picture, a file's path or name. A heart keeps a copy for good, and so do your own collections (drag a copy onto one, or right-click it); the rest go after the number above. The sizes are worked out from your copies so far: screenshots take far more room than text. Kept only on this Mac; passwords and anything else apps mark as private are never kept.")
        }
    }

    /// "12 copies · 3.2 MB"
    private func clipboardUsage(count: Int) -> String {
        let copies = count == 1 ? "1 copy" : "\(count) copies"
        return count == 0 ? "No copies kept" : "\(copies) · \(ClipboardStore.size(clipboard?.store.totalBytes ?? 0))"
    }

    // MARK: - Wheels

    /// Formats, Tools and File actions on one page: the wheels and their keys
    /// stay at the top while it scrolls, and clicking a wheel shows its settings.
    private var wheels: some View {
        Group {
            switch state.wheelPage {
            case .convert:
                ConversionsPane(settings: settings, state: state)
            case .tools:
                Form { toolsWheel }
            case .actions:
                Form { fileActionsWheel }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { wheelBar }
    }

    /// Each wheel with its keys, side by side, and what letting go of them does.
    private var wheelBar: some View {
        let clashes = settings.wheelKeys.clashes
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(WheelMode.allCases, id: \.self) { mode in
                    wheelCard(mode, clash: clashes.contains(mode))
                }
            }
            HStack(spacing: 12) {
                Text("Hold a wheel's keys while dragging files. Click a wheel for its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("When you let go of the keys", selection: $settings.keepWheelOpen) {
                    Text("Close the wheel").tag(false)
                    Text("Keep it open until you drop").tag(true)
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A wheel: its name (click to see its settings) and its keys.
    private func wheelCard(_ mode: WheelMode, clash: Bool) -> some View {
        let isOn = state.wheelPage == mode
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: mode.wheelSymbol).font(.system(size: 11, weight: .semibold))
                Text(mode.wheelTitle).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if clash {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Same keys as another wheel")
                }
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            HStack(spacing: 3) {
                ForEach(ModifierKeys.each, id: \.rawValue) { key in
                    keyToggle(key, for: mode)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045)))
        .overlay(shape.strokeBorder(isOn ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: isOn ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture { state.wheelPage = mode }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mode.wheelTitle) wheel")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { state.wheelPage = mode }
    }

    /// One key of a wheel's combination, as a keycap: filled when it's part
    /// of it (a wheel keeps at least one).
    private func keyToggle(_ key: ModifierKeys, for mode: WheelMode) -> some View {
        let keys = settings.wheelKeys[mode]
        let isOn = keys.contains(key)
        return Button {
            var updated = keys
            if isOn { updated.remove(key) } else { updated.insert(key) }
            if !updated.isEmpty { settings.wheelKeys[mode] = updated }
        } label: {
            Text(key.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: 30, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key.name)
        .accessibilityLabel(key.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - The wheel's look and feel (General)

    private var appearance: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Glass")
                    Spacer()
                    Text("\(settings.glassLevel.rawValue) of 5 · \(settings.glassLevel.title)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    Text("Frosted").font(.caption).foregroundStyle(.secondary)
                    Slider(value: glassBinding, in: 1...5, step: 1)
                    Text("Crystal").font(.caption).foregroundStyle(.secondary)
                }
                Text(settings.glassLevel.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                GlassPreview(settings: settings, state: state)
                HStack {
                    Button("Show on Desktop", action: onShowDemo)
                    Text("Shows the real wheel over your desktop for 3 seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var feedback: some View {
        Section {
            Toggle("Click sound", isOn: $settings.hoverSound)
            Picker("Sound", selection: $settings.hoverSoundName) {
                ForEach(HoverFeedback.soundNames, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!settings.hoverSound)
            .onChange(of: settings.hoverSoundName) { playSample() }
            LabeledContent("Volume") {
                HStack {
                    Slider(value: $settings.hoverSoundVolume, in: 0.05...1) { editing in
                        if !editing { playSample() }
                    }
                    .frame(width: 200)
                    Button("Test", action: playSample)
                }
            }
            .disabled(!settings.hoverSound)
            Picker("Trackpad vibration", selection: $settings.vibration) {
                ForEach(Vibration.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.vibration) { state.soundPreview.vibrate(settings.vibration) }
        } header: {
            Text("Wheel feedback")
        } footer: {
            Footnote("Plays when the pointer moves onto a format. Low is a light tap, High a firm one. Vibration needs a Force Touch trackpad and is felt only while your finger is on it.")
        }
    }

    // MARK: - Tools

    /// The tools wheel for one kind of file (chosen at the top): which tools
    /// it shows, and the custom actions made for it.
    private var toolsWheel: some View {
        let kind = state.settingsKind
        let options = settings.conversionOptions
        let actions = FormatCatalog.actions(for: kind, mode: .tools)
        let custom = settings.recipes.filter { $0.kind == kind }
        let shown = settings.shownCount(for: kind)
        return Group {
            Section {
                Text("Choose which tools the tools wheel shows for each kind of file. Tools with \u{201C}…\u{201D} open a window to choose the details first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                KindPicker(state: state, kinds: FileKind.allCases)
            }
            Section {
                ForEach(actions.map { KindAction(kind: kind, action: $0) }, id: \.self) { row in
                    let action = row.action
                    let isOn = settings.isOnWheel(action, for: kind)
                    Toggle(isOn: Binding(get: { isOn }, set: { settings.setOnWheel(action, for: kind, $0) })) {
                        Label(action.title(in: .tools, options: options), systemImage: action.symbolName(in: .tools))
                    }
                    .help(action.detail(for: kind, options: options))
                    .disabled(!isOn && shown >= FormatCatalog.maxWedges)
                    toolOptions(for: action, kind: kind)
                }
                ForEach(custom) { recipe in
                    let action = WheelAction.recipe(recipe)
                    let isOn = settings.isOnWheel(action, for: kind)
                    HStack {
                        Toggle(isOn: Binding(get: { isOn }, set: { settings.setOnWheel(action, for: kind, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Label(recipe.name, systemImage: recipe.symbol)
                                Text(recipe.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .disabled(!isOn && shown >= FormatCatalog.maxWedges)
                        Button("Edit…") {
                            state.recipeDraft = RecipeDraft(recipe, isNew: false, lastWatermark: settings.lastWatermark)
                        }
                        Button(role: .destructive) { settings.deleteRecipe(recipe) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this custom action")
                    }
                }
                if !RecipeStep.templates(for: kind).isEmpty {
                    HStack {
                        Button("New Custom Action…") {
                            let recipe = Recipe(name: "", kind: kind)
                            state.recipeDraft = RecipeDraft(recipe, isNew: true, lastWatermark: settings.lastWatermark)
                        }
                        Text("Several steps in one wedge, in the order you choose.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Label(kind.pluralTitle, systemImage: kind.symbolName)
                    Spacer()
                    Text("\(min(shown, FormatCatalog.maxWedges)) of \(actions.count + custom.count) on the wheel")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } footer: {
                Footnote(toolsFooter(kind))
            }
        }
    }

    /// The settings that belong to a tool, set in under its switch, as for
    /// formats. Custom actions and Size Limit's first try use them too.
    @ViewBuilder
    private func toolOptions(for action: WheelAction, kind: FileKind) -> some View {
        switch (kind, action) {
        case (.image, .tool(.compress)), (.pdf, .tool(.compress)):
            PercentSlider("Picture quality", value: $settings.compressQuality, range: 0.3...0.9, indented: true)
        case (.image, .tool(.resize)):
            Picker(selection: $settings.resize) {
                ForEach(ResizeOption.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Size").padding(.leading, SettingsLayout.indent)
            }
        case (.video, .tool(.compress)):
            Picker(selection: $settings.videoQuality) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Video quality").padding(.leading, SettingsLayout.indent)
            }
            Picker(selection: $settings.videoMaxSize) {
                ForEach(VideoMaxSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Video size").padding(.leading, SettingsLayout.indent)
            }
        case (.audio, .tool(.compress)):
            Picker(selection: $settings.audioBitRate) {
                ForEach([96, 128, 160, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
            } label: {
                Text("Bit rate").padding(.leading, SettingsLayout.indent)
            }
        default:
            EmptyView()
        }
    }

    private func toolsFooter(_ kind: FileKind) -> String {
        let compress: String
        switch kind {
        case .image:
            compress = settings.pngquantURL == nil
                ? "Compress keeps JPEG, HEIC and PNG in their format, and a result that isn't smaller is thrown away; for much smaller PNGs, install pngquant: brew install pngquant. "
                : "Compress keeps JPEG, HEIC and PNG in their format (PNGs are shrunk with pngquant), and a result that isn't smaller is thrown away. "
        case .video, .audio:
            compress = "Compress never gives a higher bit rate than the original's, and a result that isn't smaller is thrown away. "
        case .pdf:
            compress = "Compress shrinks the pictures inside, at the picture quality set for pictures too. "
        default:
            compress = ""
        }
        return compress + "The wheel holds up to \(FormatCatalog.maxWedges) tools, so switch one off to make room for another. Custom actions do several steps one after the other, e.g. crop 4:5, fit 1080 px, add a watermark and save as JPEG."
    }

    /// The file actions wheel: the same for any files and folders.
    private var fileActionsWheel: some View {
        let shown = settings.shownCount(for: .image, in: .actions)
        return Section {
            ForEach(FormatCatalog.fileActions, id: \.self) { action in
                let isOn = settings.isOnWheel(action, for: .image, in: .actions)
                Toggle(isOn: Binding(get: { isOn }, set: { settings.setOnWheel(action, for: .image, in: .actions, $0) })) {
                    Label(action.title(in: .actions), systemImage: action.symbolName(in: .actions))
                    Text(action.detail(for: nil))
                }
                .disabled(isOn && shown == 1)
                if action == .file(.terminal) {
                    Picker(selection: $settings.terminalApp) {
                        ForEach(TerminalApp.installed, id: \.self) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Text("Opens in").padding(.leading, SettingsLayout.indent)
                    }
                }
            }
        } header: {
            Text("For any files and folders")
        } footer: {
            Footnote("Also for ones Pinwheel can't convert. Move To… can be undone from the menu bar; ZIP makes one .zip of everything dropped, without the Mac's hidden extras.")
        }
    }

    // MARK: - Screenshots

    private var screenshotsSection: some View {
        let recorder = state.shortcutRecorder
        let allowed = ScreenshotController.hasPermission
        return Group {
            Section {
                Toggle("Take screenshots with shortcuts", isOn: $settings.screenshotsEnabled)
                HStack(spacing: 12) {
                    Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(allowed ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(allowed ? "Screen Recording is on" : "Screen Recording permission needed")
                            .font(.headline)
                        Text(allowed
                             ? "Pinwheel can take pictures of your screen. Nothing leaves your Mac."
                             : "macOS asks before an app may see the screen. Click Allow, switch Pinwheel on in the list, then quit and open Pinwheel again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !allowed {
                        Button("Allow…") {
                            CGRequestScreenCaptureAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                Footnote("Or use the menu-bar icon › Screenshot. Your last screenshots are in the menu-bar icon › Screenshot History and under the clipboard history. A picture is saved as a PNG, then opened in the editor (the same one the ⌥⇧ wheel opens on any picture), pinned on the screen, or left alone: you choose below.")
            }

            Section {
                ForEach(ScreenshotMode.allCases) { mode in
                    let shortcut = settings.screenshotShortcuts[mode] ?? mode.defaultShortcut
                    let isRecording = recorder.isRecording && state.recordingScreenshot == mode
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button {
                                if isRecording {
                                    recorder.stop()
                                } else {
                                    recorder.start { settings.screenshotShortcuts[mode] = $0 } onRecording: { recording in
                                        state.recordingScreenshot = recording ? mode : nil
                                        screenshots?.suspendShortcuts(recording)
                                    }
                                }
                            } label: {
                                Text(isRecording ? "Press the new keys…" : shortcut.title)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .frame(minWidth: 120)
                            }
                            if shortcut != mode.defaultShortcut && !isRecording {
                                Button("Use \(mode.defaultShortcut.title)") { settings.screenshotShortcuts[mode] = mode.defaultShortcut }
                            }
                        }
                    } label: {
                        Label(mode.title, systemImage: mode.symbolName)
                    }
                    if let problem = screenshots?.problems[mode], settings.screenshotsEnabled {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    }
                }
                if let message = recorder.message, state.recordingScreenshot != nil {
                    Text(message).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Footnote("Capturing an area: drag a box (Esc gives up). The same area again repeats the last box without dragging. Copy the text or code in an area reads the words in the box, and any QR code or barcode, and copies them: no picture is saved. Files are named after the app in front and the time, like Safari_20261123_1430. Full Retina resolution off saves the picture at the size you see on screen (half the width and height on a Retina Mac). A scrolling area: drag a box over what scrolls (a web page, a chat), then scroll it yourself, slowly, from top to bottom; press the shortcut again (or Done) and the pictures are joined into one tall one. Scroll down only; bars that stay put, like a website's header, are kept once. macOS keeps ⇧⌘3, ⇧⌘4 and ⇧⌘5 for its own screenshots, so these use ⌥⌘.")
            }
            .disabled(!settings.screenshotsEnabled)

            Section {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(ScreenshotFormat.allCases) { format in
                        screenshotFormatCard(format)
                    }
                }
                let chosen = settings.screenshotFormat
                VStack(alignment: .leading, spacing: 6) {
                    Label { Text("**Best for:** \(chosen.bestFor)") } icon: { Image(systemName: "hand.thumbsup") }
                    Label { Text("**Watch out:** \(chosen.watchOut)") } icon: { Image(systemName: "exclamationmark.triangle") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Save as")
            } footer: {
                Footnote("Not sure? Keep PNG: it never loses anything, and you can make a smaller JPEG or HEIC later from the wheel (hold ⇧ while dragging the file). JPEG and HEIC use the quality set in Wheels. Text read from an area (OCR) is copied, never saved as a picture.")
            }
            .disabled(!settings.screenshotsEnabled)

            Section {
                Picker("After a screenshot", selection: $settings.screenshotAfter) {
                    ForEach(ScreenshotAfter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Also copy it, to paste anywhere", isOn: $settings.screenshotCopy)
                Picker("Wait before taking it", selection: $settings.screenshotDelay) {
                    ForEach(SettingsStore.screenshotDelays, id: \.self) { Text($0 == 0 ? "No wait" : "\($0) seconds").tag($0) }
                }
                Toggle("Keep a window's shadow", isOn: $settings.screenshotWindowShadow)
                Toggle("Show the mouse pointer", isOn: $settings.screenshotCursor)
                Toggle("Full Retina resolution", isOn: $settings.screenshotFullResolution)
                LabeledContent("Save them in") {
                    HStack(spacing: 8) {
                        Text(settings.screenshotFolder.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseScreenshotFolder() }
                        if !settings.screenshotFolderPath.isEmpty {
                            Button("Default") { settings.screenshotFolderPath = "" }
                        }
                    }
                }
            } header: {
                Text("After capturing")
            } footer: {
                Footnote("The screen is frozen the moment you press the shortcut, so what you select is what was there (with a timer set, the picture is taken when it runs out instead). Saving in the editor makes a new picture next to the screenshot; the screenshot itself is never changed. A pinned picture floats above every window: drag it, scroll to resize it, double-click or press Esc to close it, right-click for more.")
            }
            .disabled(!settings.screenshotsEnabled)

            Section {
                ForEach(Self.screenshotTools, id: \.0) { tool in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.0)
                            Text(tool.2).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: tool.1)
                    }
                }
            } header: {
                Text("In the editor")
            } footer: {
                Footnote("These are the editor's Markup tools. They're the same for screenshots and for any picture you edit from the wheel (hold ⌥⇧ while dragging it, then choose Markup).")
            }
        }
    }

    /// One format: its name and a few words, click to choose.
    private func screenshotFormatCard(_ format: ScreenshotFormat) -> some View {
        let isOn = settings.screenshotFormat == format
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { settings.screenshotFormat = format } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(format.title).font(.system(size: 14, weight: .bold))
                    if format == .png {
                        Text("Recommended").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                Text(format.tagline).font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(isOn ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: isOn ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private static let screenshotTools: [(String, String, String)] = [
        ("Arrows, Lines, Boxes, Ovals", "arrow.up.right", "Arrow, two-way arrow, line, dashed line, box, rounded box, filled box, oval, check mark and cross"),
        ("One slider for size or strength", "slider.horizontal.3", "Thickness for shapes and text, with notches at Small, Medium and Large; strength for blur, blocks and dimming"),
        ("Pen and Highlight", "highlighter", "Draw freely, or mark text"),
        ("Text and Numbers", "textformat", "Notes, and numbered steps 1, 2, 3…"),
        ("Blur", "eye.slash", "Hide private details, in blocks or smoothly; switches blur faces, e-mail addresses, numbers or all text by themselves"),
        ("Spotlight", "rays", "Dim everything except what matters"),
        ("Measure", "ruler", "A ruler that snaps to edges and says how many pixels it spans. Click to measure the space around a point"),
        ("Pixel Zoom", "plus.magnifyingglass", "A magnifier that shows each pixel and its color; click to copy its code"),
        ("Color picker and contrast", "eyedropper", "macOS's own picker, and a check of how readable a text color is on its background"),
        ("Copy", "doc.on.clipboard", "⇧⌘C puts the edited picture on the clipboard without saving it"),
        ("Scrolling screenshot", "arrow.up.and.down.text.horizontal", "⌥⌘8: drag a box, scroll the page yourself, press the shortcut again: one tall picture"),
        ("Text from a screenshot", "text.viewfinder", "⌥⌘7: drag over text anywhere and it's copied (see Text Recognition for Greek)"),
        ("Crop, Adjust, Background", "crop", "Crop, light and color, a backdrop with a shadow, a watermark"),
    ]

    private func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Pinwheel saves screenshots."
        if panel.runModal() == .OK, let url = panel.url {
            settings.screenshotFolderPath = url.path
        }
    }

    // MARK: - Hot corners

    private var hotCornersSection: some View {
        Group {
            Section {
                Toggle("Open an app or folder from a screen corner", isOn: $settings.hotCornersEnabled)
                Picker("Open it", selection: $settings.hotCornerDelay) {
                    ForEach(HotCornerDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!settings.hotCornersEnabled)
                Toggle("Not in games and full-screen apps", isOn: $settings.hotCornersSkipFullScreen)
                    .disabled(!settings.hotCornersEnabled)
            } footer: {
                Footnote("Move the pointer into a corner and rest it there; the app opens (or comes to the front if it's already open), or the folder opens in Finder. Move away and back to open it again. Nothing opens while a mouse button is held, so dragging files to a corner is safe. With \"Not in games and full-screen apps\" on, corners stay quiet while a game, a full-screen app or a full-screen video is in front.")
            }
            Section {
                HotCornerPicker(settings: settings)
                    .disabled(!settings.hotCornersEnabled)
            } header: {
                Text("Corners")
            } footer: {
                Footnote("Click a corner to choose any app on this Mac. A corner that's next to another display isn't a corner: the pointer goes on through it.")
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Want an action instead of an app?")
                        .font(.headline)
                    Text("Mission Control, Notification Center, Lock Screen, Launchpad, Quick Note and more are built into macOS:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    step(1, "Click **Open Desktop & Dock** below.")
                    step(2, "Scroll to the bottom and click **Hot Corners…**.")
                    step(3, "Click a corner's menu and choose the action. Click **Done**.")
                    HStack {
                        Button("Open Desktop & Dock") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Text("A corner set there and here does both.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Text recognition

    /// Which engine reads text, and Tesseract's Greek.
    private var textRecognition: some View {
        let languages = settings.tesseractLanguages
        let recognition = settings.resolvedTextRecognition
        return Section {
            Picker("Read text with", selection: $settings.textRecognition) {
                ForEach(TextRecognitionChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Tesseract") {
                if let url = settings.tesseractURL {
                    Label(url.path, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    HStack {
                        Label("Not installed (brew install tesseract)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Copy Command") { copy(ExternalTool.tesseract.installCommand) }
                    }
                }
            }
            LabeledContent("Greek") {
                HStack {
                    if languages.contains("ell") {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        switch state.languageDownload.state {
                        case .downloading:
                            ProgressView().controlSize(.small)
                            Text("Downloading…").foregroundStyle(.secondary)
                        case .idle, .failed:
                            Button("Download Greek (9 MB)") { state.languageDownload.download("ell", settings: settings) }
                                .disabled(settings.tesseractURL == nil)
                        }
                    }
                }
            }
            if case .failed(let reason) = state.languageDownload.state {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("In use") {
                Text(recognition.engine == .vision
                     ? "Apple’s text recognition"
                     : "Tesseract: " + recognition.languages.map { TextRecognition.languageNames[$0] ?? $0 }.joined(separator: " and "))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Get Text and Searchable")
        } footer: {
            Footnote("Apple’s text recognition is built in and reads English and many other languages, but not Greek. Tesseract (free, from Homebrew) reads Greek too, once its Greek file is downloaded. Automatic uses Tesseract when it can read Greek, and Apple’s otherwise; a picture is read by both, and the better reading is kept (Apple’s is far better with photos). Everything happens on this Mac.")
        }
    }

    // MARK: - Finder and Shortcuts

    /// Pinwheel without dragging: Finder's right-click menu and the command.
    private var finderAndShortcuts: some View {
        let command = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pinwheel").path
        let example = "\"\(command)\" compress \"$@\""
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("**In Finder**, right-click files, then **Services** (at the bottom of the menu): **Convert with Pinwheel**, **Pinwheel Tools** or **Rename with Pinwheel**. The wheel opens under the pointer: click a wedge, or the middle to switch between formats and tools.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Not there? Turn them on in System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            LabeledContent("Command") {
                HStack {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy") { copy(command) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("**In Shortcuts**").fixedSize(horizontal: false, vertical: true)
                step(1, "Make a new shortcut and add **Run Shell Script**.")
                step(2, "Set **Pass Input** to **as arguments**, and write the command, e.g. to compress:")
                HStack {
                    Text(example)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy") { copy(example) }
                }
                .padding(.leading, 30)
                step(3, "To have it in Finder's right-click **Quick Actions**, open the shortcut's details and switch on **Use as Quick Action**, then **Finder**.")
                Text("Other commands: convert jpg, size-limit 10MB, run \"Your Custom Action\", show… Type `pinwheel help` in Terminal (with the full path above) for all of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Without dragging")
        } footer: {
            Footnote("Jobs started from Finder or Shortcuts show in the progress window and can be undone from the menu bar, like any other.")
        }
    }

    // MARK: - Advanced

    private var performance: some View {
        Section {
            Picker("Convert at the same time", selection: $settings.maxConcurrentJobs) {
                Text("Automatic").tag(0)
                ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text($0 == 1 ? "1 file" : "\($0) files").tag($0) }
            }
        } header: {
            Text("Speed")
        } footer: {
            Footnote("Automatic converts up to \(ConcurrencyLimit.automatic.total) files at the same time on this Mac, and 2 videos (the Mac's video engines are the limit there).")
        }
    }

    private var helperTools: some View {
        Section {
            toolStatus(.ffmpeg, url: settings.ffmpegURL, missingAction: onShowFFmpegHelp)
            TextField("Custom ffmpeg location", text: $settings.ffmpegPath, prompt: Text("Automatic"))
            toolStatus(.pngquant, url: settings.pngquantURL, missingAction: nil)
            toolStatus(.cwebp, url: settings.cwebpURL, missingAction: nil)
        } header: {
            Text("Helper tools")
        } footer: {
            Footnote("Free extras from Homebrew. ffmpeg makes MP3, OGG, Opus and WMA, MKV, WebM, AVI and WMV, and GIFs of videos, and reads files macOS can't; pngquant makes much smaller PNGs; cwebp makes WebP pictures. Tesseract is in Text Recognition.")
        }
    }

    private var reset: some View {
        Section {
            HStack {
                Text("Puts every setting back as it was, apart from custom actions and rename presets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") { settings.resetToDefaults() }
            }
        }
    }

    // MARK: - Helpers

    private var glassBinding: Binding<Double> {
        Binding(
            get: { Double(settings.glassLevel.rawValue) },
            set: { settings.glassLevel = GlassLevel(rawValue: Int($0.rounded())) ?? .defaultLevel }
        )
    }

    private func playSample() {
        state.soundPreview.playSound(named: settings.hoverSoundName, volume: settings.hoverSoundVolume)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Pinwheel saves new files."
        if panel.runModal() == .OK, let url = panel.url {
            settings.customFolderPath = url.path
        }
    }

    private func toolStatus(_ tool: ExternalTool, url: URL?, missingAction: (() -> Void)?) -> some View {
        LabeledContent(tool.rawValue) {
            HStack {
                if let url {
                    Label(url.path, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label("Not installed (\(tool.installCommand))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let missingAction {
                        Button("How to Install…", action: missingAction)
                    }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The small gray text under a section.
struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A 0…1 setting as a slider, with its value in percent.
struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Set under the switch it belongs to.
    var indented = false

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, indented: Bool = false) {
        self.title = title
        _value = value
        self.range = range
        self.indented = indented
    }

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: $value, in: range, step: 0.05)
                    .frame(width: 200)
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        } label: {
            Text(title).padding(.leading, indented ? SettingsLayout.indent : 0)
        }
    }
}

enum SettingsLayout {
    /// How far a setting sits in under the switch it belongs to.
    static let indent: CGFloat = 28
}

/// A live wheel over a colorful picture, so the glass can be seen changing.
private struct GlassPreview: View {
    var settings: SettingsStore
    var state: SettingsViewState

    /// What restarts the moving highlight.
    private struct Trigger: Equatable {
        var level: GlassLevel
        var visible: Bool
        var visits: Int
    }

    var body: some View {
        ZStack {
            PreviewBackdrop()
            WheelView(model: state.preview, settings: settings, blending: .withinWindow)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onHover { hovering in
            state.isPointerOverPreview = hovering
            if hovering { state.previewVisits += 1 }
        }
        .task(id: Trigger(level: settings.glassLevel, visible: state.isWindowVisible, visits: state.previewVisits)) {
            await moveHighlight()
        }
    }

    /// Moves the highlight around so the hover effect shows too: one lap
    /// when Settings opens or the glass changes, and for as long as the
    /// pointer is over the preview. Otherwise it rests, because a moving
    /// preview keeps the processor busy.
    private func moveHighlight() async {
        guard state.isWindowVisible else { return }
        let model = state.preview
        var steps = model.items.count
        while steps > 0 || state.isPointerOverPreview {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, case .wedge(let index)? = model.hovered, !model.items.isEmpty else { return }
            model.hovered = .wedge((index + 1) % model.items.count)
            steps -= 1
        }
    }
}

/// Bright shapes and big letters for the glass to bend and blur.
private struct PreviewBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.teal, Brand.blue, Brand.indigo, Color(red: 0.85, green: 0.3, blue: 0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: 150)
                .offset(x: -170, y: -70)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.mint)
                .frame(width: 170, height: 90)
                .rotationEffect(.degrees(18))
                .offset(x: 165, y: 80)
            Capsule()
                .fill(Color.white.opacity(0.85))
                .frame(width: 520, height: 22)
                .rotationEffect(.degrees(-12))
            Text("Pinwheel")
                .font(.system(size: 72, weight: .black, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .offset(y: 110)
        }
    }
}

/// Hosts the settings in a normal window. Closing it calls `onClose`, so
/// the window (and everything drawn in it) can be let go until next time.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let state: SettingsViewState
    private let onClose: () -> Void

    init(view: SettingsView, onClose: @escaping () -> Void) {
        state = view.state
        self.onClose = onClose
        let hosting = NSHostingController(rootView: view)
        // The page's title and the sidebar's search go in the window's toolbar.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        // SwiftUI passes on later pages' titles; the first one is set here.
        window.title = view.state.pane?.title ?? "Pinwheel Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 680))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        state.isWindowVisible = window?.occlusionState.contains(.visible) ?? false
    }

    func windowWillClose(_ notification: Notification) {
        // Kept a moment in case it's opened again: its preview mustn't
        // go on animating unseen meanwhile.
        state.isWindowVisible = false
        onClose()
        MemoryRelief.soon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        state.isWindowVisible = true
    }
}

/// A picture of a screen with a button in each corner: the app it opens, or
/// "+" to choose one.
struct HotCornerPicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1.5)
            Text("Your screen: each corner opens an app or a folder")
                .font(.callout)
                .foregroundStyle(.tertiary)
            ForEach(ScreenCorner.allCases) { corner in
                chip(corner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
                    .padding(8)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func alignment(_ corner: ScreenCorner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private func chip(_ corner: ScreenCorner) -> some View {
        let app = settings.hotCornerApps[corner]
        return Menu {
            Button("Choose App…") { choose(for: corner, folder: false) }
            Button("Choose Folder…") { choose(for: corner, folder: true) }
            if app != nil {
                Button("Remove", role: .destructive) { settings.hotCornerApps[corner] = nil }
            }
        } label: {
            HStack(spacing: 6) {
                if let app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.name(of: app)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(corner.title).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text(corner.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 160, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(app == nil ? Color.clear : Color.accentColor.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(app == nil ? Color.primary.opacity(0.2) : Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: app == nil ? [4, 3] : []))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(corner.title) corner")
        .accessibilityValue(app.map(Self.name(of:)) ?? "Nothing")
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func choose(for corner: ScreenCorner, folder: Bool) {
        let panel = NSOpenPanel()
        if folder {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.message = "Choose the folder the \(corner.title.lowercased()) corner opens in Finder."
        } else {
            panel.allowedContentTypes = [.application]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.message = "Choose the app the \(corner.title.lowercased()) corner opens."
        }
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.hotCornerApps[corner] = url
        }
    }
}
