import Foundation

/// One persisted footprint reading. Deliberately tiny.
///
/// Field names are one or two characters because this is appended once a minute forever: at ~45 bytes a line
/// a month costs about 2 MB, where spelled-out keys would triple it for no benefit — nothing reads this by
/// hand.
public struct FootprintSample: Codable, Sendable, Equatable {
    /// Seconds since 1970.
    public let t: Double
    /// Resident bytes.
    public let r: UInt64
    /// Cumulative CPU seconds since launch.
    public let c: Double
    /// Thread count.
    public let n: Int
    /// Launch id — a new value each time the process starts.
    ///
    /// Needed because `c` is cumulative PER LAUNCH: without knowing where a launch began, the drop from a
    /// restart reads as negative CPU, and a naive difference would show a huge spike on the sample after it.
    public let l: Int

    public init(t: Double, r: UInt64, c: Double, n: Int, l: Int) {
        self.t = t; self.r = r; self.c = c; self.n = n; self.l = l
    }

    public var date: Date { Date(timeIntervalSince1970: t) }
    public var residentMB: Double { Double(r) / 1_048_576 }
}

/// Bucket width for the footprint chart.
public enum FootprintResolution: String, CaseIterable, Sendable, Identifiable {
    case tenMinutes = "10m"
    case hour = "1h"
    case day = "1d"
    case week = "1w"
    case month = "1mo"

    public var id: String { rawValue }

    /// Bucket width in seconds. Month is nominal (30 days) for the same reason budgets are: this is a
    /// diagnostic chart, and a calendar-exact month would make February's bar mean something different.
    public var seconds: TimeInterval {
        switch self {
        case .tenMinutes: return 600
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 604_800
        case .month: return 2_592_000
        }
    }
}

/// One bar on the chart.
public struct FootprintBucket: Sendable, Identifiable {
    public let start: Date
    /// PEAK CPU load in the bucket, as a share of one core. The headline: spikes are what's being hunted, and
    /// an average hides exactly the thing you're looking for.
    public let peakCPULoad: Double
    /// Mean load across the bucket, for context — a bucket whose peak and mean are close is steady load,
    /// which is a different problem from an occasional spike.
    public let meanCPULoad: Double
    public let peakResidentMB: Double
    public let samples: Int

    public var id: Date { start }
}

/// Turns raw samples into chart buckets.
///
/// In Core, and pure, so the maths is testable and the Mac can chart its own numbers the same way.
public enum FootprintSeries {

    /// Bucket `samples` at `resolution`, keeping the PEAK and mean CPU load and the peak memory in each.
    ///
    /// Load is a slope between consecutive samples, so it needs pairs. Pairs are only meaningful WITHIN one
    /// launch: `FootprintSample.c` restarts at zero each time the process does, so a pair spanning a restart
    /// would report a negative delta (discarded) or, if the new launch had already accumulated more than the
    /// old one, a fictitious spike. Both are avoided by only pairing samples with the same launch id.
    ///
    /// Buckets are aligned to absolute multiples of the width rather than to the first sample, so the same
    /// data always produces the same bars and two charts can be compared.
    public static func bucket(_ samples: [FootprintSample],
                             resolution: FootprintResolution) -> [FootprintBucket] {
        guard samples.count >= 2 else { return [] }
        let sorted = samples.sorted { $0.t < $1.t }
        let width = resolution.seconds

        // Per-bucket accumulators.
        var loadsByBucket: [Double: [Double]] = [:]
        var peakMemByBucket: [Double: Double] = [:]
        var countByBucket: [Double: Int] = [:]

        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            let bucketStart = (current.t / width).rounded(.down) * width
            countByBucket[bucketStart, default: 0] += 1
            peakMemByBucket[bucketStart] = max(peakMemByBucket[bucketStart] ?? 0, current.residentMB)

            // Same launch, forward in time, and a sane gap — a pair straddling a long sleep would divide a
            // small CPU delta by hours and report a misleadingly flat zero.
            guard previous.l == current.l else { continue }
            let elapsed = current.t - previous.t
            guard elapsed > 0.5, elapsed <= width * 2 else { continue }
            let delta = current.c - previous.c
            guard delta >= 0 else { continue }
            loadsByBucket[bucketStart, default: []].append(delta / elapsed)
        }

        return countByBucket.keys.sorted().map { start in
            let loads = loadsByBucket[start] ?? []
            return FootprintBucket(
                start: Date(timeIntervalSince1970: start),
                peakCPULoad: loads.max() ?? 0,
                meanCPULoad: loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count),
                peakResidentMB: peakMemByBucket[start] ?? 0,
                samples: countByBucket[start] ?? 0)
        }
    }

    /// Drop samples older than `days`, so the log can't grow without bound.
    ///
    /// Called on load rather than on every append: rewriting the file once a minute would make the recorder
    /// more expensive than the thing it records.
    public static func trimmed(_ samples: [FootprintSample], keepingDays days: Int,
                               now: Date = Date()) -> [FootprintSample] {
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        return samples.filter { $0.t >= cutoff }
    }
}
