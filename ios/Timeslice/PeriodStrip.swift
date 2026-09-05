import SwiftUI
import TimesliceCore
import TimesliceUI

/// One period's headline figures, ready to draw as a card.
///
/// Deliberately just the numbers: every one of them comes from `Aggregations.summary` over a
/// `DateRange.stepped` window, so a card cannot disagree with the screen it sits above.
struct PeriodCard: Identifiable, Equatable {
    let range: DateRange
    let totalSeconds: TimeInterval
    let deepSeconds: TimeInterval
    /// The ring's fill, 0…1: this period's total against the BUSIEST period in the strip.
    ///
    /// Assigned by the strip builder rather than computed here, because it depends on the other cards.
    ///
    /// This was focus share (`deep / total`) first, and that was wrong in a way only a screenshot
    /// showed: focus sits near 100% for anyone whose sessions are long, so a 3h day and an 8h30m day
    /// drew nearly identical full rings — the ring actively contradicted the number inside it. Relative
    /// total makes the ring and the number say the same thing, which is the whole job of a card you
    /// scan rather than read.
    ///
    /// A relative scale, not a goal, because Timeslice has no global daily hours target — budgets are
    /// per project/tag/task. This is the same convention `Sparkline` already uses ("one shared scale,
    /// the range's own maximum"), so the two agree.
    var fraction: Double = 0

    var id: Date { range.start }

    /// Focused share of the period, 0…1. Not the ring any more; kept because it's the honest reading of
    /// "how much of this was deep work" and the hero card still shows it for the selected period.
    var focusFraction: Double {
        totalSeconds > 0 ? min(1, deepSeconds / totalSeconds) : 0
    }
}

/// A flickable row of period cards — the Health/Fitness idiom, and the browsing control for Metrics.
///
/// This replaces stepping through `‹ 25 Aug ›` one period at a time. A stepper shows you exactly one
/// period and hides its neighbours, so comparing days meant tapping back and forth and remembering the
/// number. A strip of cards puts the comparison on screen: the ring shows each period's focus at a
/// glance, the number shows its magnitude, and tapping one selects it.
///
/// Newest is on the RIGHT and the strip opens scrolled there, because the most recent period is the one
/// you nearly always want and reading left-to-right into the past is how a calendar reads.
struct PeriodStrip: View {
    let cards: [PeriodCard]
    let selected: DateRange
    let onSelect: (DateRange) -> Void

