import AppKit
import PinwheelCore

/// One file being converted.
@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// All files from one drop share a batch, so they're revealed together.
    let batch: UUID
    let file: SourceFile
    let action: WheelAction
    let destination: URL
    let icon: NSImage
    let sourceSize: Int64?

    @Published fileprivate(set) var state: State = .waiting
    @Published fileprivate(set) var progress: Double = 0
    @Published fileprivate(set) var outputs: [URL] = []
    @Published fileprivate(set) var outputSize: Int64?
    fileprivate var task: Task<Void, Never>?

    init(batch: UUID, file: SourceFile, action: WheelAction, destination: URL) {
        self.batch = batch
        self.file = file
        self.action = action
        self.destination = destination
        self.icon = NSWorkspace.shared.icon(forFile: file.url.path)
        self.sourceSize = Self.size(of: file.url)
    }

    var isDone: Bool {
        switch state {
        case .finished, .failed, .cancelled: true
        case .waiting, .running: false
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Bytes in a file, or in all files inside a folder.
    static func size(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isDirectory == true {
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            var total: Int64 = 0
            while let item = items?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: keys))?.fileSize ?? 0)
            }
            return total
        }
        return values.fileSize.map(Int64.init)
    }
}

/// Runs jobs in the background, a couple at a time.
@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []

    var maxConcurrent = 2
    var optionsProvider: () -> ConversionOptions = { ConversionOptions() }
    /// Called when every job from one drop is done (finished, failed or cancelled).
    var onBatchFinished: (([Job]) -> Void)?
    /// Called whenever jobs are added, start, end, or are cleared.
    var onChange: (() -> Void)?

    var isIdle: Bool { jobs.allSatisfy(\.isDone) }
    var hasFailures: Bool { jobs.contains(where: \.isFailed) }

    func enqueue(files: [SourceFile], action: WheelAction) {
        let batch = UUID()
        let newJobs = files.map { file in
            let plan = ConversionEngine.plan(for: file, action: action)
            let destination = OutputNaming.shared.reserve(
                for: file.url, suffix: plan.suffix, fileExtension: plan.fileExtension
            )
            return Job(batch: batch, file: file, action: action, destination: destination)
        }
        jobs.append(contentsOf: newJobs)
        pump()
        onChange?()
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .waiting:
            job.state = .cancelled
            OutputNaming.shared.release(job.destination)
            jobDidEnd(job)
        case .running:
            job.task?.cancel()
        default:
            break
        }
    }

    /// Removes finished, failed and cancelled jobs from the list.
    func clearFinished() {
        jobs.removeAll(where: \.isDone)
        onChange?()
    }

    // MARK: - Private

    private func pump() {
        while jobs.filter({ $0.state == .running }).count < maxConcurrent,
              let next = jobs.first(where: { $0.state == .waiting }) {
            start(next)
        }
    }

    private func start(_ job: Job) {
        objectWillChange.send()
        job.state = .running
        let options = optionsProvider()
        let file = job.file
        let action = job.action
        let destination = job.destination

        job.task = Task { [weak self] in
            do {
                let outputs = try await ConversionEngine.run(
                    file: file, action: action, destination: destination, options: options
                ) { value in
                    Task { @MainActor in job.progress = max(job.progress, value) }
                }
                job.outputs = outputs
                job.outputSize = outputs.compactMap(Job.size(of:)).reduce(0, +)
                job.progress = 1
                job.state = .finished
            } catch {
                job.state = Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed(error.localizedDescription)
            }
            OutputNaming.shared.release(destination)
            self?.jobDidEnd(job)
        }
    }

    private func jobDidEnd(_ job: Job) {
        objectWillChange.send()
        pump()
        let batchJobs = jobs.filter { $0.batch == job.batch }
        if batchJobs.allSatisfy(\.isDone) {
            onBatchFinished?(batchJobs)
        }
        onChange?()
    }
}
