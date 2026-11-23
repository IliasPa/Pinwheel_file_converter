import AppKit
import Observation
import SwiftUI

/// One screenshot Pinwheel took.
struct ScreenshotEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var date: Date
    /// The app that was in front when it was taken ("" if none).
    var app: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// The screenshots taken lately, newest first, kept in Application Support.
/// The pictures themselves stay in the screenshot folder: taking one out of
/// the list doesn't touch the file, and a file that's gone leaves the list.
@Observable
final class ScreenshotHistory {
    static let limit = 40

    private(set) var entries: [ScreenshotEntry] = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]

    init(file: URL = ScreenshotHistory.defaultFile) {
        self.file = file
        load()
    }

    static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinwheel/ScreenshotHistory.json")
    }

    func add(_ url: URL, app: String, date: Date = Date()) {
        entries.removeAll { $0.path == url.path }
        entries.insert(ScreenshotEntry(path: url.path, date: date, app: app), at: 0)
        if entries.count > Self.limit {
            for dropped in entries[Self.limit...] { thumbnails[dropped.id] = nil }
            entries = Array(entries.prefix(Self.limit))
        }
        save()
    }

    func remove(_ entry: ScreenshotEntry) {
        entries.removeAll { $0.id == entry.id }
        thumbnails[entry.id] = nil
        save()
    }

    func removeAll() {
        entries = []
        thumbnails = [:]
        save()
    }

    /// Whether the file is still where it was left.
    func exists(_ entry: ScreenshotEntry) -> Bool {
        FileManager.default.fileExists(atPath: entry.path)
    }

    /// A small picture of it (made once).
    func thumbnail(of entry: ScreenshotEntry) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 280,
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails[entry.id] = thumbnail
        return thumbnail
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([ScreenshotEntry].self, from: data) else { return }
        entries = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        if entries.count != saved.count { save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}

/// The strip under the clipboard's copies: the last screenshots. Click one to
/// paste it (or copy it, as a copy does); right-click for more.
struct ScreenshotStrip: View {
    var history: ScreenshotHistory
    var onUse: (ScreenshotEntry) -> Void
    var onEdit: (ScreenshotEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Screenshots").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(history.entries.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(history.entries) { entry in
                        tile(entry)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
    }

    private func tile(_ entry: ScreenshotEntry) -> some View {
        Button { onUse(entry) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07))
                if let picture = history.thumbnail(of: entry) {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 96, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("\(entry.url.lastPathComponent): click to paste or copy it")
        .contextMenu {
            Button("Edit…") { onEdit(entry) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Divider()
            Button("Remove from This List") { history.remove(entry) }
            Button("Clear the List") { history.removeAll() }
        }
        .accessibilityLabel("Screenshot \(entry.url.lastPathComponent)")
    }
}
