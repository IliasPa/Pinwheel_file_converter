import AppKit
import Observation
import SwiftUI
import PinwheelCore

/// Renames many files at once. Rules run top to bottom; the preview shows
/// every new name (and anything wrong with it) before a file is touched.
@Observable
final class RenameModel {
    /// In the order they're numbered.
    private(set) var files: [URL]
    var order = RenameOrder.name {
        didSet { if order != oldValue { arrange() } }
    }
    var reversed = false {
        didSet { if reversed != oldValue { arrange() } }
    }
    var rules: [RenameRule] {
        didSet { refresh() }
    }
    /// The rule whose settings are open.
    var expanded: RenameRule.ID?
    private(set) var previews: [RenamePreview] = []
    private(set) var isReading = true
    private(set) var error: String?
    var presets: [RenamePreset] {
        didSet { onPresetsChanged?(presets) }
    }

    var onRenamed: (([Renamer.Move]) -> Void)?
    var onPresetsChanged: (([RenamePreset]) -> Void)?
    var onClose: (() -> Void)?

    @ObservationIgnored private var infos: [URL: RenameFileInfo] = [:]
    @ObservationIgnored private var manual: [URL]

    init(urls: [URL], presets: [RenamePreset] = []) {
        let unique = Array(NSOrderedSet(array: urls.map(\.standardizedFileURL))) as? [URL] ?? urls
        manual = unique
        files = RenameOrder.name.sorted(unique, infos: [:], reversed: false)
        rules = [RenameRule(.replace)]
        self.presets = presets
        expanded = rules.first?.id
        refresh()
        Task { await readInfo() }
    }

    private struct Infos: @unchecked Sendable { var values: [URL: RenameFileInfo] }

    /// Dates, sizes and camera details, read off the main thread.
    private func readInfo() async {
        let urls = files
        let read = await Self.read(urls)
        infos = read.values
        isReading = false
        arrange()
    }

    @concurrent
    private nonisolated static func read(_ urls: [URL]) async -> Infos {
        Infos(values: Dictionary(uniqueKeysWithValues: urls.map { ($0, RenameFileInfo.read($0)) }))
    }

    private func arrange() {
        files = order.sorted(order == .manual ? manual : files, infos: infos, reversed: order == .manual ? false : reversed)
        refresh()
    }

    private func refresh() {
        previews = RenamePlanner.preview(files, rules: rules, infos: infos)
        error = nil
    }

    // MARK: - Rules

    func addRule(_ kind: RenameRule.Kind) {
        let rule = RenameRule(kind)
        rules.append(rule)
        expanded = rule.id
    }

    func remove(_ id: RenameRule.ID) {
        rules.removeAll { $0.id == id }
        if expanded == id { expanded = rules.last?.id }
    }

    func move(_ id: RenameRule.ID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
    }

    func duplicate(_ id: RenameRule.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = rules[index]
        copy.id = UUID()
        rules.insert(copy, at: index + 1)
        expanded = copy.id
    }

    func rule(_ id: RenameRule.ID) -> RenameRule? { rules.first { $0.id == id } }

