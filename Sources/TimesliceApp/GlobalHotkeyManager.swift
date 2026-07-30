import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// System-wide hotkeys via a `CGEventTap`. The tap observes the `fn` (globe) modifier, consumes
/// keystrokes, and detects modifier *release* — all needed for the ⌘-Tab-style task switcher.
/// This requires Accessibility permission (granted once in System Settings › Privacy & Security ›
/// Accessibility). Carbon is imported only for its `kVK_*` key-code constants.
///
/// Interaction (all use the chord fn+⌘+⇧):
///   • Hold fn+⌘+⇧ and tap `\` (forward) or `]` (reverse) → cycle the selected task (a HUD shows
///     the current one). Release the modifiers → commit: pause the previously-running task and
///     start the selected one. If you release without moving off the running task, it pauses.
///   • fn+⌘+⇧+P → cycle menu-bar privacy level.
@MainActor
final class GlobalHotkeyManager {
    /// Called each time `\`/`]` is tapped while the switcher chord is held. `delta` is +1 for
    /// forward (`\`) or -1 for reverse (`]`).
    var onCycle: ((Int) -> Void)?
    /// Called when the chord is released after the switcher was active (commit + start/stop).
    var onCommit: (() -> Void)?
    /// Called when the switcher first activates (so the HUD can show the current selection).
    var onActivate: (() -> Void)?
    /// Called on fn+⌘+⇧+P.
    var onPrivacy: (() -> Void)?
    /// Called on fn+⌘+⇧+A (quick-add a task and start it).
    var onQuickAdd: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var switcherActive = false
    /// Polls actual hardware modifier state to detect chord release — far more reliable than
    /// depending on flagsChanged delivery (the fn/globe key in particular is inconsistent).
    private var releasePoll: Timer?

    private let backslash = CGKeyCode(kVK_ANSI_Backslash)      // \ → forward
    private let rightBracket = CGKeyCode(kVK_ANSI_RightBracket) // ] → reverse
    private let aKey = CGKeyCode(kVK_ANSI_A)                    // A → quick-add
    private let pKey = CGKeyCode(kVK_ANSI_P)

    /// True once the event tap is installed (i.e. permission granted and tap created).
    private(set) var isActive = false

    // MARK: - Permission

    /// Whether Accessibility permission is granted. If `prompt`, shows the system prompt.
    @discardableResult
    func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Lifecycle

    /// Install the event tap. Returns false if Accessibility permission isn't granted yet.
    @discardableResult
    func register() -> Bool {
        guard hasAccessibilityPermission(prompt: false) else { return false }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // .defaultTap can consume events
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { manager.handle(type: type, event: event) }
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    func unregister() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    // MARK: - Event handling (runs on the main thread via the tap)

    private func chordHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskShift) && flags.contains(.maskSecondaryFn)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            if chordHeld(flags) {
                if keyCode == backslash || keyCode == rightBracket {
                    let delta = keyCode == backslash ? 1 : -1
                    if !switcherActive {
                        // First press: just SHOW the current task. Releasing now pauses it,
                        // rather than jumping to (and starting) the next task.
                        switcherActive = true
                        onActivate?()
                        startReleasePolling()
                    } else {
                        // Subsequent presses: move the selection (forward for \, reverse for ]).
                        onCycle?(delta)
                    }
                    return nil   // consume so the key isn't typed into the focused app
                }
                if keyCode == pKey {
                    onPrivacy?()
                    return nil
                }
                if keyCode == aKey {
                    onQuickAdd?()
                    return nil
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Poll hardware modifier flags ~20x/sec; when the fn+⌘+⇧ chord is no longer held, commit.
    private func startReleasePolling() {
        releasePoll?.invalidate()
        releasePoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let mods = NSEvent.modifierFlags
                let held = mods.contains(.command) && mods.contains(.shift) && mods.contains(.function)
                if !held {
                    timer.invalidate()
                    self.releasePoll = nil
                    if self.switcherActive {
                        self.switcherActive = false
                        self.onCommit?()
                    }
                }
            }
        }
    }

    deinit {
        // Tap teardown is main-thread affine; process-lifetime anyway.
    }
}
