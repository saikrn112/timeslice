import SwiftUI
import TimesliceCore
import TimesliceUI

/// Metrics: a sticky summary over one canvas. No sections.
///
/// ## The shape, and why
///
/// The Mac page works because everything is visible at once and your eye does the correlating. Two earlier
/// attempts lost exactly that: the first shrank the Mac's ten sections (density kept, mechanism lost), the
/// second replaced sections with taps — worse, because it hid the thing the ethos is built on.
///
/// So there are no sections. A **header** that always says where you stand, and a **canvas** that IS the period:
///
/// - **Day** → the day as a vertical calendar. Every block carries its own name, times and duration, so there's
///   no legend and nothing is a tap away. Gaps show as gaps.
/// - **Week/Month** → one row per day: total, shape, dominant task. Tap to drop into that day. Only the zoom
///   changes.
///
/// The header carries the only figures the canvas can't: the period total, focus, and the allocations that need
/// attention by name. Everything else is derivable by looking.
///
/// Deliberately absent, recorded in `docs/ios_metrics_design.md`: 6M/Y/All, the hours-per-bucket chart, the
/// weekday pattern, multi-select allocations with union/intersection overlays.
struct MetricsScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @StateObject private var metrics = MetricsModel()
    @State private var inspected: MergedBlock?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        canvas
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 24)
                    } header: {
                        MetricsHeader(metrics: metrics)
                    }
                }
                // Swipe anywhere to change period. Safe alongside vertical scrolling because `swipeDelta`
                // vetoes anything predominantly vertical.
                .gesture(periodSwipe())
            }
            .background(Theme.page)
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await SyncController.shared.syncOnce()
                model.load()
                metrics.invalidateStrip()
                metrics.rebuild()
            }
            .onAppear {
                // `load()` first, and here rather than relying on the root: a tab child's `onAppear` runs in an
                // unspecified order relative to its parent, so building against an empty task list rendered
                // every block as "(deleted task)" after a fresh install.
                model.load()
                metrics.rebuild()
            }
            .onChange(of: model.tasks) { _, _ in metrics.invalidateStrip(); metrics.rebuild() }
            .onChange(of: model.groups) { _, _ in metrics.invalidateStrip(); metrics.rebuild() }
            .onChange(of: model.running?.projectID) { _, _ in
                metrics.invalidateStrip()
                metrics.rebuild()
            }
            .sheet(item: $inspected) { block in BlockSheet(block: block, metrics: metrics) }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        if metrics.range.unit == .day {
            if metrics.data.segments.isEmpty {
                emptyCanvas
            } else {
                DayCanvas(segments: metrics.data.segments,
                          day: metrics.range.start,
                          colorHex: metrics.colorHexForTask,
                          name: metrics.nameForTask,
                          deviceLabel: metrics.labelForDevice,
                          runningIntervalID: model.running?.id,
                          onDelete: { metrics.deleteBlock($0) },
                          onInspect: { inspected = $0 })
            }
        } else if metrics.data.days.isEmpty {
            emptyCanvas
        } else {
            DayList(digests: metrics.data.days,
                    name: metrics.nameForTask,
                    colorHex: metrics.colorHexForTask,
                    onSelect: { metrics.selectDay($0) })
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        }
    }

    private var emptyCanvas: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(metrics.range.isCurrent()
                 ? "Nothing tracked yet — start a timer on the Tasks tab."
                 : "Nothing tracked \(metrics.range.label().lowercased()).")
                .font(Theme.metricLabel)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
    }

    private func periodSwipe() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard let delta = DateRange.swipeDelta(dx: value.translation.width,
                                                       dy: value.translation.height) else { return }
                if metrics.step(delta) { Haptics.switched() }
            }
    }
}

