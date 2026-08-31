import SwiftUI
import TimesliceCore

/// The colours and metrics both front-ends draw with.
///
/// Exists because the phone was rendering with stock iOS defaults — system-blue accents,
/// `.insetGrouped` cards, body-sized type — while the Mac uses a deliberately low-chrome, dense
/// look built on semantic greys plus each task's own colour. Two apps that share every number were
/// still visibly unrelated.
///
/// The rule the Mac follows, and this encodes: **colour is information, never decoration.** Chrome is
/// `.primary`/`.secondary`/`.tertiary` grey; the only saturated colour in a row is the task's own
/// swatch or a verdict. That's why nothing here defines a brand hue.
public enum Theme {

    // MARK: - Surfaces

    /// Card/tile background. The Mac uses `NSColor.controlBackgroundColor`; iOS's closest analogue is
    /// `secondarySystemGroupedBackground`, which sits the same one step off the page behind it.
    public static var card: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// The page behind the cards.
    public static var page: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Fill for the selected state of a segmented control or tab, matching the Mac's
    /// `Color.secondary.opacity(0.16)`.
    public static let selection = Color.secondary.opacity(0.16)

    /// Empty track behind a progress bar.
    public static let track = Color.secondary.opacity(0.14)

    // MARK: - Type
    //
    // Sized for TOUCH, not for the Mac.
    //
    // These were first set to the Mac's values (14pt rows, 12pt headers, 10pt captions) on the theory
    // that matching the Mac was the goal. That was wrong: the Mac is read at arm's length with a
    // pointer, a phone is read one-handed at a glance, and 14pt rows with 10pt captions are genuinely
    // hard to read. iOS `.body` is 17pt for a reason.
    //
    // Primary text is 17pt — the same as iOS `.body`. It was 14 (the Mac's size), then 16, and was
    // still reported as too small on a real phone. Stop shaving it: a row you tap to start a timer
    // has to be readable at a glance, and vertical space is cheaper than a mis-tap.

    /// Row title.
    public static let rowTitle = Font.system(size: 17)
    public static let rowTitleStrong = Font.system(size: 17, weight: .semibold)
    /// Monospaced digits for any duration, so columns line up and a ticking clock doesn't reflow.
    public static let rowTime = Font.system(size: 16, design: .monospaced)
    public static let sectionHeader = Font.system(size: 14, weight: .semibold)
    public static let caption = Font.system(size: 13)
    public static let captionSmall = Font.system(size: 12)
    /// Tile headline.
    public static let tileValue = Font.system(.title2, design: .rounded).weight(.semibold)

    // MARK: - Metrics

    /// Colour swatch beside a task.
    public static let dot: CGFloat = 11
    public static let rowSpacing: CGFloat = 10
    public static let cardRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 12
    /// Vertical padding inside a list row.
    ///
    /// 10, not 5: a row is the primary TAP TARGET in this app — tapping it starts or pauses a timer —
    /// and Apple's guidance is a 44pt minimum. A 16pt label plus 10pt either side lands close to that;
    /// at 5pt the rows were both hard to read and easy to mis-tap.
    public static let rowVPadding: CGFloat = 10

    // MARK: - A task's colour, used as text

    /// The surfaces `legibleText` measures against.
    ///
    /// Deliberately the *hardest* case in each appearance rather than the average one: pure white is
    /// the lightest surface either app puts text on, and `#2E2E2E` is the LIGHTEST dark surface (a
    /// card, not the window behind it). Measuring against the easier surface would pass colours that
    /// then fail on the harder one.
    private static let lightSurface = "#FFFFFF"
    private static let darkSurface = "#2E2E2E"

    /// A task or tag's colour, safe to use as TEXT in the current appearance.
    ///
    /// Use this anywhere a *label* is painted in a subject's own colour. Do NOT use it for fills —
    /// swatches, bars, timeline blocks and the island keyline want the true colour, and routing those
    /// through here would change every existing Mac screenshot for no gain.
    public static func legibleText(_ hex: String, dark: Bool) -> Color {
        Color(hex: Palette.legibleHex(hex, onBackground: dark ? darkSurface : lightSurface))
    }

    /// Same, for text that is genuinely large or bold — WCAG allows 3:1 there.
    ///
    /// Separate so a 9pt tag chip can't accidentally borrow the looser threshold: small text is
    /// exactly where the palette's failures are most visible.
    public static func legibleTextLarge(_ hex: String, dark: Bool) -> Color {
        Color(hex: Palette.legibleHex(hex, onBackground: dark ? darkSurface : lightSurface,
                                      minRatio: 3.0))
    }

    // MARK: - Devices

    /// Colour for the Nth device on a timeline.
    ///
    /// A separate, small, fixed set rather than `Palette` — device identity and task identity are
    /// different axes, and drawing a device in a task's colour invites reading one as the other. Kept
    /// deliberately short: only one timer runs at a time across devices, so in practice this is two or
    /// three entries, and cycling is preferable to generating hues that drift toward the task palette.
    ///
    /// Chosen to hold up on both appearances and to stay distinguishable from each other at the few
    /// points of height a band gets.
    public static func deviceColor(_ index: Int) -> Color {
        let hexes = ["#5E9CFF", "#C58AF9", "#4DD6A8", "#F2A65A", "#9AA5B1"]
        return Color(hex: hexes[abs(index) % hexes.count])
    }

    // MARK: - Verdicts

    /// Budget verdict colours, matching the Mac: trouble red, behind orange, on-pace/met green.
    public static func verdict(_ v: TargetVerdictKind) -> Color {
        switch v {
        case .over: return .red
        case .behind: return .orange
        case .onPace, .met: return .green
        }
    }
}

/// Mirror of `TargetProgress.Verdict` so `Theme` doesn't have to import Core just for a colour map.
public enum TargetVerdictKind: Sendable {
    case met, onPace, behind, over
}
