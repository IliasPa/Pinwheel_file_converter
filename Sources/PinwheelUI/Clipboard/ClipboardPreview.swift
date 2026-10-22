import AppKit
import Quartz
import SwiftUI

/// A copy shown big, over the list: the whole text, the whole picture, or
/// the file as Quick Look shows it. Space, Esc or a click outside goes back.
struct ClipPreview: View {
    let item: ClipItem
    var model: ClipboardPanelModel

    /// Long texts are shown up to here (SwiftUI slows down on huge ones).
    static let textLimit = 60_000

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { model.closePreview() }
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onExitCommand { model.closePreview() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let appID = item.appID {
                AppIcon(bundleID: appID).frame(width: 22, height: 22)
            } else {
                Image(systemName: item.kind.symbolName).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(details).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.kind == .link, let url = URL(string: item.preview) {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .help("Opens the link in your browser")
            }
            Button(model.pastes ? "Paste" : "Copy") { model.onCopy(item) }
                .buttonStyle(.borderedProminent)
                .help(model.pastes ? "Pastes it where you were typing (or press Return)" : "Copies it (or press Return)")
            Button { model.closePreview() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to the list (Space or Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var title: String {
        switch item.kind {
        case .text: "Text"
        case .link: URL(string: item.preview)?.host() ?? "Link"
        case .image: "Image"
        case .file:
            item.contents.count == 1 ? model.store.files(of: item).first?.lastPathComponent ?? "File" : "\(item.contents.count) files"
        }
    }

    /// "Notes · 5 minutes ago · 1,204 characters"
    private var details: String {
        var parts = [item.appName ?? "Unknown app", item.date.formatted(.relative(presentation: .named))]
        switch item.kind {
        case .text, .link:
            let count = (model.store.text(of: item) ?? item.preview).count
            parts.append(count == 1 ? "1 character" : "\(count.formatted()) characters")
        case .image:
            parts.append(item.preview.replacingOccurrences(of: "Image ", with: ""))
            parts.append(ClipboardStore.size(item.byteCount))
        case .file:
            break
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text, .link:
            let text = model.store.text(of: item) ?? item.preview
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(text.prefix(Self.textLimit)))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if text.count > Self.textLimit {
                        Text("Shown up to \(Self.textLimit.formatted()) characters; pasting gives you all of it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        case .image:
            if let data = model.store.imageData(of: item), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(14)
            } else {
                missing("The picture couldn't be read.")
            }
        case .file:
            FilesPreview(files: model.store.files(of: item), model: model)
        }
    }

    private func missing(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

/// Copied files in Quick Look, one at a time (chips switch between them).
private struct FilesPreview: View {
    let files: [URL]
    var model: ClipboardPanelModel

    private var shown: Int { model.previewFile }

    var body: some View {
        VStack(spacing: 0) {
            if files.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                            Button { model.previewFile = index } label: {
                                HStack(spacing: 5) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 14, height: 14)
                                    Text(file.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(index == shown ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                Divider()
            }
            if files.indices.contains(shown) {
                if FileManager.default.fileExists(atPath: files[shown].path) {
                    QuickLookView(url: files[shown])
                } else {
                    Text("\(files[shown].lastPathComponent) isn't where it was any more.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// A file as Quick Look shows it (documents, pictures, films, …).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