    func update(_ id: RenameRule.ID, _ rule: RenameRule) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index] != rule else { return }
        rules[index] = rule
    }

    func toggleExpanded(_ id: RenameRule.ID) {
        expanded = expanded == id ? nil : id
    }

    // MARK: - Presets

    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name == name }) {
            presets[index].rules = rules
        } else {
            presets.append(RenamePreset(name: name, rules: rules))
        }
    }

    func apply(_ preset: RenamePreset) {
        rules = preset.rules.map { rule in
            var copy = rule
            copy.id = UUID()
            return copy
        }
        expanded = nil
    }

    func deletePreset(_ preset: RenamePreset) {
        presets.removeAll { $0.id == preset.id }
    }

    // MARK: - Files

    /// Dragging names puts them in that order (and numbers them so).
    func moveFiles(from offsets: IndexSet, to destination: Int) {
        var arranged = files
        arranged.move(fromOffsets: offsets, toOffset: destination)
        manual = arranged
        order = .manual
        files = arranged
        refresh()
    }

    var changedCount: Int { previews.filter(\.isChanged).count }
    var problemCount: Int { previews.filter { $0.problem != nil }.count }
    var ruleProblem: String? { rules.lazy.compactMap(\.problem).first }
    var canRename: Bool { changedCount > 0 && problemCount == 0 && ruleProblem == nil }

    func rename() {
        guard canRename else { return }
        let moves = previews.filter(\.isChanged).map { Renamer.Move(from: $0.url, to: $0.destination) }
        do {
            let done = try Renamer.apply(moves)
            onRenamed?(done)
            onClose?()
        } catch {
            self.error = "Nothing was renamed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Views

struct RenameView: View {
    @Bindable var model: RenameModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                rulesColumn
                    .frame(width: 400)
                    .background(.background)
                Divider()
                previewColumn
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: Rules

    private var rulesColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Rules").font(.headline)
                    .help("Rules run from top to bottom, each on the name the one above made.")
                Spacer()
                presetsMenu
                addMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rules) { rule in
                        RuleCard(model: model, id: rule.id)
                    }
                    if model.rules.isEmpty {
                        Text("Add a rule with the + button.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                }
                .padding(12)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(RenameRule.Kind.allCases, id: \.self) { kind in
                Button { model.addRule(kind) } label: { Label(kind.title, systemImage: kind.symbolName) }
            }
        } label: {
            Label("Add Rule", systemImage: "plus")
        }
        .fixedSize()
    }

    private var presetsMenu: some View {
        Menu {
            Button("Save Rules as Preset…") { askPresetName() }
                .disabled(model.rules.isEmpty)
            if !model.presets.isEmpty {
                Divider()
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.apply(preset) }
                }
                Divider()
                Menu("Delete Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "bookmark")
        }
        .fixedSize()
    }

    private func askPresetName() {
        let alert = NSAlert()
        alert.messageText = "Save these rules as a preset"
        alert.informativeText = "Presets come back in this menu next time you rename."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name, e.g. Holiday photos"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            model.savePreset(named: field.stringValue)
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Order").foregroundStyle(.secondary)
                Picker("Order", selection: $model.order) {
                    ForEach(RenameOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button { model.reversed.toggle() } label: {
                    Image(systemName: model.reversed ? "arrow.up" : "arrow.down")
                }
                .help(model.reversed ? "Last to first" : "First to last")
                .disabled(model.order == .manual)
                if model.isReading {
                    ProgressView().controlSize(.small)
                    Text("Reading dates…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Drag names to set the order").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                Text("Now").frame(maxWidth: .infinity, alignment: .leading)
                Text("New name").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 5)
            List {
                ForEach(model.previews) { preview in
                    PreviewRow(preview: preview)
                }
                .onMove(perform: model.moveFiles)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.files.count == 1 ? "1 file" : "\(model.files.count) files")
                    .font(.system(size: 12, weight: .medium))
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(model.problemCount > 0 || model.ruleProblem != nil ? Color.orange : .secondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button(model.changedCount == 1 ? "Rename 1 File" : "Rename \(model.changedCount) Files", action: model.rename)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRename)
                .help("Undo it from the menu bar icon if it isn't what you wanted.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusLine: String {
        if let problem = model.ruleProblem { return problem }
        if model.problemCount > 0 {
            return model.problemCount == 1 ? "1 name has a problem (shown in orange)" : "\(model.problemCount) names have a problem (shown in orange)"
        }
        return model.changedCount == 0 ? "No name changes yet" : "\(model.changedCount) will get a new name"
    }
}

private struct PreviewRow: View {
    let preview: RenamePreview

    var body: some View {
        HStack(spacing: 8) {
            Text(preview.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if let problem = preview.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(problem.message)
                }
                Text(preview.newName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(preview.isChanged ? .medium : .regular)
                    .foregroundStyle(preview.problem != nil ? Color.orange : (preview.isChanged ? Color.primary : .secondary))
                    .help(preview.problem?.message ?? preview.newName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

/// One rule: its switch, name and summary; its settings when opened.
private struct RuleCard: View {
    var model: RenameModel
    let id: RenameRule.ID

    var body: some View {
        if let rule = model.rule(id) {
            let isOpen = model.expanded == id
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle("", isOn: binding(rule).isOn)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Switch this rule on or off")
                    Image(systemName: rule.kind.symbolName)
                        .frame(width: 18)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.kind.title).font(.system(size: 12, weight: .semibold))
                        if !isOpen {
                            Text(rule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button("Move Up") { model.move(id, by: -1) }
                        Button("Move Down") { model.move(id, by: 1) }
                        Button("Duplicate") { model.duplicate(id) }
                        Divider()
                        Button("Remove", role: .destructive) { model.remove(id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture { model.toggleExpanded(id) }
                if isOpen {
                    RuleSettings(rule: binding(rule))
                        .disabled(!rule.isOn)
                    if let problem = rule.problem {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isOpen ? 0.06 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isOpen ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08))
            )
            .opacity(rule.isOn ? 1 : 0.6)
        }
    }

    private func binding(_ rule: RenameRule) -> Binding<RenameRule> {
        Binding(get: { model.rule(id) ?? rule }, set: { model.update(id, $0) })
    }
}

/// The settings of one rule.
private struct RuleSettings: View {
    @Binding var rule: RenameRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch rule.kind {
            case .replace: replace
            case .remove: remove
            case .removeKinds: removeKinds
            case .insert: insert
            case .changeCase:
                Picker("Case", selection: $rule.caseStyle) {
                    ForEach(RenameRule.CaseStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Also the extension", isOn: $rule.includeExtension)
            case .separators:
                Picker("Change", selection: $rule.separatorStyle) {
                    ForEach(RenameRule.SeparatorStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            case .numbering: numbering
            case .pattern: pattern
            case .date: date
            case .transliterate:
                Picker("Style", selection: $rule.transliteration) {
                    ForEach(RenameRule.Transliteration.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                note("Accents go too, so names work on any computer and website.")
            case .padNumbers:
                number("Digits", $rule.digits, 2...8)
                note("photo 7 → photo 007, so names sort in the right order everywhere.")
            case .swap:
                field("Around", $rule.text, prompt: " - ")
                note("“Artist - Title” becomes “Title - Artist”.")
            case .ext: extensionSettings
            }
        }
        .controlSize(.small)
    }

    private var replace: some View {
        Group {
            field("Find", $rule.text, prompt: "Text to find")
            field("Replace with", $rule.text2, prompt: "Nothing (removes it)")
            Picker("Which", selection: $rule.occurrence) {
                ForEach(RenameRule.Occurrence.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 14) {
                Toggle("Match case", isOn: $rule.matchCase)
                Toggle("Regular expression", isOn: $rule.regex)
                Toggle("Extension too", isOn: $rule.includeExtension)
            }
            if rule.regex { note("Use $1, $2… in “Replace with” for the parts in brackets.") }
        }
    }

    private var remove: some View {
        Group {
            Picker("Remove", selection: $rule.removePart) {
                ForEach(RenameRule.RemovePart.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if rule.removePart.usesCount {
                number(rule.removePart == .keepFirst || rule.removePart == .keepLast ? "Keep" : "Characters", $rule.count, 0...255)
            }
            if rule.removePart == .range {
                number("From character", $rule.position, 1...255)
            }
            if rule.removePart.usesText {
                field(rule.removePart == .between ? "From" : "Text", $rule.text, prompt: rule.removePart == .between ? "(" : " - ")
                if rule.removePart == .between {
                    field("To", $rule.text2, prompt: ")")
                } else {
                    Toggle("Match case", isOn: $rule.matchCase)
                    note(rule.removePart == .upTo ? "The text itself goes too." : "The text itself goes too, up to the extension.")
                }
            }
        }
    }

    private var removeKinds: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(RenameRule.RemoveKind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { rule.removeKinds.contains(kind) },
                    set: { on in
                        rule.removeKinds.removeAll { $0 == kind }
                        if on { rule.removeKinds.append(kind) }
                    }
                ))
            }
        }
    }

    private var insert: some View {
        Group {
            field("Text", $rule.text, prompt: "Text to add")
            Picker("Where", selection: $rule.insertPlace) {
                ForEach(RenameRule.InsertPlace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if rule.insertPlace == .position || rule.insertPlace == .positionFromEnd {
                number("Characters", $rule.position, 0...255)
            }
            if rule.insertPlace == .before || rule.insertPlace == .after {
                field("Look for", $rule.text2, prompt: "Text already in the name")
            }
        }
    }

    private var numbering: some View {
        Group {
            HStack(spacing: 14) {
                number("Start at", $rule.start, 0...99_999)
                number("Step", $rule.step, 1...1000)
            }
            HStack(spacing: 14) {
                number("Digits", $rule.digits, 0...8)
                Picker("Style", selection: $rule.numberStyle) {
                    ForEach(RenameRule.NumberStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            place
            note("The order is set on the right. Digits 3 gives 001, 002…")
        }
    }

    private var pattern: some View {
        Group {
            field("Pattern", $rule.text, prompt: "{name} {n}")
            FlowLayout(spacing: 4) {
                ForEach(RenameRule.patternTokens, id: \.token) { token in
                    Button(token.title) { rule.text += token.token }
                        .buttonStyle(.bordered)
                        .help(token.token)
                }
            }
            HStack(spacing: 14) {
                number("Number from", $rule.start, 0...99_999)
                number("Digits", $rule.digits, 0...8)
            }
            dateFormat
        }
    }

    private var date: some View {
        Group {
            Picker("Date", selection: $rule.dateSource) {
                ForEach(RenameRule.DateSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            dateFormat
            place
            if rule.dateSource == .taken { note("Photos and videos use when they were taken; other files when they were created.") }
        }
    }

    private var dateFormat: some View {
        Picker("Format", selection: $rule.dateFormat) {
            ForEach(RenameRule.dateFormats, id: \.self) { format in
                Text(Self.sample(format)).tag(format)
            }
        }
    }

    private var place: some View {
        HStack(spacing: 14) {
            Picker("Place", selection: $rule.place) {
                ForEach(RenameRule.Place.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            if rule.place != .replace {
                field("Separator", $rule.separator, prompt: "none")
                    .frame(width: 130)
            }
        }
    }

    private var extensionSettings: some View {
        Group {
            Picker("Extension", selection: $rule.extensionChange) {
                ForEach(RenameRule.ExtensionChange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if rule.extensionChange == .change {
                field("New", $rule.text, prompt: "jpg")
                note("Only the name changes, not what's inside the file. To really convert it, use the format wheel.")
            }
        }
    }

    // MARK: Helpers

    private func field(_ title: String, _ text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func number(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 2) {
                TextField(title, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 54)
                Stepper(title, value: value, in: range)
                    .labelsHidden()
            }
        }
        .fixedSize()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How today looks in a date format.
    static func sample(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = format.contains("MMM") ? .current : Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }
}

/// Lays out views in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(in: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in rows(in: bounds.width, subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func rows(in width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

final class RenameWindowController: EditorWindowController {
    init(model: RenameModel) {
        let title = model.files.count == 1 ? "Rename \(model.files[0].lastPathComponent)" : "Rename \(model.files.count) Files"
        super.init(title: title, size: NSSize(width: 1080, height: 700), content: RenameView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
