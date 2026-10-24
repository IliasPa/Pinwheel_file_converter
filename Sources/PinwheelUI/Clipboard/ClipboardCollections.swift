import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A collection's name being typed: a new one (perhaps for a copy, from its
/// menu), or a new name for one there is.
struct CollectionNaming: Equatable {
    /// Nil for a new collection.
    var collection: ClipCollection.ID?
    var name = ""
    /// The copy that goes into the new collection.
    var adding: ClipItem.ID?
}

/// Where a copy dragged within the history can land.
enum ClipDropTarget: Equatable {
    case favorites
    case collection(ClipCollection.ID)
}

extension ClipboardPanelModel {
    func showCollection(_ collection: ClipCollection.ID?) {
        collectionID = collection
        if collection != nil { favoritesOnly = false }
    }

    func startNewCollection(adding item: ClipItem? = nil) {
        confirmingDelete = nil
        naming = CollectionNaming(adding: item?.id)
    }

    func startRenaming(_ collection: ClipCollection) {
        confirmingDelete = nil
        naming = CollectionNaming(collection: collection.id, name: collection.name)
    }

    /// Return in the name field: the collection is made (with the copy it
    /// was made for) or renamed. An empty name changes nothing.
    func finishNaming() {
        guard let naming else { return }
        self.naming = nil
        if let collection = naming.collection {
            store.rename(collection, to: naming.name)
        } else if let made = store.addCollection(named: naming.name) {
            madeNow.insert(made.id)
            if let adding = naming.adding, let item = store.items.first(where: { $0.id == adding }) {
                store.add(item, to: made.id)
                flash("Added to \(made.name)", on: item.id, isProblem: false)
            }
        }
    }

    /// In the collection, or out of it (from the copy's menu).
    func toggle(_ item: ClipItem, in collection: ClipCollection) {
        if collection.items.contains(item.id) {
            store.remove(item, from: collection.id)
        } else {
            store.add(item, to: collection.id)
            flash("Added to \(collection.name)", on: item.id, isProblem: false)
        }
    }

    /// The collection goes; its copies stay in the history.
    func deleteCollection(_ collection: ClipCollection.ID) {
        store.removeCollection(collection)
        if collectionID == collection { collectionID = nil }
        confirmingDelete = nil
    }

    /// A copy dragged from the list let go on a collection or the
    /// favorites. False for anything else (files from Finder).
    func drop(on target: ClipDropTarget) -> Bool {
        dropTarget = nil
        guard let dragging, let item = store.items.first(where: { $0.id == dragging }) else { return false }
        switch target {
        case .favorites:
            if !item.isFavorite { store.toggleFavorite(item) }
            flash("Added to Favorites", on: item.id, isProblem: false)
        case .collection(let id):
            guard let collection = store.collections.first(where: { $0.id == id }) else { return false }
            store.add(item, to: id)
            flash("Added to \(collection.name)", on: item.id, isProblem: false)
        }
        landed = target
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if landed == target { landed = nil }
        }
        return true
    }

    /// For a chip's drop highlight.
    func isTargeted(_ target: ClipDropTarget) -> Binding<Bool> {
        Binding(
            get: { self.dropTarget == target },
            set: { isOver in
                if isOver {
                    self.dropTarget = target
                } else if self.dropTarget == target {
                    self.dropTarget = nil
                }
            }
        )
    }
}

/// The collections, under the filters: one chip each (a click shows just
/// that collection; drop a copy on it to add the copy), then Favorites and
/// New Collection. Empty ones show only while a copy is dragged.
struct CollectionsBar: View {
    var model: ClipboardPanelModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.store.collections.filter(model.shows)) { collection in
                        if model.naming?.collection == collection.id {
                            nameField(placeholder: "Name")
                        } else {
                            chip(collection)
                        }
                    }
                    if model.showsFavorites {
                        favorites
                    }
                    if model.naming != nil && model.naming?.collection == nil {
                        nameField(placeholder: "New collection")
                    } else {
                        Button { model.startNewCollection() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.plus").font(.system(size: 10, weight: .semibold))
                                Text(model.store.collections.contains(where: model.shows) ? "New" : "New Collection").font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        }
                        .buttonStyle(.plain)
                        .help("A collection keeps copies together under a name, for good")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            if let id = model.confirmingDelete, let collection = model.store.collections.first(where: { $0.id == id }) {
                confirmDelete(collection)
            }
        }
        .onChange(of: model.naming == nil) { nameFocused = model.naming != nil }
    }

    private func chip(_ collection: ClipCollection) -> some View {
        let isOn = model.collectionID == collection.id
        let isTargeted = model.dropTarget == .collection(collection.id)
        return Button { model.showCollection(isOn ? nil : collection.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn || isTargeted ? "folder.fill" : "folder").font(.system(size: 10, weight: .semibold))
                Text(collection.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text("\(collection.items.count)").font(.system(size: 10, weight: .medium)).monospacedDigit().opacity(0.7)
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0))
            .scaleEffect(isTargeted ? 1.08 : (model.landed == .collection(collection.id) ? 1.12 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isTargeted)
            .animation(.spring(response: 0.3, dampingFraction: 0.4), value: model.landed)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.item], isTargeted: model.isTargeted(.collection(collection.id))) { _ in
            model.drop(on: .collection(collection.id))
        }
        .contextMenu {
            Button("Rename…") { model.startRenaming(collection) }
            Button("Delete Collection…") {
                model.naming = nil
                model.confirmingDelete = collection.id
            }
        }
        .help("Only the copies in \(collection.name). Drag a copy here to add it")
    }

    /// The copies with a heart. Drop a copy on it to give it one.
    private var favorites: some View {
        let isOn = model.favoritesOnly
        let isTargeted = model.dropTarget == .favorites
        return Button {
            model.favoritesOnly.toggle()
            if model.favoritesOnly { model.collectionID = nil }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.system(size: 10, weight: .semibold))
                Text("Favorites").font(.system(size: 11.5, weight: .medium))
                Text("\(model.store.items.count(where: \.isFavorite))").font(.system(size: 10, weight: .medium)).monospacedDigit().opacity(0.7)
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0))
            .scaleEffect(isTargeted ? 1.08 : (model.landed == .favorites ? 1.12 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isTargeted)
            .animation(.spring(response: 0.3, dampingFraction: 0.4), value: model.landed)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.item], isTargeted: model.isTargeted(.favorites)) { _ in model.drop(on: .favorites) }
        .help("Only the copies with a heart. Drag a copy here to give it one")
    }

    private func nameField(placeholder: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(get: { model.naming?.name ?? "" }, set: { model.naming?.name = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 130)
                .focused($nameFocused)
                .onSubmit { model.finishNaming() }
                .onKeyPress(.escape) {
                    model.naming = nil
                    return .handled
                }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
        .onAppear { nameFocused = true }
    }

    /// Asked here, in the window: a dialog would take the keyboard and close it.
    private func confirmDelete(_ collection: ClipCollection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Delete \u{201C}\(collection.name)\u{201D}? Its copies stay in the history, but no longer for good.")
                .font(.system(size: 11.5))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Cancel") { model.confirmingDelete = nil }
            Button("Delete", role: .destructive) { model.deleteCollection(collection.id) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .controlSize(.small)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}
