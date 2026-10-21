import AppKit
import Observation
import PinwheelCore

/// What the last conversions and renames did, so the menu bar's Undo can
/// take them back: new files go to the Trash, originals come back out of
/// it, and renamed files get their old names again. Kept while Pinwheel
/// runs; the newest step is undone first.
@Observable
final class UndoHistory {
    struct Entry: Identifiable {
        let id = UUID()
        /// "Compress (3 files)", "Rename (12 files)".
        let title: String
        let date: Date
        /// New files and folders.
        var created: [URL] = []
        /// Originals that went to the Trash, and where they are there.
        var trashed: [(original: URL, inTrash: URL)] = []
        /// Renamed files, in the order they were renamed.
        var renamed: [Renamer.Move] = []

        var isEmpty: Bool { created.isEmpty && trashed.isEmpty && renamed.isEmpty }
    }

    /// What happened when undoing.
    struct Report: Equatable {
        var title: String
        var problems: [String] = []
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []
    static let limit = 20

    @ObservationIgnored var moveToTrash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    var last: Entry? { entries.last }

    func record(_ entry: Entry) {
        guard !entry.isEmpty else { return }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The finished jobs of one drop (or one window's Save).
    func record(batch: [Job], now: Date = Date()) {
        let done = batch.filter { $0.state == .finished }
        guard let first = done.first else { return }
        let files = done.reduce(0) { $0 + $1.request.files.count }
        var action = first.actionLabel
        if case .convert(let format) = first.request.action { action = "Convert to \(format.title)" }
        var entry = Entry(title: Self.title(action, count: files), date: now)
        entry.created = done.flatMap(\.outputs)
        entry.trashed = done.flatMap(\.trashedOriginals)
        record(entry)
    }

    func recordRename(_ moves: [Renamer.Move], now: Date = Date()) {
        record(Entry(title: Self.title("Rename", count: moves.count), date: now, renamed: moves))
    }

    /// Files moved to another folder (the file actions' Move To…): undone like a rename.
    func recordMove(_ moves: [Renamer.Move], now: Date = Date()) {
        record(Entry(title: Self.title("Move", count: moves.count), date: now, renamed: moves))
    }

    static func title(_ action: String, count: Int) -> String {
        count == 1 ? action : "\(action) (\(count) files)"
    }

    /// Takes the newest step back. Whatever can't be (a file that was moved
    /// since, or emptied from the Trash) is listed in the report.
    @discardableResult
    func undoLast() -> Report? {
        guard let entry = entries.popLast() else { return nil }
        var report = Report(title: entry.title)
        let fileManager = FileManager.default

        for url in entry.created where fileManager.fileExists(atPath: url.path) {
            do { try moveToTrash(url) } catch { report.problems.append("Couldn't move \(url.lastPathComponent) to the Trash.") }
        }
        for (original, inTrash) in entry.trashed {
            if !fileManager.fileExists(atPath: inTrash.path) {
                report.problems.append("\(original.lastPathComponent) is no longer in the Trash.")
            } else if fileManager.fileExists(atPath: original.path) {
                report.problems.append("\(original.lastPathComponent) wasn't put back: a file with that name is there now.")
            } else {
                do { try fileManager.moveItem(at: inTrash, to: original) } catch {
                    report.problems.append("Couldn't put \(original.lastPathComponent) back from the Trash.")
                }
            }
        }
        if !entry.renamed.isEmpty {
            // Back in reverse, skipping files that were moved or renamed since.
            let back = entry.renamed.reversed().filter { fileManager.fileExists(atPath: $0.to.path) }
                .map { Renamer.Move(from: $0.to, to: $0.from) }
            let missing = entry.renamed.count - back.count
            if missing > 0 { report.problems.append("\(missing) renamed \(missing == 1 ? "file was" : "files were") moved since, so kept \(missing == 1 ? "its" : "their") new name.") }
            do { try Renamer.apply(back) } catch {
                report.problems.append("The names couldn't be changed back: \(error.localizedDescription)")
            }
        }
        return report
    }
}
