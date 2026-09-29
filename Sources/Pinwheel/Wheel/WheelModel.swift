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
}
