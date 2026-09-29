import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permission: AccessibilityPermission
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Pinwheel")
                        .font(.title2.weight(.semibold))
                    Text("Convert files by dropping them on a wheel.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Start dragging one or more files in Finder.", systemImage: "hand.draw")
                    Label("Hold ⇧ Shift: a wheel of formats appears under the pointer.", systemImage: "circle.dashed")
                    Label("Drop on a format to convert. Add ⌥ Option for tools.", systemImage: "arrow.down.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("How it works").font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Why Pinwheel needs Accessibility")
                    .font(.headline)
                Text("To know when to show the wheel, Pinwheel has to notice the Shift key and the mouse while you drag in Finder. macOS only allows that with the Accessibility permission. Pinwheel never records what you type, and all conversions happen on this Mac. Nothing is uploaded.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                step(1, "Click **Open System Settings** below.")
                step(2, "Find **Pinwheel** in the list and turn its switch **on**. macOS may ask for your password or Touch ID.")
                step(3, "If Pinwheel isn't listed, click **+**, open **Applications**, choose **Pinwheel**, and click **Open**.")
                step(4, "Come back here. This window turns green when it's done.")
            }

            statusRow

            HStack {
                Button("Later") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if permission.isTrusted {
                    Button("Done") { onClose() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") { permission.openSystemSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { permission.startWatching() }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "clock")
                .font(.title2)
                .foregroundStyle(permission.isTrusted ? .green : .orange)
                .contentTransition(.symbolEffect(.replace))
            Text(permission.isTrusted
                 ? "Permission granted. You're all set!"
                 : "Waiting for permission…")
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((permission.isTrusted ? Color.green : Color.orange).opacity(0.12))
        )
        .animation(.spring(duration: 0.4), value: permission.isTrusted)
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

/// Hosts the onboarding view in a normal window.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onClosed: (() -> Void)?

    init(permission: AccessibilityPermission) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Pinwheel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(permission: permission) { [weak window] in window?.close() }
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }
}
