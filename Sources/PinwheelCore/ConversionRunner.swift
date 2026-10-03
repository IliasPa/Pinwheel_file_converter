import Foundation

/// Runs jobs in a separate worker process (PinwheelWorker, inside the app),
/// or in this process when there is no worker (tests, `swift run`).
///
/// A worker quits as soon as its job is done, so all the memory the image
/// and video encoders used goes back to macOS, and a file that crashes a
/// converter can't take the app down with it.
public struct ConversionRunner: Sendable {
    /// The worker program, or nil to convert in this process.
    public var worker: URL?

    public init(worker: URL? = nil) {
        self.worker = worker
    }

    /// The worker next to the running app's own program, if there is one.
    public static var bundled: ConversionRunner {
        ConversionRunner(worker: Bundle.main.url(forAuxiliaryExecutable: "PinwheelWorker"))
    }

    /// Same contract as `ConversionEngine.run`: half-written files are
    /// deleted on failure or cancellation (cancelling stops the worker).
    @concurrent
    public func run(
        _ request: ConversionRequest,
        options: ConversionOptions,
        naming: OutputNaming = .shared,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        guard let worker else {
            return try await ConversionEngine.run(request, options: options, naming: naming, progress: progress)
        }
        // Naming stays here, in one process, so jobs running side by side in
        // different workers can't pick the same name.
        let job = try ConversionEngine.prepare(request, options: options, naming: naming)
        defer { naming.release(job.destination) }
        return try await Self.runInWorker(job, worker: worker, progress: progress)
    }

    /// Sends the job to a fresh worker and follows its messages.
    static func runInWorker(
        _ job: PlannedJob,
        worker: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        let outcome = Locked<WorkerMessage?>(nil)
        let input = try JSONEncoder().encode(job)
        let status: Int32
        do {
            status = try await ProcessRunner.run(worker, [], input: input) { line in
                guard let message = WorkerMessage(line: line) else { return }  // not ours: ignore
                if case .progress(let value) = message {
                    progress(value)
                } else {
                    outcome.value = message
                }
            }.status
        } catch {
            removeLeftovers(of: job)
            throw error
        }

        switch outcome.value {
        case .finished(let result)?:
            return result
        case .failed(let reason)?:
            removeLeftovers(of: job)
            throw ConversionError.failed(reason)
        case .cancelled?:
            removeLeftovers(of: job)
            throw CancellationError()
        case .progress?, nil:
            removeLeftovers(of: job)
            throw ConversionError.failed("Pinwheel's converter stopped unexpectedly (code \(status)). The file may be damaged.")
        }
    }

    /// The worker normally cleans up after itself; this covers a worker that
    /// crashed. The destination was a fresh, unused name, so removing it
    /// can't touch anything that existed before.
    private static func removeLeftovers(of job: PlannedJob) {
        try? FileManager.default.removeItem(at: job.destination)
    }
}

/// What a worker tells the app, one JSON object per line on standard output.
public enum WorkerMessage: Sendable, Equatable, Codable {
    case progress(Double)
    case finished(ConversionResult)
    case failed(String)
    case cancelled

    /// Reads one line; nil when the line isn't a message.
    public init?(line: String) {
        guard line.hasPrefix("{"),
              let message = try? JSONDecoder().decode(WorkerMessage.self, from: Data(line.utf8)) else { return nil }
        self = message
    }

    /// The message as one line of JSON, ending in a newline.
    public var line: Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// The worker's side: does one job and describes how it went.
public enum ConversionWorker {
    /// Reads a job (JSON) and does it, sending progress and the outcome.
    public static func serve(_ input: Data, send: @escaping @Sendable (WorkerMessage) -> Void) async {
        guard let job = try? JSONDecoder().decode(PlannedJob.self, from: input) else {
            send(.failed("Pinwheel's converter couldn't read the job. Try quitting and reopening Pinwheel."))
            return
        }
        await perform(job, send: send)
    }

    public static func perform(_ job: PlannedJob, send: @escaping @Sendable (WorkerMessage) -> Void) async {
        let throttle = ProgressThrottle()
        do {
            let result = try await ConversionEngine.perform(job) { value in
                if throttle.shouldReport(value) { send(.progress(value)) }
            }
            send(.finished(result))
        } catch {
            send(Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription))
        }
    }
}
