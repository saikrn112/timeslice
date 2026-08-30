import AppIntents
import Foundation

/// What the Action Button runs.
///
/// **The Action Button cannot be claimed programmatically.** There is no API for it. Shipping an
/// `AppIntent` plus the `AppShortcutsProvider` below is the whole of what an app can do; the user
/// then assigns it in Settings → Action Button → Shortcut. That manual step is unavoidable and
/// belongs in the README next to the Mac's Accessibility grant.
struct ToggleTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Timeslice Timer"
    static var description = IntentDescription(
        "Start or pause the current Timeslice task and show it in the Dynamic Island.")

    /// Opens the app rather than running silently, for a concrete reason: iOS refuses
    /// `Activity.request` from the background (it throws `.visibility`), so a background-only intent
    /// could toggle the timer but often fail to *show* the island — which is the point of the
    /// feature. Foregrounding guarantees the Dynamic Island appears.
    /// Computed, not a stored `static var`. Both compile, but a computed property is the form Apple
    /// documents and the one the metadata extractor is guaranteed to read — worth removing as a
    /// variable while the Action Button is still failing.
    static var openAppWhenRun: Bool { true }

    /// Returns a plain result, not `ProvidesDialog`.
    ///
    /// An intent that both foregrounds the app AND returns a dialog is an odd pairing: the app is
    /// about to be on screen showing exactly the state the dialog would announce. Keeping the return
    /// type minimal removes another variable from the diagnosis.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = TimerModel.shared
        model.load()
        model.toggleCurrent()
        return .result()
    }
}

/// Stops tracking entirely, as opposed to pausing. Offered so a Shortcut or Siri can end a session
/// without opening the app — this one is safe in the background because ending an activity, unlike
/// starting one, has no visibility restriction.
struct StopTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Timeslice Timer"
    static var description = IntentDescription("Stop tracking and dismiss the Dynamic Island.")
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = TimerModel.shared
        model.load()
        model.stop()
        return .result(dialog: IntentDialog("Stopped"))
    }
}

/// Makes the intents discoverable in Shortcuts (and therefore assignable to the Action Button)
/// without the user building a shortcut by hand.
///
/// Named `ShortcutsCatalog`, deliberately NOT `TimesliceShortcuts`. A type whose name repeats the
/// module name mangles with a word-substitution back-reference — `9Timeslice0A9ShortcutsV` — where
/// `0A` points back at the module. A name that doesn't repeat it mangles plainly
/// (`9Timeslice16ShortcutsCatalogV`), removing any dependence on the consumer resolving that
/// back-reference when it looks the provider up at runtime.
struct ShortcutsCatalog: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleTimerIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "Start \(.applicationName)",
                "Pause \(.applicationName)",
            ],
            shortTitle: "Toggle Timer",
            systemImageName: "timer")
        AppShortcut(
            intent: OpenSwitcherIntent(),
            phrases: [
                "Switch \(.applicationName)",
                "Switch task in \(.applicationName)",
            ],
            shortTitle: "Switch Task",
            systemImageName: "arrow.triangle.swap")
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop Timer",
            systemImageName: "stop.circle")
    }
}
