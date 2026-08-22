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

    /// Readable magnitude rather than a stopwatch: `45m`, `2h 15m`, `1d 3h`.
    ///
    /// H:MM:SS is right for a live timer, where you watch it tick — but for a *total* it forces
    /// you to parse colons to see whether "25:30:00" is a day of work or half an hour. Seconds
    /// only appear under a minute, where they're the whole story.
    static func compact(_ seconds: TimeInterval) -> String {
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

/// Default palette for new tasks (brand-neutral, works in light/dark).
enum Palette {
    /// Hand-picked, well-separated base colors used for the first tasks.
    static let colors = [
        "#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
        "#76B7B2", "#EDC948", "#FF9DA7", "#9C755F", "#BAB0AC",
    ]

    /// Beyond the base palette, generate new hues instead of repeating — with many tasks a
    /// repeated color makes the timeline/legend ambiguous. Uses the golden-angle so successive
    /// hues stay far apart, and alternates lightness so neighbours differ in two dimensions.
    static func color(forIndex index: Int) -> String {
        if index < colors.count { return colors[index] }
        let n = index - colors.count
        let hue = (Double(n) * 137.507).truncatingRemainder(dividingBy: 360) / 360   // golden angle
        let saturation = 0.55
        let brightness = n % 2 == 0 ? 0.78 : 0.62
        return hexString(fromHue: hue, saturation: saturation, brightness: brightness)
    }

    /// A shade of `baseHex` for the task at `index` within its project.
    ///
    /// Keeps the project's hue (so the group still reads as one family at a glance) but varies
    /// brightness and saturation, so adjacent blocks from different tasks in the same project
    /// stay tellable apart on the day timeline instead of merging into one band.
    ///
    /// `index == 0` returns the base colour unchanged, so the first task in a project matches the
    /// project's own swatch.
    static func shade(ofHex baseHex: String, index: Int) -> String {
        guard index > 0, let hsv = hsv(fromHex: baseHex) else { return baseHex }
        // Alternate lighter/darker in widening steps: +12%, −12%, +24%, −24%, …
        let step = (index + 1) / 2
        let sign: Double = index.isMultiple(of: 2) ? -1 : 1
        let delta = Double(step) * 0.12 * sign
        let brightness = min(0.97, max(0.30, hsv.v + delta))
        // Nudge saturation the other way so light shades don't wash out to near-white.
        let saturation = min(0.95, max(0.28, hsv.s - delta * 0.35))
        return hexString(fromHue: hsv.h, saturation: saturation, brightness: brightness)
    }

    private static func hsv(fromHex hex: String) -> (h: Double, s: Double, v: Double)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == r { h = (g - b) / delta / 6 }
            else if maxV == g { h = (2 + (b - r) / delta) / 6 }
            else { h = (4 + (r - g) / delta) / 6 }
            if h < 0 { h += 1 }
        }
        return (h, maxV > 0 ? delta / maxV : 0, maxV)
    }

    private static func hexString(fromHue h: Double, saturation s: Double, brightness v: Double) -> String {
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
