import Foundation
import PinwheelCore

/// Everything the wheel view needs to draw itself.
@MainActor
final class WheelModel: ObservableObject {
    @Published var isPresented = false
    @Published var mode: WheelMode = .convert
    @Published var fileCount = 0
}
