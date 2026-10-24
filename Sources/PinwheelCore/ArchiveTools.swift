import Compression
import Foundation

/// Archives, with macOS's own tar (libarchive), so nothing extra to install:
/// ZIP, TAR, TAR.GZ and 7Z made; those plus RAR opened. Single squeezed
/// files (.gz, .bz2, .xz) are opened too.
enum ArchiveTools {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    /// How archive names can end, longest first.
    static let endings = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".zip", ".tar", ".gzip", ".gz", ".bz2", ".xz", ".rar", ".7z",
    ]

    /// "photos.tar.gz" → "photos"; other files just lose their extension.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        for ending in endings where name.lowercased().hasSuffix(ending) && name.count > ending.count {
            return String(name.dropLast(ending.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// A single file squeezed on its own ("notes.txt.gz"), not a tar inside.
    static func singleFileCompression(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        guard ![".tar.gz", ".tar.bz2", ".tar.xz"].contains(where: name.hasSuffix) else { return nil }
        switch url.pathExtension.lowercased() {
        case "gz", "gzip": return "gz"
        case "bz2": return "bz2"
        case "xz": return "xz"
        default: return nil
        }
    }

    /// Files and folders into one archive. Mac-only extras (the "._" files,
    /// .DS_Store) are left out, so it opens cleanly on any computer.
    static func make(_ items: [URL], format: OutputFormat, destination: URL) async throws {
        var arguments = ["-c", "-f", destination.path, "--no-mac-metadata", "--exclude", ".DS_Store"]
        switch format {
        // Names marked as UTF-8, so Windows shows Greek (or any) names right.
        case .zip: arguments += ["--format", "zip", "--options", "zip:hdrcharset=UTF-8"]
        case .tar: break
        case .tgz: arguments += ["-z"]
        case .sevenZip: arguments += ["--format", "7zip"]
        default: throw ConversionError.unsupported("\(format.title) archives")
        }
        for item in items {
            let name = item.lastPathComponent
            arguments += ["-C", item.deletingLastPathComponent().path, name.hasPrefix("-") ? "./\(name)" : name]
        }
        try await run(arguments, what: "the \(format.title) file")
    }

    /// Everything in an archive, into `folder`. Returns a note when some
    /// files were left out (names that would land outside the folder).
    @discardableResult
    static func extract(_ archive: URL, into folder: URL) async throws -> String? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch singleFileCompression(of: archive) {
        case "xz":
            try decompressXZ(archive, to: folder.appendingPathComponent(baseName(of: archive)))
        case let squeeze?:
            let tool = squeeze == "gz" ? "/usr/bin/gunzip" : "/usr/bin/bunzip2"
            try await unsqueeze(tool, archive, to: folder.appendingPathComponent(baseName(of: archive)))
        case nil:
            // In UTF-8, so names in any language come out right whatever
            // locale the app was started with.
            let result = try await ProcessRunner.run(tar, ["-x", "-f", archive.path, "-C", folder.path], environment: ["LC_ALL": "en_US.UTF-8"])
            guard result.status != 0 else { return nil }
            // tar refuses names with ".." or a leading "/" and opens the
            // rest: that's a success, with a word about what was left out.
            let complaints = result.stderr.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.contains("Error exit delayed") }
            let unsafe = complaints.filter { $0.contains("Path contains '..'") || $0.contains("Removing leading") || $0.contains("absolute path") }
            guard !unsafe.isEmpty, unsafe.count == complaints.count else { throw problem(result.stderr, what: archive.lastPathComponent) }
            return unsafe.count == 1
                ? "1 file was left out: its name would have put it outside the folder."
                : "\(unsafe.count) files were left out: their names would have put them outside the folder."
        }
        return nil
    }

    /// One kind of archive into another: opened, then packed again.
    static func convert(_ archive: URL, to format: OutputFormat, destination: URL) async throws -> String? {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pinwheel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let note = try await extract(archive, into: work)
        let items = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        guard !items.isEmpty else {
            throw NothingToDo(reason: note == nil ? "\(archive.lastPathComponent) is empty."
                : "Nothing was saved: every file in \(archive.lastPathComponent) would have landed outside the folder.")
        }
        try await make(items.sorted { $0.lastPathComponent < $1.lastPathComponent }, format: format, destination: destination)
        return note
    }

    private static func run(_ arguments: [String], what: String) async throws {
        let result = try await ProcessRunner.run(tar, arguments, environment: ["LC_ALL": "en_US.UTF-8"])
        guard result.status == 0 else { throw problem(result.stderr, what: what) }
    }

    /// tar's complaint, in words a person can use.
    static func problem(_ stderr: String, what: String) -> ConversionError {
        let lower = stderr.lowercased()
        if lower.contains("passphrase") || lower.contains("encrypt") || lower.contains("password") {
            return .failed("\(what) has a password, and Pinwheel can't open those yet.")
        }
        if lower.contains("truncated") || lower.contains("premature end") || lower.contains("unexpected end") || lower.contains("damaged") {
            return .failed("\(what) is incomplete or damaged. If it was downloaded, try downloading it again.")
        }
        if lower.contains("unrecognized archive format") {
            return .failed("\(what) isn't an archive Pinwheel can open.")
        }
        let line = stderr.split(whereSeparator: \.isNewline).first { !$0.contains("Error exit delayed") }
        let reason = (line.map { $0.replacingOccurrences(of: "tar: ", with: "") } ?? "it stopped with an error")
            .replacingOccurrences(of: ": Unknown error: -1", with: "")
        return .failed("Couldn't make or open \(what): \(reason)")
    }

    /// gunzip or bunzip2, written straight into the new file (it can be big).
    private static func unsqueeze(_ tool: String, _ file: URL, to output: URL) async throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-c", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let name = file.lastPathComponent
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { ended in
                if ended.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ConversionError.failed("\(name) is damaged or isn't really compressed."))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// .xz, with Apple's Compression (macOS has no xz command).
    private static func decompressXZ(_ file: URL, to output: URL) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        do {
            let filter = try OutputFilter(.decompress, using: .lzma) { data in
                if let data { try out.write(contentsOf: data) }
            }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try filter.write(chunk)
            }
            try filter.finalize()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversionError.failed("\(file.lastPathComponent) is damaged or isn't really compressed.")
        }
    }
}
