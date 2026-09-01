import SwiftUI
import TimesliceCore

/// Compact settings for the metrics: daily goal, deep-block threshold, trend window.
struct SettingsPanel: View {
    @ObservedObject var settings: Settings
    /// The store, for the notes sheet. Passed in rather than reached for through the sync
    /// controller, which owns its copy privately and shouldn't be a back door to it.
    let store: IntervalStore
    /// nil when the app is running without sync wired up (tests, previews).
    var sync: SyncController? = nil
    var auth: GoogleAuth? = nil


    /// Read once per panel appearance, not per render — a computed DB read in a view body re-queries
    /// on every redraw.

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.headline)

            stepperRow(
                title: "Awake hours",
                value: "\(Int(settings.wakingHours))h",
                caption: "what \"used\" is measured against — the rest is unaccounted",
                onDec: { settings.wakingHours = max(4, settings.wakingHours - 1) },
                onInc: { settings.wakingHours = min(24, settings.wakingHours + 1) }
            )

            stepperRow(
                title: "Deep block ≥",
                value: "\(settings.deepBlockMinutes)m",
                caption: "sessions this long count toward Focus %",
                onDec: { settings.deepBlockMinutes = max(5, settings.deepBlockMinutes - 5) },
                onInc: { settings.deepBlockMinutes = min(120, settings.deepBlockMinutes + 5) }
            )

            Divider()

            Toggle(isOn: $settings.promptsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nudges")
                    Text("both prompts below; sleep still pauses the timer")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            stepperRow(
                title: "Still working?",
                value: settings.autoPauseMinutes == 0 ? "Off" : "\(settings.autoPauseMinutes)m",
                caption: "ask after a session runs this long, and pause it",
                onDec: { settings.autoPauseMinutes = max(0, settings.autoPauseMinutes - 15) },
                onInc: { settings.autoPauseMinutes = min(240, settings.autoPauseMinutes + 15) }
            )
            .disabled(!settings.promptsEnabled)

            stepperRow(
                title: "Still paused?",
                value: settings.idleNudgeMinutes == 0 ? "Off" : "\(settings.idleNudgeMinutes)m",
                caption: "ask after a task sits paused this long, in case you forgot to resume",
                onDec: { settings.idleNudgeMinutes = max(0, settings.idleNudgeMinutes - 5) },
                onInc: { settings.idleNudgeMinutes = min(120, settings.idleNudgeMinutes + 5) }
            )
            .disabled(!settings.promptsEnabled)

            Divider()

            stepperRow(
                title: "Dim others",
                value: "\(settings.highlightDimPercent)%",
                caption: "how far everything else fades while one task is highlighted",
                onDec: { settings.highlightDimPercent = max(0, settings.highlightDimPercent - 5) },
                onInc: { settings.highlightDimPercent = min(95, settings.highlightDimPercent + 5) }
            )

            Divider()

            syncSection
        }
        .padding(16)
        .frame(width: 360)
    }

    /// Delegates to an observing child: `@ObservedObject` can't be optional, and a plain `var`
    /// silently skips redraws when the controller publishes a change.
    @ViewBuilder
    private var syncSection: some View {
        if let sync, let auth {
            SyncSettingsSection(settings: settings, sync: sync, auth: auth)
        } else {
            Text("Sync unavailable").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func stepperRow(title: String, value: String, caption: String? = nil,
                            onDec: @escaping () -> Void, onInc: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack(spacing: 8) {
                Button { onDec() } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                Text(value).font(.system(.body, design: .monospaced)).frame(minWidth: 40)
                Button { onInc() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
        }
    }
}
