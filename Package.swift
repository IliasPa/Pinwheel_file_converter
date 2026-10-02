// swift-tools-version:6.2
import PackageDescription

/// The app code runs on the main thread unless it says otherwise.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Pinwheel",
    platforms: [.macOS(.v26)],
    targets: [
        // Conversion engine, format rules, naming and wheel math. No UI.
        .target(name: "PinwheelCore"),
        // Everything you see: menu bar, wheel, progress window, Settings.
        .target(name: "PinwheelUI", dependencies: ["PinwheelCore"], swiftSettings: mainActorByDefault),
        // The app's starting point (a few lines that hand over to PinwheelUI).
        .executableTarget(name: "Pinwheel", dependencies: ["PinwheelUI"], swiftSettings: mainActorByDefault),
        .testTarget(name: "PinwheelCoreTests", dependencies: ["PinwheelCore"]),
        .testTarget(name: "PinwheelUITests", dependencies: ["PinwheelUI", "PinwheelCore"], swiftSettings: mainActorByDefault),
    ]
)
