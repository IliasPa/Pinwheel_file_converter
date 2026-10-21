import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// What Read Codes… found in each picture.
@Observable
final class CodesModel {
    struct Found: Identifiable {
        let file: URL
        let codes: [ReadCode]
        /// Why the picture couldn't be read, if it couldn't.
        let problem: String?

        var id: URL { file }
    }

    let files: [URL]
    private(set) var results: [Found] = []
    private(set) var isReading = true

    init(files: [URL]) {
        self.files = files
    }

    /// Reads every picture, off the main thread.
    func read() async {
        let files = files
        let read = await Task.detached {
            files.map { url -> (URL, [ReadCode]?) in (url, try? CodeReader.codes(in: url)) }
        }.value
        results = read.map { url, codes in
            Found(file: url, codes: codes ?? [], problem: codes == nil ? "Couldn't read this picture." : nil)
        }
        isReading = false
    }

    var foundNothing: Bool { !isReading && results.allSatisfy(\.codes.isEmpty) }
}

struct CodesView: View {
    var model: CodesModel

    var body: some View {
        Group {
            if model.isReading {
                ProgressView("Reading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.foundNothing {
                ContentUnavailableView(
                    "No codes found", systemImage: "qrcode",
                    description: Text(model.files.count == 1
                                      ? "There's no QR code or barcode Pinwheel can read in this picture."
                                      : "There's no QR code or barcode Pinwheel can read in these pictures.")
                )
            } else {
                List {
                    ForEach(model.results) { found in
                        Section(found.file.lastPathComponent) {
                            if found.codes.isEmpty {
                                Text(found.problem ?? "No codes in this picture.").foregroundStyle(.secondary)
                            }
                            ForEach(found.codes) { code in
                                CodeRow(code: code)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 260)
        .task { await model.read() }
    }
}

private struct CodeRow: View {
    let code: ReadCode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: code.kind.hasPrefix("QR") ? "qrcode" : "barcode")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(code.kind).font(.caption).foregroundStyle(.secondary)
                Text(code.text)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.text, forType: .string)
            }
            if let link = code.link {
                Button("Open") { NSWorkspace.shared.open(link) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

final class CodesWindowController: EditorWindowController {
    init(model: CodesModel) {
        super.init(title: "Read Codes", size: NSSize(width: 540, height: 340), content: CodesView(model: model))
    }
}
