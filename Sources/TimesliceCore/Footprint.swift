import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What this process currently costs: memory, CPU time, threads.
///
/// In Core rather than the iOS target because the goal is a THIN app on both, and the Mac is the one that
/// runs for days with a 10fps clock. Comparing the two only means something if they're measured the same way.
///
/// ## What can and cannot be measured
///
/// **Battery drain cannot be attributed to your own app at runtime.** There is no API: `UIDevice` reports
/// the device's level, not your share of it, and nothing exposes per-process energy. The honest routes are
/// MetricKit (daily aggregates from the system) and Xcode's Energy gauge while attached. This type covers
/// the live half — the proxies that actually drive energy use, which are CPU time and wakeups.
///
/// CPU time is the number to watch. A time tracker is idle by nature, so measurable CPU while nothing is
/// happening is a defect: a repeating timer, a view recomputing, a query running per frame.
public struct Footprint: Sendable, Equatable {
    /// Resident memory — physical RAM actually occupied. What "how fat is this" means.
    public let residentBytes: UInt64
    /// High-water mark since launch. A footprint that settles low but peaks high still risks a jetsam kill,
    /// and the peak is what the system judges.
    public let peakResidentBytes: UInt64
    /// Total CPU seconds consumed by all threads since launch, user + system.
    ///
    /// Cumulative on purpose: an instantaneous percentage is noise at this scale, whereas the SLOPE between
    /// two samples is exactly "what did we spend since then".
    public let cpuSeconds: Double
    /// Live thread count. A creeping count means something spawns and never finishes.
    public let threads: Int
    public let at: Date

    public init(residentBytes: UInt64, peakResidentBytes: UInt64, cpuSeconds: Double,
                threads: Int, at: Date = Date()) {
        self.residentBytes = residentBytes
        self.peakResidentBytes = peakResidentBytes
        self.cpuSeconds = cpuSeconds
        self.threads = threads
        self.at = at
    }

    public var residentMB: Double { Double(residentBytes) / 1_048_576 }
    public var peakResidentMB: Double { Double(peakResidentBytes) / 1_048_576 }

    /// Average CPU utilisation between two samples, as a fraction of ONE core (0.01 = 1%).
    ///
    /// The headline number for "does this barely register": idle should read ~0, and anything above a
    /// fraction of a percent while idle needs explaining.
    public func cpuLoad(since earlier: Footprint) -> Double {
        let wall = at.timeIntervalSince(earlier.at)
        guard wall > 0.001 else { return 0 }
        return max(0, cpuSeconds - earlier.cpuSeconds) / wall
    }

    /// Sample now. Nil only if the kernel refuses, which shouldn't happen for one's own task.
    public static func sample(now: Date = Date()) -> Footprint? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basic = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard basic == KERN_SUCCESS else { return nil }

        // CPU time comes from THREAD times, not `basic_info`. `basic_info.user_time` counts only
        // TERMINATED threads, so a long-lived app reads ~0 there and looks free when it isn't.
        var threadTimes = task_thread_times_info()
        var ttCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let times = withUnsafeMutablePointer(to: &threadTimes) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(ttCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &ttCount)
            }
        }
        var cpu = seconds(info.user_time) + seconds(info.system_time)
        if times == KERN_SUCCESS {
            // Live threads plus already-retired ones, or the total would DROP when a thread exits.
            cpu += seconds(threadTimes.user_time) + seconds(threadTimes.system_time)
        }

        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        var live = 0
        if task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
           let threadList {
            live = Int(threadCount)
            // `task_threads` hands back a port right per thread plus the array. Not releasing them leaks
            // kernel ports — a slow-motion resource bug in the very thing measuring for leanness.
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threadList[i])
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        return Footprint(residentBytes: info.resident_size,
                         peakResidentBytes: info.resident_size_max,
                         cpuSeconds: cpu,
                         threads: live,
                         at: now)
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    private static func seconds(_ t: time_value_t) -> Double {
        Double(t.seconds) + Double(t.microseconds) / 1_000_000
    }
    #endif
}
