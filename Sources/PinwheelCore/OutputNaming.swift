import Foundation

/// Picks output names that never overwrite anything:
/// "photo (converted).png", "photo (converted 2).png", and so on.
///
/// Names handed out but not written yet are remembered, so two jobs running
/// at the same time can't pick the same name.
public final class OutputNaming: @unchecked Sendable {
    public static let shared = OutputNaming()

    private let lock = NSLock()
    private var reserved = Set<String>()

    public init() {}

    /// `fileExtension` nil means a folder (e.g. one image per PDF page).
    public func reserve(
        in folder: URL,
        baseName: String,
        suffix: String,
        fileExtension: String?,
        fileManager: FileManager = .default
    ) -> URL {
        lock.lock()
        defer { lock.unlock() }
        var attempt = 1
        while true {
            let url = Self.candidate(in: folder, baseName: baseName, suffix: suffix, fileExtension: fileExtension, attempt: attempt)
            let key = url.path.lowercased()  // macOS disks usually ignore case
            if !reserved.contains(key) && !fileManager.fileExists(atPath: url.path) {
                reserved.insert(key)
                return url
            }
            attempt += 1
        }
    }

    /// Call once the file is written (or the job failed).
    public func release(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        reserved.remove(url.path.lowercased())
    }

    public static func candidate(in folder: URL, baseName: String, suffix: String, fileExtension: String?, attempt: Int) -> URL {
        let label = attempt == 1 ? suffix : "\(suffix) \(attempt)"
        var name = "\(baseName) (\(label))"
        if let fileExtension { name += ".\(fileExtension)" }
        return folder.appendingPathComponent(name, isDirectory: fileExtension == nil)
    }

    /// Any name (a sheet's, say) as a file name: no "/" or ":", not hidden,
    /// not empty.
    static func safeFileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(200))
    }
}

/// Sizes of files and folders on disk.
public enum FileSize {
    /// Bytes in a file, or in all files inside a folder. Always read from the
    /// disk: a URL remembers what it read before, which is wrong once the
    /// file was written again (Size Limit's second try).
    public static func of(_ url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        var total: Int64 = 0
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = items?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.fileSize ?? 0)
        }
        return total
    }

    public static func total(_ urls: [URL]) -> Int64? {
        let sizes = urls.compactMap(of)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}
