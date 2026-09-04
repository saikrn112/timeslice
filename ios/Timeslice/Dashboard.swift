import SwiftUI
import TimesliceCore
import TimesliceUI

/// The three dashboard cards.
///
/// Whoop's actual discipline, which three earlier attempts kept missing: **few things, one dominant number each,
/// and a lot of empty space.** The mistake was never the chart type — it was nine tidy sections where there should
/// have been three loud ones. A 64pt figure with a thin gauge under it says more at a glance than six 13pt tiles.
///
/// Each card is: a small-caps label, the figure, one gauge, one qualifier. Nothing else.

// MARK: - Tracked

/// Today's total, against a typical recent day.
///
/// The gauge needs a denominator and this app has no daily target, so it compares against your own median of the
/// last fortnight of tracked days — `Aggregations.typicalDaySeconds`. Self-referential, like Whoop's baselines, and
/// it needs no setup. When there isn't enough history the arc is absent rather than measured against a guess.
struct TrackedCard: View {
    let seconds: TimeInterval
    let focusRatio: Double
    /// Median of recent tracked days, or nil when there's too little history to be honest about.
    let typical: TimeInterval?
    let label: String

    private var fraction: Double {
        guard let typical, typical > 0 else { return 0 }
        return seconds / typical
    }

    var body: some View {
        DashCard(label: "TRACKED", trailing: label) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(seconds > 0 ? Format.compact(seconds) : "—")
                        .font(Theme.dashHero)
                        .monospacedDigit()
                        .foregroundStyle(seconds > 0 ? .primary : .tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let typical {
                        Text("typical \(Format.compact(typical))")
                            .font(Theme.dashCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("building a baseline")
                            .font(Theme.dashCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                if typical != nil {
                    // The one gauge. Green past the baseline, accent below it — a state, not decoration.
                    ProgressRing(fraction: fraction,
                                 tint: fraction >= 1 ? .green : .accentColor,
                                 lineWidth: 9)
                        .frame(width: 84, height: 84)
                        .overlay {
                            VStack(spacing: 0) {
                                Text("\(Int((focusRatio * 100).rounded()))%")
                                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                                Text("focus")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Allocations

/// How many allocations are on track, then one thin bar each.
///
/// The headline is a count because that's the glanceable answer; the bars underneath are what make it actionable.
/// An earlier version showed only verdict dots, which could say "something is behind" but never which — so the row
/// was a button rather than information.
struct AllocationsCard: View {
    let rows: [BudgetRows.Row]
    let onSelect: (BudgetRows.Row) -> Void

    private var onTrack: Int {
        rows.filter { row in
            switch row.progress.verdict {
            case .met, .onPace: return true
            case .behind, .over: return false
            }
        }.count
    }

    var body: some View {
        DashCard(label: "ALLOCATIONS", trailing: nil) {
            if rows.isEmpty {
                Text("None set")
                    .font(Theme.dashCaption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(onTrack) of \(rows.count)")
                            .font(Theme.dashValue)
                            .monospacedDigit()
                        Text("on track")
                            .font(Theme.dashCaption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 12) {
                        // Worst first, so the top of the card is the thing to act on.
                        ForEach(rows.sorted { $0.progress.percent < $1.progress.percent }) { row in
                            Button { onSelect(row) } label: { AllocationBar(row: row) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

/// One allocation: name, thin bar with a pace mark, percentage.
private struct AllocationBar: View {
    let row: BudgetRows.Row

    private var p: TargetProgress { row.progress }
    private var tint: Color { Theme.verdict(verdictKind(p.verdict)) }

    var body: some View {
        HStack(spacing: 12) {
            Text(p.name)
                .font(Theme.dashRow)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.metricTrack)
                    Capsule().fill(tint)
                        .frame(width: max(3, geo.size.width * min(1, max(0, p.percent / 100))))
                    // Where the period says you should be by now. The only thing that distinguishes "behind"
                    // from "early", and meaningless for a ceiling, which has no pace to keep.
                    if p.target.direction == .atLeast, p.elapsedFraction > 0.02, p.elapsedFraction < 0.98 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * p.elapsedFraction)
                    }
                }
            }
            .frame(height: 8)
            Text("\(Int(p.percent.rounded()))%")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(minHeight: 30)
    }
}

// MARK: - Week

/// Seven bars and the week's average, drawn as the target line.
///
/// The average is the line because it's the only reference the data supplies — no goal exists to draw. It answers
/// "was today like my week", which is the same shape of question the Tracked gauge asks of the fortnight.
struct WeekCard: View {
    let digests: [DayDigest]
    /// The day currently being viewed, highlighted so the week gives it context rather than replacing it.
    let selected: Date
    let onSelect: (Date) -> Void

    private var tracked: [DayDigest] { digests.filter { $0.totalSeconds > 0 } }
    private var average: TimeInterval? {
        guard !tracked.isEmpty else { return nil }
        return tracked.reduce(0) { $0 + $1.totalSeconds } / Double(tracked.count)
    }
    private var peak: TimeInterval { max(digests.map(\.totalSeconds).max() ?? 1, average ?? 1) }

    var body: some View {
        DashCard(label: "THIS WEEK",
                 trailing: average.map { "avg \(Format.compact($0))" }) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(digests) { digest in
                    Button { onSelect(digest.day) } label: {
                        WeekBar(digest: digest,
                                peak: peak,
                                average: average,
                                isSelected: Calendar.current.isDate(digest.day, inSameDayAs: selected))
                    }
                    .buttonStyle(.plain)
                    .disabled(digest.totalSeconds <= 0)
                }
            }
            .frame(height: 128)
        }
    }
}

private struct WeekBar: View {
    let digest: DayDigest
    let peak: TimeInterval
    let average: TimeInterval?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.metricTrack)
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Theme.metricNeutralFill)
                        .frame(height: max(digest.totalSeconds > 0 ? 4 : 0,
                                           geo.size.height * (digest.totalSeconds / peak)))
                    // The average, drawn ACROSS every bar so the eye reads one line rather than seven marks.
                    if let average {
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(height: 1)
                            .offset(y: -geo.size.height * (average / peak))
                    }
                }
            }
            Text(digest.day.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shell

/// The card shell: small-caps label, optional trailing note, content. Nothing else, deliberately.
struct DashCard<Content: View>: View {
    let label: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(label)
                    .font(Theme.dashLabel)
                    .foregroundStyle(.secondary)
                    // Tracked out, which is what makes a small label read as a heading rather than as body text.
                    .tracking(1.2)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(Theme.dashCaption)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(Theme.dashCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.dashCardRadius).fill(Theme.card))
    }
}
