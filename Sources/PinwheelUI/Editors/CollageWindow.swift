import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// Several photos as one picture: a grid, rows, or a contact sheet. The
/// preview uses small copies; Save draws it again at full size.
@Observable
final class CollageModel {
    private(set) var files: [SourceFile]
    private(set) var spec = CollageSpec()
    private(set) var preview: CGImage?
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var error: String?

    var onSave: (([SourceFile], CollageSpec) -> Void)?
    var onClose: (() -> Void)?

    /// Small copies for the preview, loaded once.
    @ObservationIgnored private var pictures: [URL: CGImage] = [:]
    @ObservationIgnored private var sizes: [URL: CGSize] = [:]
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderAgain = false

    static let previewWidth = 1400

    init(files: [SourceFile]) {
        self.files = files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        if files.count <= 3 { spec.cellAspect = nil }
        load()
    }

    private struct Loaded: @unchecked Sendable {
        var pictures: [URL: CGImage] = [:]
        var sizes: [URL: CGSize] = [:]
    }

    private func load() {
        let urls = files.map(\.url)
        Task {
            let loaded = await Self.loadSmall(urls)
            pictures = loaded.pictures
            sizes = loaded.sizes
            thumbnails = loaded.pictures.mapValues { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            scheduleRender()
        }
    }

    @concurrent
    private nonisolated static func loadSmall(_ urls: [URL]) async -> Loaded {
        var loaded = Loaded()
        for url in urls {
            guard let size = try? CollageRenderer.sizes(of: [url]).first,
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = try? ImageConverter.orientedImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxPixelSize: 700)
            else { continue }
            loaded.sizes[url] = size
            loaded.pictures[url] = image
        }
        return loaded
    }

    // MARK: - Changes

    func change(_ body: (inout CollageSpec) -> Void) {
        body(&spec)
        scheduleRender()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        files.move(fromOffsets: offsets, toOffset: destination)
        scheduleRender()
    }

    func sortByName() {
        files.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        scheduleRender()
    }

    func shuffle() {
        files.shuffle()
        scheduleRender()
    }

    /// The saved picture's size.
    var outputSize: CGSize {
        let known = files.compactMap { sizes[$0.url] }
        guard known.count == files.count else { return .zero }
        return CollageLayout.make(for: known, spec: spec).canvas
    }

    func save() {
        onSave?(files, spec)
        onClose?()
    }

    // MARK: - Drawing

    private struct Request: @unchecked Sendable {
        let pictures: [CGImage]
        let sizes: [CGSize]
        let names: [String]
        let spec: CollageSpec
    }

    private struct Result: @unchecked Sendable {
        var image: CGImage?
        var error: String?
    }

    private func scheduleRender() {
        renderAgain = true
        guard renderTask == nil else { return }
        renderTask = Task {
            while renderAgain {
                renderAgain = false
                let ready = files.compactMap { file in pictures[file.url].flatMap { picture in sizes[file.url].map { (picture, $0) } } }
                guard ready.count == files.count, !ready.isEmpty else { break }
                var previewSpec = spec
                previewSpec.width = Self.previewWidth
                let result = await Self.render(Request(
                    pictures: ready.map(\.0), sizes: ready.map(\.1), names: files.map(\.url.lastPathComponent), spec: previewSpec
                ))
                preview = result.image ?? preview
                error = result.error
            }
            renderTask = nil
        }
    }

    @concurrent
    private nonisolated static func render(_ request: Request) async -> Result {
        do {
            let layout = CollageLayout.make(for: request.sizes, spec: request.spec)
            return Result(image: try CollageRenderer.render(request.pictures, names: request.names, spec: request.spec, layout: layout))
        } catch {
            return Result(error: error.localizedDescription)
        }
    }
}

struct CollageView: View {
    var model: CollageModel

