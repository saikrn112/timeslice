import Foundation
import TimesliceCore

/// Populates the store with realistic-looking data for screenshots. Activated by launching with
/// `TIMESLICE_SEED_DEMO=1` (which also uses a separate demo DB so it never touches real data).
enum DemoData {
    /// `TIMESLICE_SCREENSHOT=1` additionally suppresses anything modal that would cover the
    /// window being captured. Plain demo mode keeps every prompt, so the global hotkeys stay
    /// testable against demo data.
    static var isScreenshotRun: Bool {
        ProcessInfo.processInfo.environment["TIMESLICE_SCREENSHOT"] == "1"
    }

    /// A sandbox instance (two-device sync testing) should never nag for Accessibility: the
    /// unsigned debug binary has a different code signature from /Applications/Timeslice.app, so
    /// the grant can't be shared and the prompt is unactionable.
    static var isSandboxRun: Bool {
        ProcessInfo.processInfo.environment["TIMESLICE_SANDBOX_ROLE"] != nil
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TIMESLICE_SEED_DEMO"] == "1"
    }

    /// A separate DB file so seeding never clobbers the user's real timeslice.db.
    static var databaseURL: URL {
        TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("timeslice-demo.db")
    }

    /// Wipe and repopulate with a believable ~2 months of history for a multitasking day.
    ///
    /// Delegates to `DemoSeed` in Core, which holds the generator for both platforms. The
    /// `.screenshot` preset is this exact fixture — same 14 tasks, same block shapes — so existing
    /// Mac screenshots are unchanged. `.rich` is the many-projects/tags/devices variant used to see
    /// the UI at realistic scale.
    static func seed(into store: IntervalStore) {
        try? DemoSeed.seed(into: store, preset: .screenshot)
    }

}
