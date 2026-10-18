import AppKit
import SwiftUI
import PinwheelCore

/// The controls beside the picture, for the chosen tab.
struct StudioSidebar: View {
    var model: StudioModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.tab {
                case .crop: CropPanel(model: model)
                case .adjust: AdjustPanel(model: model)
                case .background: BackgroundPanel(model: model)
                case .markup: MarkupPanel(model: model)
                case .watermark: WatermarkPanel(model: model)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Shared pieces

struct PanelSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                trailing
            }
            content
        }
    }
}

/// A slider with its name and value; one undo step per move.
struct EditSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// How the value reads, e.g. "+35" or "20%".
    let label: (Double) -> String
    let model: StudioModel
    let set: @MainActor (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(label(value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { value }, set: set),
                in: range
            ) { editing in
                editing ? model.beginSliding() : model.endSliding()
            }
            .controlSize(.small)
        }
        .contextMenu {
            Button("Reset \(title)") {
                model.beginSliding()
                set(range.contains(0) ? 0 : range.lowerBound)
                model.endSliding()
            }
        }
    }

    /// −100…+100
    static func signed(_ value: Double) -> String {
        let number = Int((value * 100).rounded())
        return number > 0 ? "+\(number)" : "\(number)"
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// A small rounded button that shows whether it's chosen.
struct ChoiceButton: View {
    let title: String
    var symbol: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor : Color.clear, lineWidth: 1.2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension MarkupColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

extension GradientPreset {
    var gradient: LinearGradient {
        LinearGradient(colors: colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Crop

private struct CropPanel: View {
    var model: StudioModel

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 6)]

    var body: some View {
        PanelSection(title: "Shape") {
            LazyVGrid(columns: columns, spacing: 6) {
                ChoiceButton(title: "Free", isOn: model.aspect == nil) { model.choose(aspect: nil) }
                ChoiceButton(title: "Original", isOn: model.aspect == model.originalAspect) { model.choose(aspect: model.originalAspect) }
                ForEach(AspectRatio.presets, id: \.self) { preset in
                    let isOn = model.aspect == preset || model.aspect == preset.flipped
                    ChoiceButton(title: preset == .square ? "Square" : (isOn ? model.aspect!.title : preset.title), isOn: isOn) {
                        model.choose(aspect: preset)
                    }
                }
            }
            if let shape = model.aspect, shape.width != shape.height {
                Button {
                    model.turnAspect()
                } label: {
                    Label(shape.isPortrait ? "Make Landscape" : "Make Portrait", systemImage: shape.isPortrait ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                }
                .controlSize(.small)
            }
        }

        PanelSection(title: "Size") {
            HStack(spacing: 6) {
                NumberField(title: "Width", value: model.resultSize.width, set: model.setResultWidth)
                Text("×").foregroundStyle(.secondary)
                NumberField(title: "Height", value: model.resultSize.height, set: model.setResultHeight)
                Text("px").foregroundStyle(.secondary)
            }
            sizeNote
        }

        PanelSection(title: "Straighten") {
            EditSlider(
                title: "Angle", value: model.edit.straighten, range: -45...45,
                label: { String(format: "%+.1f°", $0) }, model: model, set: model.setStraighten
            )
            Text("Levels a tilted horizon. The picture is enlarged just enough to leave no empty corners.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        PanelSection(title: "Turn and flip") {
            HStack(spacing: 6) {
                iconButton("rotate.left", help: "Turn left") { model.rotate(clockwise: false) }
                iconButton("rotate.right", help: "Turn right") { model.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip left to right") { model.flip(horizontally: true) }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip upside down") { model.flip(horizontally: false) }
            }
        }

        Button("Reset Crop", action: model.resetCrop)
            .disabled(model.edit.crop == nil && model.aspect == nil && model.edit.outputSize == nil)

        Text("Drag the corners or edges, or drag inside to move. Drag outside the box to draw a new one.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sizeNote: some View {
        let crop = model.cropPixelSize
        if model.edit.outputSize != nil {
            HStack {
                let scale = Double(model.resultSize.width) / Double(max(crop.width, 1))
                Text(scale > 1.01 ? "Enlarged from \(crop.width) × \(crop.height)" : "Scaled from \(crop.width) × \(crop.height)")
                    .foregroundStyle(scale > 1.01 ? .orange : .secondary)
                Spacer()
                Button("Use Crop Size", action: model.useCropSize).controlSize(.small)
            }
            .font(.caption)
        } else {
            Text("Type a size to scale the result to exactly that many pixels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .help(help)
    }
}

/// A whole number typed in; saved when you press Return or leave the field.
private struct NumberField: View {
    let title: String
    let value: Int
    let set: @MainActor (Int) -> Void

    var body: some View {
        TextField(title, value: Binding(get: { value }, set: { if $0 != value { set($0) } }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
            .help(title)
    }
}

// MARK: - Adjust

private struct AdjustPanel: View {
    var model: StudioModel

    private var settings: Adjustments { model.edit.adjustments }
    private let filterColumns = [GridItem(.adaptive(minimum: 74), spacing: 8)]

    var body: some View {
        Toggle(isOn: Binding(get: { settings.auto }, set: model.setAutoEnhance)) {
            Label("Auto Enhance", systemImage: "wand.and.stars")
        }
        .toggleStyle(.button)
        .controlSize(.large)

        PanelSection(title: "Light") {
            slider("Exposure", \.exposure, -2...2) { String(format: "%+.1f", $0) }
            slider("Highlights", \.highlights, -1...1, EditSlider.signed)
            slider("Shadows", \.shadows, -1...1, EditSlider.signed)
            slider("Contrast", \.contrast, -1...1, EditSlider.signed)
        }
        PanelSection(title: "Color") {
            slider("Saturation", \.saturation, -1...1, EditSlider.signed)
            slider("Warmth", \.warmth, -1...1, EditSlider.signed)
        }
        PanelSection(title: "Detail") {
            slider("Sharpness", \.sharpness, 0...1, EditSlider.percent)
            slider("Vignette", \.vignette, 0...1, EditSlider.percent)
        }
        PanelSection(title: "Filter") {
            LazyVGrid(columns: filterColumns, spacing: 8) {
                ForEach(PhotoFilter.allCases, id: \.self) { filter in
                    filterButton(filter)
                }
            }
        }
        Button("Reset Adjustments", action: model.resetAdjustments)
            .disabled(settings.isNeutral)
    }

    private func slider(
        _ title: String, _ keyPath: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double>,
        _ label: @escaping (Double) -> String
    ) -> some View {
        EditSlider(title: title, value: settings[keyPath: keyPath], range: range, label: label, model: model) {
            model.setAdjustment(keyPath, $0)
        }
    }

    private func filterButton(_ filter: PhotoFilter) -> some View {
        let isOn = settings.filter == filter
        return Button { model.setFilter(filter) } label: {
            VStack(spacing: 4) {
                Group {
                    if let thumbnail = model.filterThumbnails[filter] {
                        Image(decorative: thumbnail, scale: 1).resizable()
                    } else {
                        Color.primary.opacity(0.08)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isOn ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                Text(filter.title)
                    .font(.system(size: 10.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Background

private struct BackgroundPanel: View {
    var model: StudioModel

    private var frame: FrameStyle { model.edit.frame }
    private let swatchColumns = [GridItem(.adaptive(minimum: 34), spacing: 8)]
    private let canvasShapes: [AspectRatio?] = [nil, .square, AspectRatio(4, 5), AspectRatio(4, 3), AspectRatio(16, 9), AspectRatio(9, 16)]

    var body: some View {
        PanelSection(title: "Subject") {
            Toggle("Remove the background", isOn: Binding(get: { model.edit.removeBackground }, set: model.setRemoveBackground))
            subjectStatus
        }

        PanelSection(title: "Background") {
            LazyVGrid(columns: swatchColumns, spacing: 8) {
                swatch(.clear, help: "None (see-through)") { Checkerboard(square: 5) }
                swatch(.blur, help: "The picture, blurred") {
                    if let preview = model.source?.image {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fill).blur(radius: 3)
                    }
                }
                ForEach(MarkupColor.backgrounds, id: \.self) { color in
                    swatch(.color(color), help: "Solid color") { color.color }
                }
                ForEach(GradientPreset.allCases, id: \.self) { preset in
                    swatch(.gradient(preset), help: preset.rawValue.capitalized) { preset.gradient }
                }
                ColorPicker("", selection: Binding(
                    get: { if case .color(let color) = frame.background { color.color } else { Color.white } },
                    set: { model.setBackdrop(.color(MarkupColor($0))) }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("Any color")
            }
        }

        PanelSection(title: "Frame") {
            EditSlider(title: "Padding", value: frame.padding, range: 0...0.3, label: EditSlider.percent, model: model) {
                model.setFrame(\.padding, $0)
            }
            EditSlider(title: "Corners", value: frame.cornerRadius, range: 0...0.5, label: EditSlider.percent, model: model) {
                model.setFrame(\.cornerRadius, $0)
            }
            EditSlider(title: "Shadow", value: frame.shadow, range: 0...1, label: EditSlider.percent, model: model) {
                model.setFrame(\.shadow, $0)
            }
            if frame.shadow > 0 && frame.padding < 0.02 && frame.canvasAspect == nil {
                Text("Add some padding to see the shadow.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        PanelSection(title: "Canvas") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
                ForEach(canvasShapes, id: \.self) { shape in
                    ChoiceButton(title: shape?.title ?? "Fit", isOn: frame.canvasAspect == shape) { model.setCanvas(shape) }
                }
            }
        }

        Button("Reset Background", action: model.resetFrame)
            .disabled(!frame.isActive && !model.edit.removeBackground)
    }

    @ViewBuilder
    private var subjectStatus: some View {
        if model.edit.removeBackground {
            switch model.subject {
            case .finding:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding the subject…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .notFound:
                Text("No clear subject or plain background found in this picture, so the background stays.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .plainBackground:
                Text("No subject found, so the plain background color is removed instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.red)
            case .found, .idle:
                Text("People, pets and objects are kept; the rest becomes see-through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func swatch<Fill: View>(_ backdrop: Backdrop, help: String, @ViewBuilder fill: () -> Fill) -> some View {
        let isOn = frame.background == backdrop
        return Button { model.setBackdrop(backdrop) } label: {
            fill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isOn ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Markup

private struct MarkupPanel: View {
    var model: StudioModel

    private static let tools: [(Annotation.Kind?, String, String)] = [
        (nil, "Select", "cursorarrow"),
        (.arrow, "Arrow", "arrow.up.right"),
        (.rectangle, "Box", "rectangle"),
        (.ellipse, "Oval", "circle"),
        (.pen, "Pen", "scribble.variable"),
        (.highlighter, "Highlight", "highlighter"),
        (.text, "Text", "textformat"),
        (.number, "Number", "1.circle"),
        (.redact, "Blur Out", "eye.slash"),
    ]

    private let toolColumns = [GridItem(.adaptive(minimum: 76), spacing: 6)]

    var body: some View {
        PanelSection(title: "Tool") {
            LazyVGrid(columns: toolColumns, spacing: 6) {
                ForEach(Self.tools, id: \.1) { tool in
                    ChoiceButton(title: tool.1, symbol: tool.2, isOn: model.tool == tool.0) {
                        model.tool = tool.0
                        if tool.0 != nil { model.selection = nil }
                    }
                }
            }
        }

        PanelSection(title: "Color") {
            HStack(spacing: 7) {
                ForEach(MarkupColor.palette, id: \.self) { color in
                    let isOn = (model.selected?.color ?? model.color) == color
                    Button { model.setColor(color) } label: {
                        Circle()
                            .fill(color.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 20, height: 20)
                            .padding(2)
                            .overlay(Circle().strokeBorder(isOn ? Color.accentColor : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        PanelSection(title: "Size") {
            Picker("Size", selection: Binding(get: { model.strokeSize }, set: model.setStrokeSize)) {
                ForEach(StudioModel.StrokeSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        if model.tool == .text || model.selected?.kind == .text {
            PanelSection(title: model.selected?.kind == .text ? "Text" : "Text to place") {
                TextField("Text", text: Binding(get: { model.text }, set: model.setText), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
        }

        HStack {
            Button("Delete", action: model.deleteSelected)
                .disabled(model.selection == nil)
                .keyboardShortcut(.delete, modifiers: .command)
            Spacer()
            Button("Clear All", action: model.clearMarkup)
                .disabled(model.edit.markup.isEmpty)
        }

        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hint: String {
        switch model.tool {
        case nil: "Click something to select it, then drag to move it. ⌘⌫ deletes it."
        case .text: "Click where the text goes, then type it here."
        case .number: "Click to place numbered steps: 1, 2, 3…"
        case .redact: "Drag over anything private (names, faces, numbers) to blur it out."
        case .pen, .highlighter: "Drag to draw."
        default: "Drag on the picture to draw."
        }
    }
}

// MARK: - Watermark

private struct WatermarkPanel: View {
    var model: StudioModel

    private static let colors: [MarkupColor] = [.white, .black, MarkupColor(hex: 0x8E8E93), .yellow, .red, .blue]
    private static let spots: [[Watermark.Placement]] = [
        [.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight],
    ]

    var body: some View {
        Toggle("Add a watermark", isOn: Binding(get: { model.watermark != nil }, set: model.setWatermarkShown))
            .toggleStyle(.switch)
        if let mark = model.watermark {
            Picker("Kind", selection: Binding(get: { mark.kind }, set: { kind in model.changeWatermark { $0.kind = kind } })) {
                Text("Text").tag(Watermark.Kind.text)
                Text("Logo").tag(Watermark.Kind.logo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mark.kind == .text {
                PanelSection(title: "Text") {
                    TextField("© Your Name", text: Binding(get: { mark.text }, set: model.setWatermarkText), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    HStack(spacing: 7) {
                        ForEach(Self.colors, id: \.self) { color in
                            Button { model.changeWatermark { $0.color = color } } label: {
                                Circle()
                                    .fill(color.color)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                    .frame(width: 20, height: 20)
                                    .padding(2)
                                    .overlay(Circle().strokeBorder(mark.color == color ? Color.accentColor : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                PanelSection(title: "Logo") {
                    HStack {
                        Text(mark.logoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseLogo)
                    }
                    Text("A PNG with a see-through background looks best.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            PanelSection(title: "Position") {
                HStack(alignment: .top, spacing: 14) {
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(0..<3, id: \.self) { row in
                            GridRow {
                                ForEach(Self.spots[row], id: \.self) { spot in
                                    Button { model.changeWatermark { $0.placement = spot } } label: {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(mark.placement == spot ? Color.accentColor : Color.primary.opacity(0.12))
                                            .frame(width: 22, height: 16)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    ChoiceButton(title: "Tile", symbol: "square.grid.3x3", isOn: mark.placement == .tiled) {
                        model.changeWatermark { $0.placement = .tiled }
                    }
                    .frame(width: 80)
                }
            }

            PanelSection(title: "Look") {
                EditSlider(title: "Size", value: mark.size, range: 0.01...0.15, label: { String(format: "%.1f%%", $0 * 100) }, model: model) {
                    model.slideWatermark(\.size, $0)
                }
                EditSlider(title: "Opacity", value: mark.opacity, range: 0.1...1, label: EditSlider.percent, model: model) {
                    model.slideWatermark(\.opacity, $0)
                }
                if mark.placement != .tiled {
                    EditSlider(title: "Margin", value: mark.margin, range: 0...0.12, label: { String(format: "%.1f%%", $0 * 100) }, model: model) {
                        model.slideWatermark(\.margin, $0)
                    }
                }
                Toggle("Soft shadow", isOn: Binding(get: { mark.shadow }, set: { on in model.changeWatermark { $0.shadow = on } }))
            }
        }

        Text(model.files.count > 1
             ? "Saves all \(model.files.count) pictures with this watermark, placed the same way on each."
             : "Drop several pictures on Watermark… to mark them all at once. Pinwheel remembers your last watermark.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a logo for the watermark."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.changeWatermark { mark in
                mark.kind = .logo
                mark.logoPath = url.path
            }
        }
    }
}
