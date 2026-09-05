import Foundation

/// Default palette for new tasks (brand-neutral, works in light/dark).
///
/// Lives in Core rather than the UI layer because it is pure maths over `#RRGGBB` strings and needs
/// no SwiftUI. Two payoffs: the colour path is covered by `TimesliceSelfTest`, and every process
/// that has to render a task in *its own colour* — the Mac app, the iOS app, and the Live Activity
/// widget extension, which cannot link the Mac app — derives it from this one implementation
/// instead of a copy that can drift.
public enum Palette {
    /// Hand-picked, well-separated base colors used for the first tasks.
    public static let colors = [
        "#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
        "#76B7B2", "#EDC948", "#FF9DA7", "#9C755F", "#BAB0AC",
    ]

    /// Beyond the base palette, generate new hues instead of repeating — with many tasks a
    /// repeated color makes the timeline/legend ambiguous. Uses the golden-angle so successive
    /// hues stay far apart, and alternates lightness so neighbours differ in two dimensions.
    public static func color(forIndex index: Int) -> String {
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
    public static func shade(ofHex baseHex: String, index: Int) -> String {
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

    /// The colour a task should render in: a shade of its group's, or its own when in Inbox.
    ///
    /// Hoisted out of `AppState` so it is not Mac-only. The phone must paint a task the *same*
    /// colour the Mac does — including in the Dynamic Island — and a second implementation of this
    /// derivation is exactly how that guarantee would quietly break.
    ///
    /// `allTasks` must include archived tasks: shades are positional, so hiding an archived sibling
    /// would renumber the ones after it and change their colours.
    public static func displayColorHex(
        for task: Project, groups: [TaskProject], allTasks: [Project]
    ) -> String {
        guard let groupID = task.taskProjectID,
              let group = groups.first(where: { $0.id == groupID }) else { return task.colorHex }
        return shade(ofHex: group.colorHex, index: shadeIndex(of: task, in: groupID, allTasks: allTasks))
    }

    /// A task's position among its project's tasks, in stable id order — so a task keeps the same
    /// shade as others come and go, rather than reshuffling on every change.
    public static func shadeIndex(of task: Project, in groupID: Int64, allTasks: [Project]) -> Int {
        let siblings = allTasks
            .filter { $0.taskProjectID == groupID }
            .sorted { $0.id < $1.id }
        return siblings.firstIndex { $0.id == task.id } ?? 0
    }

    /// `#RRGGBB` → HSV components, or nil when the string isn't a 6-digit hex colour.
    public static func hsv(fromHex hex: String) -> (h: Double, s: Double, v: Double)? {
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

    // MARK: - Legibility as text

    /// WCAG relative luminance (0…1) of `#RRGGBB`, or nil when the string isn't a hex colour.
    ///
    /// Distinct from `InlineBar.perceptualLuminance`, which is a cheap 0.299/0.587/0.114 average used
    /// to pick black-or-white text on a **known fill**. That's adequate for a binary choice on a bar,
    /// but it can't answer "is this colour readable *against the page*" — it isn't gamma-correct and
    /// yields no ratio. Both exist deliberately; this is the one with a threshold you can defend.
    public static func relativeLuminance(ofHex hex: String) -> Double? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        func channel(_ raw: Int) -> Double {
            let c = Double(raw) / 255
            // sRGB gamma. Skipping it is what makes naive checks pass colours that are unreadable.
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((value >> 16) & 0xFF)
            + 0.7152 * channel((value >> 8) & 0xFF)
            + 0.0722 * channel(value & 0xFF)
    }

    /// WCAG contrast ratio between two hex colours, 1…21. Order-independent.
    public static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = relativeLuminance(ofHex: a), let lb = relativeLuminance(ofHex: b) else {
            return nil
        }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `hex` adjusted until it is READABLE AS TEXT on `bgHex`, keeping its hue.
    ///
    /// A task colour is picked to be distinguishable *as a fill* — a swatch, a bar, a timeline block —
    /// which is a different requirement from being readable as text. Measured across this palette plus
    /// its `shade` variants, **47 of 60 task colours fail 4.5:1 on a light window**, worst at 1.20:1
    /// (`#B2F7F2`, effectively invisible); 17 fail on dark. So there is no fixed rendering of a task
    /// colour as text that works, and any UI painting a label in a task's own colour is illegible for
    /// most tasks unless it comes through here.
    ///
    /// Hue is held and only brightness moves, so identity survives as far as it can — not entirely:
    /// forcing yellow to 4.5:1 on white necessarily makes it olive. That's the same trade the Dynamic
    /// Island already makes, and it's the right one: identity is carried by the swatch and the keyline,
    /// where legibility doesn't depend on it, which frees text to be readable.
    ///
    /// Terminates regardless of input: brightness walks to a bound, and both bounds (near-black on
    /// light, near-white on dark) clear the threshold.
    public static func legibleHex(_ hex: String, onBackground bgHex: String,
                                  minRatio: Double = 4.5) -> String {
        guard let bgLuminance = relativeLuminance(ofHex: bgHex),
              var components = hsv(fromHex: hex) else { return hex }
        if let ratio = contrastRatio(hex, bgHex), ratio >= minRatio { return hex }

        // Move AWAY from the background: darker on a light page, lighter on a dark one.
        let darken = bgLuminance > 0.18
        var candidate = hex
        for _ in 0..<40 {
            components.v = darken ? max(0, components.v - 0.025) : min(1, components.v + 0.025)
            // Saturation climbs slightly while darkening, so a dimmed colour still reads as its hue
            // rather than as mud, and eases while lightening so pastels on dark don't glare.
            components.s = darken ? min(0.95, components.s + 0.01) : max(0.20, components.s - 0.01)
            candidate = hexString(fromHue: components.h, saturation: components.s,
                                  brightness: components.v)
            if let ratio = contrastRatio(candidate, bgHex), ratio >= minRatio { return candidate }
        }
        return candidate
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
