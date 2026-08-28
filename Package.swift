// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Timeslice",
    platforms: [
        .macOS("14.0"),
        // iOS 17 is the floor the Action Button sets (iPhone 15 Pro); Live Activities themselves
        // only need 16.1. Only `TimesliceCore` is expected to build for iOS — the `TimesliceApp`
        // executable is AppKit and stays Mac-only, and Xcode never builds it because the iOS
        // targets depend on the `TimesliceCore` product alone.
        .iOS("17.0"),
    ],
    products: [
        .library(name: "TimesliceCore", targets: ["TimesliceCore"]),
        .executable(name: "TimesliceApp", targets: ["TimesliceApp"]),
    ],
    dependencies: [
        // Global hotkeys are done with a hand-rolled Carbon RegisterEventHotKey wrapper
        // (see GlobalHotkeyManager.swift) — no external dependency. The KeyboardShortcuts
        // package can't build under Command Line Tools (its #Preview macros need full Xcode).
    ],
    targets: [
        .target(
            name: "TimesliceCore",
            path: "Sources/TimesliceCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "TimesliceApp",
            dependencies: [
                "TimesliceCore",
            ],
            path: "Sources/TimesliceApp",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // Self-test runner. XCTest/swift-testing bundles aren't available under Command Line
        // Tools (no Xcode), so core logic is verified by this executable via `swift run TimesliceSelfTest`.
        .executableTarget(
            name: "TimesliceSelfTest",
            dependencies: ["TimesliceCore"],
            path: "Tests/TimesliceSelfTest",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
