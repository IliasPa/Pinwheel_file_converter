import AppKit
import PinwheelCore

/// Takes requests from the `pinwheel` command (Terminal, Shortcuts) and
/// answers when they're done. Requests and answers travel as notifications
/// between programs on this Mac; nothing leaves it.
final class CommandCenter {
    /// Requests come in as "<channel>.command" and answers go out as
    /// "<channel>.reply"; tests use a channel of their own.
    let channel: String

    init(channel: String = "com.iliasmac.Pinwheel") {
        self.channel = channel
    }

    var enqueue: ([SourceFile], WheelAction, JobParameters?) -> UUID = { _, _, _ in UUID() }
    var showWheel: ([URL], WheelMode) -> Void = { _, _ in }
    var openEditor: (Editor, [SourceFile]) -> Void = { _, _ in }
    var recipes: () -> [Recipe] = { [] }
    var availability: (WheelAction, [SourceFile]) -> Availability = { _, _ in .available }
    /// An answer to the command: "accepted" (it's queued), "finished" or "failed".
    struct Reply: Sendable, Equatable {
        var id: String
        var state: String
        var outputs: [String] = []
        var messages: [String] = []
    }

    /// Sends an answer (tests listen here instead of to other programs).
    lazy var send: (Reply) -> Void = { [channel] reply in
        let info: [String: Any] = ["id": reply.id, "state": reply.state, "outputs": reply.outputs, "messages": reply.messages]
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(channel).reply"), object: nil, userInfo: info, deliverImmediately: true
        )
    }

    /// Batches someone is waiting for, and which request each answers.
    private var waiting: [UUID: String] = [:]
    /// The command resends a request until it hears back; each is done once.
    private var seen: Set<String> = []
    private var observer: NSObjectProtocol?

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    func start() {
        let name = Notification.Name("\(channel).command")
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            // Only plain values cross over; copy them out before hopping.
            let request = Request(info)
            MainActor.assumeIsolated { if let request { self?.receive(request) } }
        }
    }

    nonisolated struct Request: Sendable, Equatable {
        var id: String
        var command: String
        var value: String?
        var files: [String]
        var wait: Bool

        init?(_ info: [AnyHashable: Any]) {
            guard let id = info["id"] as? String, let command = info["command"] as? String,
                  let files = info["files"] as? [String] else { return nil }
            self.init(id: id, command: command, value: info["value"] as? String, files: files, wait: info["wait"] as? Bool ?? true)
        }

        init(id: String = UUID().uuidString, command: String, value: String? = nil, files: [String], wait: Bool = true) {
            self.id = id
            self.command = command
            self.value = value
            self.files = files
            self.wait = wait
        }
    }

    func receive(_ request: Request) {
        guard !seen.contains(request.id) else {
            reply(request.id, "accepted")
            return
        }
        seen.insert(request.id)
        let urls = request.files.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let files = urls.map(SourceFile.init)

        switch request.command {
        case "show":
            showWheel(urls, Self.wheel(named: request.value))
            reply(request.id, "finished")
            return
        case "open":
            guard let editor = Self.editor(named: request.value ?? "") else {
                reply(request.id, "failed", messages: ["There's no window called “\(request.value ?? "")”."])
                return
            }
            openEditor(editor, files)
            reply(request.id, "finished")
            return
        default:
            break
        }

        let job: (action: WheelAction, parameters: JobParameters?)
        switch Self.job(for: request, recipes: recipes()) {
        case .success(let found): job = found
        case .failure(let problem):
            reply(request.id, "failed", messages: [problem.message])
            return
        }
        if case .unavailable(let reason) = availability(job.action, files) {
            reply(request.id, "failed", messages: [reason])
            return
        }
        let batch = enqueue(files, job.action, job.parameters)
        if request.wait { waiting[batch] = request.id }
        reply(request.id, request.wait ? "accepted" : "finished")
    }

    /// Answers whoever waits for this batch.
    func batchFinished(_ jobs: [Job]) {
        guard let batch = jobs.first?.batch, let id = waiting.removeValue(forKey: batch) else { return }
        let outputs = jobs.flatMap(\.outputs).map(\.path)
        var messages: [String] = []
        for job in jobs {
            if let reason = job.failureReason ?? job.skipReason { messages.append("\(job.title): \(reason)") }
        }
        reply(id, jobs.contains(where: \.isFailed) ? "failed" : "finished", outputs: outputs, messages: messages)
    }

    private func reply(_ id: String, _ state: String, outputs: [String] = [], messages: [String] = []) {
        send(Reply(id: id, state: state, outputs: outputs, messages: messages))
    }

    // MARK: - Reading requests

    struct Problem: Error, Equatable {
        let message: String
    }

    static func job(for request: Request, recipes: [Recipe]) -> Result<(action: WheelAction, parameters: JobParameters?), Problem> {
        switch request.command {
        case "convert":
            guard let format = format(named: request.value ?? "") else {
                return .failure(Problem(message: "Pinwheel doesn't make “\(request.value ?? "")” files."))
            }
            return .success((.convert(format), nil))
        case "size-limit":
            guard let bytes = bytes(from: request.value ?? "") else {
                return .failure(Problem(message: "“\(request.value ?? "")” isn't a size. Try 10MB or 500KB."))
            }
            return .success((.tool(.sizeLimit), .sizeLimit(bytes: bytes)))
        case "run":
            let name = (request.value ?? "").trimmingCharacters(in: .whitespaces)
            guard let recipe = recipes.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                return .failure(Problem(message: "There's no custom action called “\(name)”. See: pinwheel list"))
            }
            return .success((.recipe(recipe), nil))
        default:
            guard let tool = tools[request.command] else {
                return .failure(Problem(message: "Pinwheel doesn't know “\(request.command)”. See: pinwheel help"))
            }
            return .success((.tool(tool), nil))
        }
    }

    static let tools: [String: ToolAction] = [
        "compress": .compress, "resize": .resize, "remove-background": .removeBackground, "strip-info": .stripMetadata,
        "get-text": .extractText, "searchable": .makeSearchable, "get-audio": .extractAudio, "mute": .mute,
        "normalize": .normalize, "merge": .merge, "split": .split, "zip": .archive, "extract": .extract,
    ]

    /// "tools", "actions"; anything else is the format wheel.
    static func wheel(named name: String?) -> WheelMode {
        switch name?.lowercased() {
        case "tools": .tools
        case "actions", "files", "file-actions": .actions
        default: .convert
        }
    }

    static func format(named name: String) -> OutputFormat? {
        let name = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let aliases = [
            "jpg": OutputFormat.jpeg, "jpe": .jpeg, "tif": .tiff, "aif": .aiff, "heif": .heic, "tgz": .tgz, "7zip": .sevenZip, "oga": .ogg,
            "word": .docx, "excel": .xlsx, "powerpoint": .pptx, "markdown": .md, "text": .txt, "htm": .html, "webvtt": .vtt,
        ]
        return aliases[name] ?? OutputFormat(rawValue: name)
    }

    static func editor(named name: String) -> Editor? {
        let names: [String: Editor] = [
            "rename": .rename, "size-limit": .sizeLimit, "crop": .crop, "edit": .adjust, "adjust": .adjust,
            "background": .background, "markup": .markup, "watermark": .watermark, "info": .info,
            "organize": .organize, "collage": .collage, "password": .password, "trim": .trim, "media": .trim,
            "codes": .codes, "qr": .codes,
        ]
        return names[name.lowercased()]
    }

    /// "10MB", "10 mb", "2.5MB", "500KB", "1GB"; a bare number means megabytes.
    static func bytes(from text: String) -> Int64? {
        let cleaned = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        let units: [(String, Double)] = [("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1000), ("g", 1_000_000_000), ("m", 1_000_000), ("k", 1000), ("b", 1)]
        for (unit, scale) in units where cleaned.hasSuffix(unit) {
            guard let number = Double(cleaned.dropLast(unit.count)), number > 0 else { return nil }
            return Int64(number * scale)
        }
        guard let number = Double(cleaned), number > 0 else { return nil }
        return Int64(number * 1_000_000)
    }
}
