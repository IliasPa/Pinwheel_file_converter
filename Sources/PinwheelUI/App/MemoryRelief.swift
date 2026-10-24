import Darwin
import Foundation

/// Gives memory back to macOS after a window closes. Freed memory otherwise
/// stays with the app (counted in Activity Monitor) until macOS runs short:
/// after Settings or the clipboard window had been open, idle Pinwheel kept
/// showing twice what it used.
enum MemoryRelief {
    private static var pending: Task<Void, Never>?

    /// A few seconds from now (once, however often it's asked), when the
    /// window's animations and pictures are surely let go.
    static func soon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .background) { _ = malloc_zone_pressure_relief(nil, 0) }.value
        }
    }
}
