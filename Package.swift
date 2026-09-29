// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pinwheel",
    platforms: [.macOS(.v14)],
    targets: [
        // Conversion engine, format rules and wheel math. No UI, so it can be tested.
        .target(name: "PinwheelCore"),
        // The menu-bar app itself (AppKit + SwiftUI).
        .executableTarget(name: "Pinwheel", dependencies: ["PinwheelCore"]),
        .testTarget(name: "PinwheelCoreTests", dependencies: ["PinwheelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
