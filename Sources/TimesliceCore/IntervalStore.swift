import Foundation
import SQLite3

// SQLite wants to know whether a bound text/blob is transient (copy it) or static.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The append-only interval store. Everything is intervals + projects; all aggregation
/// happens in `Aggregations` over the rows this store returns. Holds one connection for
/// its lifetime so transactions and WAL work cleanly (single-user, single-process app).
public final class IntervalStore {
    private let databaseURL: URL
    private var db: OpaquePointer?

    public init(databaseURL: URL = TimeslicePaths.defaultDatabaseURL()) throws {
        self.databaseURL = databaseURL
        try open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public var resolvedDatabaseURL: URL { databaseURL }

    // MARK: - Connection

    private func open() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw lastError()
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    // MARK: - Migration

    public func migrateIfNeeded() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS projects (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL,
            color_hex  TEXT NOT NULL DEFAULT '#8E8E93',
            sort_order INTEGER NOT NULL DEFAULT 0,
            archived   INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS intervals (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER NOT NULL REFERENCES projects(id),
            start_utc  REAL NOT NULL,
            end_utc    REAL,
            running    INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_intervals_project ON intervals(project_id);
        CREATE INDEX IF NOT EXISTS idx_intervals_start   ON intervals(start_utc);

        -- Enforce "at most one running interval" at the DB level. A partial unique index on
        -- (end_utc IS NULL) would NOT work: SQLite treats NULLs as distinct. The explicit
        -- running flag makes the constraint real.
        CREATE UNIQUE INDEX IF NOT EXISTS idx_one_running ON intervals(running) WHERE running = 1;
        """)

        // Migration: `finished` flag (distinct from `archived`). Finished tasks still count in
        // Today/All-Time but render struck-through at the end of the list; archived tasks leave
        // those views entirely. Ignore the error if the column already exists.
        _ = sqlite3_exec(db, "ALTER TABLE projects ADD COLUMN finished INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        // When a task was marked done (epoch seconds). Lets a finished task stay visible+struck
        // through for the rest of that day, then drop out of Today while remaining in All Time.
        _ = sqlite3_exec(db, "ALTER TABLE projects ADD COLUMN finished_at REAL", nil, nil, nil)
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(name: String, colorHex: String) throws -> Int64 {
        let sql = "INSERT INTO projects (name, color_hex, sort_order) VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM projects))"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func renameProject(id: Int64, name: String) throws {
        let stmt = try prepare("UPDATE projects SET name = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    public func setProjectColor(id: Int64, colorHex: String) throws {
        let stmt = try prepare("UPDATE projects SET color_hex = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, colorHex)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    public func setProjectArchived(id: Int64, archived: Bool) throws {
        let stmt = try prepare("UPDATE projects SET archived = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, archived ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    /// Mark finished/unfinished, stamping when it happened so Today can drop it tomorrow.
    public func setProjectFinished(id: Int64, finished: Bool, at date: Date = Date()) throws {
        let stmt = try prepare("UPDATE projects SET finished = ?, finished_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, finished ? 1 : 0)
        if finished { sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    /// Delete all of a task's intervals (reset its tracked time to zero) but keep the task.
    public func resetProjectIntervals(id: Int64) throws {
        let stmt = try prepare("DELETE FROM intervals WHERE project_id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try step(stmt)
    }

    /// Permanently delete a project and all its intervals. Destructive — removes time history.
    public func deleteProject(id: Int64) throws {
        try transaction {
            let del1 = try prepare("DELETE FROM intervals WHERE project_id = ?")
            sqlite3_bind_int64(del1, 1, id)
            try step(del1)
            sqlite3_finalize(del1)

            let del2 = try prepare("DELETE FROM projects WHERE id = ?")
            sqlite3_bind_int64(del2, 1, id)
            try step(del2)
            sqlite3_finalize(del2)
        }
    }

    public func setProjectOrder(id: Int64, sortOrder: Int) throws {
        let stmt = try prepare("UPDATE projects SET sort_order = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(sortOrder))
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    public func listProjects(includeArchived: Bool = false) throws -> [Project] {
        let sql = """
        SELECT id, name, color_hex, sort_order, archived, finished, finished_at FROM projects
        \(includeArchived ? "" : "WHERE archived = 0")
        ORDER BY sort_order ASC, id ASC
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [Project] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Project(
                id: sqlite3_column_int64(stmt, 0),
                name: text(stmt, 1),
                colorHex: text(stmt, 2),
                sortOrder: Int(sqlite3_column_int(stmt, 3)),
                archived: sqlite3_column_int(stmt, 4) != 0,
                finished: sqlite3_column_int(stmt, 5) != 0,
                finishedAt: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            ))
        }
        return rows
    }