/// The sticky header: where you stand, always visible.
///
/// Pinned rather than scrolling away, because it holds the only figures the canvas can't show. Blocks say what
/// you did; this says the total, how much was focused, and which allocation needs attention — and those stay
/// relevant while you scroll through the day.
struct MetricsHeader: View {
    @ObservedObject var metrics: MetricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(MetricsModel.units, id: \.self) { unit in
                    let selected = metrics.range.unit == unit
                    Button { metrics.select(unit: unit) } label: {
                        Text(unitLabel(unit))
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .frame(minWidth: 58, minHeight: 32)
                            .background(Capsule().fill(selected ? Color.accentColor : Theme.metricTrack))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                // Only when you've navigated away, so it isn't a permanently-disabled control.
                if !metrics.range.isCurrent() {
                    Button { metrics.select(unit: metrics.range.unit) } label: {
                        Text("Today").font(Theme.metricCaption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(metrics.range.label())
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !metrics.isEmpty {
                    Text(Format.compact(metrics.data.summary.totalSeconds))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Int((metrics.data.summary.focusRatio * 100).rounded()))% focus")
                        .font(Theme.metricCaption)
                        .foregroundStyle(.secondary)
                }
            }

            // Named, with the pace that closes the gap. A verdict colour can't say WHICH allocation is behind or
            // what would fix it, which is why this isn't a row of dots.
            ForEach(highlighted) { row in
                NavigationLink { AllocationsDetail(metrics: metrics) } label: {
                    AllocationLine(row: row)
                }
                .buttonStyle(.plain)
            }
            if metrics.data.budgets.isEmpty {
                Text("No allocations set").font(Theme.metricCaption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Opaque: a pinned header with canvas scrolling under it must not read through.
        .background(.bar)
    }

    /// What's behind, worst first — or when nothing is, the one closest to its limit, so the header always names
    /// something concrete rather than only asserting all is well.
    private var highlighted: [BudgetRows.Row] {
        let needing = metrics.allocationsNeedingAttention
        if !needing.isEmpty { return Array(needing.prefix(2)) }
        return metrics.closestAllocation.map { [$0] } ?? []
    }

    private func unitLabel(_ unit: RangeUnit) -> String {
        switch unit {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        default: return unit.rawValue
        }
    }
}

/// One allocation, named, with the gap and the pace that closes it.
struct AllocationLine: View {
    let row: BudgetRows.Row

    private var p: TargetProgress { row.progress }
    private var tint: Color { Theme.verdict(verdictKind(p.verdict)) }

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(tint).frame(width: 9, height: 9)
            Text(p.name).font(Theme.metricLabel).lineLimit(1)
            Text(standing).font(Theme.metricCaption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 30)
    }

    /// The actionable sentence, not the verdict word. "behind" gives you the colour; "5h 39m left · 1h 53m/day"
    /// tells you what to do.
    private var standing: String {
        if p.target.direction == .atLeast {
            if p.remainingSeconds <= 0 { return "met · +\(BudgetRows.duration(p.overSeconds))" }
            if let need = p.requiredPerDaySeconds {
                return "\(BudgetRows.duration(p.remainingSeconds)) left · \(BudgetRows.duration(need))/day"
            }
            return "\(BudgetRows.duration(p.remainingSeconds)) short · period over"
        }
        if p.overSeconds > 0 { return "\(BudgetRows.duration(p.overSeconds)) over" }
        return "\(BudgetRows.duration(p.remainingSeconds)) headroom"
    }
}

/// Shared so header and detail can't disagree about what a verdict looks like.
func verdictKind(_ v: TargetProgress.Verdict) -> TargetVerdictKind {
    switch v {
    case .over: return .over
    case .behind: return .behind
    case .onPace: return .onPace
    case .met: return .met
    }
}

/// What a tapped block is, and the thing you'd want to do to it.
///
/// A sheet rather than expanding in place: the canvas is positioned by time, so growing a block would shove
/// every later block down and break the one property the layout exists for.
struct BlockSheet: View {
    let block: MergedBlock
    @ObservedObject var metrics: MetricsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Task", value: metrics.nameForTask(block.projectID))
                    LabeledContent("Duration", value: Format.compact(block.seconds))
                    if block.chunkCount > 1 {
                        // Named, because deleting this removes ALL of them — a merged block is one thing on
                        // screen and several rows in the database, and the destructive action has to be honest
                        // about which it acts on.
                        LabeledContent("Recorded as", value: "\(block.chunkCount) chunks")
                    }
                    if let device = metrics.labelForDevice(block.deviceID) {
                        LabeledContent("Recorded on", value: device)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        metrics.deleteBlock(block)
                        dismiss()
                    } label: {
                        Label(block.chunkCount > 1 ? "Delete all \(block.chunkCount) chunks"
                                                  : "Delete this block",
                              systemImage: "trash")
                    }
                } footer: {
                    Text("Deleting removes the recorded time — use it to trim a timer you forgot to stop.")
                        .font(Theme.metricCaption)
                }
            }
            .navigationTitle("Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
