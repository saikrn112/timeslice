import AppKit
import SwiftUI
import TimesliceCore

/// The sync block of Settings.
///
/// A separate view because `@ObservedObject` can't wrap an Optional. Passing the controllers as
/// plain `var`s meant SwiftUI never saw their `@Published` changes — sign-in succeeded but the
/// panel kept rendering "Sign in with Google", which looked exactly like a failed login.
struct SyncSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var sync: SyncController
    @ObservedObject var auth: GoogleAuth

    @State private var signingIn = false
    @State private var authError: String?
    /// Inline rename of THIS device's row — only this device can be renamed; another machine's
    /// name is published by that machine.
    @State private var renamingThisDevice = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let pending = sync.pendingFirstMerge {
                // Must come first: until this is answered the device publishes but never merges,
                // so without the prompt it would sit "signed in" and permanently out of date.
                firstMergePrompt(pending)
            } else if settings.syncEnabled && auth.isSignedIn {
                active
            } else {
                setup
            }
        }
    }

    /// Shown once, the first time this device sees another's data. Merging a year of history
    /// silently is what destroys trust in a tracker, so it asks — but it must be answerable.
    private func firstMergePrompt(_ report: MergeReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Another device has data to merge", systemImage: "arrow.triangle.merge")
                .font(.system(size: 11, weight: .medium))
            Text("\(report.intervalsAdded) sessions · \(report.tasksAdded) tasks · "
                 + "\(report.projectsAdded) projects")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Merging keeps everything from both devices — nothing is overwritten.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Merge") { sync.acceptFirstMerge() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                Button("Not now") { sync.declineFirstMerge() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            let on = settings.syncEnabled && auth.isSignedIn
            Image(systemName: on ? "arrow.triangle.2.circlepath"
                                 : "arrow.triangle.2.circlepath.slash")
                .font(.system(size: 11))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
            Text("Sync across devices").font(.system(size: 12, weight: .medium))
            Spacer()
            if on {
                Button { sync.syncNow() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless).help("Sync now")
                Button("Sign out") { signOut() }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
    }

    @ViewBuilder
    private var setup: some View {
        if !GoogleOAuth.isConfigured {
            // No credential available, so sign-in would fail at Google rather than here. Say why,
            // and where to put one — the repo deliberately ships without one.
            Text("Sync needs a Google OAuth client, which isn't bundled with the source.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Add TIMESLICE_GOOGLE_CLIENT_ID and _CLIENT_SECRET to\n\(GoogleOAuth.configFilePath), then restart.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if auth.needsReauth {
            // Distinct from "never signed in": the credential was revoked or expired, so say that
            // rather than pitching the feature as though it were new.
            Label("Google sign-in expired — sign in again to resume syncing",
                  systemImage: "exclamationmark.arrow.circlepath")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Keep all your devices in step. Your data goes to your own Google Drive — no "
                 + "Timeslice account, and no server we run.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button {
            beginSignIn()
        } label: {
            HStack(spacing: 5) {
                if signingIn {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 11))
                }
                Text(signingIn ? "Waiting for Google…"
                     : (auth.needsReauth ? "Sign in again" : "Sign in with Google"))
            }
        }
        .controlSize(.small)
        .disabled(signingIn || !GoogleOAuth.isConfigured)

        Text("Only files this app creates — it can't see the rest of your Drive.")
            .font(.system(size: 9)).foregroundStyle(.quaternary)

        if let err = authError ?? auth.lastError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)   // so the real message can be copied out
        }
    }

    @ViewBuilder
    private var active: some View {
        if sync.peers.isEmpty {
            Text("Signed in. Waiting for another device to appear…")
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            VStack(spacing: 3) {
                ForEach(sync.peers) { peer in deviceRow(peer) }
            }
        }

        if let err = sync.lastError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if let at = sync.lastSyncedAt {
            Text("Last synced \(relative(at))").font(.caption2).foregroundStyle(.tertiary)
        }

        HStack(spacing: 6) {
            Text("Google Drive (app data)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
            Spacer()
            // Answers "is this actually working?" without needing a second device.
            Button("Test") { sync.runSelfTest() }
                .buttonStyle(.link).font(.system(size: 10))
        }
        if let result = sync.selfTestResult {
            Text(result)
                .font(.system(size: 10))
                .foregroundStyle(result.hasPrefix("Working") ? Color.green
                                 : (result == "Checking…" ? Color.secondary : Color.orange))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func deviceRow(_ peer: SyncController.Peer) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(peer.stateColor)
                .frame(width: 6, height: 6)
            if renamingThisDevice && peer.isThisDevice {
                TextField("name this device", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 130)
                    .focused($nameFieldFocused)
                    .onSubmit { commitRename() }
                    // A TextField swallows onExitCommand, so Esc needs catching explicitly —
                    // otherwise there's no way out of the editor.
                    .onKeyPress(.escape) { renamingThisDevice = false; return .handled }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused && renamingThisDevice { commitRename() }
                    }
            } else {
                Text(peer.displayName)
                    .font(.system(size: 11, weight: peer.isThisDevice ? .semibold : .regular))
                    .lineLimit(1)
                    // Double-click to rename, same gesture as task and project rows.
                    .onTapGesture(count: 2) { if peer.isThisDevice { beginRename(peer) } }
                    .help(peer.isThisDevice ? "Double-click to rename this device" : peer.id)
                if peer.isThisDevice {
                    Text("this device").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .onTapGesture(count: 2) { beginRename(peer) }
                }
            }
            Spacer(minLength: 6)
            if let task = peer.currentTask {
                // Green = timing now, orange = paused on it, matching the menu-bar paused pill. A
                // paused device used to show nothing at all, so there was no way to tell what it
                // had been on.
                Text(task)
                    .font(.system(size: 10))
                    .foregroundStyle(peer.stateColor)
                    .lineLimit(1)
                    .help(peer.isRunning ? "Timing now" : "Paused on this task")
            }
            if !peer.isRunning && !peer.isThisDevice {
                Text(relative(peer.lastSeen)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if !peer.isThisDevice {
                // Retiring a device removes its file from Drive. Its data is already merged here,
                // so nothing is lost — this is how a duplicate or dead device gets cleared.
                Button { sync.forget(deviceID: peer.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("Forget this device")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
    }

    private func beginRename(_ peer: SyncController.Peer) {
        draftName = settings.deviceLabel.isEmpty ? peer.displayName : settings.deviceLabel
        renamingThisDevice = true
        nameFieldFocused = true
    }

    private func commitRename() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        renamingThisDevice = false
        // Empty clears the override, falling back to the derived machine name.
        settings.deviceLabel = name
        sync.syncNow()   // publish the new name so other devices see it
    }

    private func beginSignIn() {
        signingIn = true
        authError = nil
        Task { @MainActor in
            do {
                try await auth.signIn()
                settings.syncMode = .googleDrive
            } catch {
                authError = error.localizedDescription
            }
            signingIn = false
        }
    }

    private func signOut() {
        auth.signOut()
        settings.syncMode = .off
    }

    private func relative(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86_400))d ago"
    }
}
