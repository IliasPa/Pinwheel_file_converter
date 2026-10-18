import Foundation

// `pinwheel`: Pinwheel from Terminal and from Shortcuts' "Run Shell Script".
// It asks the Pinwheel app to do the job (starting it if needed), so jobs
// show in the progress window and can be undone from the menu bar, then
// prints the new files' paths, one per line.

let bundleID = "com.iliasmac.Pinwheel"
/// Tests talk on a channel of their own, so a running Pinwheel stays out of it.
let testChannel = ProcessInfo.processInfo.environment["PINWHEEL_CHANNEL"]
let channel = testChannel ?? bundleID
let requestName = Notification.Name("\(channel).command")
let replyName = Notification.Name("\(channel).reply")

struct Command {
    let name: String
    /// What follows the command name, if anything: "<format>".
    let value: String?
    let valueIsOptional: Bool
    let summary: String

    init(_ name: String, _ value: String, optional: Bool = false, _ summary: String) {
        self.name = name
        self.value = value
        self.valueIsOptional = optional
        self.summary = summary
    }

    init(_ name: String, _ summary: String) {
        self.name = name
        self.value = nil
        self.valueIsOptional = false
        self.summary = summary
    }
}

let commands = [
    Command("convert", "<format>", "Convert to png, jpg, heic, tiff, gif, pdf, mp4, mov, m4a, mp3, wav, aiff or flac"),
    Command("compress", "Compress, with the quality chosen in Settings"),
    Command("size-limit", "<size>", "Make each file smaller than a size: 10MB, 2.5MB, 500KB"),
    Command("resize", "Resize pictures to the size chosen in Settings"),
    Command("remove-background", "Cut out the subject of pictures"),
    Command("strip-info", "Remove location, camera and other hidden info"),
    Command("get-text", "Save the text in pictures and PDFs as .txt files"),
    Command("searchable", "Add the text of scanned pages to PDFs, to search and copy it"),
    Command("get-audio", "Save the sound of videos as M4A"),
    Command("mute", "Remove the sound from videos"),
    Command("normalize", "Even out the loudness of audio"),
    Command("merge", "Join PDFs into one, in name order"),
    Command("split", "One PDF per page"),
    Command("run", "<name>", "Run one of your custom actions (see: pinwheel list)"),
    Command("show", "[tools]", optional: true, "Show the wheel at the pointer, to choose with a click"),
    Command("open", "<window>", "Open a window: rename, size-limit, crop, edit, watermark, info, organize, collage"),
]

func usage() -> String {
    let width = commands.map { $0.name.count + ($0.value.map { $0.count + 1 } ?? 0) }.max() ?? 20
    var lines = [
        "Usage: pinwheel <command> [choice] <files…>",
        "",
        "Commands:",
    ]
    for command in commands {
        let head = command.name + (command.value.map { " \($0)" } ?? "")
        lines.append("  " + head.padding(toLength: width + 2, withPad: " ", startingAt: 0) + command.summary)
    }
    lines += [
        "  " + "list".padding(toLength: width + 2, withPad: " ", startingAt: 0) + "Your custom actions",
        "",
        "Options:",
        "  --no-wait   Return once Pinwheel has the job, without waiting for it",
        "",
        "The new files' paths are printed, one per line. Examples:",
        "  pinwheel convert jpg ~/Desktop/*.heic",
        "  pinwheel size-limit 10MB video.mov",
        "  pinwheel run \"Instagram\" photo.jpg",
        "",
        "In Shortcuts, use “Run Shell Script”, pass the input “as arguments”, and write:",
        "  \"\(executablePath())\" compress \"$@\"",
    ]
    return lines.joined(separator: "\n")
}

func executablePath() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("pinwheel: \(message)\n".utf8))
    exit(code)
}

