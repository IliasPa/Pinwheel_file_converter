import SwiftUI

/// Pinwheel's own colors (indigo → blue → teal, matching the app icon).
enum Brand {
    static let indigo = Color(red: 0x43 / 255, green: 0x38 / 255, blue: 0xCA / 255)
    static let blue = Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
    static let teal = Color(red: 0x0D / 255, green: 0x94 / 255, blue: 0x88 / 255)

    static let gradient = LinearGradient(colors: [indigo, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}
