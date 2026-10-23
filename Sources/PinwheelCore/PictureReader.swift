import Foundation

/// What's in a picture: its words, its QR codes and barcodes, or where its
/// faces and text are. Read by Apple's Vision (or Tesseract), which loads
/// tens of megabytes of models the first time and keeps them; so it's done
/// in a helper (the worker program, started with `--reader`) that Pinwheel
/// stops a minute after it was last used, and that memory goes back to
/// macOS. Without a helper (tests, `swift run`) it's done in this process.
public actor PictureReader {
    /// The helper in the running app.
    public static let shared = PictureReader(worker: Bundle.main.url(forAuxiliaryExecutable: "PinwheelWorker"))
    public static let keepAlive: Duration = .seconds(60)

    let worker: URL?
    let keepAlive: Duration
    private var helper: Process?
    private var input: FileHandle?
    private var waiting: [UUID: CheckedContinuation<ReaderAnswer, Never>] = [:]
    private var stopper: Task<Void, Never>?

    public init(worker: URL?, keepAlive: Duration = PictureReader.keepAlive) {
        self.worker = worker
        self.keepAlive = keepAlive
    }

    /// The words, in reading order ("" when there are none).
    public func text(in picture: URL, recognition: TextRecognition) async throws -> String {
        try await ask(ReaderRequest(picture: picture, want: .text, recognition: recognition)).text ?? ""
    }

    public func codes(in picture: URL) async throws -> [ReadCode] {
        try await ask(ReaderRequest(picture: picture, want: .codes)).codes ?? []
    }

    /// Where faces and text are, for Blur Out (see `PrivacyBlur`).
    public func regions(in picture: URL, faces: Bool, text: Bool) async throws -> [RelativeRect] {
        try await ask(ReaderRequest(picture: picture, want: .regions, faces: faces, textBoxes: text)).regions ?? []
    }

    /// Whether the helper is running now (it stops `keepAlive` after its last answer).
    public var isRunning: Bool { helper?.isRunning == true }

    /// The helper's process, while there is one.
    public var processID: Int32? { helper.map(\.processIdentifier) }

    private func ask(_ request: ReaderRequest) async throws -> ReaderAnswer {
        let answer: ReaderAnswer
        if let worker {
            stopper?.cancel()
            answer = await askHelper(request, worker: worker)
            scheduleStop()
        } else {
            answer = await PictureReading.answer(request)
        }
        if let problem = answer.problem { throw ConversionError.failed(problem) }
        return answer
    }

    private func askHelper(_ request: ReaderRequest, worker: URL) async -> ReaderAnswer {
        do {
            try startIfNeeded(worker)
        } catch {
            return ReaderAnswer(id: request.id, problem: "Couldn't start Pinwheel's reader: \(error.localizedDescription)")
        }
        guard var line = try? JSONEncoder().encode(request), let input else {
            return ReaderAnswer(id: request.id, problem: "Couldn't ask Pinwheel's reader.")
        }
        line.append(0x0A)
        return await withCheckedContinuation { continuation in
            waiting[request.id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                waiting[request.id] = nil
                continuation.resume(returning: ReaderAnswer(id: request.id, problem: "Pinwheel's reader stopped unexpectedly."))
            }
        }
    }

    private func startIfNeeded(_ worker: URL) throws {
        if helper?.isRunning == true { return }
        let process = Process()
        process.executableURL = worker
        process.arguments = ["--reader"]
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        let id = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in
            Task { await self?.helperEnded(id) }
        }
        try process.run()
        // If the helper is gone, a write fails instead of macOS stopping
        // Pinwheel (SIGPIPE).
        _ = fcntl(toHelper.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        helper = process
        input = toHelper.fileHandleForWriting
        // Answers are read as they come (not with FileHandle.bytes: all of a
        // process's async readers share one queue, and one helper's quiet
        // pipe held up the others).
        let lines = LineSplitter()
        fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil  // the end
                return
            }
            for line in lines.add(data) {
                guard let answer = try? JSONDecoder().decode(ReaderAnswer.self, from: line) else { continue }
                Task { await self?.deliver(answer) }
            }
        }
    }

    deinit {
        // Gone before its minute was up: the helper is told to quit now.
        try? input?.close()
    }

    private func deliver(_ answer: ReaderAnswer) {
        waiting.removeValue(forKey: answer.id)?.resume(returning: answer)
    }

    /// It quit (stopped, or crashed on a picture): anything still asked gets
    /// an answer. (A helper stopped earlier, quitting late, changes nothing.)
    private func helperEnded(_ id: ObjectIdentifier) {
        guard let helper, ObjectIdentifier(helper) == id else { return }
        self.helper = nil
        input = nil
        for (id, continuation) in waiting {
            continuation.resume(returning: ReaderAnswer(id: id, problem: "Pinwheel's reader stopped unexpectedly. The picture may be damaged."))
        }
        waiting.removeAll()
    }

    /// A minute (`keepAlive`) after its last answer, the helper is told to
    /// quit: the end of its input. A new question starts it again.
    private func scheduleStop() {
        stopper?.cancel()
        let delay = keepAlive
        stopper = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard waiting.isEmpty else { return }
        try? input?.close()
        input = nil
        helper = nil
    }
}

