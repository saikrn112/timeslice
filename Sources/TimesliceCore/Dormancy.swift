import Foundation

/// Which tasks have gone quiet.
///
/// A task you haven't touched in a month is neither active nor done, and showing it as active is the lie
/// that makes a task list grow until it's ignored. So it gets a third state — dormant — and the rule for
/// entering it is simply time.
///
/// **Derived, never stored.** A task is dormant if nothing has been tracked against it for long enough, and
/// it stops being dormant the moment you track it again. A stored flag would need a background job to set
/// it, a migration to add it, a sync rule for two devices that disagree about when the silence started, and
/// a decision about what happens when you start the timer on it — all to represent something the intervals
/// already say.
public enum Dormancy {
    /// The tasks that have been silent for at least `afterDays`.
    ///
    /// - Parameters:
    ///   - lastActivity: task id → the most recent interval start. A task absent from this map has never
    ///     been tracked at all, which counts as silent — the day it was created is not activity.
    ///   - tasks: every task to consider. Finished and archived ones are left out by the caller, because a
    ///     task you deliberately closed is not one that drifted.
    ///   - afterDays: days of silence required. Zero or less turns the whole idea off.
    public static func dormantTaskIDs(lastActivity: [Int64: Date],
                                      tasks: [Project],
                                      afterDays: Int,
                                      now: Date = Date(),
                                      calendar: Calendar = .current) -> Set<Int64> {
        guard afterDays > 0 else { return [] }
        var out: Set<Int64> = []
        for task in tasks where !task.finished && !task.archived {
            guard let days = daysSince(lastActivity[task.id], now: now, calendar: calendar) else {
                // Never tracked. Counts as dormant, so a list of things you wrote down and never started
                // doesn't read as a list of things you are doing.
                out.insert(task.id)
                continue
            }
            if days >= afterDays { out.insert(task.id) }
        }
        return out
    }

    /// Whole days between the last activity and now, by calendar day rather than by 24-hour blocks — so
    /// "30 days" means what a person means by it regardless of the time of day either end.
    public static func daysSince(_ date: Date?, now: Date = Date(),
                                 calendar: Calendar = .current) -> Int? {
        guard let date else { return nil }
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: from, to: to).day
    }
}
