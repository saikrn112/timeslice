import AppKit
import Combine

/// How much the menu-bar item reveals while sharing/recording the screen.
enum PrivacyLevel: Int, CaseIterable {
    case full       // task name + time (ms) + clock icon
    case iconOnly   // clock icon only, no time/name

    var next: PrivacyLevel {
        PrivacyLevel(rawValue: (rawValue + 1) % PrivacyLevel.allCases.count) ?? .full
    }
}

/// Owns screen-share privacy: the menu-bar redaction level and window capture exclusion.
///
/// - The detailed windows (main + popover) are set to `sharingType = .none`, so they render
///   normally to the local display but appear blank to any capture/share, including full-screen.
/// - The menu-bar item is system-owned and cannot be excluded via `sharingType`, so instead we
///   change *what it displays* via `level`, cycled with a global hotkey.
///
/// The timer keeps running regardless: privacy only affects presentation, never the write path.
@MainActor
final class PrivacyController: ObservableObject {
    /// When true, capture-excluded windows blank out on a shared/recorded screen.
    @Published var excludeWindowsFromCapture: Bool = true
    /// Current menu-bar redaction level.
    @Published var level: PrivacyLevel = .full

    /// Windows we manage; kept weakly so closing them doesn't leak.
    private var managed: [Weak] = []

    private final class Weak { weak var window: NSWindow?; init(_ w: NSWindow?) { window = w } }

    /// Register a window to have its sharing type managed, and apply the current setting.
    func manage(_ window: NSWindow?) {
        guard let window else { return }
        managed.append(Weak(window))
        applySharing(to: window)
    }

    func applySharing(to window: NSWindow?) {
        guard let window else { return }
        window.sharingType = excludeWindowsFromCapture ? .none : .readOnly
    }

    private func applyToAll() {
        managed.removeAll { $0.window == nil }
        for entry in managed { applySharing(to: entry.window) }
    }

    /// Cycle the menu-bar redaction level (bound to fn+⌘+⇧+P).
    func cycleLevel() {
        level = level.next
    }

    func setWindowExclusion(_ enabled: Bool) {
        excludeWindowsFromCapture = enabled
        applyToAll()
    }
}
