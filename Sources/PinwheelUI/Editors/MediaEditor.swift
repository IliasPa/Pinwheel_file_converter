import AppKit
import AVFoundation
import Observation
import SwiftUI
import PinwheelCore

/// The video and audio editor: keep a part, change the speed, turn the
/// picture, mute, fade, make louder or even out the loudness; save the
/// result, a GIF of the part, or one frame. Each file has its own part; the
/// other changes can be the same for all of them.
@Observable
final class MediaEditorModel {
    let files: [SourceFile]
    var index = 0 {
        didSet { if index != oldValue { load() } }
    }
    private(set) var edits: [MediaEdit]
    /// Speed, turn and sound changes go to every file.
    var sameForAll = true

    // The file shown
    private(set) var duration: Double = 0
    private(set) var isVideo = false
    /// Frames along the timeline, turned like the picture will be.
    private(set) var filmstrip: [CGImage] = []
    @ObservationIgnored private var uprightFilmstrip: [CGImage] = []
    private(set) var waveform: [Float] = []
    private(set) var loudness: Double?
    private(set) var isMeasuring = false
    private(set) var loadError: String?
    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var dragging: Handle?

    var gifNeedsFFmpeg: Bool
    var onSave: ((SourceFile, MediaEdit) -> Void)?
    var onGIF: ((SourceFile, MediaEdit) -> Void)?
    var onFrame: ((SourceFile, Double, Int) -> Void)?
    var onClose: (() -> Void)?

    enum Handle { case start, end, playhead }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(files: [SourceFile], ffmpegAvailable: Bool) {
        self.files = files
        edits = Array(repeating: MediaEdit(), count: files.count)
        gifNeedsFFmpeg = !ffmpegAvailable
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        load()
    }

    var file: SourceFile { files[index] }
    var edit: MediaEdit { edits[index] }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        loadTask?.cancel()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Loading

