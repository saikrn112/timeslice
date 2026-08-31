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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cards) { card in
                        Button { onSelect(card.range) } label: {
                            PeriodCardView(card: card, isSelected: card.range == selected)
                        }
                        .buttonStyle(.plain)
                        .id(card.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .onAppear { scroll(proxy, animated: false) }
            // Follow an external change of range — switching the unit rebuilds the strip entirely, and
            // without this it would open scrolled to the wrong end.
            .onChange(of: selected) { _, _ in scroll(proxy, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = cards.first(where: { $0.range == selected })?.id ?? cards.last?.id else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .trailing) }
        } else {
            proxy.scrollTo(target, anchor: .trailing)
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
