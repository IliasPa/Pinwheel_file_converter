import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// The Settings window's own bits of state. (Kept outside the view because
/// SwiftUI's @State is a macro whose plugin only ships with Xcode.)
@Observable
final class SettingsViewState {
    var confirmReset = false
    let preview = WheelModel.sample()
    @ObservationIgnored let soundPreview = HoverFeedback()
    /// False while the window is hidden behind others or minimized.
    var isWindowVisible = true
    var isPointerOverPreview = false
    /// Goes up each time the pointer moves onto the preview.
    var previewVisits = 0
}

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var launch: LaunchAtLogin
    var permission: AccessibilityPermission
    @Bindable var state: SettingsViewState
    var onShowDemo: () -> Void
    var onShowFFmpegHelp: () -> Void

    var body: some View {
        Form {
            permissionSection
            appearance
            feedback
            afterConverting
            saving
            images
            media
            system
            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 480, idealHeight: 780)
        .onAppear {
            launch.refresh()
            permission.refresh()
        }
        .alert("Reset the permission?", isPresented: $state.confirmReset) {
            Button("Reset", role: .destructive) { permission.resetAndAskAgain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinwheel's entry is removed from the Accessibility list and macOS asks again. Then switch Pinwheel on once more.")
        }
    }

    // MARK: - Sections

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
                         ? "Hold ⇧ Shift while dragging files and the wheel appears."
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
            Toggle("Trackpad vibration", isOn: $settings.hapticFeedback)
        } header: {
            Text("Wheel feedback")
        } footer: {
            footnote("Plays when the pointer moves onto a format. Vibration needs a Force Touch trackpad and is felt only while your finger is on it.")
        }
    }

    private var afterConverting: some View {
        Section {
            Toggle("Show the progress window", isOn: $settings.showProgressWindow)
            Toggle("Show the new files in Finder", isOn: $settings.revealInFinder)
            Toggle("Notify me when a long conversion finishes", isOn: $settings.notifyWhenDone)
            Toggle("Move the original to the Trash", isOn: $settings.moveOriginalToTrash)
        } header: {
            Text("After converting")
        } footer: {
            footnote("Notifications are for conversions that take 10 seconds or more. The original goes to the Trash only after the new file is saved; you can put it back from the Trash.")
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
            footnote("If that place can't be written to (a disk image, a read-only shared drive), files go to Downloads instead and the progress window says so.")
        }
    }

    private var images: some View {
        Section {
            percentSlider("JPEG quality", value: $settings.jpegQuality, range: 0.5...1)
            percentSlider("HEIC quality", value: $settings.heicQuality, range: 0.5...1)
            percentSlider("Compress quality", value: $settings.compressQuality, range: 0.3...0.9)
            Picker("Resize", selection: $settings.resize) {
                ForEach(ResizeOption.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Several images on PDF make one combined PDF", isOn: $settings.combineImagesIntoOnePDF)
            Picker("PDF pages to images", selection: $settings.pdfDPI) {
                Text("72 DPI (screen)").tag(72)
                Text("150 DPI (standard)").tag(150)
                Text("300 DPI (print)").tag(300)
            }
        } header: {
            Text("Images and PDFs")
        } footer: {
            footnote(settings.pngquantURL == nil
                     ? "Compress keeps JPEG, HEIC and PNG in their format. For much smaller PNGs, install pngquant: brew install pngquant"
                     : "Compress keeps JPEG, HEIC and PNG in their format (PNGs are shrunk with pngquant). A combined PDF has one page per image, in name order.")
        }
    }

    private var media: some View {
        Section {
            Picker("Video compress quality", selection: $settings.videoQuality) {
                ForEach(VideoQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Video compress size", selection: $settings.videoMaxSize) {
                ForEach(VideoMaxSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Audio compress bit rate", selection: $settings.audioBitRate) {
                ForEach([96, 128, 160, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
            }
            Picker("GIF width", selection: $settings.gifWidth) {
                ForEach([320, 480, 640, 800, 1080], id: \.self) { Text("\($0) pixels").tag($0) }
            }
            Picker("GIF frame rate", selection: $settings.gifFPS) {
                ForEach([10, 12, 15, 20, 24], id: \.self) { Text("\($0) frames per second").tag($0) }
            }
            Picker("GIF length", selection: $settings.gifMaxSeconds) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("First \($0) seconds").tag($0) }
                Text("Whole video").tag(0)
            }
        } header: {
            Text("Video and audio")
        } footer: {
            footnote("Compress never aims above the original's bit rate, and a result that isn't smaller is thrown away. GIFs grow fast: a long one can be hundreds of megabytes.")
        }
    }

    private var system: some View {
        Section {
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
            Picker("Convert at the same time", selection: $settings.maxConcurrentJobs) {
                Text("Automatic").tag(0)
                ForEach([1, 2, 3, 4, 6, 8], id: \.self) { Text($0 == 1 ? "1 file" : "\($0) files").tag($0) }
            }
            toolStatus("ffmpeg", url: settings.ffmpegURL, missingAction: onShowFFmpegHelp)
            TextField("Custom ffmpeg location", text: $settings.ffmpegPath, prompt: Text("Automatic"))
            toolStatus("pngquant", url: settings.pngquantURL, missingAction: nil)
        } header: {
            Text("System")
        } footer: {
            footnote("Automatic converts up to \(ConcurrencyLimit.automatic.total) files at the same time on this Mac, and 2 videos (the Mac's video engines are the limit there).")
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

    private func toolStatus(_ name: String, url: URL?, missingAction: (() -> Void)?) -> some View {
        LabeledContent(name) {
            HStack {
                if let url {
                    Label(url.path, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label("Not installed (brew install \(name))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let missingAction {
                        Button("How to Install…", action: missingAction)
                    }
                }
            }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func percentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.05)
                    .frame(width: 200)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
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
        let window = NSWindow(contentViewController: hosting)
        window.title = "Pinwheel Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 580, height: 780))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        state.isWindowVisible = window?.occlusionState.contains(.visible) ?? false
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