    func load() {
        generation += 1
        let current = generation
        loadTask?.cancel()
        player.pause()
        (duration, filmstrip, waveform, loudness, loadError, currentTime, isPlaying) = (0, [], [], nil, nil, 0, false)
        uprightFilmstrip = []
        let url = file.url
        isVideo = file.kind == .video
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        loadTask = Task {
            let asset = AVURLAsset(url: url)
            do {
                let length = try await asset.load(.duration).seconds
                guard current == generation else { return }
                duration = length.isFinite ? length : 0
                applyPreview()
                if isVideo {
                    let strip = try await Self.filmstrip(of: asset, duration: duration)
                    guard current == generation else { return }
                    uprightFilmstrip = strip.images
                    turnFilmstrip()
                } else {
                    let peaks = try await MediaAnalysis.waveform(of: url, count: 600)
                    guard current == generation else { return }
                    waveform = peaks
                }
                if edit.normalize { measure() }
            } catch is CancellationError {
            } catch {
                guard current == generation else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private struct Filmstrip: @unchecked Sendable {
        var images: [CGImage] = []
    }

    private nonisolated static func filmstrip(of asset: AVURLAsset, duration: Double) async throws -> Filmstrip {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let count = 14
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var strip = Filmstrip()
        for await result in generator.images(for: times) {
            if let image = try? result.image { strip.images.append(image) }
        }
        return strip
    }

    /// The loudness, shown when evening it out.
    func measure() {
        guard loudness == nil, !isMeasuring else { return }
        isMeasuring = true
        let current = generation
        let url = file.url
        Task {
            let result = try? await MediaAnalysis.loudness(of: url)
            guard current == generation else { return }
            loudness = result?.loudness
            isMeasuring = false
        }
    }

    // MARK: - Changing the edit

    /// Changes this file's part, or the shared settings (for every file when `sameForAll`).
    func change(_ body: (inout MediaEdit) -> Void) {
        let before = edits[index]
        var after = before
        body(&after)
        edits[index] = after
        if sameForAll && files.count > 1 {
            for other in edits.indices where other != index {
                edits[other].speed = after.speed
                edits[other].quarterTurns = after.quarterTurns
                edits[other].mute = after.mute
                edits[other].fadeIn = after.fadeIn
                edits[other].fadeOut = after.fadeOut
                edits[other].volume = after.volume
                edits[other].normalize = after.normalize
            }
        }
        if after.normalize && !before.normalize { measure() }
        if after.quarterTurns != before.quarterTurns { turnFilmstrip() }
        applyPreview()
    }

    private func turnFilmstrip() {
        let turns = edit.quarterTurns
        filmstrip = turns == 0 ? uprightFilmstrip : uprightFilmstrip.compactMap { Self.turned($0, quarterTurns: turns) }
    }

    /// A small picture turned clockwise by quarter turns.
    static func turned(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        let sideways = turns % 2 == 1
        let width = sideways ? image.height : image.width, height = sideways ? image.width : image.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Core Graphics has y up, so clockwise is a negative angle.
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    func turn(clockwise: Bool) {
        change { $0.quarterTurns = (($0.quarterTurns + (clockwise ? 1 : 3)) % 4) }
    }

    func reset() {
        change { $0 = MediaEdit() }
    }

    var start: Double { edit.range(duration: max(duration, 0.1)).start }
    var end: Double { edit.range(duration: max(duration, 0.1)).end }

    /// The result's length, at the chosen speed.
    var resultLength: Double { (end - start) / edit.speed }

    /// Plays the preview the way it will sound: speed, fades and quieter volume.
    private func applyPreview() {
        guard let item = player.currentItem else { return }
        player.defaultRate = Float(edit.speed)
        if isPlaying { player.rate = Float(edit.speed) }
        player.isMuted = edit.mute
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let level = Float(min(pow(10, (edit.normalize ? 0 : edit.volume) / 20), 1))
            let (start, end) = (self.start, self.end)
            parameters.setVolume(level, at: .zero)
            if edit.fadeIn > 0 {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: edit.fadeIn * edit.speed, preferredTimescale: 600)
                ))
            }
            if edit.fadeOut > 0 {
                let length = edit.fadeOut * edit.speed
                parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(
                    start: CMTime(seconds: max(end - length, start), preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600)
                ))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    // MARK: - Playing and the timeline

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime < start || currentTime >= end - 0.05 { seek(to: start) }
            player.rate = Float(edit.speed)
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let time = min(max(seconds, 0), duration)
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, dragging == nil else { return }
        currentTime = seconds
        // Plays just the part.
        if isPlaying && seconds >= end {
            player.pause()
            isPlaying = false
            seek(to: end)
        }
        if player.rate == 0 && isPlaying && player.currentItem?.status == .readyToPlay && seconds >= duration - 0.05 {
            isPlaying = false
        }
    }

    /// `seconds` is where the pointer went down; picks the nearest handle
    /// within `reach` seconds, else the playhead.
    func beginDrag(at seconds: Double, reach: Double) {
        if isPlaying { togglePlay() }
        if abs(seconds - start) <= reach && abs(seconds - start) <= abs(seconds - end) {
            dragging = .start
        } else if abs(seconds - end) <= reach {
            dragging = .end
        } else {
            dragging = .playhead
        }
        drag(to: seconds)
    }

    func drag(to seconds: Double) {
        let time = min(max(seconds, 0), duration)
        let shortest = min(0.1, duration / 2)
        switch dragging {
        case .start:
            change { $0.start = min(time, end - shortest) }
            seek(to: start)
        case .end:
            change { $0.end = max(time, start + shortest) >= duration - 0.01 ? nil : max(time, start + shortest) }
            seek(to: end)
        case .playhead:
            seek(to: time)
        case nil:
            break
        }
    }

    func endDrag() {
        dragging = nil
    }

    func setStartToPlayhead() { change { $0.start = min(currentTime, end - 0.1) } }
    func setEndToPlayhead() { change { $0.end = max(currentTime, start + 0.1) } }

    // MARK: - Saving

    /// Files with something to save.
    var changedCount: Int {
        edits.enumerated().filter { index, edit in !isUnchanged(edit, index: index) }.count
    }

    private func isUnchanged(_ edit: MediaEdit, index: Int) -> Bool {
        index == self.index && duration > 0 ? edit.isEmpty(duration: duration) : (edit.isTrimOnly && edit.start <= 0 && edit.end == nil)
    }

    func save() {
        for (index, edit) in edits.enumerated() where !isUnchanged(edit, index: index) {
            onSave?(files[index], edit)
        }
        close()
        onClose?()
    }

    func saveGIF() {
        onGIF?(file, edit)
    }

    func saveFrame() {
        onFrame?(file, currentTime, edit.quarterTurns)
    }

    func cancel() {
        close()
        onClose?()
    }
}

// MARK: - Views

struct MediaEditorView: View {
    @Bindable var model: MediaEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    stage
                    TimelineStrip(model: model)
                        .frame(height: 64)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    transport
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .background(StudioCanvas.background)
                Divider()
                ScrollView {
                    MediaControls(model: model)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 290)
                .background(.background)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 540)
    }

    @ViewBuilder
    private var stage: some View {
        ZStack {
            if model.isVideo {
                PlayerSurface(player: model.player, quarterTurns: model.edit.quarterTurns)
                    .padding(16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(model.file.url.lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            if let error = model.loadError {
                Text(error).foregroundStyle(.white).padding().background(.red.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 24)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play the part (Space)")
            Text("\(Self.time(model.currentTime)) / \(Self.time(model.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button("Start Here", action: model.setStartToPlayhead).help("The part starts at the playhead")
            Button("End Here", action: model.setEndToPlayhead).help("The part ends at the playhead")
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.files.count > 1 {
                HStack(spacing: 4) {
                    Button { model.index -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(model.index == 0)
                    Text("\(model.index + 1) of \(model.files.count)").monospacedDigit()
                    Button { model.index += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(model.index == model.files.count - 1)
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.file.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("Part \(Self.time(model.start, tenths: true))–\(Self.time(model.end, tenths: true)) · result \(Self.time(model.resultLength, tenths: true))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isVideo {
                Button("Save Frame", action: model.saveFrame)
                    .help("Saves the frame under the playhead as a JPEG, turned as shown")
                Button("Save as GIF", action: model.saveGIF)
                    .disabled(model.gifNeedsFFmpeg)
                    .help(model.gifNeedsFFmpeg ? "Needs ffmpeg (brew install ffmpeg)" : "An animated GIF of the part, at this speed and turn")
            }
            Button("Cancel", action: model.cancel)
                .keyboardShortcut(.cancelAction)
            Button(model.changedCount > 1 ? "Save \(model.changedCount) Copies" : "Save Copy", action: model.save)
                .keyboardShortcut(.defaultAction)
                .disabled(model.changedCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// "1:05" or "1:05.3"
    static func time(_ seconds: Double, tenths: Bool = false) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(seconds)
        let text = String(format: "%d:%02d", whole / 60, whole % 60)
        return tenths ? text + String(format: ".%d", Int((seconds - Double(whole)) * 10)) : text
    }
}

/// The filmstrip (or waveform) with the yellow part handles and the playhead.
private struct TimelineStrip: View {
    var model: MediaEditorModel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let scale = width / max(model.duration, 0.001)
            let startX = model.start * scale, endX = model.end * scale
            ZStack(alignment: .topLeading) {
                strip(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // Outside the part is dimmed.
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(startX, 0), height: height)
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(width - endX, 0), height: height).offset(x: endX)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(endX - startX, 6), height: height)
                    .offset(x: startX)
                handle.offset(x: startX - 4)
                handle.offset(x: endX - 6)
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: height + 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: model.currentTime * scale - 1, y: -4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let seconds = value.location.x / scale
                        if model.dragging == nil {
                            model.beginDrag(at: value.startLocation.x / scale, reach: 12 / scale)
                        }
                        model.drag(to: seconds)
                    }
                    .onEnded { _ in model.endDrag() }
            )
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 10)
            .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 2, height: 18))
    }

    @ViewBuilder
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        if model.isVideo {
            HStack(spacing: 0) {
                ForEach(Array(model.filmstrip.enumerated()), id: \.offset) { _, frame in
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(max(model.filmstrip.count, 1)), height: height)
                        .clipped()
                }
            }
            .frame(width: width, height: height, alignment: .leading)
            .background(Color.white.opacity(0.08))
        } else {
            Canvas { context, size in
                let peaks = model.waveform
                guard !peaks.isEmpty else { return }
                let step = size.width / CGFloat(peaks.count)
                // Scaled to the loudest moment, so quiet recordings show their shape too.
                let loudest = CGFloat(max(peaks.max() ?? 1, 0.01))
                var path = Path()
                for (index, peak) in peaks.enumerated() {
                    let bar = max(CGFloat(peak) / loudest * size.height * 0.9, 1)
                    path.addRect(CGRect(x: CGFloat(index) * step, y: (size.height - bar) / 2, width: max(step - 0.5, 0.5), height: bar))
                }
                context.fill(path, with: .color(Brand.teal.opacity(0.9)))
            }
            .background(Color.white.opacity(0.08))
        }
    }
}

/// Speed, turn and sound.
private struct MediaControls: View {
    var model: MediaEditorModel

    private var edit: MediaEdit { model.edit }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isVideo {
                PanelSection(title: "Picture") {
                    HStack(spacing: 6) {
                        Button { model.turn(clockwise: false) } label: {
                            Label("Turn Left", systemImage: "rotate.left").frame(maxWidth: .infinity)
                        }
                        Button { model.turn(clockwise: true) } label: {
                            Label("Turn Right", systemImage: "rotate.right").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            PanelSection(title: "Speed") {
                Picker("Speed", selection: Binding(get: { edit.speed }, set: { speed in model.change { $0.speed = speed } })) {
                    ForEach(MediaEdit.speeds, id: \.self) { Text(MediaEdit.speedTitle($0)).tag($0) }
                }
                .labelsHidden()
                Text(edit.speed == 1 ? "Voices keep their pitch at any speed." : "Plays \(MediaEdit.speedTitle(edit.speed)) as fast; voices keep their pitch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PanelSection(title: "Sound") {
                if model.isVideo {
                    Toggle("Mute", isOn: Binding(get: { edit.mute }, set: { on in model.change { $0.mute = on } }))
                }
                Group {
                    slider("Fade in", value: edit.fadeIn, range: 0...5, unit: "s") { value in model.change { $0.fadeIn = value } }
                    slider("Fade out", value: edit.fadeOut, range: 0...5, unit: "s") { value in model.change { $0.fadeOut = value } }
                    slider("Volume", value: edit.volume, range: -20...20, unit: "dB") { value in model.change { $0.volume = value } }
                        .disabled(edit.normalize)
                    Toggle("Even out loudness (−16 LUFS)", isOn: Binding(get: { edit.normalize }, set: { on in model.change { $0.normalize = on } }))
                    if edit.normalize { loudnessNote }
                }
                .disabled(edit.mute)
            }
            if model.files.count > 1 {
                Toggle("Same changes for all \(model.files.count) files", isOn: Binding(get: { model.sameForAll }, set: { model.sameForAll = $0 }))
                Text("Each file keeps its own part; speed, turn and sound are shared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Reset", action: model.reset)
            Text("Drag the yellow handles to choose the part to keep. Space plays it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var loudnessNote: some View {
        if model.isMeasuring {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Measuring…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let loudness = model.loudness {
            Text(String(format: "Now %.1f LUFS, so %@ %.1f dB (peaks permitting).", loudness,
                        loudness < MediaEdit.targetLoudness ? "louder by" : "quieter by", abs(MediaEdit.targetLoudness - loudness)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, unit: String, set: @escaping @MainActor (Double) -> Void) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(unit == "dB" ? String(format: "%+.0f dB", value) : String(format: "%.1f s", value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { set(unit == "dB" ? $0.rounded() : ($0 * 10).rounded() / 10) }), in: range)
                .controlSize(.small)
        }
    }
}

/// Shows the video, turned as it will be saved.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let quarterTurns: Int

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.quarterTurns = quarterTurns
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var quarterTurns = 0 {
        didSet { if quarterTurns != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let turned = quarterTurns % 2 != 0
        playerLayer.bounds = CGRect(origin: .zero, size: turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Layers here have y up, so clockwise is a negative angle.
        playerLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2))
        CATransaction.commit()
    }
}

final class MediaEditorWindowController: EditorWindowController {
    let model: MediaEditorModel

    init(model: MediaEditorModel) {
        self.model = model
        let title = model.files.count == 1 ? "Edit \(model.files[0].url.lastPathComponent)" : "Edit \(model.files.count) Files"
        super.init(title: title, size: NSSize(width: 1060, height: 680), content: MediaEditorView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
        onClose = { [weak model] in model?.close() }
    }
}
