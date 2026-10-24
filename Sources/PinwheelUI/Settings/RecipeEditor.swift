import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// The custom action being made or changed, with the steps it has so far.
@Observable
final class RecipeDraft: Identifiable {
    var recipe: Recipe
    let isNew: Bool
    /// The watermark last used in the image editor, offered for watermark steps.
    let lastWatermark: Watermark?

    var id: UUID { recipe.id }

    init(_ recipe: Recipe, isNew: Bool, lastWatermark: Watermark? = nil) {
        self.recipe = recipe
        self.isNew = isNew
        self.lastWatermark = lastWatermark
    }

    /// The kind of file the next step would get (nil: nothing can follow).
    var nextKind: FileKind? {
        recipe.steps.indices.last.map { last in recipe.kindsBeforeSteps[last].flatMap(recipe.steps[last].outputKind) } ?? recipe.kind
    }

    func add(_ step: RecipeStep) {
        var step = step
        if case .watermark = step, let lastWatermark { step = .watermark(lastWatermark) }
        recipe.steps.append(step)
    }

    func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard recipe.steps.indices.contains(index), recipe.steps.indices.contains(target) else { return }
        recipe.steps.swapAt(index, target)
    }

    func remove(_ index: Int) {
        guard recipe.steps.indices.contains(index) else { return }
        recipe.steps.remove(at: index)
    }
}

struct RecipeEditor: View {
    @Bindable var draft: RecipeDraft
    var onSave: (Recipe) -> Void
    var onCancel: () -> Void

    private var recipe: Recipe { draft.recipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.isNew ? "New Custom Action for \(recipe.kind.pluralTitle)" : "Edit Custom Action")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    Image(systemName: recipe.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.15)))
                    TextField("Name", text: $draft.recipe.name, prompt: Text("Name on the wheel, e.g. Instagram"))
                        .textFieldStyle(.roundedBorder)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 16), spacing: 4) {
                    ForEach(Recipe.symbols, id: \.self) { symbol in
                        Button { draft.recipe.symbol = symbol } label: {
                            Image(systemName: symbol)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(recipe.symbol == symbol ? Color.accentColor.opacity(0.3) : .clear))
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
            }
            .padding(18)
            Divider()
            HStack {
                Text("Steps, in order").font(.headline)
                Spacer()
                addMenu
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        StepRow(draft: draft, index: index, kind: recipe.kindsBeforeSteps[index])
                            .id("\(index)-\(step.name)")
                    }
                    if recipe.steps.isEmpty {
                        Text("Add the first step with “Add Step”. Each step works on what the step before made.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            .frame(minHeight: 260)
            Divider()
            HStack {
                if let problem = recipe.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Saved files are named “… (\(recipe.fileNameSuffix))”.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft.recipe) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recipe.problem != nil)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
    }

    private var addMenu: some View {
        Menu {
            if let kind = draft.nextKind {
                ForEach(RecipeStep.templates(for: kind), id: \.self) { step in
                    Button { draft.add(step) } label: { Label(step.name, systemImage: step.symbolName) }
                }
            } else {
                Text("Nothing can come after the last step")
            }
        } label: {
            Label("Add Step", systemImage: "plus")
        }
        .fixedSize()
    }
}

/// One step: its number, name and options, with buttons to move or remove it.
private struct StepRow: View {
    var draft: RecipeDraft
    let index: Int
    let kind: FileKind?

    var body: some View {
        // A removed step's row can be asked for once more while it goes.
        if draft.recipe.steps.indices.contains(index) {
            row(draft.recipe.steps[index])
        }
    }

    private func row(_ step: RecipeStep) -> some View {
        let works = kind.map(step.works) ?? false
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(step.name, systemImage: step.symbolName).font(.system(size: 13, weight: .semibold))
                    if !works {
                        Text(kind == nil ? "Nothing can follow the step before" : "Doesn't work on \(kind!.pluralTitle.lowercased())")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                StepOptions(step: Binding(get: { draft.recipe.steps.indices.contains(index) ? draft.recipe.steps[index] : step },
                                          set: { if draft.recipe.steps.indices.contains(index) { draft.recipe.steps[index] = $0 } }),
                            kind: kind ?? draft.recipe.kind, lastWatermark: draft.lastWatermark)
                    .controlSize(.small)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button { draft.move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { draft.move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == draft.recipe.steps.count - 1)
                Button { draft.remove(index) } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(works ? Color.primary.opacity(0.08) : Color.orange.opacity(0.6)))
    }
}

/// The choices a step has (a format, a size, a shape…).
private struct StepOptions: View {
    @Binding var step: RecipeStep
    let kind: FileKind
    let lastWatermark: Watermark?

    private static let shapes: [AspectRatio] = [
        .square, AspectRatio(4, 5), AspectRatio(3, 4), AspectRatio(2, 3), AspectRatio(9, 16),
        AspectRatio(5, 4), AspectRatio(4, 3), AspectRatio(3, 2), AspectRatio(16, 9),
    ]

