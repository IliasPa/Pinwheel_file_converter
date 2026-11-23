// swift-tools-version:6.2
import PackageDescription

/// The app code runs on the main thread unless it says otherwise.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

/// Release builds are optimized for size: 15% smaller programs, and the
/// conversions run just as fast (the heavy work is in Apple's frameworks;
/// measured on the loudness, background and collage tests).
let smallInRelease: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "Pinwheel",
    platforms: [.macOS(.v26)],
    targets: [
        // Conversion engine, format rules, naming and wheel math. No UI.
        .target(name: "PinwheelCore", swiftSettings: smallInRelease),
        // Everything you see: menu bar, wheel, progress window, Settings.
        .target(name: "PinwheelUI", dependencies: ["PinwheelCore"], swiftSettings: mainActorByDefault + smallInRelease),
        // The app's starting point (a few lines that hand over to PinwheelUI).
        .executableTarget(name: "Pinwheel", dependencies: ["PinwheelUI"], swiftSettings: mainActorByDefault + smallInRelease),
        // Does one conversion and quits; the app starts one per job.
        .executableTarget(name: "PinwheelWorker", dependencies: ["PinwheelCore"], swiftSettings: smallInRelease),
        // The `pinwheel` command (Terminal, Shortcuts): asks the app to do a job.
        .executableTarget(name: "PinwheelCLI", swiftSettings: smallInRelease),
        // Finder's right-click › New File: an extension Finder loads (it starts
        // at NSExtensionMain). Packed into the app's PlugIns by build-app.sh.
        .executableTarget(
            name: "PinwheelFinder",
            swiftSettings: [.swiftLanguageMode(.v5)] + smallInRelease,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]), .linkedFramework("FinderSync")]
        ),
        .testTarget(name: "PinwheelCoreTests", dependencies: ["PinwheelCore"]),
        .testTarget(name: "PinwheelUITests", dependencies: ["PinwheelUI", "PinwheelCore"], swiftSettings: mainActorByDefault),
    ]
)
