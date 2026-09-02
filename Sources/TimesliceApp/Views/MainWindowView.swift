import SwiftUI
import TimesliceCore

struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engine: TimerEngine
    @ObservedObject var privacy: PrivacyController
    @ObservedObject var settings: Settings
    var sync: SyncController? = nil
    var auth: GoogleAuth? = nil

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

    /// One low-chrome row: icon+label view tabs, an inline text scope toggle, utilities far right.
    /// Segmented pickers stacked in two rows were too heavy for four small controls.
    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                tabButton(.projects, icon: "checklist")
                tabButton(.metrics, icon: "chart.bar.xaxis")
            }

            if selectedTab == .projects {
                Divider().frame(height: 14)
                scopeToggle
            }

            Spacer()

            notesButton
            settingsButton
            privacyIndicator
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func tabButton(_ tab: Tab, icon: String) -> some View {
        let selected = selectedTab == tab
        return Button { selectedTab = tab } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(tab.rawValue).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.secondary.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Plain text toggle — reads as a choice, not another control block.
    private var scopeToggle: some View {
        HStack(spacing: 6) {
            ForEach(Array(TimeScope.allCases.enumerated()), id: \.element.id) { idx, scope in
                if idx > 0 { Text("·").font(.system(size: 11)).foregroundStyle(.tertiary) }
                Button { appState.scope = scope } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 12, weight: appState.scope == scope ? .semibold : .regular))
                        .foregroundStyle(appState.scope == scope ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @State private var showSettings = false
    @State private var openNoteCount = 0

    /// Feedback lives up here rather than inside Settings: it's written whenever something is
    /// noticed, which is while using the app, and a thing you reach for often shouldn't be two
    /// clicks deep in a panel of preferences.
    private var notesButton: some View {
        Button { NotificationCenter.default.post(name: .openFeedbackWindow, object: nil) } label: {
            // Outline and secondary, like the gear and the eye beside it. A filled accent bubble
            // read as a live alert rather than as a third utility button — the open count belongs
            // in the tooltip, not in the chrome.
            Image(systemName: "bubble.left")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(openNoteCount > 0 ? "Feedback — \(openNoteCount) open" : "Feedback")
        .onAppear { refreshNoteCount() }
        // Opens a WINDOW, not a popover or a sheet. Both close as soon as you click the thing the
        // note is about, which is exactly when you need the list — see `FeedbackWindowController`.
        // The count refreshes on the store's own change notification, since the window can add
        // notes while this toolbar is untouched.
        // A window can add notes while this toolbar is untouched, so the count follows the store's
        // own change notification instead of a reload on open.
        .onReceive(NotificationCenter.default.publisher(for: TimesliceNotifications.dataDidChange)) { _ in
            refreshNoteCount()
        }
    }

    private func refreshNoteCount() {
        openNoteCount =
            ((try? appState.storeForEditing.listFeedback(includeResolved: false)) ?? []).count
    }

    private var settingsButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Settings")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsPanel(settings: settings, store: appState.storeForEditing,
                          sync: sync, auth: auth)
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
        .help(privacyHelp)
    }

    private var privacyHelp: String {
        switch privacy.level {
        case .full:
            return "Privacy off — the menu bar shows your task name and these windows appear "
                 + "in a screen share. Click to hide everything (Fn + ⌘ + ⇧ + P)."
        case .iconOnly:
            return "Privacy on — task name hidden and windows blank out in a screen share. The "
                 + "switcher and palette still work; they're excluded from capture too. "
                 + "Click to reveal again (Fn + ⌘ + ⇧ + P)."
        }
    }
}
