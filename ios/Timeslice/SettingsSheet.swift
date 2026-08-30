import SwiftUI
import TimesliceCore
import TimesliceUI

/// The Mac's gear popover, as a sheet.
///
/// Same settings, same keys, same defaults — it drives the shared `AppSettings` in Core, so changing
/// the deep-block threshold here and on the Mac means the same thing and Focus % can't disagree.
/// Previously the phone had no settings at all and hardcoded its own thresholds.
///
/// Two of the Mac's rows are deliberately absent, for the same reason the plan drops privacy mode:
/// **"Dim others"** governs hover-highlighting on a pointer-driven timeline, and there is no hover on
/// a phone. Everything else is here.
struct SettingsSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @ObservedObject private var settings = TimerModel.shared.settings
    @ObservedObject private var auth = GoogleAuthiOS.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingBudgets = false
    @State private var editingTags = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    stepper("Awake hours", value: "\(Int(settings.wakingHours))h",
                            caption: "what “used” is measured against — the rest is unaccounted",
                            dec: { settings.wakingHours = max(4, settings.wakingHours - 1) },
                            inc: { settings.wakingHours = min(24, settings.wakingHours + 1) })
                    stepper("Deep block ≥", value: "\(settings.deepBlockMinutes)m",
                            caption: "sessions this long count toward Focus %",
                            dec: { settings.deepBlockMinutes = max(5, settings.deepBlockMinutes - 5) },
                            inc: { settings.deepBlockMinutes = min(120, settings.deepBlockMinutes + 5) })
                } header: { header("Metrics") }

                Section {
                    Toggle(isOn: $settings.promptsEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Nudges").font(Theme.rowTitle)
                            Text("both prompts below")
                                .font(Theme.captionSmall).foregroundStyle(.secondary)
                        }
                    }
                    stepper("Still working?",
                            value: settings.autoPauseMinutes == 0 ? "Off" : "\(settings.autoPauseMinutes)m",
                            caption: "ask after a session runs this long",
                            dec: { settings.autoPauseMinutes = max(0, settings.autoPauseMinutes - 15) },
                            inc: { settings.autoPauseMinutes = min(240, settings.autoPauseMinutes + 15) })
                        .disabled(!settings.promptsEnabled)
                    stepper("Still paused?",
                            value: settings.idleNudgeMinutes == 0 ? "Off" : "\(settings.idleNudgeMinutes)m",
                            caption: "ask after a task sits paused this long",
                            dec: { settings.idleNudgeMinutes = max(0, settings.idleNudgeMinutes - 5) },
                            inc: { settings.idleNudgeMinutes = min(120, settings.idleNudgeMinutes + 5) })
                        .disabled(!settings.promptsEnabled)
                } header: { header("Nudges") } footer: {
                    // The one place the phone's behaviour genuinely differs from the Mac's, so it
                    // says so rather than letting someone discover it.
                    Text("Delivered as notifications. Unlike the Mac, the screen turning off does "
                         + "not pause the timer — a phone screen goes dark while you're still working.")
                        .font(Theme.captionSmall)
                }

                Section {
                    Button { editingBudgets = true } label: {
                        Label("Budgets…", systemImage: "target")
                    }
                    Button { editingTags = true } label: {
                        Label("Tags…", systemImage: "tag")
                    }
                } header: { header("Tags & budgets") } footer: {
                    Text("Budgets show as a section on the Metrics tab, as on the Mac.")
                        .font(Theme.captionSmall)
                }

                syncSection
                actionButtonSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $editingBudgets) { BudgetEditorSheet() }
            .sheet(isPresented: $editingTags) { TagEditorSheet() }
            .onDisappear {
                // Thresholds changed, so anything armed against the old ones is wrong.
                model.rearmNudges()
            }
        }
    }

    // MARK: - Sync / devices

    @ViewBuilder
    private var syncSection: some View {
        Section {
            LabeledContent("This device") {
                Text(model.deviceLabel).font(Theme.rowTime).foregroundStyle(.secondary)
            }
            ForEach(model.knownDevices, id: \.id) { device in
                HStack {
                    Image(systemName: device.id == model.deviceID ? "iphone" : "desktopcomputer")
                        .foregroundStyle(.secondary)
                    Text(device.label).font(Theme.rowTitle)
                    Spacer()
                    Text(device.id == model.deviceID ? "this device" : "synced")
                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                }
            }
        } header: { header("Devices") } footer: {
            Text("Time recorded on another device appears on the day timeline, and the session list "
                 + "names which device each block came from.")
                .font(Theme.captionSmall)
        }

        Section {
            // The client id is pasted rather than baked in: this repo can't carry a credential, and an
            // installed app's client id isn't a secret anyway — PKCE is what protects the exchange.
            TextField("1234-abcd.apps.googleusercontent.com", text: $settings.googleClientID)
                .font(.system(size: 11, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(auth.isSignedIn)

            if auth.isSignedIn {
                LabeledContent("Google") {
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .font(Theme.caption).foregroundStyle(.green)
                }
                Button {
                    Task { await SyncController.shared.syncOnce() }
                } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                Button("Sign out", role: .destructive) { auth.signOut() }
            } else {
                Button {
                    Task { await auth.signIn() }
                } label: { Label("Sign in with Google", systemImage: "person.badge.key") }
                    .disabled(settings.googleClientID.isEmpty)
            }

            if let error = auth.lastError {
                Text(error).font(Theme.captionSmall).foregroundStyle(.red)
            }
        } header: { header("Sync") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync is off until you sign in. Data goes to your own Google Drive "
                     + "(appDataFolder scope), so Timeslice only ever sees files it created.")
                Text("Create the client at console.cloud.google.com → Credentials → Create "
                     + "credentials → OAuth client ID → **iOS**, with bundle ID "
                     + "`com.timeslice.ios`. An iOS client has no client secret, and the redirect "
                     + "scheme is derived from the client ID — nothing else to configure.")
            }
            .font(Theme.captionSmall)
        }
    }

    /// The Action Button cannot be claimed programmatically — there is no API. This is the whole of
    /// what an app can do about it: say where to go.
    private var actionButtonSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings → Action Button → swipe to Shortcut, then pick one of:")
                    .font(Theme.caption)
                Label("Toggle Timeslice Timer — start/pause the current task",
                      systemImage: "playpause")
                    .font(Theme.captionSmall)
                Label("Switch Timeslice Task — open the switcher wheel",
                      systemImage: "arrow.triangle.swap")
                    .font(Theme.captionSmall)
            }
            .foregroundStyle(.secondary)
        } header: { header("Action Button") } footer: {
            Text("iPhone 15 Pro and later. Timeslice can't assign it for you — iOS has no API to "
                 + "claim the button, the same way the Mac needs Accessibility granted by hand.")
                .font(Theme.captionSmall)
        }
    }

    // MARK: - Bits

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.sectionHeader)
    }

    /// The Mac's `stepperRow`: title + caption on the left, −/value/+ on the right. Not a SwiftUI
    /// `Stepper`, which would hide the value and lose the caption.
    private func stepper(_ title: String, value: String, caption: String,
                         dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.rowTitle)
                Text(caption).font(Theme.captionSmall).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Button { dec() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                Text(value).font(Theme.rowTime).frame(minWidth: 34)
                Button { inc() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }
}
