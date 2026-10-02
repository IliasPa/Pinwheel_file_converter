import AppKit
import SwiftUI
import PinwheelCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launch: LaunchAtLogin
    @ObservedObject var permission: AccessibilityPermission
    var onShowDemo: () -> Void
    var onShowFFmpegHelp: () -> Void

    // Not @State: in the macOS 27 SDK @State is a macro whose plugin only ships
    // with Xcode, so with the Command Line Tools use @StateObject instead.
    @StateObject private var local = LocalState()

    var body: some View {
        Form {
            permissionSection
            appearance
            feedback
            afterConverting
            quality
            system
            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 760)
        .onAppear {
            launch.refresh()
            permission.refresh()
        }
        .alert("Reset the permission?", isPresented: $local.confirmReset) {
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
                Button("Reset Permission…") { local.confirmReset = true }
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
                .disabled(!GlassLevel.isLiquidGlassAvailable)
                Text(GlassLevel.isLiquidGlassAvailable
                     ? settings.glassLevel.detail
                     : "Liquid Glass needs macOS 26 or later, so Pinwheel uses Frosted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                GlassPreview(settings: settings)
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
            Text("Plays when the pointer moves onto a format. Vibration needs a Force Touch trackpad and is felt only while your finger is on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var afterConverting: some View {
        Section {
            Toggle("Show the progress window", isOn: $settings.showProgressWindow)
            Toggle("Show the new files in Finder", isOn: $settings.revealInFinder)
            Toggle("Move the original to the Trash", isOn: $settings.moveOriginalToTrash)
        } header: {
            Text("After converting")
        } footer: {
            Text("The original goes to the Trash only after the new file is saved. You can put it back from the Trash.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quality: some View {
        Section {
            percentSlider("JPEG quality", value: $settings.jpegQuality, range: 0.5...1)
            percentSlider("HEIC quality", value: $settings.heicQuality, range: 0.5...1)
            percentSlider("Compress tool quality", value: $settings.compressQuality, range: 0.3...0.9)
            Picker("PDF pages to images", selection: $settings.pdfDPI) {
                Text("72 DPI (screen)").tag(72)
                Text("150 DPI (standard)").tag(150)
                Text("300 DPI (print)").tag(300)
            }
            Picker("GIF width", selection: $settings.gifWidth) {
                ForEach([320, 480, 640, 800, 1080], id: \.self) { Text("\($0) pixels").tag($0) }
            }
            Picker("GIF frame rate", selection: $settings.gifFPS) {
                ForEach([10, 12, 15, 20, 24], id: \.self) { Text("\($0) frames per second").tag($0) }
            }
        } header: {
            Text("Quality")
        } footer: {
            Text("Higher quality means bigger files. Compress also shrinks the pictures inside PDFs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var system: some View {
        Section("System") {
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

            LabeledContent("ffmpeg") {
                HStack {
                    if let url = settings.ffmpegURL {
                        Label(url.path, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("How to Install…", action: onShowFFmpegHelp)
                    }
                }
            }
            TextField("Custom ffmpeg location", text: $settings.ffmpegPath, prompt: Text("Automatic"))
        }
    }

    // MARK: - Helpers

    private var glassBinding: Binding<Double> {
        Binding(
            get: { Double(settings.glassLevel.rawValue) },
            set: { settings.glassLevel = GlassLevel(rawValue: Int($0.rounded())) ?? GlassLevel.defaultLevel }
        )
    }

    private func playSample() {
        local.soundPreview.playSound(named: settings.hoverSoundName, volume: settings.hoverSoundVolume)
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

/// The Settings window's own bits of state.
@MainActor
private final class LocalState: ObservableObject {
    @Published var confirmReset = false
    let soundPreview = HoverFeedback()
}

/// A live wheel over a colorful picture, so the glass can be seen changing.
private struct GlassPreview: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var model = WheelModel.sample()

    var body: some View {
        ZStack {
            PreviewBackdrop()
            WheelView(model: model, settings: settings, blending: .withinWindow)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .task {
            // Move the highlight around so the hover effect shows too.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard case .wedge(let index)? = model.hovered, !model.items.isEmpty else { continue }
                model.hovered = .wedge((index + 1) % model.items.count)
            }
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

/// Hosts the settings in a normal window.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(view: SettingsView) {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Pinwheel Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 760))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
