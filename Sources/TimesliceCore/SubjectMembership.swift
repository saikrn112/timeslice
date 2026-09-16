import Foundation

/// Which tasks a target's subject covers.
///
/// Allocations point at a task, a project or a tag, and answering "do these two allocations overlap?"
/// means comparing the SETS OF TASKS behind them — a tag allocation and a project allocation can
/// describe much of the same work, and summing them would count those hours twice.
///
/// This logic lived in `MetricsView.taskIDs(for:)`, where the highlight needed it. It has to be in
/// Core for the planner, and hoisting it means the phone shares one definition rather than growing a
/// second that drifts.
public struct SubjectMembership: Sendable {
    /// Every task, by id, with the group it belongs to.
    private let groupByTask: [Int64: Int64?]
    /// Effective tags per task: its own plus the ones inherited from its project.
    private let tagIDsByTask: [Int64: Set<Int64>]

    public init(tasks: [Project], tagIDsByTask: [Int64: Set<Int64>]) {
        self.groupByTask = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.taskProjectID) })
        self.tagIDsByTask = tagIDsByTask
    }

    /// The tasks a subject covers. A task is itself; a project is its tasks; a tag is every task
    /// carrying it, directly or by inheritance.
    public func taskIDs(for subject: TargetSubject) -> Set<Int64> {
        switch subject {
        case .task(let id): return [id]
        case .project(let groupID): return taskIDs(inGroup: groupID)
        case .tag(let tagID): return taskIDs(withTag: tagID)
        }
    }

    /// Tasks in a group. `nil` is the Inbox — tasks belonging to no project at all.
    ///
    /// The optional matters and can't be folded into `TargetSubject`, which has no way to say
    /// "Inbox": you can't set an allocation on the absence of a project. The metrics highlight can
    /// focus it, though, so the semantics live here rather than being reimplemented in the view.
    public func taskIDs(inGroup groupID: Int64?) -> Set<Int64> {
        Set(groupByTask.filter { $0.value == groupID }.map(\.key))
    }

    /// Tasks carrying a tag. `nil` is the untagged bucket — tasks carrying no tags at all.
    public func taskIDs(withTag tagID: Int64?) -> Set<Int64> {
        guard let tagID else {
            return Set(groupByTask.keys.filter { (tagIDsByTask[$0] ?? []).isEmpty })
        }
        return Set(tagIDsByTask.filter { $0.value.contains(tagID) }.map(\.key))
    }

    /// How two subjects relate, which is what decides whether their hours can be shared.
    public enum Relation: Sendable, Equatable {
        case disjoint
        /// The first is entirely inside the second: its hours are already counted there.
        case containedIn
        case contains
        case partial
        case identical
    }

    public func relation(_ a: TargetSubject, _ b: TargetSubject) -> Relation {
        let (x, y) = (taskIDs(for: a), taskIDs(for: b))
        if x.isDisjoint(with: y) { return .disjoint }
        if x == y { return .identical }
        if x.isSubset(of: y) { return .containedIn }
        if y.isSubset(of: x) { return .contains }
        return .partial
    }
}
