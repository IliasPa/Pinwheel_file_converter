import Foundation
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

    @Published fileprivate(set) var state: State = .waiting
    @Published fileprivate(set) var progress: Double = 0
    @Published fileprivate(set) var outputs: [URL] = []
    fileprivate var task: Task<Void, Never>?

    init(batch: UUID, file: SourceFile, action: WheelAction, destination: URL) {
        self.batch = batch
        self.file = file
        self.action = action
        self.destination = destination
    }

    var isDone: Bool {
        switch state {
        case .finished, .failed, .cancelled: true
        case .waiting, .running: false
        }
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

    // MARK: - Private

    private func pump() {
        while jobs.filter({ $0.state == .running }).count < maxConcurrent,
              let next = jobs.first(where: { $0.state == .waiting }) {
            start(next)
        }
    }

    private func start(_ job: Job) {
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
        pump()
        let batchJobs = jobs.filter { $0.batch == job.batch }
        if batchJobs.allSatisfy(\.isDone) {
            onBatchFinished?(batchJobs)
        }
    }
}
