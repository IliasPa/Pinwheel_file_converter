import Foundation
import PinwheelCore

/// One wedge on the wheel.
struct WheelItem: Identifiable, Equatable {
    let action: WheelAction
    let title: String
    let symbolName: String
    let detail: String
    /// Why the wedge is grayed out, or nil when it can be used.
    let unavailableReason: String?

    var id: String { action.id }
    var isEnabled: Bool { unavailableReason == nil }
}

/// Everything the wheel view needs to draw itself.
@MainActor
final class WheelModel: ObservableObject {
    @Published var isPresented = false
    /// True when the wheel closes because something was dropped on it.
    @Published var confirmed = false
    @Published var mode: WheelMode = .convert
    @Published var items: [WheelItem] = []
    @Published var hovered: WheelLayout.Hit?
    @Published var summary = ""
    @Published var summarySymbol = "doc"

    var hoveredItem: WheelItem? {
        guard case .wedge(let index)? = hovered, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Fills in the wedges and the hub for these files.
    func load(
        files: [SourceFile],
        mode: WheelMode,
        availability: (WheelAction, [SourceFile]) -> Availability
    ) {
        self.mode = mode
        summary = FormatCatalog.summary(for: files)
        summarySymbol = FormatCatalog.symbolName(for: files)
        let kinds = Set(files.map(\.kind))
        let commonKind = kinds.count == 1 ? kinds.first! : nil
        items = FormatCatalog.actions(for: files, mode: mode).map { action in
            var reason: String?
            if case .unavailable(let why) = availability(action, files) { reason = why }
            return WheelItem(
                action: action,
                title: action.title(in: mode),
                symbolName: action.symbolName(in: mode),
                detail: action.detail(for: commonKind),
                unavailableReason: reason
            )
        }
    }

    /// A still wheel for the Settings preview and "Show on Desktop".
    static func sample(hovered: Int = 1) -> WheelModel {
        let model = WheelModel()
        model.load(files: [SourceFile.sample], mode: .convert) { _, _ in .available }
        model.hovered = .wedge(hovered)
        model.isPresented = true
        return model
    }
}

extension SourceFile {
    /// A pretend photo (it doesn't need to exist) for previews.
    static let sample = SourceFile(url: URL(fileURLWithPath: "/tmp/Pinwheel Preview.jpg"))
}
