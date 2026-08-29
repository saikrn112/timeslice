import SwiftUI
import TimesliceCore

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

    /// `start-tab` containing `switcher` opens the wheel on launch, so it can be screenshotted —
    /// the wheel is otherwise only reachable by an Action Button press or a tap, neither of which
    /// simctl can perform.
    private static var launchesSwitcher: Bool {
        let url = TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("start-tab")
        let raw = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw == "switcher"
    }

    /// Preselects a tab, so every screen can be screenshotted headlessly:
    ///
    /// ```bash
    /// C=$(xcrun simctl get_app_container booted com.timeslice.ios data)   # AFTER installing
    /// echo -n budgets > "$C/Library/Application Support/Timeslice/start-tab"
    /// xcrun simctl terminate booted com.timeslice.ios
    /// xcrun simctl launch booted com.timeslice.ios
    /// ```
    ///
    /// `simctl` can boot, install, launch and screenshot, but it cannot tap a tab bar — so without
    /// this, verifying Metrics or Budgets would need a human, which the plan asks to avoid.
    ///
    /// A plain FILE, after three other mechanisms silently failed on Xcode 26 (each doing nothing
    /// rather than erroring, which is what made this worth documenting):
    ///
    /// | Attempt | What actually happened |
    /// |---|---|
    /// | `simctl launch … --tab budgets` | swallowed by simctl; the process saw only its own path |
    /// | `SIMCTL_CHILD_TIMESLICE_TAB=…` | arrived as nil |
    /// | `defaults write` into the container plist | `cfprefsd` caches prefs, so the app never saw it |
    ///
    /// A file read at launch is cached by nothing. It sits beside the database, the same place
    /// `TimeslicePaths` already keeps `device-id`. Absent or unrecognised falls through to Tasks, so
    /// this cannot affect a real install.
    private static var launchTab: Tab? {
        let url = TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("start-tab")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Tab(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
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
        .onAppear {
            model.load()
            if Self.launchesSwitcher { model.requestSwitcher() }
        }
        // Presented from the root so the Action Button's switcher binding works whichever tab was
        // last open.
        .sheet(isPresented: $model.showingSwitcher) { SwitchWheelSheet() }
    }
}
