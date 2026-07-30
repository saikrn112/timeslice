import SwiftUI

enum Format {
    /// H:MM:SS (or M:SS under an hour) for the given seconds.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Live form with milliseconds — H:MM:SS.mmm — used for the running timer so it visibly
    /// ticks. Best paired with a monospaced font so the width stays stable.
    static func durationMs(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped.rounded(.down))
        let ms = Int((clamped - Double(total)) * 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d.%03d", h, m, s, ms)
        }
        return String(format: "%d:%02d.%03d", m, s, ms)
    }

    /// Compact form for the menu bar (whole seconds — no ms, to avoid constant width jitter
    /// shifting neighbouring menu-bar icons).
    static func menuBarDuration(_ seconds: TimeInterval) -> String {
        duration(seconds)
    }
}

extension Color {
    /// Parse a "#RRGGBB" hex string; falls back to gray.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.56; g = 0.56; b = 0.58
        }
        self.init(red: r, green: g, blue: b)
    }
}

/// Default palette for new projects (brand-neutral, works in light/dark).
enum Palette {
    static let colors = [
        "#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
        "#76B7B2", "#EDC948", "#FF9DA7", "#9C755F", "#BAB0AC",
    ]
    static func color(forIndex index: Int) -> String {
        colors[index % colors.count]
    }
}