/// Whole lines out of data that comes in pieces.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func add(_ data: Data) -> [Data] {
        lock.withLock {
            pending.append(data)
            var lines: [Data] = []
            while let end = pending.firstIndex(of: 0x0A) {
                lines.append(Data(pending[pending.startIndex..<end]))
                pending.removeSubrange(pending.startIndex...end)
            }
            return lines
        }
    }
}

/// A question for the reader, one line of JSON.
public struct ReaderRequest: Codable, Sendable {
    public enum Want: String, Codable, Sendable {
        case text, codes, regions
    }

    public var id = UUID()
    public var picture: URL
    public var want: Want
    public var recognition: TextRecognition?
    public var faces = true
    public var textBoxes = true

    public init(picture: URL, want: Want, recognition: TextRecognition? = nil, faces: Bool = true, textBoxes: Bool = true) {
        self.picture = picture
        self.want = want
        self.recognition = recognition
        self.faces = faces
        self.textBoxes = textBoxes
    }
}

/// The reader's answer, one line of JSON.
public struct ReaderAnswer: Codable, Sendable {
    public var id: UUID
    public var text: String?
    public var codes: [ReadCode]?
    public var regions: [RelativeRect]?
    public var problem: String?

    public init(id: UUID, text: String? = nil, codes: [ReadCode]? = nil, regions: [RelativeRect]? = nil, problem: String? = nil) {
        self.id = id
        self.text = text
        self.codes = codes
        self.regions = regions
        self.problem = problem
    }

    /// As one line of JSON, ending in a newline.
    public var line: Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// The reading itself: in the helper, or here when there's none.
public enum PictureReading {
    public static func answer(_ request: ReaderRequest) async -> ReaderAnswer {
        do {
            switch request.want {
            case .text:
                let text = try await PictureText.read(request.picture, recognition: request.recognition ?? TextRecognition())
                return ReaderAnswer(id: request.id, text: text)
            case .codes:
                return ReaderAnswer(id: request.id, codes: try await CodeReader.read(request.picture))
            case .regions:
                let image = try await Blocking.run { _ in try TextExtractor.picture(request.picture) }
                let regions = try await PrivacyBlur.find(in: image, faces: request.faces, text: request.textBoxes)
                return ReaderAnswer(id: request.id, regions: regions)
            }
        } catch {
            return ReaderAnswer(id: request.id, problem: error.localizedDescription)
        }
    }

    /// The helper's side: answers each question on standard input, until it ends.
    public static func serve() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let request = try? JSONDecoder().decode(ReaderRequest.self, from: Data(line.utf8)) else { continue }
                let answer = await answer(request)
                FileHandle.standardOutput.write(answer.line)
            }
        } catch {}
    }
}
