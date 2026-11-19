import Foundation
import QuickBounceDomain
import QuickBounceSQLiteShim

private final class SQLiteDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

public actor SQLiteStore {
    private let databaseHandle: SQLiteDatabaseHandle
    private var database: OpaquePointer? { databaseHandle.pointer }
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let legacyISO8601Decoder: JSONDecoder

    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.legacyISO8601Decoder = JSONDecoder()
        // The default deferred representation stores Date's reference-time
        // Double and round-trips sub-second precision. ISO-8601's default
        // formatter truncates that precision, which corrupts durable model
        // equality and can make recovery journal comparisons ambiguous.
        encoder.dateEncodingStrategy = .deferredToDate
        decoder.dateDecodingStrategy = .deferredToDate
        // V0.1 development builds briefly persisted payload dates as ISO-8601
        // strings. Keep those databases readable while all new writes retain
        // deferred Date precision.
        legacyISO8601Decoder.dateDecodingStrategy = .iso8601

        let parent = self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw QuickBounceError.persistence("Unable to open SQLite database: \(message)")
        }
        guard let handle else {
            throw QuickBounceError.persistence("SQLite returned a nil database handle")
        }
        databaseHandle = SQLiteDatabaseHandle(handle)
        try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(handle, sql: "PRAGMA foreign_keys=ON;")
        try Self.execute(handle, sql: "PRAGMA synchronous=FULL;")
        try Self.migrate(handle)
    }

    private static func migrate(_ database: OpaquePointer?) throws {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS bounce_plans (
                id TEXT PRIMARY KEY,
                session_instance_id TEXT NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS bounce_jobs (
                id TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS session_restore_snapshots (
                id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                session_instance_id TEXT NOT NULL,
                restore_required INTEGER NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS restore_required_index
            ON session_restore_snapshots(restore_required);
            """,
            """
            CREATE TABLE IF NOT EXISTS artifacts (
                id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                state TEXT NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS job_events (
                id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                state TEXT NOT NULL,
                correlation_id TEXT NOT NULL,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS review_decisions (
                artifact_id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS saved_preferences (
                id TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            "INSERT OR REPLACE INTO metadata(key, value) VALUES('schema_version', '4');"
        ]
        for sql in statements {
            try execute(database, sql: sql)
        }
    }

    public func save(presetLibrary: BouncePresetLibrary) throws {
        try upsert(sql: "INSERT OR REPLACE INTO saved_preferences(id, payload, updated_at) VALUES(?, ?, ?);",
                   strings: ["bounce_presets"], payload: try encoder.encode(presetLibrary))
    }

    public func save(presetLibrary: BouncePresetLibrary, associating plans: [BouncePlan]) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            try save(presetLibrary: presetLibrary)
            for plan in plans { try save(plan: plan) }
            try Self.execute(database, sql: "COMMIT;")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func loadPresetLibrary() throws -> BouncePresetLibrary {
        try loadAll(sql: "SELECT payload FROM saved_preferences WHERE id='bounce_presets';",
                    as: BouncePresetLibrary.self).first ?? BouncePresetLibrary()
    }

    /// All-or-nothing import; a failed write leaves the queue intact.
    public func appendPlans(_ plans: [BouncePlan]) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            for plan in plans { try save(plan: plan) }
            try Self.execute(database, sql: "COMMIT;")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func save(plan: BouncePlan) throws {
        try upsert(
            sql: """
            INSERT INTO bounce_plans(id, session_instance_id, payload, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                session_instance_id=excluded.session_instance_id,
                payload=excluded.payload,
                updated_at=excluded.updated_at;
            """,
            strings: [plan.id.uuidString, plan.session.instanceID],
            payload: try encoder.encode(plan)
        )
    }

    public func loadPlans() throws -> [BouncePlan] {
        try loadAll(sql: "SELECT payload FROM bounce_plans;", as: BouncePlan.self)
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func deletePlan(id: UUID) throws {
        try executeBound(sql: "DELETE FROM bounce_plans WHERE id=?;", strings: [id.uuidString])
    }

    /// Starts a new UI workspace without discarding a pending Session recovery
    /// journal. Plans, Jobs, Review artifacts, and their events are scoped to a
    /// single QuickBounce launch in V0.1.1.
    public func clearTransientWorkspace() throws {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            let statements = [
                "DELETE FROM job_events;",
                "DELETE FROM artifacts;",
                "DELETE FROM review_decisions;",
                "DELETE FROM bounce_jobs;",
                "DELETE FROM bounce_plans;",
                "DELETE FROM session_restore_snapshots WHERE restore_required=0;"
            ]
            for statement in statements {
                try Self.execute(database, sql: statement)
            }
            try Self.execute(database, sql: "COMMIT;")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func save(job: BounceJob) throws {
        try upsert(
            sql: """
            INSERT INTO bounce_jobs(id, state, payload, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                state=excluded.state,
                payload=excluded.payload,
                updated_at=excluded.updated_at;
            """,
            strings: [job.id.uuidString, job.state.rawValue],
            payload: try encoder.encode(job)
        )
    }

    public func loadJobs() throws -> [BounceJob] {
        try loadAll(sql: "SELECT payload FROM bounce_jobs ORDER BY updated_at DESC;", as: BounceJob.self)
    }

    public func save(snapshot: SessionSnapshot) throws {
        try upsert(
            sql: """
            INSERT INTO session_restore_snapshots(id, job_id, session_instance_id, restore_required, payload, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                restore_required=excluded.restore_required,
                payload=excluded.payload,
                updated_at=excluded.updated_at;
            """,
            strings: [snapshot.id.uuidString, snapshot.jobID.uuidString, snapshot.session.instanceID],
            integers: [snapshot.restoreRequired ? 1 : 0],
            payload: try encoder.encode(snapshot)
        )
    }

    public func pendingSnapshots() throws -> [SessionSnapshot] {
        try loadAll(
            sql: "SELECT payload FROM session_restore_snapshots WHERE restore_required=1 ORDER BY updated_at ASC;",
            as: SessionSnapshot.self
        )
    }

    /// Explicitly abandons selected recovery journals. This removes only
    /// QuickBounce metadata; it never opens, changes, saves, or deletes a
    /// Pro Tools Session.
    public func discardSnapshots(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            for id in ids {
                try executeBound(
                    sql: "DELETE FROM session_restore_snapshots WHERE id=?;",
                    strings: [id.uuidString]
                )
            }
            try Self.execute(database, sql: "COMMIT;")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func save(artifact: AudioArtifact) throws {
        try upsert(
            sql: """
            INSERT INTO artifacts(id, job_id, state, payload, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                state=excluded.state,
                payload=excluded.payload,
                updated_at=excluded.updated_at;
            """,
            strings: [artifact.id.uuidString, artifact.jobID.uuidString, artifact.state.rawValue],
            payload: try encoder.encode(artifact)
        )
    }

    public func loadArtifacts(jobID: UUID? = nil) throws -> [AudioArtifact] {
        if let jobID {
            return try loadAll(
                sql: "SELECT payload FROM artifacts WHERE job_id='\(escaped(jobID.uuidString))' ORDER BY updated_at ASC;",
                as: AudioArtifact.self
            )
        }
        return try loadAll(sql: "SELECT payload FROM artifacts ORDER BY updated_at ASC;", as: AudioArtifact.self)
    }

    public func deleteArtifact(id: UUID) throws {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            try executeBound(sql: "DELETE FROM review_decisions WHERE artifact_id=?;", strings: [id.uuidString])
            try executeBound(sql: "DELETE FROM artifacts WHERE id=?;", strings: [id.uuidString])
            try Self.execute(database, sql: "COMMIT;")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func save(reviewDecision: ReviewDecision) throws {
        try upsert(
            sql: """
            INSERT INTO review_decisions(artifact_id, status, payload, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(artifact_id) DO UPDATE SET
                status=excluded.status,
                payload=excluded.payload,
                updated_at=excluded.updated_at;
            """,
            strings: [reviewDecision.artifactID.uuidString, reviewDecision.status.rawValue],
            payload: try encoder.encode(reviewDecision)
        )
    }

    public func loadReviewDecisions() throws -> [ReviewDecision] {
        try loadAll(
            sql: "SELECT payload FROM review_decisions ORDER BY updated_at ASC;",
            as: ReviewDecision.self
        )
    }

    public func append(event: JobEvent) throws {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        let sql = """
        INSERT INTO job_events(id, job_id, state, correlation_id, payload, created_at)
        VALUES(?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError("Preparing job event insert")
        }
        defer { sqlite3_finalize(statement) }
        bind(event.id.uuidString, to: statement, index: 1)
        bind(event.jobID.uuidString, to: statement, index: 2)
        bind(event.state.rawValue, to: statement, index: 3)
        bind(event.correlationID, to: statement, index: 4)
        bind(try encoder.encode(event), to: statement, index: 5)
        sqlite3_bind_double(statement, 6, event.timestamp.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("Inserting job event")
        }
    }

    public func events(jobID: UUID) throws -> [JobEvent] {
        try loadAll(
            sql: "SELECT payload FROM job_events WHERE job_id='\(escaped(jobID.uuidString))' ORDER BY created_at ASC;",
            as: JobEvent.self
        )
    }

    public func transaction<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        do {
            let result = try operation()
            try Self.execute(database, sql: "COMMIT;")
            return result
        } catch {
            try? Self.execute(database, sql: "ROLLBACK;")
            throw error
        }
    }

    private func upsert(
        sql: String,
        strings: [String],
        integers: [Int32] = [],
        payload: Data
    ) throws {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError("Preparing upsert")
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        for string in strings {
            bind(string, to: statement, index: index)
            index += 1
        }
        for integer in integers {
            sqlite3_bind_int(statement, index, integer)
            index += 1
        }
        bind(payload, to: statement, index: index)
        index += 1
        sqlite3_bind_double(statement, index, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("Executing upsert")
        }
    }

    private func executeBound(sql: String, strings: [String]) throws {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError("Preparing statement")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in strings.enumerated() {
            bind(value, to: statement, index: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("Executing statement")
        }
    }

    private func loadAll<T: Decodable>(sql: String, as type: T.Type) throws -> [T] {
        guard let database else { throw QuickBounceError.persistence("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError("Preparing query")
        }
        defer { sqlite3_finalize(statement) }

        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            do {
                values.append(try decoder.decode(T.self, from: data))
            } catch let deferredDateError {
                do {
                    values.append(try legacyISO8601Decoder.decode(T.self, from: data))
                } catch {
                    // Preserve the current-format error because it identifies
                    // the canonical schema the application expected to read.
                    throw deferredDateError
                }
            }
        }
        return values
    }

    private func bind(_ string: String, to statement: OpaquePointer, index: Int32) {
        _ = string.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) {
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func lastError(_ operation: String) -> QuickBounceError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
        if sqlite3_errcode(database) == SQLITE_FULL {
            return .insufficientDiskSpace("\(url.path): \(operation): \(message)")
        }
        return .persistence("\(operation): \(message)")
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            if sqlite3_errcode(database) == SQLITE_FULL {
                let path = sqlite3_db_filename(database, "main").map { String(cString: $0) }
                throw QuickBounceError.insufficientDiskSpace(path.map { "\($0): \(message)" } ?? message)
            }
            throw QuickBounceError.persistence(message)
        }
    }
}
