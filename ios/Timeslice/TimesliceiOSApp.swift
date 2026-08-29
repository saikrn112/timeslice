import SwiftUI

@main
struct TimesliceiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // Registers the actionable category and asks for permission once, rather than at the
                // moment a nudge is due — which would show the prompt instead of the nudge.
                .task { NudgeScheduler.shared.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-read on foreground rather than keeping a ticking clock alive: elapsed time is
            // derived from the running interval's persisted start, so however long the app was
            // suspended, one reload recovers the correct state.
            if phase == .active { TimerModel.shared.load() }
        }
    }
}
