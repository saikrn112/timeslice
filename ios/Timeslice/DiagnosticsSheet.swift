import SwiftUI
import TimesliceCore
import TimesliceUI

/// What the app is costing, readable on the device.
///
/// Exists because "it should barely register" is only meaningful if it's checkable. Xcode's gauges need a
/// cable and a debug build; this shows the same shape of numbers from a normal run on your own phone, which
/// is the only place the real cadence happens (background refresh, chunk rolling, sync polling).
struct DiagnosticsSheet: View {
    @ObservedObject private var model = TimerModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var footprint: Footprint?
    @State private var avgLoad: Double?
    @State private var recentLoad: Double?
    @State private var paths: [(name: String, stat: Perf.Stat)] = []
    @State private var perfEnabled = Perf.shared.isEnabled

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Memory", footprint.map { String(format: "%.1f MB", $0.residentMB) } ?? "—")
                    row("Peak memory", footprint.map { String(format: "%.1f MB", $0.peakResidentMB) } ?? "—")
                    row("Threads", footprint.map { "\($0.threads)" } ?? "—")
                    row("CPU total", footprint.map { String(format: "%.2f s", $0.cpuSeconds) } ?? "—")
                } header: { Text("Footprint") } footer: {
                    Text("Resident memory is what the system judges for termination. CPU total is since "
                         + "launch — the slope matters, not the value.")
                        .font(Theme.captionSmall)
                }

                Section {
                    // Load as a share of ONE core. Two figures because a single 30s window that happens to
                    // catch a sync reads alarmingly high and the next reads zero.
                    row("CPU now", recentLoad.map { pct($0) } ?? "needs 2 samples")
                    row("CPU average", avgLoad.map { pct($0) } ?? "needs 2 samples")
                } header: { Text("Load") } footer: {
                    Text("Share of one core. Idle should be near zero — anything above a fraction of a "
                         + "percent while nothing is happening is a defect, not a reading.")
                        .font(Theme.captionSmall)
                }

                Section {
                    Toggle("Time hot paths", isOn: $perfEnabled)
                        .onChange(of: perfEnabled) { _, on in
                            Perf.shared.isEnabled = on
                            UserDefaults.standard.set(on, forKey: "perfEnabled")
                            if !on { Perf.shared.reset() }
                            refresh()
                        }
                    if paths.isEmpty {
                        Text(perfEnabled ? "No calls recorded yet" : "Off")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(paths, id: \.name) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name).font(Theme.caption)
                                    Text("\(entry.stat.count) calls")
                                        .font(Theme.captionSmall).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(ms(entry.stat.meanSeconds))
                                        .font(.system(size: 12, design: .monospaced))
                                    Text("worst \(ms(entry.stat.worstSeconds))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: { Text("Hot paths") } footer: {
                    Text("Mean per call, worst first. 16 ms is one frame at 60 Hz — anything near that on a "
                         + "path that runs per tap is felt. Off by default: always-on instrumentation is "
                         + "itself a cost you can't see.")
                        .font(Theme.captionSmall)
                }

                Section {
                    Button("Sample now") { refresh() }
                    Button("Write snapshot to disk") { DiagnosticsStore.shared.flushSnapshot() }
                    Button("Reset timings", role: .destructive) {
                        Perf.shared.reset(); refresh()
                    }
                } footer: {
                    Text("Snapshots and MetricKit payloads append to diagnostics.jsonl in the app's "
                         + "support directory. Kept out of the database on purpose — they're per-device and "
                         + "per-build, so syncing them would make both devices' numbers meaningless.")
                        .font(Theme.captionSmall)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        DiagnosticsStore.shared.takeSample()
        footprint = DiagnosticsStore.shared.latest
        avgLoad = DiagnosticsStore.shared.averageCPULoad
        recentLoad = DiagnosticsStore.shared.recentCPULoad
        paths = Perf.shared.snapshot()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.caption)
            Spacer()
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }
    private func ms(_ s: Double) -> String { String(format: "%.1f ms", s * 1000) }
}
