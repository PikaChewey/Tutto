// swift-tools-version: 6.0
//
// Tutto: every Mac utility you actually use, in one quiet menu bar app.
// Built with `scripts/build.sh`, which assembles and signs Tutto.app.
//
import PackageDescription

let package = Package(
    name: "Tutto",
    platforms: [.macOS(.v14)],
    targets: [
        // C shims over IOKit/private frameworks and the system libarchive.
        .target(
            name: "CBridges",
            path: "Sources/CBridges",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedLibrary("archive")]
        ),
        // Everything that can be tested without a UI: gesture logic, window math,
        // archives, clipboard store, sensors, battery parsing, shortcuts.
        .target(
            name: "TuttoKit",
            dependencies: ["CBridges"],
            path: "Sources/TuttoKit"
        ),
        .executableTarget(
            name: "Tutto",
            dependencies: ["CBridges", "TuttoKit"],
            path: "Sources/Tutto",
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"), .linkedFramework("ServiceManagement"), .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation"), .linkedFramework("Network"),
                .linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("LocalAuthentication"),
                .linkedFramework("Quartz"),
            ]
        ),
        // Finder Sync extension: the right-click menu for archives.
        .executableTarget(
            name: "TuttoFinder",
            path: "Sources/TuttoFinder",
            linkerSettings: [
                .linkedFramework("FinderSync"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        // Quick Look extension: space on an archive in Finder shows what's inside.
        .executableTarget(
            name: "TuttoQuickLook",
            dependencies: ["TuttoKit"],
            path: "Sources/TuttoQuickLook",
            linkerSettings: [
                .linkedFramework("Quartz"), .linkedFramework("SwiftUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        // Privileged helper (LaunchDaemon) that writes fan speeds to the SMC. Runs only on demand.
        .executableTarget(
            name: "TuttoHelper",
            dependencies: ["CBridges"],
            path: "Sources/TuttoHelper"
        ),
        .testTarget(
            name: "TuttoKitTests",
            dependencies: ["TuttoKit"],
            path: "Tests/TuttoKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
