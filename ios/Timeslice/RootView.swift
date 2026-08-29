import SwiftUI

/// Tasks / Metrics / Budgets, mirroring the Mac's main-window tabs.
///
/// A `TabView` rather than the Mac's segmented header because a phone needs the switch reachable by
/// thumb, and because Metrics and Budgets are full screens here rather than sections of one window.
struct RootView: View {
    @ObservedObject private var model = TimerModel.shared

    var body: some View {
        TabView {
            TasksView()
                .tabItem { Label("Tasks", systemImage: "list.bullet") }
            MetricsScreen()
                .tabItem { Label("Metrics", systemImage: "chart.bar") }
            BudgetsScreen()
                .tabItem { Label("Budgets", systemImage: "target") }
        }
        .onAppear { model.load() }
    }
}
