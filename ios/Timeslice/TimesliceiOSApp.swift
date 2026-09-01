import AppIntents
import SwiftUI
import TimesliceIntents

@main
struct TimesliceiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // Registers the actionable category and asks for permission once, rather than at the
                // moment a nudge is due — which would show the prompt instead of the nudge.
                .task {
                    NudgeScheduler.shared.start()
                    // Registration must happen before the app finishes launching, or the system
                    // refuses the identifier.
                    SyncController.shared.registerBackgroundTask()
                    SyncController.shared.scheduleNextRefresh()
                    // Re-wires the Drive transport when a refresh token is already in the Keychain,
                    // so sync resumes without another sign-in.
                    GoogleAuthiOS.shared.restoreIfPossible()
                    // Hands the shared Live Activity intents their behaviour. Without this the
                    // Lock Screen and island buttons render but do nothing.
                    TimerActionRegistry.register(TimerModel.shared)

                    // Tells the system about our App Shortcuts, and — just as importantly — is the
                    // only place in the app that REFERENCES `ShortcutsCatalog` at all.
                    //
                    // Without a reference, nothing guarantees the provider type is linked into the
                    // binary, while the build-time metadata extractor still records its mangled name.
                    // The system then finds the phrases but not the type, and running a shortcut fails
                    // with `LNActionForAutoShortcutPhraseFetchError Code=1 "Couldn't find
                    // AppShortcutsProvider."` — which is exactly the error observed.
                    ShortcutsCatalog.updateAppShortcutParameters()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-read on foreground rather than keeping a ticking clock alive: elapsed time is
            // derived from the running interval's persisted start, so however long the app was
            // suspended, one reload recovers the correct state.
            if phase == .active {
                TimerModel.shared.load()
                // Catch up any focus-length boundaries crossed while suspended.
                TimerModel.shared.rollChunks()
                // Foreground is the one moment a phone can sync promptly, so take it — the
                // background task is opportunistic and may not have run for hours.
                Task { await SyncController.shared.syncOnce() }
            }
        }
    }
}
