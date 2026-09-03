import SwiftUI
import TimesliceCore
import TimesliceUI

/// Metrics, as a SUMMARY with drill-downs.
///
/// ## Why this isn't the Mac's page
///
/// It was, and that was the mistake. The Mac has ten sections on one scroll because a pointer and a large
/// window make that readable: you sweep a breakdown row and watch matching timeline blocks light up,
/// drag-select a span, compare a weekday pattern against an hours chart. None of those gestures exist on a
/// phone, so the port kept the density and lost the mechanism — nine stacked sections to scroll past to reach
/// the one you wanted, at type sized for a display twice as far away.
///
/// So: one screen answering "how is it going", with each section a row that opens its detail on demand.
/// Shallow by default. Nothing was deleted — it moved one tap away instead of one scroll among nine.
///
/// ## What is deliberately not here yet
///
/// 6M/Y/All ranges, the weekday pattern, the hours-per-bucket chart, and multi-select allocations with
/// union/intersection overlays. All comparative analysis done at a desk. Recorded in
/// `docs/ios_metrics_design.md` so they read as decisions rather than omissions.
struct MetricsScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @StateObject private var metrics = MetricsModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    unitPills
                    if !metrics.strip.isEmpty {
                        PeriodStrip(cards: metrics.strip, selected: metrics.range) {
                            metrics.select($0)
                        }
                    }
                    if metrics.filter != nil { filterBanner }
                    heroCard
                    allocationsRow
                    timelineRow
                    breakdownRow
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // The swipe stays: it's the fastest way to move a period, and it doesn't compete with the
                // strip's own horizontal scrolling because that's a separate subtree.
                .gesture(periodSwipe())
            }
            .background(Theme.page)
            .navigationTitle("Metrics")
            .refreshable {
                await SyncController.shared.syncOnce()
                model.load()
                metrics.invalidateStrip()
                metrics.rebuild()
            }
            .onAppear {
                // `load()` first, and here rather than relying on the root: a tab child's `onAppear` runs in
                // an unspecified order relative to its parent, so building against an empty task list
                // rendered every row as "(deleted task)" after a fresh install.
                model.load()
                metrics.rebuild()
            }
            .onChange(of: model.tasks) { _, _ in metrics.invalidateStrip(); metrics.rebuild() }
            .onChange(of: model.groups) { _, _ in metrics.invalidateStrip(); metrics.rebuild() }
            .onChange(of: model.running?.projectID) { _, _ in metrics.invalidateStrip() }
        }
    }

    // MARK: - Range

    private var unitPills: some View {
        HStack(spacing: 8) {
            ForEach(MetricsModel.units, id: \.self) { unit in
                let selected = metrics.range.unit == unit
                Button { metrics.select(unit: unit) } label: {
                    Text(label(for: unit))
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(minWidth: 68, minHeight: 36)
                        .background(Capsule().fill(selected ? Color.accentColor : Theme.metricTrack))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Spelled out rather than `D`/`W`/`M`: those abbreviations came from a Mac range bar squeezed onto a
    /// phone, and with three units there is room to say what they are.
    private func label(for unit: RangeUnit) -> String {
        switch unit {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        default: return unit.rawValue
        }
    }

    private func periodSwipe() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard let delta = DateRange.swipeDelta(dx: value.translation.width,
                                                       dy: value.translation.height) else { return }
                if metrics.step(delta) { Haptics.switched() }
            }
    }

    // MARK: - Filter

    /// What the page is narrowed to, and the way out.
    ///
    /// A filter with no visible indicator is how you read a small number and conclude you did nothing all
    /// day. States the subject, clears on tap.
    private var filterBanner: some View {
        Button { metrics.toggleFilter(nil, name: nil) } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                Text("Only \(metrics.filterName ?? "one subject")")
                    .font(Theme.metricLabel).lineLimit(1)
                Spacer()
                Text("Clear").font(Theme.metricCaption)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.metricSelection))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hours(metrics.data.summary.totalSeconds))
                        .font(Theme.metricHero)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("tracked \(metrics.range.label().lowercased())")
                        .font(Theme.metricCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(percent(metrics.data.summary.focusRatio))
                        .font(Theme.metricValue)
                    Text("focus").font(Theme.metricCaption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                stat("\(metrics.data.summary.switches)", "switches")
                stat(Format.compact(metrics.data.summary.longestSessionSeconds), "longest")
                if metrics.range.unit == .day {
                    stat(Format.compact(metrics.data.summary.deepSeconds), "focused")
                } else {
                    stat(hours(metrics.data.summary.bestDaySeconds), "best day")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }

    /// Grey, not tinted. The four hues this replaces taught nothing except which tile was third.
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.metricStat)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(Theme.metricCaption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section rows

    private var allocationsRow: some View {
        NavigationLink { AllocationsDetail(metrics: metrics) } label: {
            SummaryRow(title: "Allocations", detail: allocationSummary) {
                if metrics.data.budgets.isEmpty {
                    Text("None set").font(Theme.metricCaption).foregroundStyle(.secondary)
                } else {
                    AllocationDots(rows: metrics.data.budgets)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var allocationSummary: String {
        guard !metrics.data.budgets.isEmpty else { return "" }
        let counts = metrics.allocationCounts
        if counts.behind == 0 { return "all \(counts.onTrack) on track" }
        return "\(counts.onTrack) on track, \(counts.behind) behind"
    }

    private var timelineRow: some View {
        NavigationLink { TimelineDetail(metrics: metrics) } label: {
            SummaryRow(title: "Timeline",
                       detail: metrics.data.segments.isEmpty
                           ? "" : "\(metrics.data.sessions.count) blocks") {
                if metrics.data.segments.isEmpty {
                    Text("Nothing tracked").font(Theme.metricCaption).foregroundStyle(.secondary)
                } else {
                    MiniTimeline(segments: metrics.data.segments, colorHex: metrics.colorHexForTask)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var breakdownRow: some View {
        NavigationLink { BreakdownDetail(metrics: metrics) } label: {
            SummaryRow(title: "Where time went", detail: "") {
                let top = Array(metrics.data.taskTotals.prefix(3))
                if top.isEmpty {
                    Text("Nothing tracked").font(Theme.metricCaption).foregroundStyle(.secondary)
                } else {
                    let peak = top.map(\.seconds).max() ?? 1
                    VStack(spacing: 10) {
                        ForEach(top) { total in
                            BreakdownBar(name: total.project.name,
                                         seconds: total.seconds,
                                         fraction: peak > 0 ? total.seconds / peak : 0,
                                         colorHex: metrics.colorHexForTask(total.project.id))
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func percent(_ ratio: Double) -> String { "\(Int((ratio * 100).rounded()))%" }

    /// Hours, dropping the decimal once it stops mattering — the Mac's `hoursOnly`.
    private func hours(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        return h >= 10 ? String(format: "%.0fh", h) : String(format: "%.1fh", h)
    }
}

// MARK: - Shared pieces

/// A summary section: title, a one-line gist, a compact preview, a chevron.
///
/// The gist is what makes the drill-down honest — you can tell what's behind the row before spending a tap,
/// which a bare disclosure row doesn't give you.
struct SummaryRow<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title).font(Theme.metricSection)
                if !detail.isEmpty {
                    Text(detail).font(Theme.metricCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .contentShape(Rectangle())
    }
}

/// One dot per allocation in its verdict colour — the set's health at a glance, with no list to read.
struct AllocationDots: View {
    let rows: [BudgetRows.Row]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(rows) { row in
                Circle()
                    .fill(Theme.verdict(verdictKind(row.progress.verdict)))
                    .frame(width: 12, height: 12)
            }
            Spacer()
        }
    }
}

/// Shared so the summary and the detail can't disagree about what a verdict looks like.
func verdictKind(_ v: TargetProgress.Verdict) -> TargetVerdictKind {
    switch v {
    case .over: return .over
    case .behind: return .behind
    case .onPace: return .onPace
    case .met: return .met
    }
}

/// The day's shape at thumbnail size — enough to see whether it was fragmented, not enough to read.
struct MiniTimeline: View {
    let segments: [DaySegment]
    let colorHex: (Int64) -> String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.metricTrack)
                ForEach(segments) { seg in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: colorHex(seg.projectID)))
                        .frame(width: max(2, w * CGFloat((seg.endHour - seg.startHour) / 24)),
                               height: 20)
                        .offset(x: w * CGFloat(seg.startHour / 24))
                }
            }
        }
        .frame(height: 20)
    }
}

/// A name, a duration and a proportional bar. The bar is the subject's own colour — the only saturated thing
/// in the row.
struct BreakdownBar: View {
    let name: String
    let seconds: TimeInterval
    let fraction: Double
    let colorHex: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: colorHex)).frame(width: 10, height: 10)
            Text(name).font(Theme.metricLabel).lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.compact(seconds))
                .font(Theme.metricTime)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.metricTrack)
                    Capsule().fill(Color(hex: colorHex))
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(width: 60, height: 8)
        }
    }
}
