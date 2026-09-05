import Foundation
import MetricKit
import TimesliceCore

/// Collects what the system will tell us about this app's cost, and keeps it where it can be read later.
///
/// ## Why MetricKit rather than reading the battery
///
/// There is no API that reports your own app's energy use. `UIDevice.batteryLevel` is the DEVICE's level,
/// which is worthless for attribution — it moves because of the screen, the radios and every other process.
/// MetricKit is Apple's answer: once every 24h the system hands over a payload of what your app actually
/// consumed, including CPU time, GPU time, display-on time, launch times, hangs and memory. Those are the
/// inputs to battery drain, measured by the only party that can measure them.
///
/// The trade is cadence: payloads arrive daily, not on demand, and never in the Simulator. So this is the
/// long-run picture, and `Footprint` is the immediate one. Both are needed — you can't optimise what only
/// shows up tomorrow, and you can't trust a spot reading as representative.
///
/// ## Where it goes
///
/// A JSONL file in the app's support directory, NOT the sqlite database. Diagnostics are per-device and
/// per-build; syncing them would push one phone's numbers onto the Mac and make both meaningless, and they'd
/// ride the Drive payload forever.
@MainActor
final class DiagnosticsStore: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsStore()

    /// One line per record, appended. Newline-delimited JSON so a truncated write costs one line rather than
    /// the file, and so it can be read with `tail` without parsing the whole thing.
    /// The log, if it exists — `nil` keeps the export button out of the UI rather than sharing nothing.
    var exportURL: URL? {
        FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Size and line count, so you can tell whether a run actually recorded anything before exporting.
    var fileSummary: String {
        guard let data = try? Data(contentsOf: fileURL) else { return "empty" }
        let lines = data.split(separator: UInt8(ascii: "\n")).count
        return String(format: "%d records · %.1f KB", lines, Double(data.count) / 1024)
    }

    private var fileURL: URL {
        TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("diagnostics.jsonl")
    }

    /// Footprint samples, in memory, for the live view. Bounded — this is a diagnostic, not a time series
    /// worth growing without limit.
    private(set) var samples: [Footprint] = []
    private let maxSamples = 240

    private var sampleTimer: Timer?

    /// Distinguishes this process's samples from a previous launch's. `cpuSeconds` is cumulative per launch,
    /// so without this a restart looks like negative CPU or, worse, a fabricated spike.
    private let launchID = Int(Date().timeIntervalSince1970)

    /// The persisted series, for the chart.
    private var seriesURL: URL {
        TimeslicePaths.defaultSupportDirectoryURL().appendingPathComponent("footprint.jsonl")
    }

    func start() {
        MXMetricManager.shared.add(self)
        // 60s. The measurement must not become the overhead: one `task_info` call is microseconds, so the
        // real cost is the wakeup, and a minute is frequent enough to place a spike within a 10-minute
        // bucket while adding one wakeup per minute to an app that already polls sync every 10-15s.
        takeSample()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.takeSample() }
        }
    }

    func stop() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        MXMetricManager.shared.remove(self)
    }

    /// The most recent CPU load, as a fraction of one core, over the last sampling interval.
    ///
    /// Nil until two samples exist, because load is a slope and one point has none. Reporting 0 instead
    /// would be a lie that reads as good news.
    var recentCPULoad: Double? {
        guard samples.count >= 2 else { return nil }
        return samples[samples.count - 1].cpuLoad(since: samples[samples.count - 2])
    }

    /// Load since the first sample — the honest "what is this costing me overall" figure, which a single
    /// interval can't give because a 30s window catching one sync looks alarming and the next looks free.
    var averageCPULoad: Double? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }
        return last.cpuLoad(since: first)
    }

    var latest: Footprint? { samples.last }

    @discardableResult
    func takeSample() -> Footprint? {
        guard let f = Footprint.sample() else { return nil }
        samples.append(f)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        // Persist too, so the chart survives a relaunch — the in-memory ring only covers this session, and a
        // spike you care about is usually one you noticed after the fact.
        appendSeries(FootprintSample(t: f.at.timeIntervalSince1970, r: f.residentBytes,
                                     c: f.cpuSeconds, n: f.threads, l: launchID))
        return f
    }

    /// Read the persisted series back, trimmed to the last 30 days.
    ///
    /// Trimming happens HERE and rewrites the file, rather than on append: rewriting once a minute would make
    /// the recorder cost more than what it records.
    func loadSeries(keepingDays: Int = 30) -> [FootprintSample] {
        guard let text = try? String(contentsOf: seriesURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let all: [FootprintSample] = text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(FootprintSample.self, from: data)
        }
        let kept = FootprintSeries.trimmed(all, keepingDays: keepingDays)
        if kept.count < all.count { rewriteSeries(kept) }
        return kept
    }

    private func appendSeries(_ sample: FootprintSample) {
        guard let data = try? JSONEncoder().encode(sample),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: seriesURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: seriesURL)
        }
    }

    private func rewriteSeries(_ samples: [FootprintSample]) {
        let encoder = JSONEncoder()
        let text = samples.compactMap { sample -> String? in
            guard let data = try? encoder.encode(sample) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        try? Data((text + "\n").utf8).write(to: seriesURL)
    }

    /// Both files, for the share sheet — the series is the one worth processing offline.
    var exportURLs: [URL] {
        [seriesURL, fileURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { append(line: summarise(payload)) }
    }

    /// Crashes, hangs and terminations. Worth keeping for a background-heavy app: a jetsam kill for memory
    /// is exactly the failure a "thin layer" is supposed to make impossible, and it's invisible otherwise.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var record: [String: Any] = ["kind": "diagnostic",
                                         "at": ISO8601DateFormatter().string(from: Date())]
            if let hangs = payload.hangDiagnostics { record["hangs"] = hangs.count }
            if let crashes = payload.crashDiagnostics { record["crashes"] = crashes.count }
            if let cpu = payload.cpuExceptionDiagnostics { record["cpuExceptions"] = cpu.count }
            if let disk = payload.diskWriteExceptionDiagnostics { record["diskWriteExceptions"] = disk.count }
            append(line: record)
        }
    }

    private func summarise(_ payload: MXMetricPayload) -> [String: Any] {
        var record: [String: Any] = [
            "kind": "metrickit",
            "at": ISO8601DateFormatter().string(from: Date()),
            "app": payload.latestApplicationVersion,
        ]
        // `measurement(of:)` converts the unit explicitly rather than trusting the default, which differs
        // between metrics and has bitten people comparing seconds against milliseconds.
        if let cpu = payload.cpuMetrics {
            record["cpuSeconds"] = cpu.cumulativeCPUTime.converted(to: .seconds).value
            record["cpuInstructions"] = cpu.cumulativeCPUInstructions.value
        }
        if let mem = payload.memoryMetrics {
            record["peakMemoryMB"] = mem.peakMemoryUsage.converted(to: .megabytes).value
            record["avgSuspendedMemoryMB"] =
                mem.averageSuspendedMemory.averageMeasurement.converted(to: .megabytes).value
        }
        if let display = payload.displayMetrics,
           let ppi = display.averagePixelLuminance?.averageMeasurement.value {
            record["avgPixelLuminance"] = ppi
        }
        if let launch = payload.applicationLaunchMetrics {
            record["launchTimeP50ms"] = launch.histogrammedTimeToFirstDraw
                .bucketEnumerator.compactMap { $0 as? MXHistogramBucket<UnitDuration> }
                .first?.bucketStart.converted(to: .milliseconds).value ?? 0
        }
        if let responsiveness = payload.applicationResponsivenessMetrics {
            record["hangBuckets"] = responsiveness.histogrammedApplicationHangTime
                .bucketEnumerator.allObjects.count
        }
        if let exit = payload.applicationExitMetrics {
            let bg = exit.backgroundExitData
            record["bgExitMemoryPressure"] = bg.cumulativeMemoryPressureExitCount
            record["bgExitMemoryLimit"] = bg.cumulativeMemoryResourceLimitExitCount
            record["bgExitWatchdog"] = bg.cumulativeAppWatchdogExitCount
            record["bgExitNormal"] = bg.cumulativeNormalAppExitCount
        }
        return record
    }

    // MARK: - Persistence

    /// Append one JSON line. Best-effort: diagnostics must never be able to break the app they measure, so
    /// every failure here is swallowed rather than surfaced.
    private func append(line record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Write the current footprint and timing table out, so a session's numbers survive the app closing and
    /// can be read off the device without Xcode.
    func flushSnapshot() {
        var record: [String: Any] = ["kind": "snapshot",
                                     "at": ISO8601DateFormatter().string(from: Date())]
        if let f = latest {
            record["residentMB"] = f.residentMB
            record["peakResidentMB"] = f.peakResidentMB
            record["cpuSeconds"] = f.cpuSeconds
            record["threads"] = f.threads
        }
        if let load = averageCPULoad { record["avgCPULoad"] = load }
        record["paths"] = Perf.shared.snapshot().reduce(into: [String: Any]()) { out, entry in
            out[entry.name] = ["count": entry.stat.count,
                               "meanMs": entry.stat.meanSeconds * 1000,
                               "worstMs": entry.stat.worstSeconds * 1000]
        }
        append(line: record)
    }
}
