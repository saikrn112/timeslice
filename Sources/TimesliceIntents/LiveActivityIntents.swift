import AppIntents
import Foundation

/// Intents driven from buttons **inside** a Live Activity — the Lock Screen card and the expanded
/// Dynamic Island.
///
/// ## Why these live in a shared library
///
/// `Button(intent:)` needs the intent *type* visible to the widget extension in order to render, while
/// `perform()` only ever runs in the app's process (that's what `LiveActivityIntent` guarantees). The
/// obvious shortcut — compiling one source file into both targets — ships **two** AppIntents metadata
/// bundles declaring the same intent identifiers, and provider resolution can bind to the wrong one.
///
/// So the types live here, in a target both the app and the extension *link*: one type, one
/// registration, one metadata contribution. This is what Apple's own guidance recommends — "consider
/// placing its code in a Swift package or library that you share between your app and app extension".
///
/// ## Why the behaviour is injected
///
/// This target cannot reach `TimerModel` — the app owns it, and dragging the app's store into an
/// extension process is what `0xdead10cc` punishes. So the intent calls a handler the app registers at
/// launch. In the widget process the handler is simply nil, which is harmless because the widget never
/// executes `perform()`.
@MainActor
public protocol TimerActions: AnyObject {
    /// Pause the running task, or resume the current one.
    func toggleCurrent()
    /// Switch to the task worked before this one — the alt-tab case.
    func switchToPrevious()
    /// Start the task with this **uid**.
    ///
    /// A uid, never a row id: the island's buttons are built from a payload that can outlive a sync,
    /// and `subject_id = 8` is a different task on another machine. Resolving here also means an
    /// unknown uid is a no-op rather than starting the wrong timer.
    func switchTo(uid: String)
}

/// Where the app hands its behaviour to the shared intents.
@MainActor
public enum TimerActionRegistry {
    public private(set) static weak var handler: TimerActions?

    /// Called once by the app at launch. Weak, so registering cannot keep a torn-down model alive.
    public static func register(_ handler: TimerActions) {
        self.handler = handler
    }
}

// `LiveActivityIntent` does not exist on macOS — Live Activities are an iOS feature. The registry
// above stays cross-platform so the Mac can link this target without caring; only the intents
// themselves are gated.
#if os(iOS)

/// Pause the running task, or resume the current one, from a Live Activity.
public struct ToggleFromActivityIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Pause or Resume Timeslice"
    public static var description = IntentDescription("Pause or resume the current task.")
    /// Must stay false: the point of a button on the Lock Screen is not opening the app.
    public static var openAppWhenRun: Bool { false }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TimerActionRegistry.handler?.toggleCurrent()
        return .result()
    }
}

/// Switch straight back to the previous task, without opening the app.
///
/// "Previous" is index 1 of the shared recency order, exactly as one press of the Mac's `\` lands on
/// the task you came from. Index 0 is the current task, which is pinned.
public struct PreviousTaskIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Switch to Previous Task"
    public static var description = IntentDescription("Switch back to the task you were on before.")
    public static var openAppWhenRun: Bool { false }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        TimerActionRegistry.handler?.switchToPrevious()
        return .result()
    }
}

/// Start a specific task from the island's switcher row.
///
/// This is the "switcher in the island" case: the expanded Dynamic Island shows the last few tasks as
/// buttons, so a switch costs one press without ever opening the app. A slider or a drag control — the
/// flashlight-style interaction — is not available to a third-party Live Activity; intent-backed
/// buttons are the whole vocabulary, so the switcher is expressed as a row of them.
///
/// The uid travels as an `@Parameter` because a `Button(intent:)` in a widget serialises the intent and
/// its parameters into the tap; nothing of the widget's own memory survives to `perform()`, which runs
/// in the app.
public struct SwitchToTaskIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Switch Timeslice Task"
    public static var description = IntentDescription("Start tracking a specific task.")
    public static var openAppWhenRun: Bool { false }

    /// The task's uid. A string, so it stays valid across devices and across a re-sync.
    @Parameter(title: "Task")
    public var taskUID: String

    public init() {}

    public init(taskUID: String) {
        self.taskUID = taskUID
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        TimerActionRegistry.handler?.switchTo(uid: taskUID)
        return .result()
    }
}

#endif
