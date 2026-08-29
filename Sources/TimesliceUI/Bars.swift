import SwiftUI

/// A progress bar with its percentage centred INSIDE it, legible at every fill level.
///
/// The label is drawn twice — once in a colour that reads on the fill, once in a colour that reads
/// on the empty track — each masked to its own side of the fill boundary. That is the whole trick:
/// a centred label is crossed by the boundary at ~50% fill, which is the common case, and a single
/// text colour disappears there against one side or the other.
///
/// The on-fill colour comes from the fill's luminance, so this works for any tag colour as well as
/// the green/orange/red verdict states without a per-colour table.
///
/// Lives in `TimesliceUI` rather than the Mac app so the phone's Budgets screen renders bars that are
/// the *same component*, not a lookalike — the one thing that keeps two platforms' charts honest.
public struct InlineBar: View {
    let fraction: Double          // 0…1, already clamped by the caller if it can exceed
    let label: String
    let fill: Color
    var height: CGFloat = 13

    public init(fraction: Double, label: String, fill: Color, height: CGFloat = 13) {
        self.fraction = fraction
        self.label = label
        self.fill = fill
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fw = min(max(fraction, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                // No sliver at zero: a minimum-width stub reads as "started" when nothing has been.
                if fw > 0 { Capsule().fill(fill).frame(width: max(3, fw)) }

                text(color: onTrack)
                    .frame(width: w)
                    .mask(alignment: .leading) {
                        // Only the part of the glyphs sitting over empty track.
                        HStack(spacing: 0) { Color.clear.frame(width: fw); Rectangle() }
                    }
                text(color: onFill)
                    .frame(width: w)
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) { Rectangle().frame(width: fw); Color.clear }
                    }
            }
        }
        .frame(height: height)
    }

    private func text(color: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Readable against the empty track (which is a faint grey over the window background).
    private var onTrack: Color { .secondary }

    /// Readable against the fill.
    private var onFill: Color { InlineBar.readableTextColor(on: fill) }

    /// Text colour that reads on `fill`. Exposed (and pure) so the threshold is covered by
    /// `TimesliceSelfTest` — an unreadable label is a silent bug no compiler catches.
    public static func readableTextColor(on fill: Color) -> Color {
        guard let l = perceptualLuminance(of: fill) else { return .white }
        return l > 0.6 ? .black : .white
    }

    /// Perceptual luminance (0…1) of a colour, or nil if its components can't be read.
    ///
    /// Perceptual, **not** plain brightness: a saturated yellow is far lighter to the eye than its
    /// RGB max suggests, so `max(r,g,b)` picks white text on yellow and it disappears.
    ///
    /// Platform-branched rather than unified via `Color.resolve(in:)`: the macOS arm is deliberately
    /// the *identical* `NSColor` code it was before the move, so no Mac bar can change which text
    /// colour it picks. (`Color.resolve` would remove the branch and is available on both minimums,
    /// but its components aren't guaranteed to land on the same side of the threshold for every
    /// colour, and "the Mac looks unchanged" is this refactor's gate.)
    ///
    /// Note the two arms must be kept in step by hand: a macOS build cannot even typecheck the UIKit
    /// branch, which is how a missing argument label in it survived the first compile here.
    public static func perceptualLuminance(of color: Color) -> Double? {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return 0.299 * r + 0.587 * g + 0.114 * b
        #else
        guard let c = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        #endif
    }
}

/// A minimal per-bucket bar chart: shape at a glance, no axes or labels.
///
/// One shared scale (the range's own maximum), so heights within a row compare honestly. Empty
/// buckets draw a faint baseline rather than nothing, so a gap reads as a gap instead of the chart
/// silently compressing it.
public struct Sparkline: View {
    let values: [TimeInterval]
    let tint: Color

    public init(values: [TimeInterval], tint: Color) {
        self.values = values
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            let maxV = values.max() ?? 0
            // Downsample: a year of days would otherwise be 365 sub-pixel bars.
            let step = max(1, values.count / 60)
            let shown = stride(from: 0, to: values.count, by: step).map { values[$0] }
            let gap: CGFloat = shown.count > 30 ? 0.5 : 1
            let w = max(1, (geo.size.width - CGFloat(max(0, shown.count - 1)) * gap)
                        / CGFloat(max(1, shown.count)))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, v in
                    Rectangle()
                        .fill(v > 0 ? tint : Color.secondary.opacity(0.25))
                        .frame(width: w, height: maxV > 0 ? max(1, geo.size.height * CGFloat(v / maxV)) : 1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
    }
}
