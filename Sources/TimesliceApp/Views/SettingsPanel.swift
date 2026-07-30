import SwiftUI

/// Compact settings for the metrics: daily goal, deep-block threshold, trend window.
struct SettingsPanel: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.headline)

            stepperRow(
                title: "Daily goal",
                value: "\(Int(settings.dailyGoalHours))h",
                onDec: { settings.dailyGoalHours = max(1, settings.dailyGoalHours - 1) },
                onInc: { settings.dailyGoalHours = min(24, settings.dailyGoalHours + 1) }
            )

            stepperRow(
                title: "Deep block ≥",
                value: "\(settings.deepBlockMinutes)m",
                caption: "sessions this long count toward Focus %",
                onDec: { settings.deepBlockMinutes = max(5, settings.deepBlockMinutes - 5) },
                onInc: { settings.deepBlockMinutes = min(120, settings.deepBlockMinutes + 5) }
            )

            stepperRow(
                title: "Still-working prompt",
                value: settings.autoPauseMinutes == 0 ? "Off" : "\(settings.autoPauseMinutes)m",
                caption: "ask after a session runs this long (sleep always pauses regardless)",
                onDec: { settings.autoPauseMinutes = max(0, settings.autoPauseMinutes - 15) },
                onInc: { settings.autoPauseMinutes = min(240, settings.autoPauseMinutes + 15) }
            )
        }
        .padding(16)
        .frame(width: 300)
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
