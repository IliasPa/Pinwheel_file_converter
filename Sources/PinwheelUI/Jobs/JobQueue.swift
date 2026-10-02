import AppKit
import Observation
import PinwheelCore

/// One conversion: usually one file, or several images becoming one PDF.
@Observable
final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case running
        case finished
        /// Nothing useful to do (e.g. Compress couldn't make it smaller).
        case skipped(String)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// All files from one drop share a batch, so they're revealed together.
    let batch: UUID
    let request: ConversionRequest
    /// "photo.png", or "photo.png + 2 more" for a combined PDF.
    let title: String
    /// What's being done, e.g. "PNG" or "Resize 50%".
    let actionLabel: String
    let icon: NSImage
    let sourceSize: Int64?
    let created = Date()

    fileprivate(set) var state: State = .waiting
    fileprivate(set) var progress: Double = 0
    fileprivate(set) var outputs: [URL] = []
    fileprivate(set) var outputSize: Int64?
    /// Worth telling: where it was saved, what was left out, and so on.
    fileprivate(set) var note: String?
    /// True once the originals were moved to the Trash (when that's switched on).
    fileprivate(set) var originalTrashed = false
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    init(batch: UUID, request: ConversionRequest, actionLabel: String) {
        self.batch = batch
        self.request = request
        self.actionLabel = actionLabel
        let urls = request.files.map(\.url)
        let first = urls.first?.lastPathComponent ?? "File"
        title = urls.count > 1 ? "\(first) + \(urls.count - 1) more" : first
        icon = NSWorkspace.shared.icon(forFile: urls.first?.path ?? "/")
        sourceSize = FileSize.total(urls)
    }

    var isDone: Bool {
        switch state {
        case .finished, .skipped, .failed, .cancelled: true
        case .waiting, .running: false
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// Runs jobs in the background, a few at a time.
@Observable
final class JobQueue {
    private(set) var jobs: [Job] = []

    @ObservationIgnored var maxConcurrent: () -> Int = { 2 }
    @ObservationIgnored var optionsProvider: () -> ConversionOptions = { ConversionOptions() }
    /// Whether to move the originals to the Trash after a successful job.
    @ObservationIgnored var shouldTrashOriginals: () -> Bool = { false }
    /// Moves one file to the Trash (tests swap this out).
    @ObservationIgnored var moveToTrash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    /// How an action is named in the progress window.
    @ObservationIgnored var actionLabel: (WheelAction) -> String = { $0.title(in: .tools) }
    /// Called when every job from one drop is done.
    @ObservationIgnored var onBatchFinished: (([Job]) -> Void)?
    /// Called whenever jobs are added, start, end, or are cleared.
    @ObservationIgnored var onChange: (() -> Void)?

    var isIdle: Bool { jobs.allSatisfy(\.isDone) }
    var hasFailures: Bool { jobs.contains(where: \.isFailed) }

    func enqueue(files: [SourceFile], action: WheelAction) {
        let batch = UUID()
        let combined = ConversionRequest(files: files, action: action)
        let requests = combined.isCombinedPDF && optionsProvider().combineImagesIntoOnePDF
            ? [combined]
            : files.map { ConversionRequest(file: $0, action: action) }
        let label = actionLabel(action)
        jobs.append(contentsOf: requests.map { Job(batch: batch, request: $0, actionLabel: label) })
        pump()
        onChange?()
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .waiting:
            job.state = .cancelled
            jobDidEnd(job)
        case .running:
            job.task?.cancel()
        default:
            break
        }
    }

    /// Removes finished, skipped, failed and cancelled jobs from the list.
    func clearFinished() {
        jobs.removeAll(where: \.isDone)
        onChange?()
    }

    // MARK: - Private

    private func pump() {
        while jobs.filter({ $0.state == .running }).count < max(1, maxConcurrent()),
              let next = jobs.first(where: { $0.state == .waiting }) {
            start(next)
        }
    }

    private func start(_ job: Job) {
        job.state = .running
        onChange?()
        let options = optionsProvider()
        let request = job.request
        let throttle = ProgressThrottle()

        job.task = Task { [weak self] in
            do {
                let result = try await ConversionEngine.run(request, options: options) { value in
                    guard throttle.shouldReport(value) else { return }
                    Task { @MainActor in job.progress = max(job.progress, value) }
                }
                job.note = result.note
                if result.skipped {
                    job.state = .skipped(result.note ?? "Nothing to do.")
                } else {
                    job.outputs = result.outputs
                    job.outputSize = FileSize.total(result.outputs)
                    job.progress = 1
                    job.state = .finished
                    if self?.shouldTrashOriginals() == true {
                        self?.trashOriginals(of: job)
                    }
                }
            } catch {
                job.state = Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed(error.localizedDescription)
            }
            self?.jobDidEnd(job)
        }
    }

    /// Moves the originals to the Trash (you can put them back from there),
    /// but only once the new file exists and no other job still needs them.
    private func trashOriginals(of job: Job) {
        let outputsExist = !job.outputs.isEmpty && job.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        guard outputsExist else { return }
        var trashed = false
        for source in job.request.files.map(\.url) {
            let stillNeeded = jobs.contains { other in
                other !== job && !other.isDone && other.request.files.contains { $0.url == source }
            }
            if !stillNeeded, (try? moveToTrash(source)) != nil {
                trashed = true
            }
        }
        job.originalTrashed = trashed
    }

    private func jobDidEnd(_ job: Job) {
        pump()
        let batchJobs = jobs.filter { $0.batch == job.batch }
        if batchJobs.allSatisfy(\.isDone) {
            onBatchFinished?(batchJobs)
        }
        onChange?()
    }
}