    // MARK: - Timer write path

    /// The currently-running interval, if any.
    public func openInterval() throws -> RunningInterval? {
        let stmt = try prepare("SELECT id, project_id, start_utc FROM intervals WHERE running = 1 LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return RunningInterval(
            id: sqlite3_column_int64(stmt, 0),
            projectID: sqlite3_column_int64(stmt, 1),
            start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        )
    }

    /// Close any open interval and open a new one for `projectID`, atomically. This is the
    /// single "context switch" operation; the DB unique index guarantees only one open row.
    public func switchTo(projectID: Int64, at now: Date = Date()) throws {
        try transaction {
            try closeOpenIntervalLocked(at: now)
            let stmt = try prepare("INSERT INTO intervals (project_id, start_utc, end_utc, running) VALUES (?, ?, NULL, 1)")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, projectID)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            try step(stmt)
        }
    }

    /// Stop the running interval (if any). No-op when nothing is running.
    public func stopOpenInterval(at now: Date = Date()) throws {
        try transaction {
            try closeOpenIntervalLocked(at: now)
        }
    }

    /// Most recent activity time per task id — powers "recently used" ordering in the palette.
    public func lastActivityByProject() throws -> [Int64: Date] {
        let stmt = try prepare("SELECT project_id, MAX(COALESCE(end_utc, start_utc)) FROM intervals GROUP BY project_id")
        defer { sqlite3_finalize(stmt) }
        var map: [Int64: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            map[id] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        }
        return map
    }

    /// Start of the earliest recorded interval, if any — bounds the "All time" range.
    public func earliestIntervalStart() throws -> Date? {
        let stmt = try prepare("SELECT MIN(start_utc) FROM intervals")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    /// Insert an already-closed interval at explicit times. For backfilling demo/history data.
    public func insertClosedInterval(projectID: Int64, start: Date, end: Date) throws {
        let stmt = try prepare("INSERT INTO intervals (project_id, start_utc, end_utc, running) VALUES (?, ?, ?, 0)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, projectID)
        sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
        try step(stmt)
    }

    private func closeOpenIntervalLocked(at now: Date) throws {
        let stmt = try prepare("UPDATE intervals SET end_utc = ?, running = 0 WHERE running = 1")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        try step(stmt)
    }

    // MARK: - Interval reads

    /// All intervals overlapping [from, to], plus any open interval. `to` defaults to distant future.
    /// Used by the Swift-side aggregation/clipping in `Aggregations`.
    public func intervals(from: Date? = nil, to: Date? = nil) throws -> [Interval] {
        var clauses: [String] = []
        if from != nil { clauses.append("(end_utc IS NULL OR end_utc > ?)") }
        if to != nil { clauses.append("start_utc < ?") }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT id, project_id, start_utc, end_utc FROM intervals \(whereClause) ORDER BY start_utc ASC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        if let from { sqlite3_bind_double(stmt, idx, from.timeIntervalSince1970); idx += 1 }
        if let to { sqlite3_bind_double(stmt, idx, to.timeIntervalSince1970); idx += 1 }

        var rows: [Interval] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let end: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            rows.append(Interval(
                id: sqlite3_column_int64(stmt, 0),
                projectID: sqlite3_column_int64(stmt, 1),
                start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                end: end
            ))
        }
        return rows
    }

    // MARK: - Transactions

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - sqlite helpers (mirrors muesli's DictationStore)

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw lastError()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError()
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError()
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: pointer)
    }

    private func lastError() -> TimesliceError {
        TimesliceError.database(
            code: sqlite3_errcode(db),
            message: String(cString: sqlite3_errmsg(db))
        )
    }
}
