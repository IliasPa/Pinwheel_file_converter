import Foundation
import PinwheelCore

// Pinwheel's converter. The app starts one for each job and sends the job
// (JSON) on standard input; this program does it and reports progress and
// the outcome as JSON lines on standard output, then quits. That way every
// bit of memory a conversion used goes back to macOS right away, and a file
// that crashes a converter can't take the app down.

/// The running job, so a stop request can cancel it from another thread.
final class WorkerControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopRequested = false

    /// Cancels the job (its half-written files are then deleted).
    func stop() {
        lock.withLock {
            stopRequested = true
            task?.cancel()
        }
    }

    func run(_ work: @escaping @Sendable () async -> Void) async {
        let task = Task { await work() }
        let stopNow = lock.withLock {
            self.task = task
            return stopRequested
        }
        if stopNow { task.cancel() }
        await task.value
    }
}

/// Writes whole messages to standard output, one at a time.
final class MessageWriter: @unchecked Sendable {
    private let lock = NSLock()

    func send(_ message: WorkerMessage) {
        lock.withLock { FileHandle.standardOutput.write(message.line) }
    }
}

let control = WorkerControl()
let writer = MessageWriter()

// Pinwheel asks a job to stop with SIGTERM: watch for it (then ignore the
// signal's default "quit at once"), so the job can clean up first.
let stopSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
stopSignal.setEventHandler { [control] in control.stop() }
stopSignal.resume()
signal(SIGTERM, SIG_IGN)

let input = FileHandle.standardInput.readDataToEndOfFile()
await control.run { [writer] in
    await ConversionWorker.serve(input) { writer.send($0) }
}
exit(0)
