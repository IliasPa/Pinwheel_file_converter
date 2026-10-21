import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import PinwheelCore

/// A sound into a video with moving bars or a wave, over a picture or a
/// gradient: for sharing music, podcasts and voice notes where only videos
/// go. The preview shows the look; Make Video listens to the whole sound.
@Observable
final class VisualizerModel {
    let files: [SourceFile]
    private(set) var spec = VisualizerSpec()
    private(set) var preview: CGImage?
    /// What the video's title is.
    var titleMode = TitleMode.fileName {
        didSet { schedulePreview() }
    }
    var customTitle = "" {
        didSet { if titleMode == .custom { schedulePreview() } }
    }

    var onSave: (([ConversionRequest]) -> Void)?
    var onClose: (() -> Void)?

    enum TitleMode: String, CaseIterable {
        case none, fileName, custom

        var title: String {
            switch self {
            case .none: "None"
            case .fileName: "File name"
            case .custom: "Your text"
            }
        }
    }

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewAgain = false

    init(files: [SourceFile]) {
        self.files = files
        schedulePreview()
    }

    func change(_ body: (inout VisualizerSpec) -> Void) {
        body(&spec)
        schedulePreview()
    }

    func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to go behind the sound"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { $0.picture = url.path }
    }

    /// The look for one file, with its title.
    func spec(for file: SourceFile) -> VisualizerSpec {
        var spec = spec
        switch titleMode {
        case .none: spec.title = ""
        case .fileName: spec.title = file.url.deletingPathExtension().lastPathComponent
        case .custom: spec.title = customTitle
        }
        return spec
    }

    func save() {
        onSave?(files.map { ConversionRequest(file: $0, action: .tool(.visualize), parameters: .visualizer(spec(for: $0))) })
        onClose?()
    }

    private struct Drawn: @unchecked Sendable {
        let image: CGImage?
    }

    private func schedulePreview() {
        previewAgain = true
        guard previewTask == nil else { return }
        previewTask = Task {
            while previewAgain {
                previewAgain = false
                guard let first = files.first else { break }
                preview = await Self.draw(spec(for: first)).image
            }
            previewTask = nil
        }
    }

    @concurrent
    private nonisolated static func draw(_ spec: VisualizerSpec) async -> Drawn {
        Drawn(image: Visualizer.preview(spec, longerSide: 720))
    }
}

struct VisualizerView: View {
    @Bindable var model: VisualizerModel

    private var spec: VisualizerSpec { model.spec }
    private static let colors: [MarkupColor] = [.white, .yellow, MarkupColor(hex: 0x5EEAD4), MarkupColor(hex: 0x93C5FD), MarkupColor(hex: 0xF9A8D4), .black]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                canvas
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { controls }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 290)
                .background(.background)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                StudioCanvas.background
                if let preview = model.preview {
                    let rect = StudioCanvas.fit(CGSize(width: preview.width, height: preview.height), in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 28, dy: 28))
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        PanelSection(title: "Shape") {
            Picker("Shape", selection: Binding(get: { spec.shape }, set: { shape in model.change { $0.shape = shape } })) {
                ForEach(VisualizerSpec.Shape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }

        PanelSection(title: "Moves as") {
            Picker("Style", selection: Binding(get: { spec.style }, set: { style in model.change { $0.style = style } })) {
                ForEach(VisualizerSpec.Style.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 7) {
                ForEach(Self.colors, id: \.self) { color in
                    Button { model.change { $0.color = color } } label: {
                        Circle()
                            .fill(color.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 20, height: 20)
                            .padding(2)
                            .overlay(Circle().strokeBorder(spec.color == color ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { spec.color.color }, set: { color in model.change { $0.color = MarkupColor(color) } }), supportsOpacity: false)
                    .labelsHidden()
            }
        }

        PanelSection(title: "Behind it") {
            HStack {
                Button(spec.picture == nil ? "Choose a Picture…" : "Another Picture…", action: model.choosePicture)
                if spec.picture != nil {
                    Button("Remove") { model.change { $0.picture = nil } }
                }
            }
            if let picture = spec.picture {
                Text(URL(fileURLWithPath: picture).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 6)], spacing: 6) {
                    ForEach(GradientPreset.allCases, id: \.self) { preset in
                        Button { model.change { $0.gradient = preset } } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(preset.gradient)
                                .frame(width: 26, height: 26)
                                .padding(2)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(spec.gradient == preset ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(preset.rawValue.capitalized)
                    }
                }
            }
        }

        PanelSection(title: "Title") {
            Picker("Title", selection: $model.titleMode) {
                ForEach(VisualizerModel.TitleMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.titleMode == .custom {
                TextField("Title", text: $model.customTitle).textFieldStyle(.roundedBorder)
            }
        }

        Text("The bars follow the pitches of the sound, low on the left; the wave follows the sound itself. The video is MP4, 30 frames a second, with the sound as it is.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.files.count == 1 ? model.files[0].url.lastPathComponent : "\(model.files.count) sounds")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Int(spec.shape.size.width)) × \(Int(spec.shape.size.height)) px")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button(model.files.count == 1 ? "Make Video" : "Make \(model.files.count) Videos", action: model.save)
                .keyboardShortcut(.defaultAction)
                .help("Saves an MP4 next to each sound, named “… (visualizer)”")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

final class VisualizerWindowController: EditorWindowController {
    init(model: VisualizerModel) {
        let title = model.files.count == 1 ? "Visualizer for \(model.files[0].url.lastPathComponent)" : "Visualizer for \(model.files.count) Sounds"
        super.init(title: title, size: NSSize(width: 1000, height: 680), content: VisualizerView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