    /// Must match `PeriodCardView`'s own width — the side insets are derived from it.
    static let cardWidth: CGFloat = 68
    private static let spacing: CGFloat = 8
    /// Fixed, because the `GeometryReader` that measures the viewport needs a height from its parent.
    private static let stripHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            // ASYMMETRIC insets, and that asymmetry is the whole behaviour.
            //
            // LEADING gets half a viewport, so an older card can reach the middle. TRAILING gets almost
            // nothing, so the newest period sits flush against the right edge when it's selected —
            // `anchor: .center` simply clamps at the content's end and lands it there.
            //
            // Padding both ends (which is what this did) centred Today with dead space to its right,
            // making the strip look like it had scrolled somewhere odd. With only the leading inset you
            // get the described behaviour for free: Today is right-most, and the first swipe left brings
            // the selection to the centre, where every further swipe keeps it.
            let leadInset = max(Self.spacing, (geo.size.width - Self.cardWidth) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(cards) { card in
                            Button { onSelect(card.range) } label: {
                                PeriodCardView(card: card, isSelected: card.range == selected)
                            }
                            .buttonStyle(.plain)
                            .id(card.id)
                        }
                    }
                    .padding(.leading, leadInset)
                    .padding(.trailing, Self.spacing)
                    .padding(.vertical, 2)
                }
                // NO `.scrollTargetBehavior(.viewAligned)`.
                //
                // It was added for snapping, and it fights `scrollTo(anchor: .center)`: `viewAligned`
                // re-settles the content onto its own alignment AFTER a programmatic scroll, so the
                // selected card ended up against an edge instead of the middle. That's the "focus snaps
                // back to left instead of being at the center" — two mechanisms deciding the same scroll
                // offset, and the last one wins.
                //
                // Snapping isn't lost. Every period change re-centres the selection with an animation, and
                // a period change is what a swipe DOES here, so the strip still lands on a card — it just
                // lands on the selected one rather than wherever alignment rounds to.
                .onAppear { scroll(proxy, animated: false) }
                // Follow an external change of range — a swipe on the cards below, or switching the
                // unit, which rebuilds the strip entirely.
                .onChange(of: selected) { _, _ in scroll(proxy, animated: true) }
                // AND follow the cards arriving.
                //
                // This is the fix for "it comes back to the beginning like a circular buffer". The strip's
                // window is built to include the selection, but SwiftUI gives no ordering guarantee
                // between the parent recomputing `cards` and this child seeing `selected` change. Swiping
                // past the oldest card fired the scroll while `cards` was still the PREVIOUS window — so
                // the selection wasn't in it, and the fallback jumped to the newest card. Re-scrolling
                // once the rebuilt window lands settles it on the right card.
                .onChange(of: cards.first?.id) { _, _ in scroll(proxy, animated: false) }
                .onChange(of: cards.count) { _, _ in scroll(proxy, animated: false) }
            }
        }
        .frame(height: Self.stripHeight)
    }

    /// Bring the selected card to the CENTRE.
    ///
    /// It was pinned to the trailing edge, which meant the selected period sat against the right wall
    /// with its whole future off screen — selecting yesterday hid today. Centring shows neighbours on
    /// both sides, so the strip reads as a position in time rather than as the end of a list.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        // NO fallback to `cards.last`. That fallback was the "circular buffer": when the selection wasn't
        // in the current window — which happens for one frame every time the window grows — it scrolled to
        // the NEWEST card, so swiping into the past kept flinging the strip back to Today. Staying put is
        // correct; the `cards` observers above re-run this once the right window arrives.
        guard let target = cards.first(where: { $0.range == selected })?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

/// A single card: caption, ring with the period's total in the middle.
///
/// Sized so about four and a half fit on screen — enough that the strip reads as a comparison and
/// obviously scrolls, without the cards becoming too small for the number inside the ring.
private struct PeriodCardView: View {
    let card: PeriodCard
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .lineLimit(1)

            LabelledRing(fraction: card.fraction,
                         tint: isSelected ? .accentColor : ringTint,
                         lineWidth: 5) {
                Text(card.totalSeconds > 0 ? Format.compact(card.totalSeconds) : "–")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(card.totalSeconds > 0 ? .primary : .tertiary)
                    .lineLimit(1)
            }
            .frame(width: 46, height: 46)
        }
        .frame(width: 68)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
        )
    }

    /// Empty periods keep the track only, so a gap in the history reads as a gap instead of as a
    /// zero-focus day.
    private var ringTint: Color {
        card.totalSeconds > 0 ? .green : .clear
    }

    /// Unit-appropriate label. Short by necessity — the card is 68pt wide.
    private var caption: String {
        let cal = Calendar.current
        let start = card.range.start
        switch card.range.unit {
        case .day:
            // Weekday plus day-of-month: "Mon 25". Today is named, because "today" is the one label
            // worth spending the width on.
            if cal.isDateInToday(start) { return "Today" }
            if cal.isDateInYesterday(start) { return "Yest." }
            return start.formatted(.dateTime.weekday(.abbreviated).day())
        case .week:
            return start.formatted(.dateTime.month(.abbreviated).day())
        case .month:
            return start.formatted(.dateTime.month(.abbreviated))
        case .sixMonths:
            return start.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        case .year:
            return start.formatted(.dateTime.year())
        case .all:
            return "All"
        }
    }
}
