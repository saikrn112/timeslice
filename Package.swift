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
        // Linked by BOTH the iOS app and its widget extension, so a Live Activity button's intent is
        // one type with one metadata contribution rather than a copy per target.
        .library(name: "TimesliceIntents", targets: ["TimesliceIntents"]),
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
        // Live Activity intents. Separate from TimesliceUI because these are behaviour, not views, and
        // because AppIntents metadata extraction runs per target — keeping them alone makes it obvious
        // which target contributes the intents.
        .target(
            name: "TimesliceIntents",
            dependencies: ["TimesliceCore"],
            path: "Sources/TimesliceIntents"
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
        // Seeds a database with demo data. A separate executable so it can be pointed at an iOS
        // SIMULATOR container — that database is just a file on disk, and going through
        // `IntervalStore` keeps uids/updated_at/migrations correct in a way hand-written SQL would not.
        .executableTarget(
            name: "TimesliceSeed",
            dependencies: ["TimesliceCore"],
            path: "Tools/TimesliceSeed",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // Self-test runner. XCTest/swift-testing bundles aren't available under Command Line
        // Tools (no Xcode), so core logic is verified by this executable via `swift run TimesliceSelfTest`.
        .executableTarget(
            name: "TimesliceSelfTest",
            // TimesliceUI too, so the shared bar/sparkline components are covered here rather than
            // in an iOS test target that would need Xcode to run.
            dependencies: ["TimesliceCore", "TimesliceUI"],
            path: "Tests/TimesliceSelfTest",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
