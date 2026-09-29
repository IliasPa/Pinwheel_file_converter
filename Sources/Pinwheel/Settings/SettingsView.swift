import AppKit
import SwiftUI
import PinwheelCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launch: LaunchAtLogin
    @ObservedObject var permission: AccessibilityPermission
    var onShowDemo: () -> Void
    var onShowPermissions: () -> Void
    var onShowFFmpegHelp: () -> Void

    var body: some View {
        Form {
            appearance
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
    }

    // MARK: - Sections

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
            Toggle("Gentle tick on the trackpad when moving over a wedge", isOn: $settings.hapticFeedback)
        }
    }

    private var afterConverting: some View {
        Section("After converting") {
            Toggle("Show the progress window", isOn: $settings.showProgressWindow)
            Toggle("Show the new files in Finder", isOn: $settings.revealInFinder)
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

            LabeledContent("Accessibility") {
                HStack {
                    Label(permission.isTrusted ? "Allowed" : "Not allowed",
                          systemImage: permission.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permission.isTrusted ? .green : .orange)
                    Button("Help…", action: onShowPermissions)
                }
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
