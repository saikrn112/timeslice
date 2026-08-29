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
