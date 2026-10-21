import SwiftUI
import PinwheelCore

extension SettingsStore {
    /// Whether an extra tool (ffmpeg, cwebp) is on this Mac.
    func isInstalled(_ tool: ExternalTool) -> Bool {
        switch tool {
        case .ffmpeg: ffmpegURL != nil
        case .pngquant: pngquantURL != nil
        case .tesseract: tesseractURL != nil
        case .cwebp: cwebpURL != nil
        case .pages, .keynote, .numbers: tool.locate() != nil
        }
    }
}

/// A row for a format or tool in one kind's section. The same one is in
/// several sections, and named by itself SwiftUI put rows in the wrong
/// section's box.
struct KindAction: Hashable {
    var kind: FileKind
    var action: WheelAction
}

/// Settings › Conversions: for each kind of file, the formats on its
/// format wheel, each with its own settings right under it.
struct ConversionsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Text("Choose what each kind of file can become on the format wheel (\(settings.wheelKeys[.convert].title)), and how each format is made. Switched off, a format stays out of the wheel; custom actions and the `pinwheel` command can still use it.")
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
                    ForEach(FormatCatalog.choices(for: kind, mode: .convert).map { KindAction(kind: kind, action: $0) }, id: \.self) { row in
                        formatSwitch(row.action, kind: kind)
                        options(for: row.action, kind: kind)
                    }
                } header: {
                    header(kind)
                } footer: {
                    Footnote(footer(kind))
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

    /// A format's switch, with what it makes. The last one on a wheel stays
    /// on, and a full wheel takes no more.
    private func formatSwitch(_ action: WheelAction, kind: FileKind) -> some View {
        let isOn = settings.isOnWheel(action, for: kind, in: .convert)
        let shown = settings.shownCount(for: kind, in: .convert)
        let isLast = isOn && shown == 1
        let isFull = !isOn && shown >= FormatCatalog.maxFormats
        let missing = Compatibility.tool(for: action, kind: kind).flatMap { settings.isInstalled($0) ? nil : $0 }
        return Toggle(isOn: Binding(get: { isOn }, set: { settings.setOnWheel(action, for: kind, in: .convert, $0) })) {
            Label(action.title(in: .convert), systemImage: action.symbolName(in: .convert))
            Text(caption(for: action, kind: kind) + (missing.map { " · Needs \($0.name)" } ?? ""))
        }
        .disabled(isLast || isFull)
        .help(isLast ? "At least one format stays on the wheel." : isFull ? "The wheel holds \(FormatCatalog.maxFormats); switch one off first." : "")
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
        case (.image, .convert(.webp)):
            PercentSlider("Quality", value: $settings.webpQuality, range: 0.5...1, indented: true)
        case (.image, .convert(.avif)):
            PercentSlider("Quality", value: $settings.avifQuality, range: 0.3...1, indented: true)
        case (.image, .convert(.pdf)):
            Toggle(isOn: $settings.combineImagesIntoOnePDF) {
                Text("Several pictures make one PDF").padding(.leading, SettingsLayout.indent)
            }
        case (.pdf, .convert(.docx)):
            Picker(selection: $settings.pdfPagesAsPictures) {
                Text("Text you can edit").tag(false)
                Text("Pages as pictures (look the same)").tag(true)
            } label: {
                Text("Word, Pages, EPUB and HTML get").padding(.leading, SettingsLayout.indent)
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

    private func footer(_ kind: FileKind) -> String {
        let ffmpeg = settings.isInstalled(.ffmpeg)
        switch kind {
        case .image:
            return "A picture's own format is left out: a JPEG isn't offered JPEG. SVG drawings become pictures \(Int(2048)) pixels across, or stay drawings in a PDF. ICO and ICNS are icons with every size inside. A combined PDF has a page for each picture, in name order."
                + (settings.isInstalled(.cwebp) ? "" : " WebP needs cwebp: \(ExternalTool.cwebp.installCommand)")
        case .video:
            return "MP4, MOV and MKV copy the picture and sound as they are when they can: quick, and nothing is lost. WebM takes longest to make. GIFs grow fast: a long one can be hundreds of megabytes."
                + (ffmpeg ? "" : " MKV, WebM, AVI, WMV, MP3 and GIF need ffmpeg: \(FFmpeg.installCommand)")
        case .audio:
            return "WAV and AIFF are uncompressed; FLAC is lossless and about half their size; Opus sounds best for its size."
                + (ffmpeg ? "" : " MP3, OGG, Opus and WMA need ffmpeg: \(FFmpeg.installCommand)")
        case .pdf:
            return "A PDF with several pages becomes a folder with a picture for each page. Word, Pages, EPUB, Markdown and HTML get its text with headings, paragraphs and lists (scanned pages are read with text recognition), or each page as a picture; Excel gets the tables on each page; PowerPoint a slide for each page."
        case .archive:
            return "Extract opens ZIP, RAR, 7Z, TAR and GZ files. Archives are made without the Mac's hidden extras, so they open cleanly on any computer. Files with a password can't be opened yet."
        case .document:
            return "Word, RTF, ODT, Markdown, text, web pages and EPUBs become any of these. Pages files are opened by Pages, and Pages files are made by it (it's free on the App Store); macOS asks once whether Pinwheel may use it."
        case .spreadsheet:
            return "Excel, ODS, CSV and TSV become any of these; CSV and TSV hold one sheet. Numbers files and old Excel (.xls) files are opened by Numbers."
        case .presentation:
            return "Keynote draws the slides (PowerPoint and Keynote files), so it's needed for these. Each slide becomes a picture in a folder for PNG and JPEG."
        case .subtitle:
            return "SRT and WebVTT become each other, or just their words."
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Settings › Compatibility: for each kind of file, every format Pinwheel
/// reads (rows) against every format it can become (columns).
struct CompatibilityPane: View {
    var settings: SettingsStore
    @Bindable var state: SettingsViewState

    /// A box of a table: its kind, row and column.
    struct Spot: Equatable {
        var kind: FileKind
        var row: Int
        var column: Int
    }

    private static let labelWidth: CGFloat = 64
    private static let cellWidth: CGFloat = 38
    private static let rowHeight: CGFloat = 22

    var body: some View {
        Form {
            ForEach(Compatibility.sections) { section in
                Section {
                    ScrollView(.horizontal) {
                        table(section)
                            .padding(.vertical, 4)
                    }
                    if section.kind == Compatibility.sections.first?.kind || state.tableSpot?.kind == section.kind {
                        Text(spotDescription(in: section))
                            .font(.callout)
                            .foregroundStyle(state.tableSpot?.kind == section.kind ? .primary : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    }
                } header: {
                    Label(section.kind.pluralTitle, systemImage: section.kind.symbolName)
                }
            }
            Section {
                EmptyView()
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    legend
                    Footnote("Rows are the files you drop, columns what they can become. Also: several pictures can become one PDF or a collage, PDFs can become a smaller PDF, archives can be extracted, and every tool on the tools wheel works on its kind of file.")
                }
            }
        }
    }

    // MARK: - Table

    private func table(_ section: Compatibility.Section) -> some View {
        let groups = Self.families(section.targets)
        return Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("To →")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .trailing)
                ForEach(groups, id: \.start) { family in
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
                ForEach(section.targets.indices, id: \.self) { column in
                    Text(section.targets[column].title)
                        .font(.caption2.weight(isSpot(section, column: column) ? .bold : .medium))
                        .frame(width: Self.cellWidth, height: Self.rowHeight)
                        .background(highlight(section, row: nil, column: column))
                        .overlay(alignment: .leading) { familyEdge(groups, column) }
                }
            }
            ForEach(section.rows.indices, id: \.self) { row in
                GridRow {
                    Text(section.rows[row].source.title)
                        .font(.callout.weight(isSpot(section, row: row) ? .semibold : .regular))
                        .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                        .padding(.leading, 6)
                        .background(highlight(section, row: row, column: nil))
                        .help(section.rows[row].source.detail ?? section.rows[row].source.title)
                    ForEach(section.targets.indices, id: \.self) { column in
                        box(section, row: row, column: column, groups: groups)
                    }
                }
            }
        }
    }

    private func box(_ section: Compatibility.Section, row: Int, column: Int, groups: [Family]) -> some View {
        let spot = Spot(kind: section.kind, row: row, column: column)
        return mark(section, row: row, column: column)
            .frame(width: Self.cellWidth, height: Self.rowHeight)
            .background(highlight(section, row: row, column: column))
            .overlay(alignment: .leading) { familyEdge(groups, column) }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    state.tableSpot = spot
                } else if state.tableSpot == spot {
                    state.tableSpot = nil
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(section.rows[row].source.title) to \(section.targets[column].title)")
            .accessibilityValue(meaning(section, row: row, column: column))
    }

    @ViewBuilder
    private func mark(_ section: Compatibility.Section, row: Int, column: Int) -> some View {
        switch section.rows[row].cells[column] {
        case .same:
            Image(systemName: "minus").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        case .no:
            Color.clear
        case .converts(let needs):
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(tickStyle(onWheel: isOnWheel(section, column: column), missing: needs.map { !settings.isInstalled($0) } ?? false))
        }
    }

    private func tickStyle(onWheel: Bool, missing: Bool) -> AnyShapeStyle {
        if !onWheel { return AnyShapeStyle(.tertiary) }
        return missing ? AnyShapeStyle(.orange) : AnyShapeStyle(.green)
    }

    private func isOnWheel(_ section: Compatibility.Section, column: Int) -> Bool {
        settings.isOnWheel(.convert(section.targets[column]), for: section.kind, in: .convert)
    }

    private func isSpot(_ section: Compatibility.Section, row: Int? = nil, column: Int? = nil) -> Bool {
        guard let spot = state.tableSpot, spot.kind == section.kind else { return false }
        if let row { return spot.row == row }
        if let column { return spot.column == column }
        return false
    }

    /// The row and column under the pointer are tinted, so a box is easy to
    /// follow back to both; every other row is shaded a little.
    private func highlight(_ section: Compatibility.Section, row: Int?, column: Int?) -> Color {
        let inRow = row.map { isSpot(section, row: $0) } ?? false
        let inColumn = column.map { isSpot(section, column: $0) } ?? false
        if inRow && inColumn { return Color.accentColor.opacity(0.22) }
        if inRow || inColumn { return Color.accentColor.opacity(0.09) }
        if let row, row.isMultiple(of: 2) { return Color.primary.opacity(0.035) }
        return .clear
    }

    /// A thin line before each group of columns but the first.
    @ViewBuilder
    private func familyEdge(_ groups: [Family], _ column: Int) -> some View {
        if column > 0 && groups.contains(where: { $0.start == column }) {
            Rectangle().fill(.separator).frame(width: 1)
        }
    }

    typealias Family = (title: String, start: Int, count: Int)

    /// The columns, grouped: images, PDF, video, audio, archives.
    private static func families(_ targets: [OutputFormat]) -> [Family] {
        var result: [Family] = []
        for (index, format) in targets.enumerated() {
            let title = format.kind == .pdf ? "PDF" : format.kind.pluralTitle
            if result.last?.title == title {
                result[result.count - 1].count += 1
            } else {
                result.append((title, index, 1))
            }
        }
        return result
    }

    // MARK: - Words

    private func spotDescription(in section: Compatibility.Section) -> String {
        guard let spot = state.tableSpot, spot.kind == section.kind else { return "Point at a box to see what it means." }
        return "\(section.rows[spot.row].source.title) → \(section.targets[spot.column].title): " + meaning(section, row: spot.row, column: spot.column)
    }

    private func meaning(_ section: Compatibility.Section, row: Int, column: Int) -> String {
        let target = section.targets[column]
        switch section.rows[row].cells[column] {
        case .same:
            return target == .pdf ? "the same format (Smaller PDF is on its wheel)" : "the same format"
        case .no:
            return "not possible"
        case .converts(let needs):
            guard isOnWheel(section, column: column) else {
                return "switched off for \(section.kind.pluralTitle.lowercased()) in Conversions"
            }
            if let needs {
                return settings.isInstalled(needs) ? "on the format wheel, made with \(needs.name)" : "needs \(needs.name) (\(needs.installCommand))"
            }
            return "on the format wheel"
        }
    }

    private var legend: some View {
        let missing = [ExternalTool.ffmpeg, .cwebp, .pages, .keynote, .numbers].filter { !settings.isInstalled($0) }
        return HStack(spacing: 16) {
            legendItem("checkmark", .green, "Converts")
            if !missing.isEmpty { legendItem("checkmark", .orange, "Needs " + missing.map(\.name).joined(separator: ", ")) }
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
