import AppKit
import Observation
import SwiftUI
import PinwheelCore

@Observable
final class PasswordModel {
    let files: [SourceFile]
    var password = ""
    var repeated = ""
    var onSave: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(files: [SourceFile]) {
        self.files = files
    }

    var canSave: Bool { !password.isEmpty && password == repeated }
    var mismatch: Bool { !repeated.isEmpty && password != repeated }

    func save() {
        guard canSave else { return }
        onSave?(password)
        onClose?()
    }
}

/// Asks for the password a PDF should need. Pinwheel doesn't keep it.
struct PasswordView: View {
    @Bindable var model: PasswordModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(model.files.count == 1 ? "Protect “\(model.files[0].url.lastPathComponent)”" : "Protect \(model.files.count) PDFs")
                    .font(.headline)
            } icon: {
                Image(systemName: "lock.doc").foregroundStyle(Brand.blue)
            }
            Form {
                SecureField("Password", text: $model.password)
                SecureField("Repeat", text: $model.repeated)
            }
            .formStyle(.columns)
            Text(model.mismatch
                 ? "The two passwords aren't the same."
                 : "The copy asks for this password to open. Pinwheel doesn't remember it, so keep it somewhere safe.")
                .font(.caption)
                .foregroundStyle(model.mismatch ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                Button(model.files.count > 1 ? "Save \(model.files.count) Copies" : "Save Copy", action: model.save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

final class PasswordWindowController: EditorWindowController {
    init(model: PasswordModel) {
        super.init(title: "Add Password", size: NSSize(width: 400, height: 250), resizable: false, content: PasswordView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
