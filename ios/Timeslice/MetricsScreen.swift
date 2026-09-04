import SwiftUI
import TimesliceCore
import TimesliceUI

/// Metrics as a DASHBOARD: three cards, one figure each, plenty of space.
///
/// ## Three attempts got this wrong before
///
/// 1. The Mac's ten sections, shrunk — density kept, mechanism lost.
/// 2. A summary of five sections behind taps — hid the very thing the Mac's ethos is built on.
/// 3. The day as a vertical list of labelled blocks — concept rejected outright.
///
/// The reference that settled it was Whoop, and its discipline is not the chart types: it's **few things, one
/// dominant number each, and a lot of empty space.** Every earlier version arranged nine tidy things where there
/// should have been three loud ones. A 64pt figure with one thin gauge says more at a glance than six 13pt tiles.
///
/// So: **Tracked** (today against a typical recent day), **Allocations** (how many on track, one bar each),
/// **This week** (seven bars with the average as the line). That's the screen.
///
/// No Day/Week/Month switcher. The dashboard is always about one day, and the week card supplies the context a
/// range picker used to — one fewer control, and the week is visible rather than being a mode you switch into.
/// Swipe or tap a week bar to change day.
///
/// Deliberately absent, recorded in `docs/ios_metrics_design.md`: 6M/Y/All, the hours-per-bucket chart, the
/// weekday pattern, multi-select allocations with union/intersection overlays.
struct MetricsScreen: View {
    @ObservedObject private var model = TimerModel.shared
    @StateObject private var metrics = MetricsModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.dashCardSpacing) {
                    // Tapping it opens "where time went" — a list, which is a poor fit for a card but the
                    // obvious next question after seeing the total.
                    NavigationLink { BreakdownDetail(metrics: metrics) } label: {
                        TrackedCard(seconds: metrics.data.summary.totalSeconds,
                                    focusRatio: metrics.data.summary.focusRatio,
                                    typical: metrics.data.typicalDay,
                                    label: metrics.range.label())
                    }
                    .buttonStyle(.plain)

                    AllocationsCard(rows: metrics.data.budgets) { row in
                        metrics.toggleFilter(row.progress.target.subject, name: row.progress.name)
                    }

                    WeekCard(digests: metrics.data.weekDays,
                             selected: metrics.range.start) { day in
                        metrics.selectDay(day)
                        Haptics.switched()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                // Swipe to change day. Safe alongside vertical scrolling: `swipeDelta` vetoes anything
                // predominantly vertical.
                .gesture(daySwipe())
            }
            .background(Theme.page)
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if metrics.filter != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        // A filter with no visible exit is how you read a small number and conclude you did
                        // nothing all day.
                        Button { metrics.toggleFilter(nil, name: nil) } label: {
                            Label(metrics.filterName ?? "Filtered",
                                  systemImage: "line.3.horizontal.decrease.circle.fill")
                                .font(Theme.dashCaption)
                        }
                    }
                } else if !metrics.range.isCurrent() {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Today") { metrics.selectDay(Date()) }
                            .font(Theme.dashCaption)
                    }
                }
            }
            .refreshable {
                await SyncController.shared.syncOnce()
                model.load()
                metrics.rebuild()
            }
            .onAppear {
                // `load()` first, and here rather than relying on the root: a tab child's `onAppear` runs in an
                // unspecified order relative to its parent, so building against an empty task list rendered
                // every name as "(deleted task)" after a fresh install.
                model.load()
                metrics.rebuild()
            }
            .onChange(of: model.tasks) { _, _ in metrics.rebuild() }
            .onChange(of: model.groups) { _, _ in metrics.rebuild() }
            .onChange(of: model.running?.projectID) { _, _ in metrics.rebuild() }
        }
    }

    private func daySwipe() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard let delta = DateRange.swipeDelta(dx: value.translation.width,
                                                       dy: value.translation.height) else { return }
                if metrics.step(delta) { Haptics.switched() }
            }
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
