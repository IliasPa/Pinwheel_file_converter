import Foundation

/// Picks output names next to the original that never overwrite anything:
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
        for source: URL,
        suffix: String,
        fileExtension: String?,
        fileManager: FileManager = .default
    ) -> URL {
        lock.lock()
        defer { lock.unlock() }
        var attempt = 1
        while true {
            let url = Self.candidate(for: source, suffix: suffix, fileExtension: fileExtension, attempt: attempt)
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

    public static func candidate(for source: URL, suffix: String, fileExtension: String?, attempt: Int) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let label = attempt == 1 ? suffix : "\(suffix) \(attempt)"
        var name = "\(base) (\(label))"
        if let fileExtension { name += ".\(fileExtension)" }
        return source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: fileExtension == nil)
    }
}
