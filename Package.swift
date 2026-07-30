// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Timeslice",
    platforms: [
        .macOS("14.0"),
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
