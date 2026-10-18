import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import PinwheelCore

/// The pages of one or more PDFs as thumbnails: drag to reorder, turn,
/// remove, then save them as one PDF.
@Observable
final class OrganizeModel {
    let files: [SourceFile]
    private(set) var pages: [PageArrangement.Page] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var pageCounts: [Int] = []
    var selection: Set<String> = []
    private(set) var error: String?
    /// For shift-click ranges.
    @ObservationIgnored private var anchor: String?
    @ObservationIgnored private var history: [[PageArrangement.Page]] = []
    @ObservationIgnored private var future: [[PageArrangement.Page]] = []
    private(set) var historyCount = 0

    var onSave: (([SourceFile], PageArrangement) -> Void)?
    var onClose: (() -> Void)?

    /// Where a dragged page would land: before or after `page`, or at the
    /// end (`page` nil). Shown as a bar between pages.
    struct DropTarget: Equatable {
        var page: String?
        var after = false
    }

    private(set) var dropTarget: DropTarget?
    /// The page being dragged (with the selection, when it's selected).
    @ObservationIgnored var dragging: String?
    /// How wide a page's place in the grid is (to tell its left half from its right).
    @ObservationIgnored var cellWidth: CGFloat = 170

    init(files: [SourceFile]) {
        self.files = files
        load()
    }

    private func load() {
        var counts: [Int] = []
        for file in files {
            guard let document = PDFDocument(url: file.url), !document.isLocked else {
                error = "\(file.url.lastPathComponent) can't be opened (password-protected or damaged)."
                counts.append(0)
                continue
            }
            counts.append(document.pageCount)
        }
        pageCounts = counts
        pages = PageArrangement.all(pageCounts: counts).pages
        let urls = files.map(\.url)
        Task {
            for (fileIndex, url) in urls.enumerated() {
                let images = await Self.thumbnails(of: url, fileIndex: fileIndex)
                thumbnails.merge(images.images) { $1 }
            }
        }
    }

    private struct Thumbnails: @unchecked Sendable {
        var images: [String: NSImage] = [:]
    }

    @concurrent
    private nonisolated static func thumbnails(of url: URL, fileIndex: Int) async -> Thumbnails {
        var result = Thumbnails()
        guard let document = PDFDocument(url: url) else { return result }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            // The page as it is (its own rotation included); extra turns are shown on top.
            result.images[PageArrangement.Page(file: fileIndex, page: index).id] = page.thumbnail(of: NSSize(width: 260, height: 260), for: .cropBox)
        }
        return result
    }

    func name(of page: PageArrangement.Page) -> String {
        let file = files[page.file].url.deletingPathExtension().lastPathComponent
        return files.count > 1 ? "\(file) · \(page.page + 1)" : "Page \(page.page + 1)"
    }

    // MARK: - Selecting

    func click(_ page: PageArrangement.Page) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(page.id) { selection.remove(page.id) } else { selection.insert(page.id) }
            anchor = page.id
        } else if flags.contains(.shift), let anchor, let from = pages.firstIndex(where: { $0.id == anchor }),
                  let to = pages.firstIndex(where: { $0.id == page.id }) {
            selection = Set(pages[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [page.id]
            anchor = page.id
        }
    }

    func selectAll() { selection = Set(pages.map(\.id)) }

    // MARK: - Changing (undoable)

    private func change(_ body: (inout [PageArrangement.Page]) -> Void) {
        var copy = pages
        body(&copy)
        guard copy != pages else { return }
        history.append(pages)
        future.removeAll()
        pages = copy
        historyCount += 1
    }

    var canUndo: Bool { _ = historyCount; return !history.isEmpty }
    var canRedo: Bool { _ = historyCount; return !future.isEmpty }

    func undo() {
        guard let previous = history.popLast() else { return }
        future.append(pages)
        pages = previous
        historyCount += 1
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(pages)
        pages = next
        historyCount += 1
    }

    /// Turns the selected pages (or `page`) a quarter turn.
    func turn(clockwise: Bool, only page: PageArrangement.Page? = nil) {
        let ids = page.map { [$0.id] } ?? Array(selection)
        change { pages in
            for index in pages.indices where ids.contains(pages[index].id) {
                pages[index].turns = (pages[index].turns + (clockwise ? 1 : 3)) % 4
            }
        }
    }

    func deleteSelected() {
        change { $0.removeAll { selection.contains($0.id) } }
        selection = []
    }

    func reverse() {
        change { $0.reverse() }
    }

    func reset() {
        change { $0 = PageArrangement.all(pageCounts: pageCounts).pages }
        selection = []
    }

    /// The pages a drag moves: the dragged one, or the whole selection when
    /// it's part of it.
    private func moving(_ ids: [String]) -> Set<String> {
        var moving = Set(ids)
        if let first = ids.first, selection.contains(first) { moving.formUnion(selection) }
        return moving
    }

    /// Shows where the dragged pages would go, if they can go there.
    func hover(_ target: DropTarget?) {
        guard let target, let dragging else {
            dropTarget = nil
            return
        }
        if let page = target.page, moving([dragging]).contains(page) {
            dropTarget = nil  // onto itself: nothing would change
        } else if dropTarget != target {
            dropTarget = target
        }
    }

    /// Drops the dragged pages where the bar is.
    func dropDragged() {
        defer {
            dropTarget = nil
            dragging = nil
        }
        guard let target = dropTarget, let dragging else { return }
        var before = target.page
        if target.after, let page = target.page, let index = pages.firstIndex(where: { $0.id == page }) {
            let movingPages = moving([dragging])
            before = pages[(index + 1)...].first { !movingPages.contains($0.id) }?.id
        }
        move([dragging], before: before)
    }

    /// Moves the dragged pages (all selected ones, if the dragged page is
    /// selected) to just before `target` (nil: the end).
    func move(_ ids: [String], before target: String?) {
        let moving = moving(ids)
        guard target.map({ !moving.contains($0) }) ?? true else { return }
        change { pages in
            let moved = pages.filter { moving.contains($0.id) }
            pages.removeAll { moving.contains($0.id) }
            let at = target.flatMap { id in pages.firstIndex { $0.id == id } } ?? pages.count
            pages.insert(contentsOf: moved, at: at)
        }
    }

    // MARK: - Saving

    var isUnchanged: Bool { pages == PageArrangement.all(pageCounts: pageCounts).pages && files.count == 1 }

    func save() {
        onSave?(files, PageArrangement(pages: pages))
        onClose?()
    }
}

