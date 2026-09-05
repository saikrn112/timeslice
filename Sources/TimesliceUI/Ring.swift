import SwiftUI

/// A closed progress ring, the Fitness-app idiom: one glance says "how much of this is done".
///
/// In `TimesliceUI` rather than the iOS target so the Mac can adopt it and so there is one
/// implementation of the geometry. It takes **already-computed** fractions — `TargetProgress` supplies
/// `actualSeconds`, `expectedSeconds` and `elapsedFraction`, and `Aggregations` supplies the totals — so
/// nothing here derives a number. The ring is a rendering of maths that lives in Core.
///
/// Why a ring rather than another bar: a bar's meaning comes from its width, which on a phone is
/// whatever is left after the labels, so twelve stacked bars read as a table. A ring is the same size
/// wherever it sits, which is what lets a row of them scan as cards.
public struct ProgressRing: View {
    /// Progress, 0…1 before overflow. Values above 1 are drawn as a full ring plus an overflow arc,
    /// because "127% of a ceiling" is the case you most need to see and a clamped ring hides it.
    let fraction: Double
    /// Where the period *should* be by now, 0…1 — drawn as a tick on the track. Nil when the notion
    /// doesn't apply (a finished period, or a total with no target).
    let pace: Double?
    let tint: Color
    let lineWidth: CGFloat

    public init(fraction: Double, pace: Double? = nil, tint: Color, lineWidth: CGFloat = 7) {
        self.fraction = fraction
        self.pace = pace
        self.tint = tint
        self.lineWidth = lineWidth
    }

    /// The part of `fraction` that fits in one turn.
    private var primary: Double { min(max(fraction, 0), 1) }
    /// Anything past 100%, itself capped at one more turn so a wild overrun stays a ring.
    private var overflow: Double { min(max(fraction - 1, 0), 1) }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: primary)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // From the top, clockwise — the convention every ring UI uses, and `trim` starts at
                // 3 o'clock without this.
                .rotationEffect(.degrees(-90))

            if overflow > 0 {
                // Drawn darker and on top, so an overrun reads as a second lap rather than as a
                // longer first one.
                Circle()
                    .trim(from: 0, to: overflow)
                    .stroke(tint.opacity(0.55),
                            style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            if let pace, pace > 0.01, pace < 0.99 {
                PaceTick(fraction: pace, lineWidth: lineWidth)
            }
        }
    }
}

/// The "where you should be by now" mark on a ring's track.
///
/// Separate view so the trigonometry that places it isn't inlined in the ring's body, and so it can be
/// reused if the Mac adopts rings. Draws a short radial notch rather than a dot — a dot at this size
/// reads as a bullet point, a notch reads as a gauge marking.
private struct PaceTick: View {
    let fraction: Double
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            Rectangle()
                .fill(Color.primary.opacity(0.55))
                .frame(width: 1.5, height: lineWidth + 3)
                // Offset to the ring's own radius, then rotated into place. `-90°` matches the ring's
                // own rotation so 0 is the top for both.
                .offset(y: -radius + lineWidth / 2)
                .rotationEffect(.degrees(fraction * 360))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Two concentric rings plus a centre label — the Fitness "rings" idiom.
///
/// Exists so a budget can show BOTH of its goals as circles instead of a ring plus a labelled bar plus
/// four durations. The bar version was complete and cluttered: per card it spent a whole row and three
/// extra numbers restating what a second ring says at a glance.
///
/// The two are told apart by colour, consistently across every card — the outer takes the verdict's
/// colour (is the period on track), the inner takes the subject's own (how much today). Nesting rather
/// than sitting side by side keeps one focal point per card, which is what makes a grid of them scan.
public struct NestedRings<Content: View>: View {
    let outerFraction: Double
    let outerPace: Double?
    let outerTint: Color
    let innerFraction: Double
    let innerTint: Color
    let lineWidth: CGFloat
    let content: Content

    public init(outerFraction: Double, outerPace: Double? = nil, outerTint: Color,
                innerFraction: Double, innerTint: Color, lineWidth: CGFloat = 6,
                @ViewBuilder content: () -> Content) {
        self.outerFraction = outerFraction
        self.outerPace = outerPace
        self.outerTint = outerTint
        self.innerFraction = innerFraction
        self.innerTint = innerTint
        self.lineWidth = lineWidth
        self.content = content()
    }

    public var body: some View {
        ZStack {
            ProgressRing(fraction: outerFraction, pace: outerPace, tint: outerTint,
                         lineWidth: lineWidth)
            ProgressRing(fraction: innerFraction, tint: innerTint, lineWidth: lineWidth * 0.75)
                // One stroke width plus a hairline gap, so the two read as separate rings rather than
                // as a thick band.
                .padding(lineWidth + 2.5)
            content
                .padding(lineWidth * 2.5 + 4)
                .minimumScaleFactor(0.5)
        }
    }
}

/// A ring with something in the middle — a number, or a glyph.
///
/// The pairing exists because a bare ring is a proportion with no magnitude: it says "two thirds" but
/// not "of what". On a card the middle is the only place the magnitude fits.
public struct LabelledRing<Content: View>: View {
    let fraction: Double
    let pace: Double?
    let tint: Color
    let lineWidth: CGFloat
    let content: Content

    public init(fraction: Double, pace: Double? = nil, tint: Color, lineWidth: CGFloat = 7,
                @ViewBuilder content: () -> Content) {
        self.fraction = fraction
        self.pace = pace
        self.tint = tint
        self.lineWidth = lineWidth
        self.content = content()
    }

    public var body: some View {
        ZStack {
            ProgressRing(fraction: fraction, pace: pace, tint: tint, lineWidth: lineWidth)
            content
                // Keep the label clear of the stroke, so a three-character value doesn't collide with
                // the ring at small diameters.
                .padding(lineWidth + 3)
                .minimumScaleFactor(0.5)
        }
    }
}
