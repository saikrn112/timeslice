import SwiftUI
import TimesliceCore

/// A warning dot on the Settings gear when sync has stopped working.
///
/// Three states count as broken, and all three were silent before:
///
/// - **signed out** while sync is switched on. Nothing auto-signs the app out, but a credential can still go
///   missing — a Keychain item whose ACL no longer matches the code signature, a token file removed — and the
///   app then sits with `syncMode = googleDrive` and no way to use it.
/// - **the last sync failed**, which `SyncController` already records and only Settings ever showed.
/// - **nothing has synced for hours** while the app has been running. Only counted once a sync HAS succeeded
///   this launch, because `lastSyncedAt` starts nil and a badge on every cold start would cry wolf.
struct SyncBadge: View {
    @ObservedObject var sync: SyncController
    @ObservedObject var auth: GoogleAuth
    @ObservedObject var settings: AppSettings

    /// Hours without a successful sync before it's worth saying so. Long enough that a laptop shut for the
    /// afternoon doesn't raise it, short enough that a day's work on another device isn't lost to it.
    private static let staleAfter: TimeInterval = 6 * 3600

    private var problem: String? {
        if ProcessInfo.processInfo.environment["TIMESLICE_SYNC_WARN"] == "1" {
            return "Sync is signed out — other devices' hours aren't arriving."
        }
        guard settings.syncEnabled else { return nil }
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
                .accessibilityLabel("Sync problem")
        }
    }
}
