import AppIntents
import Foundation

/// Intents driven from buttons **inside** the Live Activity.
///
/// These live in `Shared/` because a `Button(intent:)` in the Dynamic Island needs the intent *type*
/// visible to the widget extension in order to render, while `perform()` only ever runs in the app's
/// process. `LiveActivityIntent` is what guarantees that split — iOS runs it in the owning app, which
/// is also why it can touch `TimerModel.shared` and the database at all.
///
/// These live in the APP target only. They were briefly in `Shared/`, compiled into the widget too so
/// `Button(intent:)` could render — but that shipped a second AppIntents metadata bundle declaring the
/// same intent identifiers without an `AppShortcutsProvider`, and shortcut resolution could bind to it
/// and fail with "Couldn't find AppShortcutsProvider", breaking the Action Button.
///
/// They're kept (Siri and Shortcuts can still run them) but no longer rendered as island buttons.

/// Pause the running task, or resume the current one, from the island.
struct ToggleFromActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Timeslice"
    static var description = IntentDescription("Pause or resume the current task.")
    /// Must stay false: the point of a button in the island is not opening the app.
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = TimerModel.shared
        model.load()
        model.toggleCurrent()
        return .result()
    }
}

/// Switch straight back to the previous task — the alt-tab case, without opening the app.
///
/// "Previous" is index 1 of the shared recency order, exactly as one press of the Mac's `\` lands on
/// the task you came from. Index 0 is the current task, which is pinned.
struct PreviousTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Switch to Previous Task"
    static var description = IntentDescription("Switch back to the task you were on before.")
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = TimerModel.shared
        model.load()
        if let previous = model.recencyOrdered.dropFirst().first {
            model.toggle(taskID: previous.id)
        }
        return .result()
    }
}
