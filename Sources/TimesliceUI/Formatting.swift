import SwiftUI

/// UI-layer helpers shared by every Timeslice front-end.
///
/// Separate from `TimesliceApp` because the Live Activity / Dynamic Island widget runs in its own
/// extension process and cannot link an AppKit executable, yet must render times and colours
/// identically to the Mac app. Everything here is plain SwiftUI, so it builds for macOS, iOS and an
/// app extension alike. Colour *maths* deliberately lives in `TimesliceCore.Palette`; this target
/// only turns the result into a `Color`.
public enum Format {
    /// H:MM:SS (or M:SS under an hour) for the given seconds.
    public static func duration(_ seconds: TimeInterval) -> String {
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
    /// `1:23.45` — HUNDREDTHS, the way the system Stopwatch reads.
    ///
    /// Two fractional digits, not three. Milliseconds give a digit that can never be read at any refresh
    /// rate a battery-conscious app should use, and it churns the widest column in the row for no
    /// information. Hundredths is what Apple's own stopwatch shows and it's legible.
    public static func durationHundredths(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped.rounded(.down))
        // Truncated, not rounded: rounding can produce `.100`, which then renders as a jump.
        let cs = min(99, Int((clamped - Double(total)) * 100))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, cs) }
        return String(format: "%d:%02d.%02d", m, s, cs)
    }

    public static func durationMs(_ seconds: TimeInterval) -> String {
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
    public static func menuBarDuration(_ seconds: TimeInterval) -> String {
        duration(seconds)
    }

    /// Readable magnitude rather than a stopwatch: `45m`, `2h 15m`, `1d 3h`.
    ///
    /// H:MM:SS is right for a live timer, where you watch it tick — but for a *total* it forces
    /// you to parse colons to see whether "25:30:00" is a day of work or half an hour. Seconds
    /// only appear under a minute, where they're the whole story.
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, remMinutes = minutes % 60
        if hours < 24 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
        }
        let days = hours / 24, remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }
}

extension Color {
    /// Parse a "#RRGGBB" hex string; falls back to gray.
    public init(hex: String) {
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
