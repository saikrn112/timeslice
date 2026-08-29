import SwiftUI

/// Tasks / Metrics / Budgets, mirroring the Mac's main-window tabs.
///
/// A `TabView` rather than the Mac's segmented header because a phone needs the switch reachable by
/// thumb, and because Metrics and Budgets are full screens here rather than sections of one window.
struct RootView: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var tab: Tab

    enum Tab: String { case tasks, metrics, budgets }

    init() {
        _tab = State(initialValue: Self.launchTab ?? .tasks)
    }

    /// Preselects a tab, so every screen can be screenshotted headlessly:
    ///
    /// ```
    /// xcrun simctl spawn booted defaults write com.timeslice.ios TimesliceStartTab -string budgets
    /// xcrun simctl launch booted com.timeslice.ios
    /// ```
    ///
    /// `simctl` can boot, install, launch and screenshot, but it cannot tap a tab bar — so without
    /// this, verifying Metrics or Budgets would need a human, which the plan asks to avoid.
    ///
    /// A preference rather than a launch argument or environment variable, because **neither reaches
    /// the app through `simctl launch`** on Xcode 26 — both were tried and logged: `--tab budgets`
    /// arrived as nothing (the process saw only its executable path), and `SIMCTL_CHILD_TIMESLICE_TAB`
    /// arrived as nil. A preference is set from outside the process entirely, so nothing can swallow
    /// it, and it can be changed between screenshots without reinstalling.
    ///
    /// An unrecognised value falls through to Tasks, so a stale preference can't break a real launch.
    private static var launchTab: Tab? {
        UserDefaults.standard.string(forKey: "TimesliceStartTab").flatMap(Tab.init(rawValue:))
    }

    var body: some View {
        TabView(selection: $tab) {
            TasksView()
                .tabItem { Label("Tasks", systemImage: "list.bullet") }
                .tag(Tab.tasks)
            MetricsScreen()
                .tabItem { Label("Metrics", systemImage: "chart.bar") }
                .tag(Tab.metrics)
            BudgetsScreen()
                .tabItem { Label("Budgets", systemImage: "target") }
                .tag(Tab.budgets)
        }
        .onAppear { model.load() }
    }
}
