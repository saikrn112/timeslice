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
        // Consumed by the iOS app AND its Live Activity extension, which is why it's a product.
        .library(name: "TimesliceUI", targets: ["TimesliceUI"]),
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
        // Shared SwiftUI helpers (time formatting, hex → Color). UI-framework-only, no AppKit, so
        // it builds for the iOS app and its widget extension as well as the Mac app.
        .target(
            name: "TimesliceUI",
            dependencies: ["TimesliceCore"],
            path: "Sources/TimesliceUI"
        ),
        .executableTarget(
            name: "TimesliceApp",
            dependencies: [
                "TimesliceCore",
                "TimesliceUI",
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
