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
        // Self-stamp so every entry point (app, replay harness, tools) attributes what it writes
        // without each having to remember to set it. Same derivation sync uses, so the ids agree.
        self.localDeviceID = TimeslicePaths.deviceID(databaseURL: databaseURL)
        try open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public var resolvedDatabaseURL: URL { databaseURL }

    /// Stamped onto every interval this device records, so the timeline and session list can say
    /// which machine the time came from. Set once at startup; nil in tests/tools, which leaves
    /// `device_id` NULL (shown as unattributed rather than mis-attributed).
    public var localDeviceID: String?

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

        // Grouping: one optional project per task. NOTE the naming — the `projects` table above
        // holds TASKS (early name, never migrated), so the grouping table is `task_projects`.
        //
        // Only tasks carry the reference; intervals are untouched. That's what makes
        // re-categorising retroactive for free: the interval still points at its task, the task
        // points at a different group, and every rollup recomputes with no data migration.
        _ = sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS task_projects (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL UNIQUE,
            color_hex  TEXT NOT NULL DEFAULT '#8E8E93',
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        """, nil, nil, nil)
        // NULL = Inbox. Inbox is implicit — never a row — so there's nothing to keep in sync.
        _ = sqlite3_exec(db, "ALTER TABLE projects ADD COLUMN task_project_id INTEGER REFERENCES task_projects(id)", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_projects_task_project ON projects(task_project_id)", nil, nil, nil)

        // MARK: Sync groundwork (no networking; these just make the store merge-safe)
        //
        // `uid` is a SEPARATE sync identity, not a replacement for `id`. Local `id` stays an
        // INTEGER PRIMARY KEY so nothing in Interval/DaySegment/Identifiable has to change;
        // AUTOINCREMENT ids are only unique *per device*, so a merge keys on `uid` instead.
        for table in ["intervals", "projects", "task_projects"] {
            _ = sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN uid TEXT", nil, nil, nil)
            _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_\(table)_uid ON \(table)(uid)", nil, nil, nil)
        }

        // Which device recorded an interval. Needed so the timeline/sessions can attribute a block
        // to a machine; NULL means "recorded before this column existed" (or by an older build),
        // which the UI shows as unattributed rather than guessing.
        _ = sqlite3_exec(db, "ALTER TABLE intervals ADD COLUMN device_id TEXT", nil, nil, nil)

        // Last-write-wins needs a mutation timestamp. `created_at` can't serve: it never changes,
        // so two devices renaming the same task would have no way to order the edits.
        for table in ["projects", "task_projects"] {
            _ = sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN updated_at REAL", nil, nil, nil)
        }

        // Device labels have to persist independently of live presence: an interval recorded months
        // ago by a machine that is currently offline still needs a name in the timeline. The peer
        // list only knows devices that published recently, so it can't answer that.
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, label TEXT, last_seen REAL)", nil, nil, nil)

        // Deletes must leave a trace. `deleteProject`/`resetProjectIntervals` issue real DELETEs,
        // so without tombstones the other device's log would re-add the rows and a delete would
        // appear not to work.
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS tombstones (uid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at REAL NOT NULL)", nil, nil, nil)

        // The `UNIQUE` on task_projects.name is case-SENSITIVE, but `taskProject(named:)` looks up
        // with COLLATE NOCASE. That mismatch lets "personal" and "Personal" coexist while lookups
        // arbitrarily pick one — and a merge would create exactly that pair. A case-insensitive
        // index makes the constraint match the lookup.
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_task_projects_name_nocase ON task_projects(name COLLATE NOCASE)", nil, nil, nil)

        try backfillSyncColumns()
    }

    /// Give pre-sync rows a `uid` and `updated_at` once. Idempotent: only touches NULLs, so it's
    /// a no-op on every launch after the first.
    private func backfillSyncColumns() throws {
        let now = Date().timeIntervalSince1970
        for table in ["intervals", "projects", "task_projects"] {
            let stmt = try prepare("SELECT id FROM \(table) WHERE uid IS NULL")
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
            sqlite3_finalize(stmt)
            guard !ids.isEmpty else { continue }
            try transaction {
                for id in ids {
                    let up = try prepare("UPDATE \(table) SET uid = ? WHERE id = ?")
                    bindText(up, 1, UUID().uuidString)
                    sqlite3_bind_int64(up, 2, id)
                    try step(up)
                    sqlite3_finalize(up)
                }
            }
        }
        // Every pre-existing interval was, by definition, recorded on THIS device: attribution
        // only just started, and no other device could have written to this file before it synced.
        // Leaving them NULL would show all existing history as "unknown".
        if let localDeviceID {
            let stmt = try prepare("UPDATE intervals SET device_id = ? WHERE device_id IS NULL")
            bindText(stmt, 1, localDeviceID)
            try step(stmt)
            sqlite3_finalize(stmt)
        }

        // Seed updated_at so LWW has a baseline; real edits overwrite it.
        for table in ["projects", "task_projects"] {
            let stmt = try prepare("UPDATE \(table) SET updated_at = ? WHERE updated_at IS NULL")
            sqlite3_bind_double(stmt, 1, now)
            try step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Projects

    @discardableResult
    /// Find an existing task by name within a group, case-insensitively. `taskProjectID` nil means
    /// Inbox, and matches only other Inbox tasks — the same name in two different projects is two
    /// legitimately different tasks ("review" under `work` vs under `home`).
    ///
    /// Archived tasks are excluded: archiving is how a task is put out of the way, so silently
    /// resurrecting one would be surprising. Finished tasks DO match — a finished task is a
    /// completed instance of the same thing, so re-adding it should reopen it rather than fork the
    /// history in two.
    public func task(named name: String, inGroup taskProjectID: Int64?) throws -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let groupClause = taskProjectID == nil ? "task_project_id IS NULL" : "task_project_id = ?"
        let stmt = try prepare("SELECT id FROM projects WHERE name = ? COLLATE NOCASE "
                               + "AND archived = 0 AND \(groupClause) LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, trimmed)
        if let taskProjectID { sqlite3_bind_int64(stmt, 2, taskProjectID) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        return try listProjects(includeArchived: true).first { $0.id == id }
    }

    /// Create a task, or reuse the one that already has this name in the same group.
    ///
    /// Reuse rather than duplicate, mirroring how `upsertTaskProject` treats groups: typing a name
    /// you already have almost always means "this thing again", and a twin task splits its history
    /// across two rows that both show partial totals. Cross-device twins are a separate problem —
    /// neither device can see the other's tasks until a sync, and tasks never merge by name.
    ///
    /// A reused task is unfinished on return, so re-adding a completed task reopens it.
    public func createProject(name: String, colorHex: String,
                             inGroup taskProjectID: Int64? = nil) throws -> Int64 {
        if let existing = try task(named: name, inGroup: taskProjectID) {
            if existing.finished { try setProjectFinished(id: existing.id, finished: false) }
            return existing.id
        }
        let sql = "INSERT INTO projects (name, color_hex, sort_order, uid, updated_at) VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM projects), ?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        bindText(stmt, 3, UUID().uuidString)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func renameProject(id: Int64, name: String) throws {
        let stmt = try prepare("UPDATE projects SET name = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    public func setProjectColor(id: Int64, colorHex: String) throws {
        let stmt = try prepare("UPDATE projects SET color_hex = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, colorHex)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    public func setProjectArchived(id: Int64, archived: Bool) throws {
        let stmt = try prepare("UPDATE projects SET archived = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, archived ? 1 : 0)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    /// Mark finished/unfinished, stamping when it happened so Today can drop it tomorrow.
    public func setProjectFinished(id: Int64, finished: Bool, at date: Date = Date()) throws {
        let stmt = try prepare("UPDATE projects SET finished = ?, finished_at = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, finished ? 1 : 0)
        if finished { sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 4, id)
        try step(stmt)
    }

    /// Delete all of a task's intervals (reset its tracked time to zero) but keep the task.
    public func resetProjectIntervals(id: Int64) throws {
        try transaction {
            for uid in try intervalUIDsLocked(projectID: id) {
                try recordTombstoneLocked(uid: uid, kind: "interval")
            }
            let stmt = try prepare("DELETE FROM intervals WHERE project_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
    }

    /// Delete ONE interval. Destructive: this removes recorded time, and there's no undo.
    ///
    /// Refuses to delete the RUNNING interval — the timer would keep ticking against a row that no
    /// longer exists, and the engine's restore-on-launch would find nothing. Stop the timer first.
    /// Returns false if the id doesn't exist or is the running one.
    @discardableResult
    public func deleteInterval(id: Int64) throws -> Bool {
        var deleted = false
        try transaction {
            let check = try prepare("SELECT running FROM intervals WHERE id = ?")
            sqlite3_bind_int64(check, 1, id)
            let found = sqlite3_step(check) == SQLITE_ROW
            let running = found && sqlite3_column_int(check, 0) == 1
            sqlite3_finalize(check)
            guard found, !running else { return }

            // Tombstone before deleting — afterwards the uid is gone, and without it the other
            // device's log would simply re-add the row on the next sync.
            try recordTombstoneLocked(uid: try uidLocked(table: "intervals", id: id), kind: "interval")
            let stmt = try prepare("DELETE FROM intervals WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
            deleted = true
        }
        return deleted
    }

    /// Permanently delete a project and all its intervals. Destructive — removes time history.
    public func deleteProject(id: Int64) throws {
        try transaction {
            // Tombstone before deleting — afterwards the uids are gone.
            try recordTombstoneLocked(uid: try uidLocked(table: "projects", id: id), kind: "task")
            for uid in try intervalUIDsLocked(projectID: id) {
                try recordTombstoneLocked(uid: uid, kind: "interval")
            }
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



    // MARK: - Sync introspection

    /// Rows carrying a sync uid. Public so tests can assert the invariant that every row has one.
    public func uidCount(table: String) throws -> Int {
        try scalarInt("SELECT count(uid) FROM \(table)")
    }

    public func distinctUIDCount(table: String) throws -> Int {
        try scalarInt("SELECT count(DISTINCT uid) FROM \(table)")
    }

    /// LWW timestamp for a row, nil if unset.
    public func updatedAt(table: String, id: Int64) throws -> TimeInterval? {
        let stmt = try prepare("SELECT updated_at FROM \(table) WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }


    // MARK: - Merge primitives (used by sync; no networking here)

    /// Every interval with its sync uid — the export half of a sync payload.
    public func intervalsWithUIDs() throws -> [(interval: Interval, uid: String)] {
        let stmt = try prepare("SELECT id, project_id, start_utc, end_utc, uid, device_id FROM intervals WHERE uid IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        var out: [(Interval, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let iv = Interval(
                id: sqlite3_column_int64(stmt, 0),
                projectID: sqlite3_column_int64(stmt, 1),
                start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                end: sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                deviceID: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : text(stmt, 5)
            )
            out.append((iv, text(stmt, 4)))
        }
        return out
    }

    public func uidsPresent(table: String) throws -> Set<String> {
        let stmt = try prepare("SELECT uid FROM \(table) WHERE uid IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(text(stmt, 0)) }
        return out
    }

    /// Local id for a uid, if we already have that row.
    public func localID(table: String, uid: String) throws -> Int64? {
        let stmt = try prepare("SELECT id FROM \(table) WHERE uid = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, uid)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Insert a task that came from another device, preserving its uid so both sides agree on
    /// identity. Tasks are NOT merged by name: two devices may legitimately have distinct tasks
    /// with the same name, and fusing them would mix unrelated time irreversibly.
    @discardableResult
    public func insertRemoteTask(uid: String, name: String, colorHex: String, sortOrder: Int,
                                 archived: Bool, finished: Bool, finishedAt: Date?,
                                 taskProjectID: Int64?, updatedAt: TimeInterval) throws -> Int64 {
        let stmt = try prepare("""
            INSERT INTO projects (name, color_hex, sort_order, archived, finished, finished_at,
                                  task_project_id, uid, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        sqlite3_bind_int(stmt, 4, archived ? 1 : 0)
        sqlite3_bind_int(stmt, 5, finished ? 1 : 0)
        if let finishedAt { sqlite3_bind_double(stmt, 6, finishedAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 6) }
        if let taskProjectID { sqlite3_bind_int64(stmt, 7, taskProjectID) } else { sqlite3_bind_null(stmt, 7) }
        bindText(stmt, 8, uid)
        sqlite3_bind_double(stmt, 9, updatedAt)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Insert a closed interval from another device under its own uid. Never inserts a *running*
    /// interval: only one timer runs across all devices, and liveness is handled separately.
    /// `deviceID` is the device that ORIGINALLY recorded it, not the one merging — otherwise every
    /// interval would end up attributed to whichever device happened to sync it.
    public func insertRemoteInterval(uid: String, projectID: Int64, start: Date, end: Date,
                                     deviceID: String? = nil) throws {
        let stmt = try prepare("INSERT INTO intervals (project_id, start_utc, end_utc, running, uid, device_id) VALUES (?, ?, ?, 0, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, projectID)
        sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
        bindText(stmt, 4, uid)
        if let deviceID { bindText(stmt, 5, deviceID) } else { sqlite3_bind_null(stmt, 5) }
        try step(stmt)
    }

    /// Apply a remote task edit if it's newer than ours (last-write-wins on `updated_at`).
    /// Returns true when the remote version won.
    @discardableResult
    /// `taskProjectID` is included: without it, moving a task between projects never propagated —
    /// every other field synced while the assignment stayed pinned to whatever each device had.
    public func applyRemoteTaskEdit(uid: String, name: String, colorHex: String, archived: Bool,
                                    finished: Bool, finishedAt: Date?, taskProjectID: Int64?,
                                    remoteUpdatedAt: TimeInterval) throws -> Bool {
        guard let id = try localID(table: "projects", uid: uid) else { return false }
        let mine = try updatedAt(table: "projects", id: id) ?? 0
        guard remoteUpdatedAt > mine else { return false }
        let stmt = try prepare("""
            UPDATE projects SET name = ?, color_hex = ?, archived = ?, finished = ?,
                                finished_at = ?, task_project_id = ?, updated_at = ? WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        sqlite3_bind_int(stmt, 3, archived ? 1 : 0)
        sqlite3_bind_int(stmt, 4, finished ? 1 : 0)
        if let finishedAt { sqlite3_bind_double(stmt, 5, finishedAt.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 5) }
        if let taskProjectID { sqlite3_bind_int64(stmt, 6, taskProjectID) }
        else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_double(stmt, 7, remoteUpdatedAt)
        sqlite3_bind_int64(stmt, 8, id)
        try step(stmt)
        return true
    }

    /// Delete whatever a remote tombstone refers to, and keep the tombstone so it propagates on.
    /// Apply a remote PROJECT edit if newer (LWW). Renames must not collide with the
    /// case-insensitive unique index, so a clashing name is left alone rather than throwing.
    @discardableResult
    public func applyRemoteProjectEdit(uid: String, name: String, colorHex: String,
                                       sortOrder: Int, remoteUpdatedAt: TimeInterval) throws -> Bool {
        guard let id = try localID(table: "task_projects", uid: uid) else { return false }
        let mine = try updatedAt(table: "task_projects", id: id) ?? 0
        guard remoteUpdatedAt > mine else { return false }
        // A different project already holding this name would violate the unique index.
        if let clash = try taskProject(named: name), clash.id != id { return false }
        let stmt = try prepare("""
            UPDATE task_projects SET name = ?, color_hex = ?, sort_order = ?, updated_at = ?
            WHERE id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name.trimmingCharacters(in: .whitespaces))
        bindText(stmt, 2, colorHex)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        sqlite3_bind_double(stmt, 4, remoteUpdatedAt)
        sqlite3_bind_int64(stmt, 5, id)
        try step(stmt)
        return true
    }

    public func applyRemoteTombstone(uid: String, kind: String, deletedAt: TimeInterval) throws {
        try transaction {
            let table = kind == "interval" ? "intervals" : (kind == "task" ? "projects" : "task_projects")
            if let id = try localID(table: table, uid: uid) {
                if table == "projects" {
                    // Deleting a task takes its intervals with it, same as a local delete.
                    let d = try prepare("DELETE FROM intervals WHERE project_id = ?")
                    sqlite3_bind_int64(d, 1, id)
                    try step(d)
                    sqlite3_finalize(d)
                }
                if table == "task_projects" {
                    // Release tasks still sitting in this group BEFORE removing it, mirroring
                    // `deleteTaskProject`. Without this the DELETE violated
                    // projects.task_project_id -> task_projects(id) and threw SQLITE_CONSTRAINT,
                    // aborting the whole merge transaction — so one deleted group anywhere stopped
                    // that device syncing at all until the group came back.
                    //
                    // Only rows pointing AT this group are touched, so a task moved elsewhere in
                    // the meantime keeps its new group.
                    let clear = try prepare("UPDATE projects SET task_project_id = NULL, updated_at = ? WHERE task_project_id = ?")
                    sqlite3_bind_double(clear, 1, Date().timeIntervalSince1970)
                    sqlite3_bind_int64(clear, 2, id)
                    try step(clear)
                    sqlite3_finalize(clear)
                }
                let del = try prepare("DELETE FROM \(table) WHERE id = ?")
                sqlite3_bind_int64(del, 1, id)
                try step(del)
                sqlite3_finalize(del)
            }
            let t = try prepare("INSERT OR REPLACE INTO tombstones (uid, kind, deleted_at) VALUES (?, ?, ?)")
            bindText(t, 1, uid)
            bindText(t, 2, kind)
            sqlite3_bind_double(t, 3, deletedAt)
            try step(t)
            sqlite3_finalize(t)
        }
    }

    /// A task's uid, for building a payload.
    public func uid(table: String, id: Int64) throws -> String? {
        try uidLocked(table: table, id: id)
    }

    // MARK: - Tombstones (so deletes survive a merge)

    /// Record that `uid` was deleted. Without this, the other device's log re-adds the row on the
    /// next merge and the delete silently undoes itself.
    private func recordTombstoneLocked(uid: String?, kind: String) throws {
        guard let uid else { return }   // pre-migration row with no uid: nothing to tombstone
        let stmt = try prepare("INSERT OR REPLACE INTO tombstones (uid, kind, deleted_at) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, uid)
        bindText(stmt, 2, kind)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        try step(stmt)
    }

    private func intervalUIDsLocked(projectID: Int64) throws -> [String] {
        let stmt = try prepare("SELECT uid FROM intervals WHERE project_id = ? AND uid IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, projectID)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
        return out
    }

    private func uidLocked(table: String, id: Int64) throws -> String? {
        let stmt = try prepare("SELECT uid FROM \(table) WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return text(stmt, 0)
    }


    /// Tombstones as payload records.
    public func tombstoneRecords() throws -> [SyncPayload.TombstoneRecord] {
        let stmt = try prepare("SELECT uid, kind, deleted_at FROM tombstones")
        defer { sqlite3_finalize(stmt) }
        var out: [SyncPayload.TombstoneRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(.init(uid: text(stmt, 0), kind: text(stmt, 1),
                             deletedAt: sqlite3_column_double(stmt, 2)))
        }
        return out
    }

    /// uids of everything deleted locally — the delete half of a sync payload.
    public func tombstoneUIDs(kind: String? = nil) throws -> [String] {
        let sql = kind == nil
            ? "SELECT uid FROM tombstones"
            : "SELECT uid FROM tombstones WHERE kind = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let kind { bindText(stmt, 1, kind) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(text(stmt, 0)) }
        return out
    }

    // MARK: - Task projects (grouping above tasks)

    /// Find-or-create by name, so "assign to a group" and "create a group" are one action.
    @discardableResult
    public func upsertTaskProject(name: String, colorHex: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing = try taskProject(named: trimmed) { return existing.id }
        let stmt = try prepare("""
            INSERT INTO task_projects (name, color_hex, sort_order, uid, updated_at)
            VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM task_projects), ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, trimmed)
        bindText(stmt, 2, colorHex)
        bindText(stmt, 3, UUID().uuidString)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func taskProject(named name: String) throws -> TaskProject? {
        let stmt = try prepare("SELECT id, name, color_hex, sort_order FROM task_projects WHERE name = ? COLLATE NOCASE")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name.trimmingCharacters(in: .whitespaces))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return TaskProject(id: sqlite3_column_int64(stmt, 0), name: text(stmt, 1),
                           colorHex: text(stmt, 2), sortOrder: Int(sqlite3_column_int(stmt, 3)))
    }

    public func listTaskProjects() throws -> [TaskProject] {
        let stmt = try prepare("SELECT id, name, color_hex, sort_order FROM task_projects ORDER BY sort_order ASC, id ASC")
        defer { sqlite3_finalize(stmt) }
        var rows: [TaskProject] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(TaskProject(id: sqlite3_column_int64(stmt, 0), name: text(stmt, 1),
                                    colorHex: text(stmt, 2), sortOrder: Int(sqlite3_column_int(stmt, 3))))
        }
        return rows
    }

    /// Move a task into a group, or to Inbox with `nil`. Intervals are never touched, so this
    /// retroactively re-buckets all of the task's history.
    public func setTaskProject(taskID: Int64, taskProjectID: Int64?) throws {
        let stmt = try prepare("UPDATE projects SET task_project_id = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        if let taskProjectID { sqlite3_bind_int64(stmt, 1, taskProjectID) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, taskID)
        try step(stmt)
    }

    /// Persist a new display order for groups (index in `orderedIDs` becomes `sort_order`).
    public func setTaskProjectOrder(_ orderedIDs: [Int64]) throws {
        try transaction {
            for (index, id) in orderedIDs.enumerated() {
                let stmt = try prepare("UPDATE task_projects SET sort_order = ?, updated_at = ? WHERE id = ?")
                sqlite3_bind_int(stmt, 1, Int32(index))
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, id)
                try step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Insert a project from another device PRESERVING its uid, so both sides share one identity.
    ///
    /// `upsertTaskProject` mints a fresh uid, which meant a merged project had a different uid on
    /// each device — so later renames could never be matched by uid and arrived as new projects
    /// instead, leaving duplicates behind.
    @discardableResult
    public func insertRemoteTaskProject(uid: String, name: String, colorHex: String,
                                       sortOrder: Int, updatedAt: TimeInterval) throws -> Int64 {
        let stmt = try prepare("""
            INSERT INTO task_projects (name, color_hex, sort_order, uid, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name.trimmingCharacters(in: .whitespaces))
        bindText(stmt, 2, colorHex)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        bindText(stmt, 4, uid)
        sqlite3_bind_double(stmt, 5, updatedAt)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Adopt a remote uid for a project we matched by NAME, so the two devices converge on one
    /// identity and subsequent renames match by uid instead of duplicating.
    public func adoptTaskProjectUID(id: Int64, uid: String) throws {
        let stmt = try prepare("UPDATE task_projects SET uid = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, uid)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    public func renameTaskProject(id: Int64, name: String) throws {
        let stmt = try prepare("UPDATE task_projects SET name = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name.trimmingCharacters(in: .whitespaces))
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    public func setTaskProjectColor(id: Int64, colorHex: String) throws {
        let stmt = try prepare("UPDATE task_projects SET color_hex = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, colorHex)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    /// Delete a group. Its tasks fall back to Inbox — deleting a grouping must never delete
    /// tracked time.
    public func deleteTaskProject(id: Int64) throws {
        try transaction {
            let clear = try prepare("UPDATE projects SET task_project_id = NULL, updated_at = ? WHERE task_project_id = ?")
            sqlite3_bind_double(clear, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(clear, 2, id)
            try step(clear)
            sqlite3_finalize(clear)

            try recordTombstoneLocked(uid: try uidLocked(table: "task_projects", id: id),
                                      kind: "task_project")
            let del = try prepare("DELETE FROM task_projects WHERE id = ?")
            sqlite3_bind_int64(del, 1, id)
            try step(del)
            sqlite3_finalize(del)
        }
    }

    public func setProjectOrder(id: Int64, sortOrder: Int) throws {
        let stmt = try prepare("UPDATE projects SET sort_order = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(sortOrder))
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    public func listProjects(includeArchived: Bool = false) throws -> [Project] {
        let sql = """
        SELECT id, name, color_hex, sort_order, archived, finished, finished_at, task_project_id
        FROM projects
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
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                taskProjectID: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(stmt, 7)
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
            let stmt = try prepare("INSERT INTO intervals (project_id, start_utc, end_utc, running, uid, device_id) VALUES (?, ?, NULL, 1, ?, ?)")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, projectID)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            bindText(stmt, 3, UUID().uuidString)
            if let localDeviceID { bindText(stmt, 4, localDeviceID) } else { sqlite3_bind_null(stmt, 4) }
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
    public func insertClosedInterval(projectID: Int64, start: Date, end: Date,
                                     deviceID: String? = nil) throws {
        let stmt = try prepare("INSERT INTO intervals (project_id, start_utc, end_utc, running, uid, device_id) VALUES (?, ?, ?, 0, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, projectID)
        sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
        bindText(stmt, 4, UUID().uuidString)
        if let d = deviceID ?? localDeviceID { bindText(stmt, 5, d) } else { sqlite3_bind_null(stmt, 5) }
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
        let sql = "SELECT id, project_id, start_utc, end_utc, device_id FROM intervals \(whereClause) ORDER BY start_utc ASC"
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
                end: end,
                deviceID: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return rows
    }

    /// Correct the device on an interval we already hold, keyed by uid. Returns true if it changed.
    ///
    /// Needed because attribution was backfilled to "the local device" for every pre-existing row,
    /// which is right for rows this device recorded but wrong for ones it had already merged from a
    /// peer. Only the originating device knows the truth, and it says so in its payload — so the
    /// next sync repairs the guess.
    @discardableResult
    public func reattributeInterval(uid: String, deviceID: String) throws -> Bool {
        let stmt = try prepare("UPDATE intervals SET device_id = ? WHERE uid = ? AND device_id IS NOT ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, deviceID)
        bindText(stmt, 2, uid)
        bindText(stmt, 3, deviceID)
        try step(stmt)
        return sqlite3_changes(db) > 0
    }

    // MARK: - Device labels

    /// Remember a device's human-facing name so historical intervals stay attributable after that
    /// device goes offline. Called whenever a peer publishes.
    public func rememberDevice(id: String, label: String?, lastSeen: Date = Date()) throws {
        // COALESCE keeps a previously-known label when a payload arrives without one, rather than
        // blanking the name of a device the user already named.
        let sql = "INSERT INTO devices (device_id, label, last_seen) VALUES (?, ?, ?) "
            + "ON CONFLICT(device_id) DO UPDATE SET "
            + "label = COALESCE(excluded.label, devices.label), "
            + "last_seen = MAX(excluded.last_seen, devices.last_seen)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        if let label, !label.isEmpty { bindText(stmt, 2, label) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_double(stmt, 3, lastSeen.timeIntervalSince1970)
        try step(stmt)
    }

    /// device_id -> label for every device ever seen. Devices with no label are absent.
    public func deviceLabels() throws -> [String: String] {
        let stmt = try prepare("SELECT device_id, label FROM devices WHERE label IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        var map: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            map[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return map
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