    private var spec: CollageSpec { model.spec }
    private static let backgrounds: [MarkupColor] = [.white, MarkupColor(hex: 0xF2F2F7), MarkupColor(hex: 0x1C1C1E), .black, MarkupColor(hex: 0xFDF6E3)]
    private static let shapes: [AspectRatio?] = [.square, AspectRatio(4, 3), AspectRatio(3, 4), AspectRatio(16, 9), nil]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                canvas
                Divider()
                ScrollView {
                    controls
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 300)
                .background(.background)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 560)
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
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) { controlSections }
    }

    @ViewBuilder
    private var controlSections: some View {
        PanelSection(title: "Layout") {
            Picker("Layout", selection: Binding(get: { spec.layout }, set: { layout in
                model.change { spec in
                    spec.layout = layout
                    // Contact sheets look best with cells shaped like the photos.
                    if layout == .contactSheet { spec.cellAspect = nil }
                }
            })) {
                ForEach(CollageSpec.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Stepper(value: Binding(get: { spec.columns }, set: { columns in model.change { $0.columns = max(0, min(columns, 12)) } }), in: 0...12) {
                Text(spec.columns == 0 ? "Across: automatic" : "Across: \(spec.columns)")
            }
            if spec.layout != .rows {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                    ForEach(Self.shapes, id: \.self) { shape in
                        ChoiceButton(title: shape.map { $0 == .square ? "1:1" : $0.title } ?? "Photos", isOn: spec.cellAspect == shape) {
                            model.change { $0.cellAspect = shape }
                        }
                    }
                }
            }
            if spec.layout == .contactSheet {
                TextField("Title (optional)", text: Binding(get: { spec.title }, set: { title in model.change { $0.title = title } }))
                    .textFieldStyle(.roundedBorder)
            }
        }

        PanelSection(title: "Look") {
            slider("Spacing", spec.spacing, 0...0.05) { value in model.change { $0.spacing = value } }
            slider("Margin", spec.margin, 0...0.08) { value in model.change { $0.margin = value } }
            slider("Corners", spec.cornerRadius, 0...0.5) { value in model.change { $0.cornerRadius = value } }
            HStack(spacing: 8) {
                ForEach(Self.backgrounds, id: \.self) { color in
                    Button { model.change { $0.background = color } } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color.color)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 26, height: 26)
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(spec.background == color ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { spec.background.color }, set: { color in model.change { $0.background = MarkupColor(color) } }), supportsOpacity: false)
                    .labelsHidden()
            }
        }

        PanelSection(title: "Order") {
            List {
                ForEach(model.files, id: \.url) { file in
                    HStack(spacing: 8) {
                        if let thumbnail = model.thumbnails[file.url] {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                }
                .onMove(perform: model.move)
            }
            .frame(height: min(CGFloat(model.files.count) * 38 + 12, 230))
            .listStyle(.bordered)
            HStack {
                Button("Sort by Name", action: model.sortByName)
                Button("Shuffle", action: model.shuffle)
            }
            .controlSize(.small)
            Text("Drag names to change the order.").font(.caption).foregroundStyle(.secondary)
        }

        PanelSection(title: "Size and format") {
            Picker("Width", selection: Binding(get: { spec.width }, set: { width in model.change { $0.width = width } })) {
                ForEach(CollageSpec.widths, id: \.self) { Text("\($0) px wide").tag($0) }
            }
            Picker("Format", selection: Binding(get: { spec.format }, set: { format in model.change { $0.format = format } })) {
                ForEach([OutputFormat.jpeg, .png, .heic], id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping @MainActor (Double) -> Void) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
            }
            Slider(value: Binding(get: { value }, set: set), in: range).controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.files.count) pictures").font(.system(size: 12, weight: .medium))
                let size = model.outputSize
                Text(size == .zero ? " " : "\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer()
            Button("Cancel") { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button("Save Collage", action: model.save)
                .keyboardShortcut(.defaultAction)
                .help("Saves the collage next to the first picture, named “… (collage)”")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

final class CollageWindowController: EditorWindowController {
    init(model: CollageModel) {
        super.init(title: "Collage of \(model.files.count) Pictures", size: NSSize(width: 1100, height: 740), content: CollageView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
