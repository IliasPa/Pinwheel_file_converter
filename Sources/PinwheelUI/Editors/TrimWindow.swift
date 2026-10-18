import AppKit
import AVKit
import PinwheelCore

/// QuickTime-style trimming: drag the yellow handles, then Trim. Videos can
/// also save the frame under the playhead. Several files come one after another.
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private let files: [SourceFile]
    private var index = 0
    private let onTrim: (SourceFile, Double, Double) -> Void
    private let onFrame: (SourceFile, Double) -> Void

    private let playerView = AVPlayerView()
    private let hint = NSTextField(labelWithString: "")
    private lazy var frameButton = NSButton(title: "Save This Frame", target: self, action: #selector(saveFrame))
    private var waiting: Task<Void, Never>?

    init(
        files: [SourceFile],
        onTrim: @escaping (SourceFile, Double, Double) -> Void,
        onFrame: @escaping (SourceFile, Double) -> Void
    ) {
        self.files = files
        self.onTrim = onTrim
        self.onFrame = onFrame
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 560, height: 380)
        super.init(window: window)
        window.delegate = self

        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.lineBreakMode = .byTruncatingTail
        frameButton.bezelStyle = .rounded
        frameButton.toolTip = "Saves the frame under the playhead as a JPEG next to the video."

        let bar = NSStackView(views: [hint, NSView(), frameButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let stack = NSStackView(views: [playerView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        playerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var file: SourceFile { files[index] }

    private func load() {
        let name = file.url.lastPathComponent
        window?.title = files.count > 1 ? "Trim \(name) (\(index + 1) of \(files.count))" : "Trim \(name)"
        playerView.player = AVPlayer(url: file.url)
        frameButton.isHidden = file.kind != .video
        hint.stringValue = "Drag the yellow handles to choose the part to keep, then click Trim."
        startTrimming()
    }

    /// The trim bar can appear only once the player has loaded the file.
    private func startTrimming() {
        waiting?.cancel()
        waiting = Task {
            for _ in 0..<100 where !playerView.canBeginTrimming {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            guard playerView.canBeginTrimming else {
                hint.stringValue = "This file can't be trimmed here."
                return
            }
            let result = await playerView.beginTrimming()
            trimmingEnded(result)
        }
    }

    private func trimmingEnded(_ result: AVPlayerViewTrimResult) {
        guard let item = playerView.player?.currentItem else { return }
        if result == .okButton {
            let duration = item.duration.isNumeric ? item.duration.seconds : 0
            let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
            let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : duration
            // Trim with nothing cut off would only make a copy.
            if end > start, start > 0.05 || end < duration - 0.05 {
                onTrim(file, start, end)
            }
        }
        next()
    }

    private func next() {
        if index + 1 < files.count {
            index += 1
            load()
        } else {
            window?.close()
        }
    }

    @objc private func saveFrame() {
        guard let player = playerView.player else { return }
        let seconds = player.currentTime().seconds
        onFrame(file, seconds)
        hint.stringValue = "Saving the frame at \(String(format: "%.2f", seconds)) s…"
    }

    func windowWillClose(_ notification: Notification) {
        waiting?.cancel()
        playerView.player?.pause()
        playerView.player = nil
    }
}
