import SwiftUI
import TimesliceCore

/// A warning dot on the Settings gear when something has quietly stopped working.
///
/// Four states count as broken, and all four were silent before:
///
/// - **signed out** while sync is switched on. Nothing auto-signs the app out, but a credential can still go
///   missing — a Keychain item whose ACL no longer matches the code signature, a token file removed — and the
///   app then sits with `syncMode = googleDrive` and no way to use it.
/// - **the last sync failed**, which `SyncController` already records and only Settings ever showed.
/// - **the global hotkeys aren't live.** The switcher needs Accessibility permission, macOS ties that
///   grant to the code signature, and an ad-hoc signature changes on every build — so a rebuild silently
///   kills it. Worse, a grant re-enabled AFTER launch isn't picked up by a process macOS has already
///   answered "not trusted", so the fix is a relaunch and nothing said so.
/// - **nothing has synced for hours** while the app has been running. Only counted once a sync HAS succeeded
///   this launch, because `lastSyncedAt` starts nil and a badge on every cold start would cry wolf.
struct SyncBadge: View {
    /// Optional, because the hotkey warning has to appear in a build with no sync wired up at all —
    /// tests, previews, and anyone running the app purely locally.
    @ObservedObject var settings: AppSettings
    @ObservedObject var appState: AppState
    var sync: SyncController?
    var auth: GoogleAuth?

    /// Hours without a successful sync before it's worth saying so. Long enough that a laptop shut for the
    /// afternoon doesn't raise it, short enough that a day's work on another device isn't lost to it.
    private static let staleAfter: TimeInterval = 6 * 3600

    /// A capture run suppresses the badge so it doesn't sit in every screenshot, so the only way to
    /// review either message is to ask for it: `SYNC_WARN=1` or `SYNC_WARN=hotkeys`.
    private var forced: String? { ProcessInfo.processInfo.environment["TIMESLICE_SYNC_WARN"] }

    private var problem: String? {
        if forced == "1" {
            return "Sync is signed out — other devices' hours aren't arriving."
        }
        // Checked before sync, and NOT gated on `syncEnabled`: the hotkeys have nothing to do with sync,
        // and someone running the app entirely locally still needs to be told.
        if !appState.hotkeysActive && (!DemoData.isScreenshotRun || forced == "hotkeys") {
            return "The ⌃+⌘+⇧ switcher isn't active — macOS hasn't granted Accessibility.\n"
                 + "Enable Timeslice under System Settings › Privacy & Security › Accessibility,\n"
                 + "then QUIT AND REOPEN Timeslice: a grant added after launch isn't picked up."
        }
        guard settings.syncEnabled, let sync, let auth else { return nil }
        if !auth.isSignedIn {
            return "Sync is signed out, so other devices' hours aren't arriving.\n"
                 + "Open Settings and sign in with Google."
        }
        if let error = sync.lastError {
            return "The last sync failed:\n\(error)"
        }
        if let last = sync.lastSyncedAt, Date().timeIntervalSince(last) > Self.staleAfter {
            let hours = Int(Date().timeIntervalSince(last) / 3600)
            return "Nothing has synced for \(hours)h, so this device may be behind the others."
        }
        return nil
    }

    var body: some View {
        if let problem {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
                // A dark ring, so the badge reads against the gear it sits on rather than merging with it.
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 9, height: 9))
                .help(problem)
                .accessibilityLabel("Something needs attention")
        }
    }
}
