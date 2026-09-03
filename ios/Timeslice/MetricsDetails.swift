import SwiftUI
import TimesliceCore
import TimesliceUI

// MARK: - Allocations

/// Every allocation, full width, one per card.
///
/// Full width because the numbers didn't fit in two columns: `41h 52m` truncated to `41h…` and a pro-rated
/// goal to `≥3h…`, and a budget whose figures you can't read has no purpose. Scrolling is the cheaper cost.
///
/// Tapping one FILTERS the whole Metrics page to its subject. That's the touch answer to note 7 — on the Mac
/// you hover a row and matching blocks light up, which needs a pointer and dies when you look away. A filter
/// is stateful: it survives scrolling, drilling down, and coming back.
struct AllocationsDetail: View {
    @ObservedObject var metrics: MetricsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if metrics.data.budgets.isEmpty {
                    Text("No allocations set. Add them in Settings.")
                        .font(Theme.metricCaption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(metrics.data.budgets) { row in
                        Button {
                            metrics.toggleFilter(row.progress.target.subject, name: row.progress.name)
                            // Straight back to the summary: you filtered in order to see everything else
                            // narrowed, and staying here would hide the effect of the tap.
                            dismiss()
                        } label: {
                            AllocationCard(row: row,
                                           isFiltered: metrics.filter == row.progress.target.subject)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.page)
        .navigationTitle("Allocations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One allocation: the verdict, both pairs of numbers, and what to do about it.
struct AllocationCard: View {
    let row: BudgetRows.Row
    let isFiltered: Bool

    private var p: TargetProgress { row.progress }
    private var tint: Color { Theme.verdict(verdictKind(p.verdict)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(Color(hex: row.colorHex)).frame(width: 12, height: 12)
                Text(p.name).font(Theme.metricSection).lineLimit(1)
                Spacer()
                Text(verdictLabel)
                    .font(Theme.metricCaption.weight(.semibold))
                    .foregroundStyle(tint)
            }

            // The two figures, each stated in full. `41h 52m / ≥60h` beats a percentage: the percentage is
            // derivable and the durations are what you reason with.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(BudgetRows.duration(p.actualSeconds))
                    .font(Theme.metricValue)
                    .foregroundStyle(tint)
                Text("/ \(p.target.direction.symbol)\(BudgetRows.duration(p.target.seconds))")
                    .font(Theme.metricLabel)
                    .foregroundStyle(.secondary)
                Text(periodName).font(Theme.metricCaption).foregroundStyle(.tertiary)
            }

            // Progress with a pace mark, which is the only thing that distinguishes "behind" from "early".
            InlineBar(fraction: min(max(p.percent / 100, 0), 1),
                      label: "\(Int(p.percent.rounded()))%",
                      fill: tint,
                      height: 16,
                      marker: p.target.direction == .atLeast ? p.elapsedFraction : nil)

            HStack(spacing: 6) {
                Text(standing).font(Theme.metricCaption).foregroundStyle(.secondary)
                Spacer()
                if isFiltered {
                    Label("Filtering", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(Theme.metricCaption)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isFiltered ? Theme.metricSelection : Theme.card)
        )
    }

    private var verdictLabel: String {
        switch p.verdict {
        case .met: return "met"
        case .onPace: return "on pace"
        case .behind: return "behind"
        case .over: return "over"
        }
    }

    private var periodName: String {
        switch p.target.period {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        }
    }

    /// What to do about it, in words rather than a chart. A budget is scoped to a period that ends, so the
    /// useful figure is the gap and the pace that closes it.
    private var standing: String {
        let isFloor = p.target.direction == .atLeast
        if isFloor {
            if p.remainingSeconds <= 0 {
                return "met, with \(BudgetRows.duration(p.overSeconds)) to spare"
            }
            if let need = p.requiredPerDaySeconds {
                return "\(BudgetRows.duration(p.remainingSeconds)) left · "
                     + "\(BudgetRows.duration(need))/day to land it"
            }
            return "\(BudgetRows.duration(p.remainingSeconds)) short, period over"
        }
        if p.overSeconds > 0 { return "\(BudgetRows.duration(p.overSeconds)) over the limit" }
        return "\(BudgetRows.duration(p.remainingSeconds)) of headroom left"
    }
}

// MARK: - Timeline

/// The day's blocks, the device band, and the sessions that make them up.
///
/// Sessions live HERE rather than as their own summary row, because the two are one job: you come to the
/// timeline to find the block that shouldn't be there, and the list underneath is where you delete it. That's
/// the phone-specific reason this section exists at all — correcting a forgotten timer is something you do
/// away from the desk.
struct TimelineDetail: View {
    @ObservedObject var metrics: MetricsModel
    @ObservedObject private var model = TimerModel.shared
    @State private var inspected: DaySegment?

    private var devices: [String?] { Aggregations.orderedDevices(metrics.data.segments) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if metrics.data.segments.isEmpty {
                    Text("Nothing tracked \(metrics.range.label().lowercased()).")
                        .font(Theme.metricCaption).foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    timelineCard
                    sessionsCard
                }
            }
            .padding(16)
        }
        .background(Theme.page)
        .navigationTitle(metrics.range.label())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineStrip(segments: metrics.data.segments,
                          lanes: max(1, Aggregations.laneCount(metrics.data.segments)),
                          colorHex: metrics.colorHexForTask,
                          onTap: { inspected = $0 })
            if devices.count > 1 {
                DeviceBand(segments: metrics.data.segments, devices: devices)
                DeviceLegend(segments: metrics.data.segments, devices: devices,
                             labels: model.deviceLabels)
            }
            HourAxis()
            if let seg = inspected { inspector(seg) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }

    private func inspector(_ seg: DaySegment) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: metrics.colorHexForTask(seg.projectID)))
                .frame(width: 10, height: 10)
            Text(model.task(id: seg.projectID)?.name ?? "(deleted task)")
                .font(Theme.metricLabel).lineLimit(1)
            Spacer()
            Text(Format.compact((seg.endHour - seg.startHour) * 3600))
                .font(Theme.metricTime).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions").font(Theme.metricSection)
                Text("swipe to delete").font(Theme.metricCaption).foregroundStyle(.tertiary)
            }
            ForEach(metrics.data.sessions, id: \.id) { s in
                SessionRow(interval: s,
                           name: model.task(id: s.projectID)?.name ?? "(deleted task)",
                           colorHex: metrics.colorHexForTask(s.projectID),
                           deviceLabel: deviceLabel(s))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(s) } label: {
                            Image(systemName: "trash")
                        }
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
    }

