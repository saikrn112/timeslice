import SwiftUI
import TimesliceCore

struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine
    @ObservedObject var privacy: PrivacyController
    @ObservedObject var settings: Settings

    // Screenshot mode can open straight to the Metrics tab (TIMESLICE_DEMO_TAB=metrics).
    @State private var selectedTab: Tab =
        ProcessInfo.processInfo.environment["TIMESLICE_DEMO_TAB"] == "metrics" ? .metrics : .projects

    enum Tab: String, CaseIterable, Identifiable {
        case projects = "Tasks"
        case metrics = "Metrics"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch selectedTab {
            case .projects: ProjectListView(appState: appState, engine: engine)
            case .metrics: MetricsView(appState: appState, engine: engine, settings: settings)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { appState.reload() }
    }

    private var toolbar: some View {
        HStack {
            // Today / All-Time on the LEFT.
            if selectedTab == .projects {
                Picker("", selection: $appState.scope) {
                    ForEach(TimeScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Spacer()

            // Tasks / Metrics on the RIGHT.
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            settingsButton
            privacyIndicator
        }
        .padding(10)
    }

    @State private var showSettings = false

    private var settingsButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Settings")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsPanel(settings: settings)
        }
    }

    private var privacyIndicator: some View {
        Button {
            privacy.cycleLevel()
        } label: {
            Image(systemName: privacy.level == .full ? "eye" : "eye.slash.fill")
                .foregroundStyle(privacy.level == .full ? Color.secondary : Color.orange)
                .font(.system(size: 14))
        }
        .buttonStyle(.borderless)
        .help(privacy.level == .full
              ? "Privacy off — menu bar shows the task name. Click to hide it and disable the switcher for screen sharing."
              : "Privacy on — task name hidden and switcher disabled. Click to show it again. (Window & popover are always hidden from capture.)")
    }

    private var privacyLabel: String {
        switch privacy.level {
        case .full: return "showing task name + time"
        case .iconOnly: return "clock icon only"
        }
    }
}