struct OrganizeView: View {
    var model: OrganizeModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(model.pages) { page in
                        PageCell(model: model, page: page)
                    }
                }
                .padding(22)
                EndDropZone(model: model)
            }
            .background(StudioCanvas.background)
            .onTapGesture { model.selection = [] }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Group {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo")
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 18)
            Button { model.turn(clockwise: false) } label: { Label("Turn Left", systemImage: "rotate.left") }
                .keyboardShortcut("l", modifiers: .command)
            Button { model.turn(clockwise: true) } label: { Label("Turn Right", systemImage: "rotate.right") }
                .keyboardShortcut("r", modifiers: .command)
            Button(role: .destructive, action: model.deleteSelected) { Label("Remove", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
            Spacer()
            Button("Select All", action: model.selectAll)
                .keyboardShortcut("a", modifiers: .command)
            Button("Reverse", action: model.reverse)
            Button("Reset", action: model.reset)
        }
        .disabled(model.pages.isEmpty)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.files.count == 1 ? model.files[0].url.lastPathComponent : "\(model.files.count) PDFs")
                    .font(.system(size: 12, weight: .medium))
                Text("\(model.pages.count) pages\(model.selection.isEmpty ? "" : " · \(model.selection.count) selected")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Spacer()
            Text("Drag pages to reorder · ⌘-click or ⇧-click to select several")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") { model.onClose?() }
                .keyboardShortcut(.cancelAction)
            Button(model.files.count > 1 ? "Save as One PDF" : "Save Copy", action: model.save)
                .keyboardShortcut(.defaultAction)
                .disabled(model.pages.isEmpty || model.isUnchanged)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The space after the last page: dropping there puts pages at the end.
private struct EndDropZone: View {
    var model: OrganizeModel

    var body: some View {
        let targeted = model.dropTarget == OrganizeModel.DropTarget(page: nil)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(targeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(targeted ? Color.accentColor.opacity(0.15) : .clear))
            .overlay {
                if targeted { Text("Put at the end").font(.caption.weight(.semibold)).foregroundStyle(.white) }
            }
            .frame(height: 60)
            .padding(.horizontal, 22)
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], delegate: PageDrop(model: model, page: nil))
    }
}

/// Follows a page dragged over a page (or the end), so the bar shows the
/// side it would land on, and drops it there.
private struct PageDrop: DropDelegate {
    let model: OrganizeModel
    let page: String?

    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil }
    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) {
        if model.dropTarget?.page == page { model.hover(nil) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: model.dropTarget == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard model.dropTarget != nil else { return false }
        model.dropDragged()
        return true
    }

    private func update(_ info: DropInfo) {
        model.hover(OrganizeModel.DropTarget(page: page, after: page != nil && info.location.x > model.cellWidth / 2))
    }
}

private struct PageCell: View {
    var model: OrganizeModel
    let page: PageArrangement.Page

    private var isSelected: Bool { model.selection.contains(page.id) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbnail = model.thumbnails[page.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .rotationEffect(.degrees(Double(page.turns) * 90))
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(width: 140, height: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.35) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(model.name(of: page))
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // The whole column, so the bar below lands in the middle of the gap.
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { model.cellWidth = $0 }
        .overlay(alignment: model.dropTarget?.after == true ? .trailing : .leading) {
            if model.dropTarget?.page == page.id {
                // The bar sits in the gap where the pages would go (18 points wide).
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4)
                    .padding(.vertical, 2)
                    .shadow(color: Color.accentColor.opacity(0.7), radius: 5)
                    .offset(x: model.dropTarget?.after == true ? 11 : -11)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.dropTarget)
        .contentShape(Rectangle())
        .onTapGesture { model.click(page) }
        .contextMenu {
            Button("Turn Left") { model.turn(clockwise: false, only: page) }
            Button("Turn Right") { model.turn(clockwise: true, only: page) }
            Button("Remove") {
                model.selection = [page.id]
                model.deleteSelected()
            }
        }
        .onDrag {
            model.dragging = page.id
            return NSItemProvider(object: page.id as NSString)
        }
        .onDrop(of: [.plainText], delegate: PageDrop(model: model, page: page.id))
    }
}

final class OrganizeWindowController: EditorWindowController {
    init(model: OrganizeModel) {
        let title = model.files.count == 1 ? "Organize \(model.files[0].url.lastPathComponent)" : "Organize \(model.files.count) PDFs"
        super.init(title: title, size: NSSize(width: 980, height: 720), content: OrganizeView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }
}
