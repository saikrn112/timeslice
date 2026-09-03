import SwiftUI
import TimesliceCore
import TimesliceUI

/// **Four** tabs — Tasks, Metrics, Feedback, Settings.
///
/// Settings and Feedback used to be sheets behind a gear, mirroring the Mac's gear popover. That
/// mirroring was the mistake: a Mac popover sits under a pointer that's already at the top of the
/// screen, whereas on a phone the top-right corner is the hardest place to reach one-handed. Both were
/// reported as too hard to get to, and Feedback especially — the whole point of a note is catching a
/// thought before it evaporates, which a two-tap detour through Settings defeats.
///
/// Budgets is still a *section inside Metrics*, not a tab. On the Mac a budget is one block of the
/// metrics page, read alongside the tiles and the breakdown it derives from; promoting it to a peer of
/// Metrics would imply it were a separate subject.
struct RootView: View {
    @ObservedObject private var model = TimerModel.shared
    @State private var tab: Tab

    enum Tab: String { case tasks, metrics, feedback, settings }

    init() {
        _tab = State(initialValue: Self.launchTab ?? .tasks)
    }

    /// Preselects a tab, so every screen can be screenshotted headlessly:
    ///
    /// ```bash
    /// xcrun simctl install booted "$APP"                                  # install FIRST
    /// C=$(xcrun simctl get_app_container booted com.timeslice.ios data)   # UUID changes on install
    /// printf metrics > "$C/Library/Application Support/Timeslice/start-tab"
    /// xcrun simctl terminate booted com.timeslice.ios && xcrun simctl launch booted com.timeslice.ios
    /// ```
    ///
    /// A plain FILE, after four other mechanisms silently failed on Xcode 26 — launch arguments
    /// (swallowed by simctl), `SIMCTL_CHILD_*` (arrives nil), a global-domain `defaults write` (wrong
    /// domain), and a container plist write (`cfprefsd` caches it). Each did nothing rather than
    /// erroring. `switcher` and `settings` additionally open those sheets, which are otherwise only
    /// reachable by a tap simctl cannot perform.
    private static var launchHint: String? {
        let url = TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("start-tab")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var launchTab: Tab? { launchHint.flatMap(Tab.init(rawValue:)) }

    var body: some View {
        TabView(selection: $tab) {
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(Tab.tasks)
            MetricsScreen()
                .tabItem { Label("Metrics", systemImage: "chart.bar.xaxis") }
                .tag(Tab.metrics)
            FeedbackScreen()
                .tabItem { Label("Feedback", systemImage: "note.text") }
                .tag(Tab.feedback)
                // Open notes as a tab badge: a note you haven't dealt with should be visible without
                // opening the tab, which is the only thing that makes jotting one feel worthwhile.
                .badge(model.openFeedbackCount)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear {
            model.load()
            // Also applied HERE, not just as the @State initial value: SwiftUI restores a TabView's
            // previous selection across launches, which silently overrode the init value and made
            // the launch hint look broken.
            if let hinted = Self.launchTab { tab = hinted }
            switch Self.launchHint {
            case "switcher": model.requestSwitcher()
            case "add": model.showingAddTask = true
            case "diagnostics": tab = .settings; model.showingDiagnostics = true   // focuses the Tasks search field
            default: break
            }
        }
        // Both presented from the root so the Action Button's switcher binding works whichever tab
        // was last open, and so Settings is reachable from either.
        .sheet(isPresented: $model.showingSwitcher) { SwitchWheelSheet() }
        .sheet(isPresented: $model.showingSettings) { SettingsScreen(showsDone: true) }
        .sheet(isPresented: $model.showingDiagnostics) { DiagnosticsSheet() }
    }
}
