import Foundation
import Observation

/// The last few files Pinwheel made, for the menu's "Recent Conversions".
@Observable
final class RecentsStore {
    struct Item: Codable, Equatable, Identifiable {
        var id = UUID()
        let path: String
        /// What was done, e.g. "PNG" or "Compress".
        let action: String
        let date: Date

        var url: URL { URL(fileURLWithPath: path) }
        var exists: Bool { FileManager.default.fileExists(atPath: path) }
    }

    static let limit = 10
    private static let key = "recentConversions"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var items: [Item] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(_ urls: [URL], action: String) {
        let now = Date()
        let new = urls.map { Item(path: $0.path, action: action, date: now) }
        let newPaths = Set(new.map(\.path))
        items = Array((new + items.filter { !newPaths.contains($0.path) }).prefix(Self.limit))
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
