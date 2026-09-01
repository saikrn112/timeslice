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

        // MARK: Tags and targets
        //
        // A tag is a flat label attached to a PROJECT or an individual TASK; a task inherits its
        // project's tags. Deliberately not a third level in the hierarchy — tags overlap freely and
        // don't have to cover everything, so nothing new has to be filled in when creating a task.
        //
        // `subject_kind` + `subject_id` rather than two nullable columns: one link row shape, and
        // adding a future subject type doesn't change the schema.
        _ = sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS tags (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                color_hex  TEXT NOT NULL DEFAULT '#8E8E93',
                sort_order INTEGER NOT NULL DEFAULT 0,
                uid        TEXT,
                updated_at REAL,
                created_at TEXT DEFAULT (datetime('now'))
            )
            """, nil, nil, nil)
        // Case-insensitive uniqueness, matching how task_projects learned it the hard way: a
        // case-SENSITIVE constraint lets "Office" and "office" coexist while lookups pick one
        // arbitrarily, and a merge would create exactly that pair.
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name_nocase ON tags(name COLLATE NOCASE)", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_uid ON tags(uid)", nil, nil, nil)

        _ = sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS tag_links (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                tag_id       INTEGER NOT NULL REFERENCES tags(id),
                subject_kind TEXT NOT NULL,          -- 'task' | 'project'
                subject_id   INTEGER NOT NULL,
                uid          TEXT,
                updated_at   REAL
            )
            """, nil, nil, nil)
        // One link per (tag, subject) — re-tagging must be idempotent rather than piling up rows.
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tag_links_unique ON tag_links(tag_id, subject_kind, subject_id)", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tag_links_uid ON tag_links(uid)", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tag_links_subject ON tag_links(subject_kind, subject_id)", nil, nil, nil)

        // A target can point at a task, a project OR a tag, so a per-project budget needs no tag
        // and a cross-project one needs no restructuring.
        _ = sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS targets (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                subject_kind TEXT NOT NULL,          -- 'task' | 'project' | 'tag'
                subject_id   INTEGER NOT NULL,
                seconds      REAL NOT NULL,
                direction    TEXT NOT NULL,          -- 'atLeast' | 'atMost'
                period       TEXT NOT NULL,          -- 'day' | 'week' | 'month'
                uid          TEXT,
                updated_at   REAL
            )
            """, nil, nil, nil)
        // Manual ordering for the allocations list. Backfilled from rowid so existing rows keep the
        // order they already appeared in rather than jumping around on first launch.
        _ = sqlite3_exec(db, "ALTER TABLE targets ADD COLUMN sort_order INTEGER", nil, nil, nil)
        _ = sqlite3_exec(db, "UPDATE targets SET sort_order = id WHERE sort_order IS NULL", nil, nil, nil)

        // When an allocation started and, once retired, when it finished. Needed for the historical
        // "allocated vs spent" view: without a start there's no span to measure over.
        //
        // created_at backfills to NOW for existing rows rather than to their real creation time,
        // which isn't recorded. Their history therefore begins today — wrong but bounded, and the
        // alternative (guessing) would be worse.
        _ = sqlite3_exec(db, "ALTER TABLE targets ADD COLUMN created_at REAL", nil, nil, nil)
        _ = sqlite3_exec(db, "ALTER TABLE targets ADD COLUMN completed_at REAL", nil, nil, nil)
        _ = sqlite3_exec(db, "UPDATE targets SET created_at = strftime('%s','now') WHERE created_at IS NULL", nil, nil, nil)

        // ONE target per subject — the period is a property of it, not part of its identity.
        //
        // Scoped to LIVE allocations only: retiring one and starting a fresh allocation for the same
        // subject later is the normal case, and a plain unique index would forbid it.
        _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_targets_one_per_subject", nil, nil, nil)
        //
        // Keying on (subject, period) meant changing the period in the editor INSERTED a second
        // target instead of moving the existing one, and the editor only ever showed the first: the
        // extra became invisible and un-editable while still appearing in the metrics list. It also
        // let one subject carry contradictory budgets ("<=1h/week" and ">=1h/day" at once).
        //
        // Collapse any pre-existing duplicates first, keeping the newest (the latest intent) — the
        // unique index below would otherwise fail and leave the old one in place.
        _ = sqlite3_exec(db, "DELETE FROM targets WHERE id NOT IN (SELECT MAX(id) FROM targets GROUP BY subject_kind, subject_id)", nil, nil, nil)
        _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_targets_subject", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_targets_one_live_per_subject ON targets(subject_kind, subject_id) WHERE completed_at IS NULL", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_targets_uid ON targets(uid)", nil, nil, nil)

        // Notes written while using the app. Its own table rather than a flag on an existing
        // row: a note has no duration and is never aggregated, so keeping it out of the
        // interval tables means it cannot accidentally land in a time total.
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS feedback (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, device_id TEXT, created_at REAL NOT NULL, resolved_at REAL, uid TEXT, updated_at REAL)", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_feedback_uid ON feedback(uid)", nil, nil, nil)

        try backfillSyncColumns()
    }

    /// Give pre-sync rows a `uid` and `updated_at` once. Idempotent: only touches NULLs, so it's
    /// a no-op on every launch after the first.
    private func backfillSyncColumns() throws {
        let now = Date().timeIntervalSince1970
        // tags/tag_links/targets included: a row with no uid can't be addressed by a peer, so it
        // would stay invisible to sync forever.
        for table in ["intervals", "projects", "task_projects", "tags", "tag_links", "targets",
                      "feedback"] {
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
        for table in ["projects", "task_projects", "tags", "tag_links", "targets", "feedback"] {
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
        // `inGroup` also ASSIGNS the group, not just scopes the duplicate lookup. Doing only the
        // lookup meant a caller that forgot the follow-up `setTaskProject` created the task in Inbox
        // while believing it was filed — and the next create with the same name then didn't match it.
        let sql = "INSERT INTO projects (name, color_hex, sort_order, task_project_id, uid, updated_at) VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM projects), ?, ?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        if let taskProjectID { sqlite3_bind_int64(stmt, 3, taskProjectID) }
        else { sqlite3_bind_null(stmt, 3) }
        bindText(stmt, 4, UUID().uuidString)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
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
            try detachSubjectLocked(.task(id))
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

    /// Every value of a single TEXT column. Used to collect uids before deleting their rows.
    private func scalarTexts(_ sql: String) throws -> [String] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL { out.append(text(stmt, 0)) }
        }
        return out
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
            let table: String
            switch kind {
            case "interval": table = "intervals"
            case "task": table = "projects"
            case "task_project": table = "task_projects"
            case "tag": table = "tags"
            case "tag_link": table = "tag_links"
            case "target": table = "targets"
            case "feedback": table = "feedback"
            default: return          // an unknown kind from a newer build: record it, touch nothing
            }
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
                if table == "tags" {
                    // Drop what POINTS AT the tag before the tag itself: tag_links.tag_id is a
                    // foreign key and keys are ON, so deleting the tag first throws — the same trap
                    // that broke a remote group delete, and with the same blast radius, since the
                    // merge is one transaction and the violation aborts all of it.
                    for sql in ["DELETE FROM tag_links WHERE tag_id = ?",
                                "DELETE FROM targets WHERE subject_kind = 'tag' AND subject_id = ?"] {
                        let d = try prepare(sql)
                        sqlite3_bind_int64(d, 1, id)
                        try step(d)
                        sqlite3_finalize(d)
                    }
                }
                if table == "projects" || table == "task_projects" {
                    // A deleted task or project can still be a tag link's or a budget's subject.
                    // Those aren't foreign keys (subject_id is polymorphic) so they wouldn't throw —
                    // they'd linger pointing at a row that no longer exists, and an unresolvable
                    // target silently vanishes from the UI while sitting in the database.
                    let kindName = table == "projects" ? "task" : "project"
                    for t in ["tag_links", "targets"] {
                        let d = try prepare("DELETE FROM \(t) WHERE subject_kind = ? AND subject_id = ?")
                        bindText(d, 1, kindName)
                        sqlite3_bind_int64(d, 2, id)
                        try step(d)
                        sqlite3_finalize(d)
                    }
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

            try detachSubjectLocked(.project(id))
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

    /// Remove tag links and targets belonging to a subject that's being deleted.
    ///
    /// Without this a deleted project left its target behind, and a target whose subject no longer
    /// resolves is dropped from the UI — so it looked like the budget had vanished while the row was
    /// still in the database, unreachable and un-editable.
    private func detachSubjectLocked(_ subject: TargetSubject) throws {
        for (table, kind) in [("tag_links", "tag_link"), ("targets", "target")] {
            let sql = "SELECT uid FROM \(table) WHERE subject_kind = '\(subject.kind)' "
                + "AND subject_id = \(subject.id) AND uid IS NOT NULL"
            for uid in try scalarTexts(sql) { try recordTombstoneLocked(uid: uid, kind: kind) }
        }
        for sql in ["DELETE FROM tag_links WHERE subject_kind = ? AND subject_id = ?",
                    "DELETE FROM targets WHERE subject_kind = ? AND subject_id = ?"] {
            let stmt = try prepare(sql)
            bindText(stmt, 1, subject.kind)
            sqlite3_bind_int64(stmt, 2, subject.id)
            try step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Tags

    /// All tags, in sort order.
    public func listTags() throws -> [Tag] {
        let stmt = try prepare("SELECT id, name, color_hex, sort_order FROM tags ORDER BY sort_order, name COLLATE NOCASE")
        defer { sqlite3_finalize(stmt) }
        var out: [Tag] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Tag(id: sqlite3_column_int64(stmt, 0), name: text(stmt, 1),
                           colorHex: text(stmt, 2), sortOrder: Int(sqlite3_column_int(stmt, 3))))
        }
        return out
    }

    public func tag(named name: String) throws -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let stmt = try prepare("SELECT id FROM tags WHERE name = ? COLLATE NOCASE LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, trimmed)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        return try listTags().first { $0.id == id }
    }

    /// Create a tag, or return the existing one with that name. Reuse rather than duplicate, for the
    /// same reason projects do it: two tags called "office" would silently split their totals.
    @discardableResult
    public func upsertTag(name: String, colorHex: String) throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing = try tag(named: trimmed) { return existing.id }
        let stmt = try prepare("INSERT INTO tags (name, color_hex, sort_order, uid, updated_at) VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tags), ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, trimmed)
        bindText(stmt, 2, colorHex)
        bindText(stmt, 3, UUID().uuidString)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func renameTag(id: Int64, name: String) throws {
        let stmt = try prepare("UPDATE tags SET name = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name.trimmingCharacters(in: .whitespaces))
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    public func setTagColor(id: Int64, colorHex: String) throws {
        let stmt = try prepare("UPDATE tags SET color_hex = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, colorHex)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    /// Delete a tag, its links and any target pointing at it.
    ///
    /// Links and targets go first: `tag_links.tag_id` references `tags(id)` and foreign keys are ON,
    /// so removing the tag first would throw — the same trap that broke a remote group delete.
    public func deleteTag(id: Int64) throws {
        try transaction {
            // Tombstone before deleting — afterwards the uids are gone and the peer's copy would
            // simply come back on the next merge.
            try recordTombstoneLocked(uid: try uidLocked(table: "tags", id: id), kind: "tag")
            for uid in try scalarTexts("SELECT uid FROM tag_links WHERE tag_id = \(id) AND uid IS NOT NULL") {
                try recordTombstoneLocked(uid: uid, kind: "tag_link")
            }
            for uid in try scalarTexts("SELECT uid FROM targets WHERE subject_kind = 'tag' AND subject_id = \(id) AND uid IS NOT NULL") {
                try recordTombstoneLocked(uid: uid, kind: "target")
            }
            for (sql, bindTag) in [("DELETE FROM tag_links WHERE tag_id = ?", true),
                                   ("DELETE FROM targets WHERE subject_kind = 'tag' AND subject_id = ?", true),
                                   ("DELETE FROM tags WHERE id = ?", true)] {
                _ = bindTag
                let stmt = try prepare(sql)
                sqlite3_bind_int64(stmt, 1, id)
                try step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Tag links

    /// Attach a tag to a task or project. Idempotent — re-tagging can't pile up duplicate rows.
    public func addTag(_ tagID: Int64, to subject: TargetSubject) throws {
        let stmt = try prepare("INSERT OR IGNORE INTO tag_links (tag_id, subject_kind, subject_id, uid, updated_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, tagID)
        bindText(stmt, 2, subject.kind)
        sqlite3_bind_int64(stmt, 3, subject.id)
        bindText(stmt, 4, UUID().uuidString)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        try step(stmt)
    }

    public func removeTag(_ tagID: Int64, from subject: TargetSubject) throws {
        try transaction {
            let sql = "SELECT uid FROM tag_links WHERE tag_id = \(tagID) AND "
                + "subject_kind = '\(subject.kind)' AND subject_id = \(subject.id) AND uid IS NOT NULL"
            for uid in try scalarTexts(sql) { try recordTombstoneLocked(uid: uid, kind: "tag_link") }
            let stmt = try prepare("DELETE FROM tag_links WHERE tag_id = ? AND subject_kind = ? AND subject_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, tagID)
            bindText(stmt, 2, subject.kind)
            sqlite3_bind_int64(stmt, 3, subject.id)
            try step(stmt)
        }
    }

    /// Tag ids directly attached to a subject (no inheritance).
    public func tagIDs(for subject: TargetSubject) throws -> [Int64] {
        let stmt = try prepare("SELECT tag_id FROM tag_links WHERE subject_kind = ? AND subject_id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, subject.kind)
        sqlite3_bind_int64(stmt, 2, subject.id)
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    /// Effective tags per TASK id, including those inherited from the task's project.
    ///
    /// One query rather than per-task lookups: this feeds the metrics breakdown, which would
    /// otherwise issue a query per task on every recompute.
    public func effectiveTagIDsByTask() throws -> [Int64: Set<Int64>] {
        var out: [Int64: Set<Int64>] = [:]
        // Directly tagged tasks.
        let direct = try prepare("SELECT subject_id, tag_id FROM tag_links WHERE subject_kind = 'task'")
        while sqlite3_step(direct) == SQLITE_ROW {
            out[sqlite3_column_int64(direct, 0), default: []].insert(sqlite3_column_int64(direct, 1))
        }
        sqlite3_finalize(direct)
        // Inherited from the task's project.
        let inherited = try prepare("""
            SELECT p.id, l.tag_id FROM projects p
            JOIN tag_links l ON l.subject_kind = 'project' AND l.subject_id = p.task_project_id
            """)
        while sqlite3_step(inherited) == SQLITE_ROW {
            out[sqlite3_column_int64(inherited, 0), default: []].insert(sqlite3_column_int64(inherited, 1))
        }
        sqlite3_finalize(inherited)
        return out
    }

    // MARK: - Targets

    /// Allocations. LIVE ones by default — a retired allocation shouldn't reappear in the section
    /// that asks "am I on track", only in history.
    public func listTargets(includeCompleted: Bool = false) throws -> [Target] {
        let sql = "SELECT id, subject_kind, subject_id, seconds, direction, period, "
            + "COALESCE(created_at, 0), completed_at, COALESCE(sort_order, id) FROM targets"
            + (includeCompleted ? "" : " WHERE completed_at IS NULL")
            + " ORDER BY COALESCE(sort_order, id)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [Target] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let subject = TargetSubject(kind: text(stmt, 1), id: sqlite3_column_int64(stmt, 2)),
                  let direction = Target.Direction(rawValue: text(stmt, 4)),
                  let period = Target.Period(rawValue: text(stmt, 5)) else { continue }
            out.append(Target(id: sqlite3_column_int64(stmt, 0), subject: subject,
                              seconds: sqlite3_column_double(stmt, 3),
                              direction: direction, period: period,
                              createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                              completedAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                                  ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                              sortOrder: Int(sqlite3_column_int(stmt, 8))))
        }
        return out
    }

    /// Move an allocation up or down among the LIVE ones by swapping with its neighbour.
    ///
    /// A swap rather than renumbering the whole list: one UPDATE pair per move, and it can't drift
    /// out of step with what's on screen.
    public func moveTarget(id: Int64, up: Bool) throws {
        let live = try listTargets()
        guard let i = live.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i - 1 : i + 1
        guard live.indices.contains(j) else { return }
        try transaction {
            for (target, order) in [(live[i], live[j].sortOrder), (live[j], live[i].sortOrder)] {
                let stmt = try prepare("UPDATE targets SET sort_order = ?, updated_at = ? WHERE id = ?")
                sqlite3_bind_int(stmt, 1, Int32(order))
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, target.id)
                try step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Persist an explicit order for the live allocations, by position in `orderedIDs`.
    ///
    /// Used by drag-and-drop, where a row can land anywhere — `moveTarget` only swaps neighbours,
    /// which can't express "moved to the top".
    public func reorderTargets(_ orderedIDs: [Int64]) throws {
        try transaction {
            for (index, id) in orderedIDs.enumerated() {
                let stmt = try prepare("UPDATE targets SET sort_order = ?, updated_at = ? WHERE id = ?")
                sqlite3_bind_int(stmt, 1, Int32(index))
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_int64(stmt, 3, id)
                try step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Retire an allocation, or bring it back. Never deletes: the point is to keep it for history.
    public func setTargetCompleted(id: Int64, completed: Bool, at when: Date = Date()) throws {
        let stmt = try prepare("UPDATE targets SET completed_at = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        if completed { sqlite3_bind_double(stmt, 1, when.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    /// Create or replace the target for a subject. Exactly one per subject: changing the amount,
    /// direction OR period edits that single row rather than adding another.
    @discardableResult
    public func setTarget(subject: TargetSubject, seconds: TimeInterval,
                          direction: Target.Direction, period: Target.Period) throws -> Int64 {
        // The conflict target names the partial index's predicate too, so this upserts against the
        // LIVE allocation and a retired one for the same subject is left alone.
        let sql = "INSERT INTO targets (subject_kind, subject_id, seconds, direction, period, uid, updated_at, created_at, sort_order) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM targets)) "
            + "ON CONFLICT(subject_kind, subject_id) WHERE completed_at IS NULL DO UPDATE SET "
            + "seconds = excluded.seconds, direction = excluded.direction, "
            + "period = excluded.period, updated_at = excluded.updated_at"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, subject.kind)
        sqlite3_bind_int64(stmt, 2, subject.id)
        sqlite3_bind_double(stmt, 3, seconds)
        bindText(stmt, 4, direction.rawValue)
        bindText(stmt, 5, period.rawValue)
        bindText(stmt, 6, UUID().uuidString)
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func deleteTarget(id: Int64) throws {
        try transaction {
            try recordTombstoneLocked(uid: try uidLocked(table: "targets", id: id), kind: "target")
            let stmt = try prepare("DELETE FROM targets WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
    }

    // MARK: - Tag / target merge primitives

    /// The table a subject kind lives in, so a uid can be resolved to a local id.
    public static func table(forSubjectKind kind: String) -> String? {
        switch kind {
        case "task": return "projects"
        case "project": return "task_projects"
        case "tag": return "tags"
        default: return nil
        }
    }

    /// Insert a tag from another device PRESERVING its uid, so both sides share one identity.
    @discardableResult
    public func insertRemoteTag(uid: String, name: String, colorHex: String, sortOrder: Int,
                                updatedAt: TimeInterval) throws -> Int64 {
        let stmt = try prepare("INSERT INTO tags (name, color_hex, sort_order, uid, updated_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        bindText(stmt, 4, uid)
        sqlite3_bind_double(stmt, 5, updatedAt)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Apply a remote tag edit if it's newer (last-write-wins on `updated_at`).
    @discardableResult
    public func applyRemoteTagEdit(uid: String, name: String, colorHex: String, sortOrder: Int,
                                   remoteUpdatedAt: TimeInterval) throws -> Bool {
        guard let id = try localID(table: "tags", uid: uid) else { return false }
        guard remoteUpdatedAt > (try updatedAt(table: "tags", id: id) ?? 0) else { return false }
        let stmt = try prepare("UPDATE tags SET name = ?, color_hex = ?, sort_order = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        bindText(stmt, 2, colorHex)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        sqlite3_bind_double(stmt, 4, remoteUpdatedAt)
        sqlite3_bind_int64(stmt, 5, id)
        try step(stmt)
        return true
    }

    /// Adopt a remote uid for a tag matched by NAME, so the two devices converge on one identity —
    /// otherwise later renames arrive as brand-new tags. Same rule projects already use.
    public func adoptTagUID(id: Int64, uid: String) throws {
        let stmt = try prepare("UPDATE tags SET uid = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, uid)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    /// Insert a tag link from another device, preserving its uid. Idempotent on (tag, subject).
    public func insertRemoteTagLink(uid: String, tagID: Int64, subject: TargetSubject,
                                    updatedAt: TimeInterval) throws {
        let stmt = try prepare("INSERT OR IGNORE INTO tag_links (tag_id, subject_kind, subject_id, uid, updated_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, tagID)
        bindText(stmt, 2, subject.kind)
        sqlite3_bind_int64(stmt, 3, subject.id)
        bindText(stmt, 4, uid)
        sqlite3_bind_double(stmt, 5, updatedAt)
        try step(stmt)
    }

    /// Apply a remote budget: insert, or overwrite ours when the remote is newer.
    ///
    /// Keyed on the SUBJECT, not the uid — there's one budget per subject, so two devices that each
    /// created one for the same tag are describing the same thing and must converge rather than
    /// fight the unique index.
    @discardableResult
    public func applyRemoteTarget(uid: String, subject: TargetSubject, seconds: TimeInterval,
                                  direction: Target.Direction, period: Target.Period,
                                  remoteUpdatedAt: TimeInterval,
                                  createdAt: TimeInterval? = nil,
                                  completedAt: TimeInterval? = nil) throws -> Bool {
        // By UID first — that's the row's identity. Matching on the subject alone broke as soon as
        // the done state existed: a REOPENED allocation has no live row for its subject here, so the
        // subject lookup missed and the insert collided with the uid we already held.
        var mineID: Int64?
        var mineUpdated: Double = 0
        let byUID = try prepare("SELECT id, COALESCE(updated_at, 0) FROM targets WHERE uid = ? LIMIT 1")
        bindText(byUID, 1, uid)
        if sqlite3_step(byUID) == SQLITE_ROW {
            mineID = sqlite3_column_int64(byUID, 0)
            mineUpdated = sqlite3_column_double(byUID, 1)
        }
        sqlite3_finalize(byUID)

        if mineID == nil {
            // No row with that uid: fall back to the LIVE allocation for this subject, which is the
            // convergence case — two devices each set one up independently, so they're the same
            // intention under different uids.
            let bySubject = try prepare("SELECT id, COALESCE(updated_at, 0) FROM targets WHERE subject_kind = ? AND subject_id = ? AND completed_at IS NULL LIMIT 1")
            bindText(bySubject, 1, subject.kind)
            sqlite3_bind_int64(bySubject, 2, subject.id)
            if sqlite3_step(bySubject) == SQLITE_ROW {
                mineID = sqlite3_column_int64(bySubject, 0)
                mineUpdated = sqlite3_column_double(bySubject, 1)
            }
            sqlite3_finalize(bySubject)
        }

        if let mineID {
            guard remoteUpdatedAt > mineUpdated else { return false }
            let stmt = try prepare("UPDATE targets SET seconds = ?, direction = ?, period = ?, uid = ?, updated_at = ?, completed_at = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, seconds)
            bindText(stmt, 2, direction.rawValue)
            bindText(stmt, 3, period.rawValue)
            bindText(stmt, 4, uid)
            sqlite3_bind_double(stmt, 5, remoteUpdatedAt)
            if let completedAt { sqlite3_bind_double(stmt, 6, completedAt) }
            else { sqlite3_bind_null(stmt, 6) }
            sqlite3_bind_int64(stmt, 7, mineID)
            try step(stmt)
            return true
        }
        let stmt = try prepare("INSERT INTO targets (subject_kind, subject_id, seconds, direction, period, uid, updated_at, created_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, subject.kind)
        sqlite3_bind_int64(stmt, 2, subject.id)
        sqlite3_bind_double(stmt, 3, seconds)
        bindText(stmt, 4, direction.rawValue)
        bindText(stmt, 5, period.rawValue)
        bindText(stmt, 6, uid)
        sqlite3_bind_double(stmt, 7, remoteUpdatedAt)
        // Fall back to the sender's update time when it predates created_at — better than "now",
        // which would restart the history of an allocation that has been running for weeks.
        sqlite3_bind_double(stmt, 8, createdAt ?? remoteUpdatedAt)
        if let completedAt { sqlite3_bind_double(stmt, 9, completedAt) }
        else { sqlite3_bind_null(stmt, 9) }
        try step(stmt)
        return true
    }

    /// Tag links with their uids and both ends resolved to uids — the export half.
    public func tagLinksForExport() throws -> [(uid: String, tagUID: String, subjectKind: String,
                                                subjectUID: String, updatedAt: TimeInterval)] {
        let sql = "SELECT l.uid, t.uid, l.subject_kind, l.subject_id, COALESCE(l.updated_at, 0) "
            + "FROM tag_links l JOIN tags t ON t.id = l.tag_id "
            + "WHERE l.uid IS NOT NULL AND t.uid IS NOT NULL"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String, String, String, TimeInterval)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = text(stmt, 2)
            guard let table = Self.table(forSubjectKind: kind),
                  let subjectUID = try uidLocked(table: table, id: sqlite3_column_int64(stmt, 3))
            else { continue }   // subject has no uid yet: it'll travel on a later sync
            out.append((text(stmt, 0), text(stmt, 1), kind, subjectUID,
                        sqlite3_column_double(stmt, 4)))
        }
        return out
    }

    /// Budgets with their subject resolved to a uid — the export half.
    public func targetsForExport() throws -> [(uid: String, subjectKind: String, subjectUID: String,
                                               seconds: TimeInterval, direction: String,
                                               period: String, updatedAt: TimeInterval,
                                               createdAt: TimeInterval, completedAt: TimeInterval?)] {
        // Completed ones travel too: history is the point of keeping them, so a peer must learn both
        // that an allocation ended and when.
        let stmt = try prepare("SELECT uid, subject_kind, subject_id, seconds, direction, period, COALESCE(updated_at, 0), COALESCE(created_at, 0), completed_at FROM targets WHERE uid IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String, String, TimeInterval, String, String, TimeInterval,
                   TimeInterval, TimeInterval?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = text(stmt, 1)
            guard let table = Self.table(forSubjectKind: kind),
                  let subjectUID = try uidLocked(table: table, id: sqlite3_column_int64(stmt, 2))
            else { continue }
            out.append((text(stmt, 0), kind, subjectUID, sqlite3_column_double(stmt, 3),
                        text(stmt, 4), text(stmt, 5), sqlite3_column_double(stmt, 6),
                        sqlite3_column_double(stmt, 7),
                        sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)))
        }
        return out
    }

    /// Tags with their uids — the export half.
    public func tagsWithUIDs() throws -> [(tag: Tag, uid: String, updatedAt: TimeInterval)] {
        let stmt = try prepare("SELECT id, name, color_hex, sort_order, uid, COALESCE(updated_at, 0) FROM tags WHERE uid IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        var out: [(Tag, String, TimeInterval)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tag = Tag(id: sqlite3_column_int64(stmt, 0), name: text(stmt, 1),
                          colorHex: text(stmt, 2), sortOrder: Int(sqlite3_column_int(stmt, 3)))
            out.append((tag, text(stmt, 4), sqlite3_column_double(stmt, 5)))
        }
        return out
    }

    // MARK: - Feedback

    /// Newest first — a note list is read from the top.
    public func listFeedback(includeResolved: Bool = true) throws -> [Feedback] {
        let sql = "SELECT id, text, device_id, created_at, resolved_at FROM feedback"
            + (includeResolved ? "" : " WHERE resolved_at IS NULL")
            + " ORDER BY created_at DESC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [Feedback] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Feedback(
                id: sqlite3_column_int64(stmt, 0),
                text: text(stmt, 1),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                deviceID: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : text(stmt, 2),
                resolvedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))))
        }
        return out
    }

    /// Record a note. Stamped with the local device so "where was I" is answerable later.
    @discardableResult
    public func addFeedback(_ body: String, at when: Date = Date()) throws -> Int64? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let stmt = try prepare("INSERT INTO feedback (text, device_id, created_at, uid, updated_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, trimmed)
        if let localDeviceID { bindText(stmt, 2, localDeviceID) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_double(stmt, 3, when.timeIntervalSince1970)
        bindText(stmt, 4, UUID().uuidString)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Reword a note. Bumps `updated_at`, so the edit wins over a peer's older copy.
    public func updateFeedback(id: Int64, text body: String) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // clearing it would silently destroy the note
        let stmt = try prepare("UPDATE feedback SET text = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, trimmed)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    public func setFeedbackResolved(id: Int64, resolved: Bool, at when: Date = Date()) throws {
        let stmt = try prepare("UPDATE feedback SET resolved_at = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        if resolved { sqlite3_bind_double(stmt, 1, when.timeIntervalSince1970) }
        else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, id)
        try step(stmt)
    }

    /// Really delete one — for a note written by mistake. Tombstoned, or the peer re-adds it.
    public func deleteFeedback(id: Int64) throws {
        try transaction {
            try recordTombstoneLocked(uid: try uidLocked(table: "feedback", id: id), kind: "feedback")
            let stmt = try prepare("DELETE FROM feedback WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
    }

    /// The export half: notes with their uids.
    public func feedbackForExport() throws -> [(uid: String, text: String, deviceID: String?,
                                                createdAt: TimeInterval, resolvedAt: TimeInterval?,
                                                updatedAt: TimeInterval)] {
        let stmt = try prepare("SELECT uid, text, device_id, created_at, resolved_at, COALESCE(updated_at, 0) FROM feedback WHERE uid IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String, String?, TimeInterval, TimeInterval?, TimeInterval)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((text(stmt, 0), text(stmt, 1),
                        sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : text(stmt, 2),
                        sqlite3_column_double(stmt, 3),
                        sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4),
                        sqlite3_column_double(stmt, 5)))
        }
        return out
    }

    /// Insert or update a note from a peer, keyed on its uid, newest write winning.
    @discardableResult
    public func applyRemoteFeedback(uid: String, text body: String, deviceID: String?,
                                    createdAt: TimeInterval, resolvedAt: TimeInterval?,
                                    remoteUpdatedAt: TimeInterval) throws -> Bool {
        if let id = try localID(table: "feedback", uid: uid) {
            guard remoteUpdatedAt > (try updatedAt(table: "feedback", id: id) ?? 0) else { return false }
            let stmt = try prepare("UPDATE feedback SET text = ?, resolved_at = ?, updated_at = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, body)
            if let resolvedAt { sqlite3_bind_double(stmt, 2, resolvedAt) } else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_double(stmt, 3, remoteUpdatedAt)
            sqlite3_bind_int64(stmt, 4, id)
            try step(stmt)
            return true
        }
        let stmt = try prepare("INSERT INTO feedback (text, device_id, created_at, resolved_at, uid, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, body)
        if let deviceID { bindText(stmt, 2, deviceID) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_double(stmt, 3, createdAt)
        if let resolvedAt { sqlite3_bind_double(stmt, 4, resolvedAt) } else { sqlite3_bind_null(stmt, 4) }
        bindText(stmt, 5, uid)
        sqlite3_bind_double(stmt, 6, remoteUpdatedAt)
        try step(stmt)
        return true
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
