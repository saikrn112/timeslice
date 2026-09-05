import Foundation
import os.signpost

/// Timing for the paths that actually cost something, kept cheap enough to leave on.
///
/// The point is not profiling for its own sake: it's that "thin" has to be a measured claim. Every
/// slowdown found so far was found by accident — `reload()` loading every interval ever recorded before the
/// Lock Screen button could redraw, the period strip summarising the full history once per card. Both were
/// invisible until something felt slow. This makes them visible without attaching Xcode.
///
/// ## Cost of measuring
///
/// One `Date()` pair and a dictionary write per measured call. `record` is O(1) and keeps only aggregates —
/// count, total, worst — so memory doesn't grow with call count. That matters because the hot paths here run
/// ten times a second.
///
/// Also emits `os_signpost`s, which cost nothing when no tool is listening and give exact intervals in
/// Instruments when one is.
public final class Perf: @unchecked Sendable {
    public static let shared = Perf()

    /// What one named path has cost.
    public struct Stat: Sendable, Equatable {
        public var count: Int = 0
        public var totalSeconds: Double = 0
        public var worstSeconds: Double = 0
        /// Mean, which is the number to compare against a frame budget (16ms at 60fps).
        public var meanSeconds: Double { count > 0 ? totalSeconds / Double(count) : 0 }
    }

    private let lock = NSLock()
    private var stats: [String: Stat] = [:]
    private let log = OSLog(subsystem: "com.timeslice", category: .pointsOfInterest)

    /// Off by default. Instrumentation that's always on is a cost you can't see, which is the exact thing
    /// being hunted — so it's opt-in from Settings and persists across launches.
    public var isEnabled: Bool = false

    private init() {}

    /// Time `body`, attribute it to `name`, and return its value.
    ///
    /// Rethrows so it can wrap throwing work without changing the call site's error handling.
    @discardableResult
    public func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "measure", signpostID: id, "%{public}s", name)
        let started = Date()
        defer {
            record(name, seconds: Date().timeIntervalSince(started))
            os_signpost(.end, log: log, name: "measure", signpostID: id, "%{public}s", name)
        }
        return try body()
    }

    public func record(_ name: String, seconds: Double) {
        lock.lock()
        var s = stats[name] ?? Stat()
        s.count += 1
        s.totalSeconds += seconds
        s.worstSeconds = max(s.worstSeconds, seconds)
        stats[name] = s
        lock.unlock()
    }

    /// Snapshot, worst mean first — the order you want when deciding what to fix.
    public func snapshot() -> [(name: String, stat: Stat)] {
        lock.lock()
        let copy = stats
        lock.unlock()
        return copy.map { (name: $0.key, stat: $0.value) }
            .sorted { $0.stat.meanSeconds > $1.stat.meanSeconds }
    }

    public func reset() {
        lock.lock()
        stats = [:]
        lock.unlock()
    }

    /// Names used across both apps, so the Mac and the phone report the SAME path under the same key and the
    /// two can be compared directly. A typo'd string would silently create a second bucket.
    public enum Path {
        public static let reload = "store.reload"
        public static let stripBuild = "metrics.stripBuild"
        public static let metricsRebuild = "metrics.rebuild"
        public static let syncCycle = "sync.cycle"
        public static let rollChunks = "store.rollChunks"
        public static let activityUpdate = "activity.update"
        public static let toggle = "timer.toggle"
    }
}
