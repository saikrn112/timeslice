import SwiftUI

@main
struct TimesliceiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-read on foreground rather than keeping a ticking clock alive: elapsed time is
            // derived from the running interval's persisted start, so however long the app was
            // suspended, one reload recovers the correct state.
            if phase == .active { TimerModel.shared.load() }
        }
    }
}
