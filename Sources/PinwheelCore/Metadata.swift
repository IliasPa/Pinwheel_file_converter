import Foundation

/// A detail the Info window can change.
public enum MetadataField: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    case title, artist, album, genre, year, author, description, comment, copyright, subject, keywords

    public var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .year: "Year"
        case .author: "Author"
        case .description: "Description"
        case .comment: "Comment"
        case .copyright: "Copyright"
        case .subject: "Subject"
        case .keywords: "Keywords"
        }
    }

    /// Shown in the empty field.
    public var prompt: String {
        switch self {
        case .keywords: "Separated by commas"
        case .year: "e.g. 2026"
        case .author, .artist: "Name"
        default: "None"
        }
    }

    /// Which details each kind of file can have, in the order shown.
    public static func fields(for kind: FileKind?) -> [MetadataField] {
        switch kind {
        case .image: [.title, .description, .author, .copyright, .keywords]
        case .video: [.title, .artist, .description]
        case .audio: [.title, .artist, .album, .genre, .year, .comment]
        case .pdf: [.title, .author, .subject, .keywords]
        case nil: []
        }
    }

    /// Lists such as keywords are typed with commas in between.
    static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// What the Info window changes. Saved as a new file, like everything else.
public struct MetadataEdit: Codable, Sendable, Equatable {
    /// New values; an empty string removes that detail.
    public var changes: [MetadataField: String] = [:]
    /// Removes where a photo or video was taken.
    public var removeLocation = false

    public init(changes: [MetadataField: String] = [:], removeLocation: Bool = false) {
        self.changes = changes
        self.removeLocation = removeLocation
    }

    public var isEmpty: Bool { changes.isEmpty && !removeLocation }
}

/// Where a photo or video was taken.
public struct GeoLocation: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "37.9838° N, 23.7275° E" (four decimals is about ten meters)
    public var description: String {
        String(format: "%.4f° %@, %.4f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }

    /// Opens in the Maps app.
    public var mapsURL: URL {
        URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(latitude),\(longitude)")!
    }

    /// From the ISO 6709 text videos use: "+37.9838+023.7275+000.000/".
    init?(iso6709 text: String) {
        let pattern = /([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)/
        guard let match = text.firstMatch(of: pattern),
              let latitude = Double(match.1), let longitude = Double(match.2) else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }
}

/// Everything the Info window shows about one file.
public struct FileDetails: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Hashable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public let title: String
        public let rows: [Row]
        public var id: String { title }
    }

    public var sections: [Section] = []
    /// The details that can be edited for this kind of file…
    public var fields: [MetadataField] = []
    /// …and their current values.
    public var values: [MetadataField: String] = [:]
    /// Why the details can't be saved, or nil when they can.
    public var readOnlyReason: String?
    public var location: GeoLocation?
}
