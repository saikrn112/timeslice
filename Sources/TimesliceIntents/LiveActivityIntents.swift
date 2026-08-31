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

#endif
