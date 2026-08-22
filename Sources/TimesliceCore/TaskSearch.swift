import Foundation

/// A palette row: a task plus why/how it matched, so the UI can show status and ordering.
public struct TaskMatch: Identifiable, Sendable {
    public let project: Project
    public let score: Int
    public let lastActivity: Date?
    public var id: Int64 { project.id }

    public init(project: Project, score: Int, lastActivity: Date?) {
        self.project = project
        self.score = score
        self.lastActivity = lastActivity
    }
}

/// Spotlight-style search over tasks: subsequence fuzzy match, ranked so live work wins ties.
/// A palette query split into the task name and an optional trailing `/project` token.
public struct ParsedQuery: Equatable, Sendable {
    /// What to match task names against — the `/token` removed.
    public let name: String
    /// Group name typed after `/`, if any. Empty string means "`/` typed, nothing after it yet",
    /// which is the cue to list all groups.
    public let groupToken: String?

    public init(name: String, groupToken: String?) {
        self.name = name
        self.groupToken = groupToken
    }
}

public enum TaskSearch {

    /// Split `"profiling /tensor"` into name `"profiling"` + group `"tensor"`.
    ///
    /// Only a `/` that starts a word counts, so task names containing slashes (`a/b testing`)
    /// aren't mangled. The token must be last — it's a suffix, not free-floating syntax.
    public static func parse(_ query: String) -> ParsedQuery {
        // Find a "/" that begins a word (start of string, or preceded by whitespace).
        var slashIndex: String.Index?
        var i = query.startIndex
        while i < query.endIndex {
            if query[i] == "/" {
                let atStart = i == query.startIndex
                let afterSpace = !atStart && query[query.index(before: i)].isWhitespace
                if atStart || afterSpace { slashIndex = i }   // keep the LAST such slash
            }
            i = query.index(after: i)
        }
        guard let slash = slashIndex else {
            return ParsedQuery(name: query.trimmingCharacters(in: .whitespaces), groupToken: nil)
        }
        let name = String(query[query.startIndex..<slash]).trimmingCharacters(in: .whitespaces)
        let token = String(query[query.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        return ParsedQuery(name: name, groupToken: token)
    }

    /// Groups matching a `/token`, ranked by the same tiered scoring as tasks. An empty token
    /// lists everything.
    public static func rankGroups(token: String, groups: [TaskProject], limit: Int = 8) -> [TaskProject] {
        let q = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(groups.prefix(limit)) }
        return groups
            .compactMap { g -> (TaskProject, Int)? in
                let s = score(query: q, candidate: g.name.lowercased())
                return s > 0 ? (g, s) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .prefix(limit)
            .map(\.0)
    }

    /// Rank tasks for `query`. Empty query → recents (active first, then recently-done, then
    /// archived). Non-empty → fuzzy subsequence match, same status tiering within equal quality.
    /// `groupNames` maps task id → its project's name, so a query can match a task by the
    /// project it belongs to. A project-name hit scores lower than a name hit of the same
    /// quality, so directly-named tasks still win.
    public static func rank(
        query: String, projects: [Project], lastActivity: [Int64: Date],
        groupNames: [Int64: String] = [:], limit: Int = 8
    ) -> [TaskMatch] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        let scored: [TaskMatch] = projects.compactMap { p in
            guard !q.isEmpty else {
                return TaskMatch(project: p, score: 0, lastActivity: lastActivity[p.id])
            }
            var s = score(query: q, candidate: p.name.lowercased())
            if let group = groupNames[p.id] {
                // Halved so "task named X" outranks "task in project X".
                let viaGroup = score(query: q, candidate: group.lowercased()) / 2
                s = max(s, viaGroup)
            }
            guard s > 0 else { return nil }
            return TaskMatch(project: p, score: s, lastActivity: lastActivity[p.id])
        }

        return scored.sorted { a, b in
            let ta = tier(a.project), tb = tier(b.project)
            if q.isEmpty {
                // No query → a recents list, so lead with live work: active, then done, then
                // archived, most-recently-touched first inside each tier.
                if ta != tb { return ta < tb }
            } else {
                // With a query, match quality comes FIRST and status is only a tiebreaker.
                // Tiering ahead of score meant a finished task could never place above an
                // active one, so with 8+ active tasks the limit cut every done task off the
                // list — exactly the tasks you open the palette to resume.
                if a.score != b.score { return a.score > b.score }
                if ta != tb { return ta < tb }
            }
            let da = a.lastActivity ?? .distantPast, db = b.lastActivity ?? .distantPast
            if da != db { return da > db }
            return a.project.name.localizedCaseInsensitiveCompare(b.project.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    /// 0 = active, 1 = finished, 2 = archived.
    private static func tier(_ p: Project) -> Int {
        if p.archived { return 2 }
        if p.finished { return 1 }
        return 0
    }

    /// Match score, 0 = no match. Tiered so results feel predictable:
    ///   1. contiguous substring (highest) — "me" → "**Me**etings"
    ///   2. acronym of word initials      — "dw" → "**D**eep **W**ork"
    ///   3. scattered subsequence (lowest) — "me" → "ML L**e**ctures"
    ///
    /// The tiers matter: pure subsequence matching alone ranked "ML Lectures" alongside
    /// "Meetings" for "me", which reads as broken.
    public static func score(query: String, candidate: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let cs = Array(candidate)

        // 1) Contiguous substring — by far the most intuitive match.
        if let r = candidate.range(of: query) {
            let atStart = r.lowerBound == candidate.startIndex
            let atWordStart = atStart || {
                let i = candidate.index(before: r.lowerBound)
                return " -_/".contains(candidate[i])
            }()
            var points = 4000
            if atStart { points += 2000 } else if atWordStart { points += 1000 }
            // Prefer tighter candidates: "docs" beats "design docs review" for "docs".
            return points + max(0, 400 - cs.count * 4)
        }

        // 2) Acronym: query letters match successive word initials.
        let initials = String(candidate.split(whereSeparator: { " -_/".contains($0) }).compactMap { $0.first })
        if initials.hasPrefix(query) {
            return 3000 + max(0, 400 - cs.count * 4)
        }

        // 3) Scattered subsequence — still findable, but always ranked below the above.
        var qi = 0
        let qs = Array(query)
        for ch in cs where qi < qs.count {
            if ch == qs[qi] { qi += 1 }
        }
        guard qi == qs.count else { return 0 }
        return 100 + max(0, 100 - cs.count)
    }
}
