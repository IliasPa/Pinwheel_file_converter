import SwiftUI
import PinwheelCore

/// Settings › Conversions: for each kind of file, the formats on its
/// ⇧ Shift wheel, each with its own settings right under it.
struct ConversionsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        let hasFFmpeg = settings.ffmpegURL != nil
        Form {
            Section {
                Text("Choose what each kind of file can become on the ⇧ Shift wheel, and how each format is made. Switched off, a format stays out of the wheel; custom actions and the `pinwheel` command can still use it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(FileKind.allCases, id: \.self) { kind in
                Section {
                    if kind == .pdf {
                        Picker("Pages to pictures at", selection: $settings.pdfDPI) {
                            Text("72 DPI (screen)").tag(72)
                            Text("150 DPI (standard)").tag(150)
                            Text("300 DPI (print)").tag(300)
                        }
                    }
                    ForEach(FormatCatalog.choices(for: kind, mode: .convert), id: \.self) { action in
                        formatSwitch(action, kind: kind, hasFFmpeg: hasFFmpeg)
                        options(for: action, kind: kind)
                    }
                } header: {
                    header(kind)
                } footer: {
                    Footnote(footer(kind, hasFFmpeg: hasFFmpeg))
                }
            }
        }
    }

    private func header(_ kind: FileKind) -> some View {
        let total = FormatCatalog.choices(for: kind, mode: .convert).count
        return HStack {
            Label(kind.pluralTitle, systemImage: kind.symbolName)
            Spacer()
            Text("\(settings.shownCount(for: kind, in: .convert)) of \(total) on the wheel")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// A format's switch, with what it makes. The last one on a wheel stays on.
    private func formatSwitch(_ action: WheelAction, kind: FileKind, hasFFmpeg: Bool) -> some View {
        let isOn = settings.isOnWheel(action, for: kind, in: .convert)
        let isLast = isOn && settings.shownCount(for: kind, in: .convert) == 1
        let missing = !hasFFmpeg && Compatibility.needsFFmpeg(action, for: kind)
        return Toggle(isOn: Binding(get: { isOn }, set: { settings.setOnWheel(action, for: kind, in: .convert, $0) })) {
            Label(action.title(in: .convert), systemImage: action.symbolName(in: .convert))
            Text(caption(for: action, kind: kind) + (missing ? " · Needs ffmpeg" : ""))
        }
        .disabled(isLast)
        .help(isLast ? "At least one format stays on the wheel." : "")
    }

    private func caption(for action: WheelAction, kind: FileKind) -> String {
        switch (kind, action) {
        case (.image, .open(.collage)):
            "When several pictures are dropped: a grid, rows or a contact sheet"
        case (.pdf, .convert(.jpeg)):
            "One photo per page, at \(percent(settings.jpegQuality)) quality, as for pictures"
        case (.pdf, .convert(.heic)):
            "One picture per page, at \(percent(settings.heicQuality)) quality, as for pictures"
        case (.pdf, .tool(.compress)):
            "Shrinks the pictures inside, at Compress's picture quality (Tools)"
        default:
            action.detail(for: kind, options: settings.conversionOptions)
        }
    }

    /// The settings that belong to one format, set in under its switch.
    @ViewBuilder
    private func options(for action: WheelAction, kind: FileKind) -> some View {
        switch (kind, action) {
        case (.image, .convert(.jpeg)):
            PercentSlider("Quality", value: $settings.jpegQuality, range: 0.5...1, indented: true)
        case (.image, .convert(.heic)):
            PercentSlider("Quality", value: $settings.heicQuality, range: 0.5...1, indented: true)
        case (.image, .convert(.pdf)):
            Toggle(isOn: $settings.combineImagesIntoOnePDF) {
                Text("Several pictures make one PDF").padding(.leading, SettingsLayout.indent)
            }
        case (.video, .convert(.gif)):
            Picker(selection: $settings.gifWidth) {
                ForEach([320, 480, 640, 800, 1080], id: \.self) { Text("\($0) pixels").tag($0) }
            } label: {
                Text("Width").padding(.leading, SettingsLayout.indent)
            }
            Picker(selection: $settings.gifFPS) {
                ForEach([10, 12, 15, 20, 24], id: \.self) { Text("\($0) frames per second").tag($0) }
            } label: {
                Text("Frame rate").padding(.leading, SettingsLayout.indent)
            }
            Picker(selection: $settings.gifMaxSeconds) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("First \($0) seconds").tag($0) }
                Text("Whole video").tag(0)
            } label: {
                Text("Length").padding(.leading, SettingsLayout.indent)
            }
        default:
            EmptyView()
        }
    }

    private func footer(_ kind: FileKind, hasFFmpeg: Bool) -> String {
        switch kind {
        case .image:
            "A picture's own format is left out: a JPEG isn't offered JPEG. A combined PDF has a page for each picture, in name order."
        case .video:
            "MP4 and MOV copy the picture and sound as they are when they can: quick, and nothing is lost. GIFs grow fast: a long one can be hundreds of megabytes."
                + (hasFFmpeg ? "" : " MP3 and GIF need ffmpeg: brew install ffmpeg")
        case .audio:
            "WAV and AIFF are uncompressed; FLAC is lossless and about half their size."
                + (hasFFmpeg ? "" : " MP3 needs ffmpeg: brew install ffmpeg")
        case .pdf:
            "A PDF with several pages becomes a folder with a picture for each page."
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Settings › Compatibility: every kind of file Pinwheel reads (rows)
/// against every format it writes (columns).
struct CompatibilityPane: View {
    var settings: SettingsStore
    @Bindable var state: SettingsViewState

    /// A box of the table: a row and a column.
    struct Spot: Equatable {
        var row: Int
        var column: Int
    }

    private let rows = Compatibility.rows
    private let targets = Compatibility.targets
    private static let labelWidth: CGFloat = 64
    private static let cellWidth: CGFloat = 36
    private static let rowHeight: CGFloat = 22

    var body: some View {
        let hasFFmpeg = settings.ffmpegURL != nil
        Form {
            Section {
                ScrollView(.horizontal) {
                    table(hasFFmpeg: hasFFmpeg)
                        .padding(.vertical, 4)
                }
                Text(spotDescription(hasFFmpeg: hasFFmpeg))
                    .font(.callout)
                    .foregroundStyle(state.tableSpot == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } header: {
                Text("What each kind of file can become")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    legend(hasFFmpeg: hasFFmpeg)
                    Footnote("Rows are the files you drop, columns the new format. Also: several pictures can become one PDF or a collage, PDFs can become a smaller PDF, and every tool on the ⌥ Option wheel works on its kind of file.")
                }
            }
        }
    }

    // MARK: - Table

    private func table(hasFFmpeg: Bool) -> some View {
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("To →")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .trailing)
                ForEach(families, id: \.start) { family in
                    Text(family.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.rowHeight)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 4) }
                        .gridCellColumns(family.count)
                }
            }
            GridRow {
                Text("From ↓")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .padding(.leading, 6)
                ForEach(targets.indices, id: \.self) { column in
                    Text(targets[column].title)
                        .font(.caption2.weight(state.tableSpot?.column == column ? .bold : .medium))
                        .frame(width: Self.cellWidth, height: Self.rowHeight)
                        .background(highlight(row: nil, column: column))
                        .overlay(alignment: .leading) { familyEdge(column) }
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                let source = rows[row].source
                if row == 0 || rows[row - 1].source.kind != source.kind {
                    GridRow {
                        Label(source.kind.pluralTitle, systemImage: source.kind.symbolName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: Self.rowHeight + 6, alignment: .bottom)
                            .gridCellColumns(targets.count + 1)
                            .gridCellAnchor(.leading)
                    }
                }
                GridRow {
                    Text(source.title)
                        .font(.callout.weight(state.tableSpot?.row == row ? .semibold : .regular))
                        .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                        .padding(.leading, 6)
                        .background(highlight(row: row, column: nil))
                        .help(source.detail ?? source.title)
                    ForEach(targets.indices, id: \.self) { column in
                        box(row: row, column: column, hasFFmpeg: hasFFmpeg)
                    }
                }
            }
        }
    }

    private func box(row: Int, column: Int, hasFFmpeg: Bool) -> some View {
        let spot = Spot(row: row, column: column)
        return mark(rows[row].cells[column], row: row, column: column, hasFFmpeg: hasFFmpeg)
            .frame(width: Self.cellWidth, height: Self.rowHeight)
            .background(highlight(row: row, column: column))
            .overlay(alignment: .leading) { familyEdge(column) }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    state.tableSpot = spot
                } else if state.tableSpot == spot {
                    state.tableSpot = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(rows[row].source.title) to \(targets[column].title)")
            .accessibilityValue(meaning(of: spot, hasFFmpeg: hasFFmpeg))
    }

    @ViewBuilder
    private func mark(_ cell: Compatibility.Cell, row: Int, column: Int, hasFFmpeg: Bool) -> some View {
        switch cell {
        case .same:
            Image(systemName: "minus").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        case .no:
            Color.clear
        case .converts(let needsFFmpeg):
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(tickStyle(onWheel: isOnWheel(row: row, column: column), missingFFmpeg: needsFFmpeg && !hasFFmpeg))
        }
    }

    private func tickStyle(onWheel: Bool, missingFFmpeg: Bool) -> AnyShapeStyle {
        if !onWheel { return AnyShapeStyle(.tertiary) }
        return missingFFmpeg ? AnyShapeStyle(.orange) : AnyShapeStyle(.green)
    }

    private func isOnWheel(row: Int, column: Int) -> Bool {
        settings.isOnWheel(.convert(targets[column]), for: rows[row].source.kind, in: .convert)
    }

    /// The row and column under the pointer are tinted, so a box is easy to
    /// follow back to both; every other row is shaded a little.
    private func highlight(row: Int?, column: Int?) -> Color {
        let spot = state.tableSpot
        let inRow = row != nil && spot?.row == row
        let inColumn = column != nil && spot?.column == column
        if inRow && inColumn { return Color.accentColor.opacity(0.22) }
        if inRow || inColumn { return Color.accentColor.opacity(0.09) }
        if let row, row.isMultiple(of: 2) { return Color.primary.opacity(0.035) }
        return .clear
    }

    /// A thin line before the PDF, Video and Audio columns.
    @ViewBuilder
    private func familyEdge(_ column: Int) -> some View {
        if column > 0 && families.contains(where: { $0.start == column }) {
            Rectangle().fill(.separator).frame(width: 1)
        }
    }

    /// The columns, grouped: images, PDF, video, audio.
    private var families: [(title: String, start: Int, count: Int)] {
        var result: [(title: String, start: Int, count: Int)] = []
        for (index, format) in targets.enumerated() {
            let title = Self.family(of: format)
            if result.last?.title == title {
                result[result.count - 1].count += 1
            } else {
                result.append((title, index, 1))
            }
        }
        return result
    }

    private static func family(of format: OutputFormat) -> String {
        switch format {
        case .png, .jpeg, .heic, .tiff, .gif: "Images"
        case .pdf: "PDF"
        case .mp4, .mov: "Video"
        case .m4a, .mp3, .wav, .aiff, .flac: "Audio"
        }
    }

    // MARK: - Words

    private func spotDescription(hasFFmpeg: Bool) -> String {
        guard let spot = state.tableSpot else { return "Point at a box to see what it means." }
        return "\(rows[spot.row].source.title) → \(targets[spot.column].title): " + meaning(of: spot, hasFFmpeg: hasFFmpeg)
    }

    private func meaning(of spot: Spot, hasFFmpeg: Bool) -> String {
        let source = rows[spot.row].source
        let target = targets[spot.column]
        switch rows[spot.row].cells[spot.column] {
        case .same:
            return target == .pdf ? "the same format (Smaller PDF is on its wheel)" : "the same format"
        case .no:
            return "not possible"
        case .converts(let needsFFmpeg):
            guard isOnWheel(row: spot.row, column: spot.column) else {
                return "switched off for \(source.kind.pluralTitle.lowercased()) in Conversions"
            }
            if needsFFmpeg { return hasFFmpeg ? "on the ⇧ Shift wheel, made with ffmpeg" : "needs ffmpeg (brew install ffmpeg)" }
            return "on the ⇧ Shift wheel"
        }
    }

    private func legend(hasFFmpeg: Bool) -> some View {
        HStack(spacing: 16) {
            legendItem("checkmark", .green, "Converts")
            if !hasFFmpeg { legendItem("checkmark", .orange, "Needs ffmpeg") }
            legendItem("checkmark", .tertiary, "Switched off in Conversions")
            legendItem("minus", .tertiary, "Same format")
        }
        .font(.caption)
    }

    private func legendItem(_ symbol: String, _ style: some ShapeStyle, _ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).fontWeight(.bold).foregroundStyle(style)
            Text(title).foregroundStyle(.secondary)
        }
    }
}
