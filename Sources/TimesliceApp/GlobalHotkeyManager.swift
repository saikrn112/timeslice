import AppKit
import Carbon.HIToolbox
import ApplicationServices
import TimesliceCore

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
    /// Rate limit for the incomplete-chord log line.
    private var lastChordMiss = Date.distantPast

    /// Diagnostics go to a FILE beside the database, not `NSLog`.
    ///
    /// Learned the hard way: nothing this app writes with `NSLog` reaches the unified log — `log show`
    /// finds zero mentions of the process at any level, including at launch — so the one question that
    /// mattered ("is the tap even receiving the key?") was unanswerable from outside. A file always works
    /// and can be read while the app keeps running.
    private static let logURL = TimeslicePaths.defaultSupportDirectoryURL()
        .appendingPathComponent("hotkeys.log")

    private static var lastDenialNote = Date.distantPast

    private static func note(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
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
        guard hasAccessibilityPermission(prompt: false) else {
            // Rate-limited: the two-second poll calls this forever while permission is missing, and an
            // unbounded line per poll turns a diagnostic into a growing file.
            if Date().timeIntervalSince(Self.lastDenialNote) > 60 {
                Self.lastDenialNote = Date()
                Self.note("not registering — Accessibility not granted to THIS process; "
                          + "a grant added after launch needs a relaunch")
            }
            return false
        }

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
            Self.note("tapCreate FAILED despite Accessibility being granted")
            return false
        }

        Self.note("event tap installed"
                  + (Self.secureInputBlocking
                     ? " — but macOS Secure Input is ON, so NO key events will be delivered to it"
                     : ""))
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

    /// The prefix, as fn+⌘+⇧.
    ///
    /// Briefly remapped to ⌃+⌘+⇧ while chasing a dead switcher; fn was innocent. macOS **Secure Input**
    /// had got stuck on (`kCGSSessionSecureInputPID` non-zero, attributed to `loginwindow`), and while
    /// that is active the system delivers no key events to ANY event tap — so the tap was created,
    /// enabled and permitted, and its callback never fired once. A restart cleared it. See
    /// `secureInputBlocking` below, which now says so instead of leaving it to be rediscovered.
    ///
    /// Defined once in both vocabularies, because the tap tests `CGEventFlags` while the release poll
    /// reads `NSEvent.modifierFlags`, and the two drifting apart would mean a chord that activates and
    /// never commits. They were written out separately before.
    private func chordHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskShift) && flags.contains(.maskSecondaryFn)
    }

    private func chordHeld(_ mods: NSEvent.ModifierFlags) -> Bool {
        mods.contains(.command) && mods.contains(.shift) && mods.contains(.function)
    }

    /// True when macOS Secure Input is on, which silently stops every event tap from receiving keys.
    ///
    /// `IsSecureEventInputEnabled()` is the cheap public answer (Carbon, already imported here for the
    /// key codes). Worth checking precisely because nothing else reveals it: permission, tap creation and
    /// `CGGetEventTapList` all look perfect while no keystroke ever arrives.
    static var secureInputBlocking: Bool { IsSecureEventInputEnabled() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            // The one thing that was impossible to see from outside: the tap IS receiving the key and
            // the chord test is what rejects it. Logged only for the switcher's own keys and only when
            // some modifier is held, so ordinary typing stays silent, and rate-limited so leaning on a
            // key can't fill the log.
            if keyCode == backslash || keyCode == rightBracket, !chordHeld(flags),
               flags.contains(.maskCommand) || flags.contains(.maskShift)
                || flags.contains(.maskSecondaryFn) {
                let now = Date()
                if now.timeIntervalSince(lastChordMiss) > 2 {
                    lastChordMiss = now
                    Self.note("switcher key \(keyCode) with an incomplete chord — "
                              + "cmd=\(flags.contains(.maskCommand)) shift=\(flags.contains(.maskShift)) "
                              + "fn=\(flags.contains(.maskSecondaryFn)) raw=0x"
                              + String(flags.rawValue, radix: 16))
                }
            }

            if chordHeld(flags) {
                Self.note("chord held, key \(keyCode)")
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
                if !self.chordHeld(NSEvent.modifierFlags) {
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