    private func deviceLabel(_ s: Interval) -> String? {
        guard model.knownDevices.count > 1, let id = s.deviceID else { return nil }
        return model.deviceLabels[id]
    }

    private func delete(_ s: Interval) {
        guard let store = model.storeIfLoaded else { return }
        try? store.deleteInterval(id: s.id)
        model.reload()
        metrics.invalidateStrip()
        metrics.rebuild()
        SyncController.shared.publishSoon()
    }
}

/// One recorded block: what, when, how long.
struct SessionRow: View {
    let interval: Interval
    let name: String
    let colorHex: String
    let deviceLabel: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: colorHex)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.metricLabel).lineLimit(1)
                HStack(spacing: 5) {
                    Text(clock)
                    if let deviceLabel { Text("· \(deviceLabel)") }
                }
                .font(Theme.metricCaption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(Format.compact(interval.seconds()))
                .font(Theme.metricTime)
        }
        .frame(minHeight: 44)
    }

    /// `13:44–14:20`, or `–now` while running. When it happened, which a duration alone can't tell you and
    /// which is what lets a block be matched against the timeline above.
    private var clock: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let start = f.string(from: interval.start)
        guard let end = interval.end else { return "\(start)–now" }
        return "\(start)–\(f.string(from: end))"
    }
}

// MARK: - Breakdown

/// Where the time went, by task, project or tag — with a tap to filter.
struct BreakdownDetail: View {
    @ObservedObject var metrics: MetricsModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .tasks

    enum Scope: String, CaseIterable, Identifiable {
        case tasks = "Tasks", projects = "Projects", tags = "Tags"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)

                if scope == .tags {
                    // Tags overlap, so their totals can exceed the range's tracked time. Said once, here,
                    // rather than leaving the sums looking broken.
                    Text("Tags overlap, so these can add up to more than the total.")
                        .font(Theme.metricCaption).foregroundStyle(.tertiary)
                }

                VStack(spacing: 12) { rows }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            }
            .padding(16)
        }
        .background(Theme.page)
        .navigationTitle("Where time went")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var rows: some View {
        switch scope {
        case .tasks:
            let peak = metrics.data.taskTotals.map(\.seconds).max() ?? 1
            ForEach(metrics.data.taskTotals) { total in
                Button {
                    metrics.toggleFilter(.task(total.project.id), name: total.project.name)
                    dismiss()
                } label: {
                    BreakdownBar(name: total.project.name, seconds: total.seconds,
                                 fraction: peak > 0 ? total.seconds / peak : 0,
                                 colorHex: metrics.colorHexForTask(total.project.id))
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
            }
        case .projects:
            let peak = metrics.data.groupTotals.map(\.seconds).max() ?? 1
            ForEach(metrics.data.groupTotals) { total in
                Button {
                    guard let id = total.project?.id else { return }
                    metrics.toggleFilter(.project(id), name: total.name)
                    dismiss()
                } label: {
                    BreakdownBar(name: total.name, seconds: total.seconds,
                                 fraction: peak > 0 ? total.seconds / peak : 0,
                                 colorHex: total.colorHex)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .disabled(total.project == nil)
            }
        case .tags:
            let peak = metrics.data.tagTotals.map(\.seconds).max() ?? 1
            ForEach(metrics.data.tagTotals) { total in
                Button {
                    guard let id = total.tag?.id else { return }
                    metrics.toggleFilter(.tag(id), name: total.name)
                    dismiss()
                } label: {
                    BreakdownBar(name: total.name, seconds: total.seconds,
                                 fraction: peak > 0 ? total.seconds / peak : 0,
                                 colorHex: total.colorHex)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.plain)
                .disabled(total.tag == nil)
            }
        }
    }
}