    var body: some View {
        switch step {
        case .convert(let format):
            Picker("Format", selection: Binding(get: { format }, set: { step = .convert($0) })) {
                ForEach(OutputFormat.allCases.filter { RecipeStep.convert($0).works(on: kind) }, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
        case .sizeLimit(let megabytes):
            HStack {
                Text("Under")
                TextField("MB", value: Binding(get: { megabytes }, set: { step = .sizeLimit(megabytes: max($0, 0.05)) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("MB")
            }
        case .resize(let option):
            Picker("Size", selection: Binding(get: { option }, set: { step = .resize($0) })) {
                ForEach(ResizeOption.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
        case .crop(let aspect):
            Picker("Shape", selection: Binding(get: { aspect }, set: { step = .crop($0) })) {
                ForEach(Self.shapes, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Text("The largest part with this shape, from the middle.").font(.caption).foregroundStyle(.secondary)
        case .turn(let turns):
            turnPicker(turns) { step = .turn(quarterTurns: $0) }
        case .turnVideo(let turns):
            turnPicker(turns) { step = .turnVideo(quarterTurns: $0) }
        case .filter(let filter):
            Picker("Filter", selection: Binding(get: { filter }, set: { step = .filter($0) })) {
                ForEach(PhotoFilter.allCases.filter { $0 != .original }, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
        case .frame(let style):
            FrameOptions(style: Binding(get: { style }, set: { step = .frame($0) }))
        case .watermark(let mark):
            WatermarkOptions(mark: Binding(get: { mark }, set: { step = .watermark($0) }), lastWatermark: lastWatermark)
        case .speed(let speed):
            Picker("Speed", selection: Binding(get: { speed }, set: { step = .speed($0) })) {
                ForEach(MediaEdit.speeds, id: \.self) { Text(MediaEdit.speedTitle($0)).tag($0) }
            }
            .fixedSize()
        case .fade(let fadeIn, let fadeOut):
            HStack(spacing: 16) {
                seconds("In", fadeIn) { step = .fade(inSeconds: $0, outSeconds: fadeOut) }
                seconds("Out", fadeOut) { step = .fade(inSeconds: fadeIn, outSeconds: $0) }
            }
        case .volume(let decibels):
            HStack {
                Slider(value: Binding(get: { decibels }, set: { step = .volume(decibels: $0.rounded()) }), in: -20...20)
                    .frame(width: 180)
                Text(String(format: "%+.0f dB", decibels)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .compress:
            note("With the quality set in Settings › Wheels › Tools.")
        case .removeLocation:
            note("Keeps the camera and date; removes only where it was taken.")
        case .extractText:
            note("Makes a text file, so it comes last.")
        case .makeSearchable:
            note("Scanned pages get their text (Settings › Text Recognition chooses how it's read).")
        case .extractAudio:
            note("The steps after this one work on the sound.")
        default:
            EmptyView()
        }
    }

    private func turnPicker(_ turns: Int, set: @escaping @MainActor (Int) -> Void) -> some View {
        Picker("Turn", selection: Binding(get: { turns }, set: { set($0) })) {
            Text("Right").tag(1)
            Text("Left").tag(3)
            Text("180°").tag(2)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private func seconds(_ title: String, _ value: Double, set: @escaping @MainActor (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title)
            TextField(title, value: Binding(get: { value }, set: { set(min(max($0, 0), 10)) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
            Text("s")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

private struct FrameOptions: View {
    @Binding var style: FrameStyle

    private static let backdrops: [(title: String, backdrop: Backdrop)] = [
        ("White", .color(.white)), ("Light gray", .color(MarkupColor(hex: 0xF2F2F7))), ("Black", .color(.black)),
        ("Blur", .blur), ("See-through", .clear),
    ] + GradientPreset.allCases.map { ($0.rawValue.capitalized, .gradient($0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Background", selection: $style.background) {
                ForEach(Self.backdrops, id: \.title) { Text($0.title).tag($0.backdrop) }
            }
            .fixedSize()
            slider("Padding", $style.padding, 0...0.25)
            slider("Corners", $style.cornerRadius, 0...0.5)
            slider("Shadow", $style.shadow, 0...1)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range).frame(width: 180)
        }
    }
}

private struct WatermarkOptions: View {
    @Binding var mark: Watermark
    let lastWatermark: Watermark?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mark.kind == .logo {
                HStack {
                    Text("Logo: \(mark.logoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none")")
                    Button("Use Text Instead") { mark.kind = .text }
                }
            } else {
                TextField("Text", text: $mark.text, prompt: Text("© Your Name"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            HStack {
                Picker("Place", selection: $mark.placement) {
                    ForEach(Watermark.Placement.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
                .fixedSize()
                Picker("Color", selection: $mark.color) {
                    Text("White").tag(MarkupColor.white)
                    Text("Black").tag(MarkupColor.black)
                }
                .fixedSize()
            }
            HStack {
                Text("Size").frame(width: 60, alignment: .leading)
                Slider(value: $mark.size, in: 0.02...0.15).frame(width: 180)
            }
            HStack {
                Text("Opacity").frame(width: 60, alignment: .leading)
                Slider(value: $mark.opacity, in: 0.1...1).frame(width: 180)
            }
            if let lastWatermark, lastWatermark != mark {
                Button("Use My Last Watermark from the Editor") { mark = lastWatermark }
            }
        }
    }

    static func title(_ placement: Watermark.Placement) -> String {
        switch placement {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .center: "Middle"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        case .tiled: "All over"
        }
    }
}
