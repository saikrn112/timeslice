import SwiftUI

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

    /// Row title. The Mac's task rows are 12–13pt, not iOS `.body` (17pt) — which is the single
    /// biggest reason the phone felt oversized.
    public static let rowTitle = Font.system(size: 14)
    public static let rowTitleStrong = Font.system(size: 14, weight: .semibold)
    /// Monospaced digits for any duration, so columns line up and a ticking clock doesn't reflow.
    public static let rowTime = Font.system(size: 14, design: .monospaced)
    public static let sectionHeader = Font.system(size: 12, weight: .semibold)
    public static let caption = Font.system(size: 11)
    public static let captionSmall = Font.system(size: 10)
    /// Tile headline — the Mac uses `.title2` rounded semibold.
    public static let tileValue = Font.system(.title3, design: .rounded).weight(.semibold)

    // MARK: - Metrics

    /// Colour swatch beside a task. 9pt on the Mac.
    public static let dot: CGFloat = 9
    public static let rowSpacing: CGFloat = 9
    public static let cardRadius: CGFloat = 10
    public static let cardPadding: CGFloat = 10
    /// Vertical padding inside a list row. Tight on purpose: a tracker's list is scanned, not read.
    public static let rowVPadding: CGFloat = 5

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
