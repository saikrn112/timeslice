import AppKit
import Combine

/// How much Timeslice reveals while the screen is being shared or recorded.
enum PrivacyLevel: Int, CaseIterable {
    case full       // menu bar shows task name + time; windows render to a capture
    case iconOnly   // menu bar shows the clock icon only; windows blank out on a capture

    var next: PrivacyLevel {
        PrivacyLevel(rawValue: (rawValue + 1) % PrivacyLevel.allCases.count) ?? .full
    }
}

/// Owns screen-share privacy. One switch — `level` — governs everything visible:
///
/// - `.full`     → menu bar shows the task name + time, windows have `sharingType = .readOnly`
///                 (they appear in a share like any normal window).
/// - `.iconOnly` → menu bar shows only the clock icon, windows have `sharingType = .none`
///                 (they render locally but come out blank in any capture, including full-screen),
///                 and the switcher HUD is suppressed.
///
/// The timer keeps running regardless: privacy only affects presentation, never the write path.
@MainActor
final class PrivacyController: ObservableObject {
    /// The single source of truth for how much is revealed.
    @Published var level: PrivacyLevel = .full {
        didSet { if oldValue != level { applyToAll() } }
    }

    /// Demo/screenshot mode: keep windows capturable even at `.iconOnly` so `screencapture`
    /// can actually record them.
    private var forceWindowsCapturable = false

    /// Windows we manage; kept weakly so closing them doesn't leak.
    private var managed: [Weak] = []

    private final class Weak { weak var window: NSWindow?; init(_ w: NSWindow?) { window = w } }

    /// Whether managed windows should be hidden from captures right now.
    private var hidesWindowsFromCapture: Bool {
        !forceWindowsCapturable && level == .iconOnly
    }

    /// Register a window to have its sharing type managed, and apply the current setting.
    func manage(_ window: NSWindow?) {
        guard let window else { return }
        managed.append(Weak(window))
        applySharing(to: window)
    }

    func applySharing(to window: NSWindow?) {
        guard let window else { return }
        window.sharingType = hidesWindowsFromCapture ? .none : .readOnly
    }

    private func applyToAll() {
        managed.removeAll { $0.window == nil }
        for entry in managed { applySharing(to: entry.window) }
    }

    /// Cycle privacy (bound to fn+⌘+⇧+P and the window's eye button).
    func cycleLevel() {
        level = level.next
    }

    /// Screenshot/demo mode only: let captures see the windows regardless of level.
    func setWindowsAlwaysCapturable(_ enabled: Bool) {
        forceWindowsCapturable = enabled
        applyToAll()
    }

    // No auto-detection of screen sharing. macOS has no public API for "am I being
    // captured?" — `CGDisplayIsCaptured` covers exclusive fullscreen display capture, not
    // sharing, and ScreenCaptureKit only reports captures *this* app starts. Guessing from
    // running apps doesn't work either: Zoom/Slack/QuickTime sit running all day without a
    // share active, and Google Meet is just a browser tab with no distinct process. That
    // would pin privacy on permanently, which is worse than an honest manual toggle.
}