/// Custom actions, read from Pinwheel's settings.
func listCustomActions() {
    let defaults = UserDefaults(suiteName: bundleID)
    let data = defaults?.data(forKey: "recipes") ?? Data()
    let recipes = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    guard !recipes.isEmpty else {
        print("No custom actions yet. Make them in Pinwheel's Settings › Tools wheel.")
        return
    }
    for recipe in recipes {
        let name = recipe["name"] as? String ?? "?"
        let kind = recipe["kind"] as? String ?? ""
        print("\(name)\t(\(kind))")
    }
}

// MARK: - Talking to the app

/// Follows the replies to one request.
final class Conversation: @unchecked Sendable {
    let id = UUID().uuidString
    var accepted = false
    var finished = false
    var outputs: [String] = []
    var messages: [String] = []
    var failed = false
    private var observer: NSObjectProtocol?

    func listen() {
        observer = DistributedNotificationCenter.default().addObserver(forName: replyName, object: nil, queue: .main) { [self] note in
            guard let info = note.userInfo, info["id"] as? String == id else { return }
            let state = info["state"] as? String ?? ""
            outputs = info["outputs"] as? [String] ?? outputs
            messages = info["messages"] as? [String] ?? messages
            switch state {
            case "accepted": accepted = true
            case "finished": accepted = true; finished = true
            default: accepted = true; finished = true; failed = true
            }
        }
    }

    func send(_ request: [String: Any]) {
        var info = request
        info["id"] = id
        DistributedNotificationCenter.default().postNotificationName(requestName, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// Runs until `done` is true or the time is up; false when it's up.
    func wait(seconds: Double, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() >= deadline { return false }
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.1)))
        }
        return true
    }
}

/// Starts Pinwheel in the background (`front: false`), or brings it to the
/// front: an app may not bring itself forward when the request came from
/// Terminal or Shortcuts, but opening it does.
func openPinwheel(front: Bool) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = front ? ["-b", bundleID] : ["-g", "-j", "-b", bundleID]
    try? open.run()
    open.waitUntilExit()
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
var wait = true
if let index = arguments.firstIndex(of: "--no-wait") {
    wait = false
    arguments.remove(at: index)
}
guard let name = arguments.first, !["help", "-h", "--help"].contains(name) else {
    print(usage())
    exit(0)
}
if name == "list" {
    listCustomActions()
    exit(0)
}
guard let command = commands.first(where: { $0.name == name }) else {
    fail("unknown command “\(name)”. Try: pinwheel help", code: 2)
}
var rest = Array(arguments.dropFirst())
var value: String?
if command.value != nil {
    if command.valueIsOptional {
        if let first = rest.first, ["tools", "formats", "convert"].contains(first) { value = rest.removeFirst() }
    } else {
        guard !rest.isEmpty else { fail("“\(name)” needs \(command.value!) first. Try: pinwheel help", code: 2) }
        value = rest.removeFirst()
    }
}
let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let files = rest.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: current).standardizedFileURL.path }
guard !files.isEmpty else { fail("no files given. Try: pinwheel help", code: 2) }
for file in files where !FileManager.default.fileExists(atPath: file) {
    fail("\(file) doesn't exist.", code: 2)
}

let conversation = Conversation()
conversation.listen()
var request: [String: Any] = ["command": name, "files": files, "wait": wait]
if let value { request["value"] = value }
conversation.send(request)
if !conversation.wait(seconds: 1.5, until: { conversation.accepted }) && testChannel == nil {
    // Not running (or still starting): start it, then ask again until it answers.
    openPinwheel(front: false)
    var heard = false
    for _ in 0..<30 where !heard {
        conversation.send(request)
        heard = conversation.wait(seconds: 1, until: { conversation.accepted })
    }
    if !heard { fail("Pinwheel didn't answer. Is it in your Applications folder?", code: 3) }
}
if !conversation.accepted { fail("nobody answered on the test channel.", code: 3) }
// A window was opened: show it in front of the app the command came from.
if name == "open" && testChannel == nil { openPinwheel(front: true) }
if wait {
    _ = conversation.wait(seconds: 6 * 3600, until: { conversation.finished })
}
for output in conversation.outputs { print(output) }
for message in conversation.messages { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
exit(conversation.failed ? 1 : 0)
