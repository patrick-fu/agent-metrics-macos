import Foundation
import SQLite3
import Darwin

struct ResetCleanupOperations: @unchecked Sendable {
    var removeItem: (URL) throws -> Void
    var beforeStagingManagedRoots: () throws -> Void
    var beforeManagedRootMove: (Int) throws -> Void

    init(
        removeItem: @escaping (URL) throws -> Void,
        beforeStagingManagedRoots: @escaping () throws -> Void = {},
        beforeManagedRootMove: @escaping (Int) throws -> Void = { _ in }
    ) {
        self.removeItem = removeItem
        self.beforeStagingManagedRoots = beforeStagingManagedRoots
        self.beforeManagedRootMove = beforeManagedRootMove
    }

    static let live = ResetCleanupOperations(
        removeItem: { try FileManager.default.removeItem(at: $0) }
    )
}

public final class SQLiteFactStore: @unchecked Sendable {
    private static let telemetryTableNames = [
        "observations", "usage_observations",
        "facts", "usage_facts", "performance_facts",
        "rollups", "daily_rollups", "daily_usage_rollups",
        "cursors", "ingestion_cursors", "watermarks",
        "source_state", "source_states",
        "opaque_identities", "diagnostics", "telemetry_diagnostics",
        "snapshots", "runtime_snapshots", "snapshot_caches",
        "retention_metadata", "app_managed_exports", "migration_backups",
        "app_managed_artifacts",
    ]
    private static let preservedResetTableNames: Set<String> = [
        "schema_metadata",
        "telemetry_table_registry",
        "reset_cleanup_journal",
        "preferences",
        "app_preferences",
        "user_preferences",
        "telemetry_reset_metadata",
    ]

    private var database: OpaquePointer?
    private let databaseURL: URL
    private let resetCleanupOperations: ResetCleanupOperations
    private let capacityReclaimProbe: (() -> Void)?

    public convenience init(url: URL) throws {
        try self.init(url: url, resetCleanupOperations: .live)
    }

    convenience init(url: URL, capacityReclaimProbe: @escaping () -> Void) throws {
        try self.init(
            url: url,
            resetCleanupOperations: .live,
            capacityReclaimProbe: capacityReclaimProbe
        )
    }

    init(
        url: URL,
        resetCleanupOperations: ResetCleanupOperations,
        capacityReclaimProbe: (() -> Void)? = nil
    ) throws {
        databaseURL = url
        self.resetCleanupOperations = resetCleanupOperations
        self.capacityReclaimProbe = capacityReclaimProbe
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, database != nil else {
            throw StoreError.openFailed(status)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS usage_facts (
                id TEXT PRIMARY KEY,
                schema_version TEXT NOT NULL,
                coding_agent_raw TEXT NOT NULL,
                coding_agent_display TEXT NOT NULL,
                model_raw TEXT NOT NULL,
                model_display TEXT NOT NULL,
                session_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                observed_at REAL NOT NULL,
                output_tokens INTEGER NOT NULL,
                measurement_quality TEXT NOT NULL,
                authority TEXT NOT NULL,
                definition_version TEXT NOT NULL,
                input_uncached INTEGER,
                cache_read INTEGER,
                cache_write INTEGER,
                output_visible INTEGER,
                reasoning INTEGER,
                normalized_burn_total INTEGER,
                model_call_id TEXT,
                model_call_capability TEXT,
                source_channel TEXT,
                authority_tier TEXT,
                measurement_granularity TEXT,
                measurement_range_start REAL,
                measurement_range_end REAL,
                source_id TEXT,
                superseded_by TEXT
            );
            """
        )
        try migrateUsageFacts()
        try exec("CREATE INDEX IF NOT EXISTS usage_facts_observed_at ON usage_facts(observed_at);")
        try exec("CREATE INDEX IF NOT EXISTS usage_facts_source_observed_at ON usage_facts(source_id, observed_at);")
        try createPerformanceFactsTable()
        try migratePerformanceFactsIfNeeded()
        try exec("CREATE INDEX IF NOT EXISTS performance_facts_observed_at ON performance_facts(observed_at);")
        try exec("CREATE INDEX IF NOT EXISTS performance_facts_source_observed_at ON performance_facts(source_id, observed_at);")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS source_states (
                source_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            );
            """
        )
        try createDailyUsageRollupsTable()
        try createRetentionMetadataTable()
        try createSchemaMetadataTable()
        try createManagedArtifactsTable()
        try createTelemetryTableRegistry()
        try createResetCleanupJournalTable()
        try createTelemetryResetMetadataTable()
        _ = try? retryPendingResetCleanup()
    }

    deinit {
        sqlite3_close(database)
    }

    public func replaceAll(_ facts: [UsageFact]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM usage_facts;")
            for fact in facts {
                try insert(fact)
            }
            try markSupersededAuthorityFacts()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func upsert(_ facts: [UsageFact]) throws {
        guard !facts.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for fact in facts {
                try insert(fact, replace: true)
            }
            try markSupersededAuthorityFacts()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func deleteFacts(schemaVersion: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec(
                "DELETE FROM usage_facts WHERE schema_version = '\(escapeSQL(schemaVersion))';"
            )
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func deleteFacts(idPrefix: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec(
                "DELETE FROM usage_facts WHERE id LIKE '\(escapeSQL(idPrefix))%';"
            )
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    public func deleteSupersededFacts() throws -> Int {
        let before = sqlite3_total_changes(database)
        try exec("DELETE FROM usage_facts WHERE superseded_by IS NOT NULL;")
        return Int(sqlite3_total_changes(database) - before)
    }

    public func sourceState(sourceID: String) throws -> SourceState? {
        var statement: OpaquePointer?
        let sql = "SELECT payload FROM source_states WHERE source_id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sourceID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let payload = text(statement, 0)
        guard let data = payload.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(SourceState.self, from: data)
    }

    public func saveSourceState(_ state: SourceState) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try writeSourceState(state)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func applyIncremental(
        facts: [UsageFact],
        deleting scopes: [SourceFactScope],
        state: SourceState,
        failureInjection: (() throws -> Void)? = nil
    ) throws {
        try applyIncrementalChunk(
            facts: facts,
            deleting: scopes,
            finalState: state,
            failureInjection: failureInjection
        )
    }

    func applyIncrementalChunk(
        facts: [UsageFact],
        deleting scopes: [SourceFactScope],
        finalState: SourceState?,
        failureInjection: (() throws -> Void)? = nil
    ) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            for scope in scopes {
                try deleteFacts(in: scope)
            }
            for fact in facts {
                try insert(fact, replace: true)
            }
            try markSupersededAuthorityFacts()
            try failureInjection?()
            if let finalState { try writeSourceState(finalState) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func writeSourceState(_ state: SourceState) throws {
        let data = try JSONEncoder().encode(state)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw StoreError.insertFailed
        }
        try exec("DELETE FROM source_states WHERE source_id = '\(escapeSQL(state.sourceID))';")
        let sql = "INSERT INTO source_states (source_id, payload) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, state.sourceID)
        bind(statement, 2, payload)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.insertFailed
        }
    }

    public func allFacts() throws -> [UsageFact] {
        try query("SELECT * FROM usage_facts ORDER BY observed_at ASC, id ASC;")
    }

    public func upsertPerformanceFacts(_ facts: [PerformanceFact]) throws {
        guard !facts.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for fact in facts { try insertPerformance(fact) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func allPerformanceFacts() throws -> [PerformanceFact] {
        let sql = "SELECT * FROM performance_facts ORDER BY observed_at ASC, stable_request_id ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        var facts: [PerformanceFact] = []
        while sqlite3_step(statement) == SQLITE_ROW { facts.append(try performanceRow(statement)) }
        return facts
    }

    /// Counts logical Fact rows and every on-disk SQLite file that contributes
    /// to the store's actual capacity: the database, WAL, and shared-memory sidecar.
    public func capacity() throws -> StoreCapacity {
        let factCount = try rowCount(in: "usage_facts")
            + rowCount(in: "performance_facts")
            + rowCount(in: "daily_usage_rollups")
        let bytes = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
            .reduce(Int64(0)) { total, path in
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                return total + size
            }
        return StoreCapacity(bytes: bytes, factCount: factCount)
    }

    /// Predicts the physical footprint after one checkpoint/VACUUM without
    /// performing either operation. Retention can finish all ordered bulk
    /// deletions first and reclaim disk exactly once.
    func projectedCapacityAfterReclaim() throws -> StoreCapacity {
        let current = try capacity()
        let pageSize = try pragmaInt64("page_size")
        let pageCount = try pragmaInt64("page_count")
        let freePages = try pragmaInt64("freelist_count")
        let compactedDatabaseBytes = max(0, pageCount - freePages) * pageSize
        let sharedMemoryBytes = (try? FileManager.default.attributesOfItem(
            atPath: databaseURL.path + "-shm"
        )[.size] as? NSNumber)?.int64Value ?? 0
        return StoreCapacity(
            bytes: compactedDatabaseBytes + sharedMemoryBytes,
            factCount: current.factCount
        )
    }

    private func rowCount(in table: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func pragmaInt64(_ name: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name);", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
        return sqlite3_column_int64(statement, 0)
    }

    func reclaimCapacity() throws {
        capacityReclaimProbe?()
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try exec("VACUUM;")
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Atomically builds new daily rollups and consumes their complete raw
    /// backing set. Raw that appears after compaction is retained separately;
    /// it can neither overwrite nor be added to totals that can no longer be
    /// proven complete.
    @discardableResult
    public func compactDailyRollups(olderThan cutoff: Date) throws -> Int {
        try processDailyRollups(olderThan: cutoff, consumingRaw: true)
    }

    /// Rebuilds invalidated buckets only while their complete raw backing set
    /// still exists. The invalidated row is deleted before recomputation.
    @discardableResult
    public func rebuildDailyRollups(olderThan cutoff: Date) throws -> Int {
        try processDailyRollups(olderThan: cutoff, consumingRaw: false)
    }

    private func processDailyRollups(olderThan cutoff: Date, consumingRaw: Bool) throws -> Int {
        let day: TimeInterval = 24 * 60 * 60
        let fullBucketCutoff = floor(cutoff.timeIntervalSince1970 / day) * day
        let bucketStarts = try distinctBucketStarts(before: fullBucketCutoff)
        guard !bucketStarts.isEmpty else { return 0 }
        let prunedBefore = try retentionMetadata().retentionPrunedBefore?.timeIntervalSince1970

        try exec("BEGIN IMMEDIATE;")
        do {
            var consumed = 0
            for bucketStart in bucketStarts {
                let bucketEnd = bucketStart + day
                let facts = try query(
                    """
                    SELECT * FROM usage_facts
                    WHERE observed_at >= ? AND observed_at < ?
                    ORDER BY observed_at ASC, id ASC;
                    """,
                    binds: [bucketStart, bucketEnd]
                )
                guard !facts.isEmpty else { continue }
                let hadInvalidatedRollup = try hasDailyRollup(bucketStart: bucketStart)
                if let prunedBefore, bucketStart < prunedBefore {
                    if hadInvalidatedRollup {
                        try exec(
                            "UPDATE daily_usage_rollups SET coverage = 'partial' WHERE bucket_start = \(bucketStart);"
                        )
                    }
                    continue
                }
                if consumingRaw, hadInvalidatedRollup {
                    try exec(
                        "UPDATE daily_usage_rollups SET coverage = 'partial' WHERE bucket_start = \(bucketStart);"
                    )
                    continue
                }
                try exec("DELETE FROM daily_usage_rollups WHERE bucket_start = \(bucketStart);")
                for rollup in Self.makeDailyRollups(
                    facts: facts,
                    bucketStart: Date(timeIntervalSince1970: bucketStart),
                    coverage: .complete
                ) {
                    try insert(rollup)
                }
                if consumingRaw {
                    try exec(
                        "DELETE FROM usage_facts WHERE observed_at >= \(bucketStart) AND observed_at < \(bucketEnd);"
                    )
                }
                consumed += facts.count
            }
            try exec("COMMIT;")
            return consumed
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func dailyRollups() throws -> [DailyUsageRollup] {
        let sql = "SELECT * FROM daily_usage_rollups ORDER BY bucket_start ASC, id ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        var rows: [DailyUsageRollup] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(try dailyRollupRow(statement)) }
        return rows
    }

    public func retentionMetadata() throws -> RetentionMetadata {
        let sql = """
            SELECT retention_pruned_before, earliest_retained_at, ingestion_paused, diagnostic_code
            FROM retention_metadata WHERE singleton = 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return RetentionMetadata() }
        return RetentionMetadata(
            retentionPrunedBefore: optionalDate(statement, 0),
            earliestRetainedAt: optionalDate(statement, 1),
            ingestionPaused: sqlite3_column_int(statement, 2) != 0,
            diagnosticCode: optionalText(statement, 3)
        )
    }

    public func telemetryResetCutoff() throws -> Date? {
        var statement: OpaquePointer?
        let sql = "SELECT cutoff FROM telemetry_reset_metadata WHERE singleton = 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func retentionCoverage(in interval: DateInterval) throws -> Coverage {
        guard let prunedBefore = try retentionMetadata().retentionPrunedBefore,
              interval.start <= prunedBefore else { return .complete }
        return .partial
    }

    func factCount(since date: Date) throws -> Int {
        let sql = """
            SELECT
                (SELECT COUNT(*) FROM usage_facts WHERE observed_at >= ?) +
                (SELECT COUNT(*) FROM performance_facts WHERE observed_at >= ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func unprotectedFactCount(before date: Date) throws -> Int {
        let sql = """
            SELECT
                (SELECT COUNT(*) FROM usage_facts WHERE observed_at < ?) +
                (SELECT COUNT(*) FROM performance_facts WHERE observed_at < ?) +
                (SELECT COUNT(*) FROM daily_usage_rollups);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @discardableResult
    func deleteOldestRawFacts(from lowerBound: Date, before upperBound: Date, limit: Int) throws -> Int {
        guard limit > 0 else { return 0 }
        try exec("BEGIN IMMEDIATE;")
        do {
            let sql = """
                SELECT kind, identity, observed_at FROM (
                    SELECT 'usage' AS kind, id AS identity, observed_at FROM usage_facts
                    UNION ALL
                    SELECT 'performance' AS kind, CAST(rowid AS TEXT) AS identity, observed_at FROM performance_facts
                )
                WHERE observed_at >= ? AND observed_at < ?
                ORDER BY observed_at ASC, kind ASC, identity ASC
                LIMIT \(limit);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw StoreError.prepareFailed }
            sqlite3_bind_double(statement, 1, lowerBound.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, upperBound.timeIntervalSince1970)
            var selected: [(kind: String, identity: String)] = []
            var prunedBefore: Date?
            while sqlite3_step(statement) == SQLITE_ROW {
                selected.append((text(statement, 0), text(statement, 1)))
                let observedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                prunedBefore = max(prunedBefore ?? observedAt, observedAt)
            }
            sqlite3_finalize(statement)
            guard let prunedBefore, !selected.isEmpty else {
                try exec("COMMIT;")
                return 0
            }
            for row in selected {
                if row.kind == "usage" {
                    try exec("DELETE FROM usage_facts WHERE id = '\(escapeSQL(row.identity))';")
                } else if let rowID = Int64(row.identity) {
                    try exec("DELETE FROM performance_facts WHERE rowid = \(rowID);")
                }
            }
            try recordPruning(before: prunedBefore)
            try exec("COMMIT;")
            return selected.count
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    func deleteOldestDailyRollups(limit: Int) throws -> Int {
        guard limit > 0 else { return 0 }
        var statement: OpaquePointer?
        let selection = """
            SELECT id, bucket_end FROM daily_usage_rollups
            ORDER BY bucket_start ASC, id ASC LIMIT \(limit);
            """
        guard sqlite3_prepare_v2(database, selection, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        var ids: [String] = []
        var prunedBefore: Date?
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(text(statement, 0))
            let end = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            prunedBefore = max(prunedBefore ?? end, end)
        }
        sqlite3_finalize(statement)
        guard let prunedBefore, !ids.isEmpty else { return 0 }

        try exec("BEGIN IMMEDIATE;")
        do {
            for id in ids {
                try exec("DELETE FROM daily_usage_rollups WHERE id = '\(escapeSQL(id))';")
            }
            try recordPruning(before: prunedBefore)
            try exec("COMMIT;")
            return ids.count
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func setRetentionPause(_ paused: Bool, diagnosticCode: String?) throws {
        let metadata = try retentionMetadata()
        guard metadata.ingestionPaused != paused || metadata.diagnosticCode != diagnosticCode else { return }
        try writeRetentionMetadata(RetentionMetadata(
            retentionPrunedBefore: metadata.retentionPrunedBefore,
            earliestRetainedAt: try earliestRetainedAt(),
            ingestionPaused: paused,
            diagnosticCode: diagnosticCode
        ))
    }

    /// The single destructive store API. It clears telemetry rows in one
    /// transaction and only removes managed files rooted beside this database.
    /// Coding Agent logs and user-saved exports outside that root are out of scope.
    public func resetTelemetryData(at cutoff: Date = Date()) throws -> TelemetryResetResult {
        let fileManager = FileManager.default
        let root = databaseURL.deletingLastPathComponent().standardizedFileURL
        let tablesToClear = try classifiedTelemetryTables()
        let managedRootURLs = [
            root.appendingPathComponent("exports", isDirectory: true),
            root.appendingPathComponent("migration-backups", isDirectory: true),
        ]
        let stagingRoot = root.appendingPathComponent(".telemetry-reset-\(UUID().uuidString)", isDirectory: true)
        let staged = try stageManagedRootEntries(
            managedRootURLs,
            root: root,
            stagingRoot: stagingRoot
        )

        do {
            try exec("PRAGMA secure_delete=ON;")
            try exec("BEGIN IMMEDIATE;")
            for table in tablesToClear {
                try exec("DELETE FROM \(quotedIdentifier(table));")
            }
            try writeTelemetryResetCutoff(cutoff)
            if !staged.isEmpty {
                try insertResetCleanupTask(
                    id: "artifact-\(UUID().uuidString)",
                    kind: "staging",
                    path: stagingRoot.path
                )
            }
            try insertResetCleanupTask(id: "space-reclaim", kind: "space-reclaim", path: nil)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            for item in staged.reversed() where entryExistsNoFollow(item.staged) {
                try? renameEntryNoFollow(from: item.staged, to: item.original)
            }
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }

        let cleanupPending = (try? retryPendingResetCleanup()) ?? true
        return TelemetryResetResult(cleanupState: cleanupPending ? .pending : .complete)
    }

    public func registerManagedTelemetryArtifact(_ url: URL, kind: String) throws {
        let root = databaseURL.deletingLastPathComponent().standardizedFileURL
        let standardized = try validatedManagedArtifactURL(url, root: root)
        let sql = "INSERT OR REPLACE INTO app_managed_artifacts (path, kind) VALUES (?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, standardized.path)
        bind(statement, 2, kind)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    /// Future migrations register telemetry tables that do not use the
    /// reserved `telemetry_` namespace. Reset fails closed for unclassified
    /// tables, so a migration cannot silently leave new telemetry behind.
    func registerTelemetryTableForReset(_ tableName: String) throws {
        guard !tableName.isEmpty,
              !tableName.hasPrefix("sqlite_"),
              try tableExists(tableName) else {
            throw StoreError.invalidResetTableRegistration(tableName)
        }
        let sql = "INSERT OR REPLACE INTO telemetry_table_registry (table_name) VALUES (?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, tableName)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    public func performanceFactWindow(in interval: DateInterval, limit: Int) throws -> PerformanceFactWindow {
        let boundedLimit = max(1, limit)
        let counts = try performanceFactCounts(in: interval)
        let allocations = Self.allocate(counts: counts, limit: boundedLimit)
        var rows: [PerformanceFact] = []
        for sourceID in allocations.keys.sorted() {
            guard let allocation = allocations[sourceID], allocation > 0 else { continue }
            rows.append(contentsOf: try performanceFacts(
                sourceID: sourceID,
                in: interval,
                limit: allocation
            ))
        }
        rows.sort {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.codingAgent.rawValue != $1.codingAgent.rawValue {
                return $0.codingAgent.rawValue < $1.codingAgent.rawValue
            }
            if $0.stableRequestID != $1.stableRequestID {
                return $0.stableRequestID < $1.stableRequestID
            }
            return $0.measurementGranularity.rawValue < $1.measurementGranularity.rawValue
        }
        let truncatedSourceIDs = Set(counts.compactMap { sourceID, count in
            count > allocations[sourceID, default: 0] ? sourceID : nil
        })
        return PerformanceFactWindow(
            rows: rows,
            isTruncated: !truncatedSourceIDs.isEmpty,
            truncatedSourceIDs: truncatedSourceIDs
        )
    }

    private func performanceFacts(
        sourceID: String,
        in interval: DateInterval,
        limit: Int
    ) throws -> [PerformanceFact] {
        let sql = """
            SELECT * FROM (
                SELECT * FROM performance_facts
                WHERE source_id = ? AND observed_at >= ? AND observed_at <= ?
                ORDER BY observed_at DESC, coding_agent_raw DESC,
                         stable_request_id DESC, measurement_granularity DESC
                LIMIT \(limit)
            )
            ORDER BY observed_at ASC, coding_agent_raw ASC,
                     stable_request_id ASC, measurement_granularity ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sourceID)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        var rows: [PerformanceFact] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(try performanceRow(statement)) }
        return rows
    }

    public func performanceFactColumnNames() throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(performance_facts);", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(text(statement, 1)) }
        return names
    }

    public func facts(in interval: DateInterval, limit: Int? = nil) throws -> [UsageFact] {
        guard let limit else {
            return try query(
                """
                SELECT * FROM usage_facts
                WHERE observed_at >= ? AND observed_at <= ?
                ORDER BY observed_at ASC, id ASC;
                """,
                binds: [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
            )
        }
        return try factWindow(in: interval, limit: limit).rows
    }

    /// Reads the newest bounded working set, then restores chronological order
    /// for metric builders. One bounded sentinel row makes truncation explicit.
    public func factWindow(in interval: DateInterval, limit: Int) throws -> FactWindow {
        let boundedLimit = max(1, limit)
        let counts = try usageFactCounts(in: interval)
        let allocations = Self.allocate(counts: counts, limit: boundedLimit)
        var rows: [UsageFact] = []
        for sourceID in allocations.keys.sorted() {
            guard let allocation = allocations[sourceID], allocation > 0 else { continue }
            rows.append(contentsOf: try factWindow(
                sourceID: sourceID,
                in: interval,
                limit: allocation
            ).rows)
        }
        rows.sort {
            $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt
        }
        let truncatedSourceIDs = Set(counts.compactMap { sourceID, count in
            count > allocations[sourceID, default: 0] ? sourceID : nil
        })
        return FactWindow(
            rows: rows,
            isTruncated: !truncatedSourceIDs.isEmpty,
            truncatedSourceIDs: truncatedSourceIDs
        )
    }

    public func latestObservedAt(sourceID: String, before: Date) throws -> Date? {
        let sql = "SELECT MAX(observed_at) FROM usage_facts WHERE source_id = ? AND observed_at <= ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sourceID)
        sqlite3_bind_double(statement, 2, before.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func facts(sourceID: String, in interval: DateInterval) throws -> [UsageFact] {
        let sql = """
            SELECT * FROM usage_facts
            WHERE source_id = ? AND observed_at >= ? AND observed_at <= ?
            ORDER BY observed_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sourceID)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        var facts: [UsageFact] = []
        while sqlite3_step(statement) == SQLITE_ROW { facts.append(try row(statement)) }
        return facts
    }

    public func factWindow(sourceID: String, in interval: DateInterval, limit: Int) throws -> FactWindow {
        let boundedLimit = max(1, limit)
        let sql = """
            SELECT * FROM (
                SELECT * FROM usage_facts
                WHERE source_id = ? AND observed_at >= ? AND observed_at <= ?
                ORDER BY observed_at DESC, id DESC
                LIMIT \(boundedLimit + 1)
            )
            ORDER BY observed_at ASC, id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, sourceID)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        var facts: [UsageFact] = []
        while sqlite3_step(statement) == SQLITE_ROW { facts.append(try row(statement)) }
        let isTruncated = facts.count > boundedLimit
        if isTruncated { facts.removeFirst(facts.count - boundedLimit) }
        return FactWindow(
            rows: facts,
            isTruncated: isTruncated,
            truncatedSourceIDs: isTruncated ? [sourceID] : []
        )
    }

    private func usageFactCounts(in interval: DateInterval) throws -> [String: Int] {
        try factCounts(table: "usage_facts", in: interval)
    }

    private func performanceFactCounts(in interval: DateInterval) throws -> [String: Int] {
        try factCounts(table: "performance_facts", in: interval)
    }

    private func factCounts(table: String, in interval: DateInterval) throws -> [String: Int] {
        let sql = """
            SELECT source_id, COUNT(*) FROM \(table)
            WHERE observed_at >= ? AND observed_at <= ?
            GROUP BY source_id
            ORDER BY source_id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            counts[text(statement, 0)] = Int(sqlite3_column_int64(statement, 1))
        }
        return counts
    }

    /// Max-min allocation keeps every quiet source whole before noisy sources
    /// share the remaining bounded working set.
    private static func allocate(counts: [String: Int], limit: Int) -> [String: Int] {
        var allocations = Dictionary(uniqueKeysWithValues: counts.keys.map { ($0, 0) })
        var active = counts.keys.sorted()
        var remaining = max(0, limit)
        while !active.isEmpty, remaining > 0 {
            let share = remaining / active.count
            let quiet = active.filter { counts[$0, default: 0] <= share }
            if quiet.isEmpty {
                let base = remaining / active.count
                var remainder = remaining % active.count
                for sourceID in active {
                    allocations[sourceID] = base + (remainder > 0 ? 1 : 0)
                    if remainder > 0 { remainder -= 1 }
                }
                remaining = 0
            } else {
                for sourceID in quiet {
                    let count = counts[sourceID, default: 0]
                    allocations[sourceID] = count
                    remaining -= count
                }
                let quietSet = Set(quiet)
                active.removeAll { quietSet.contains($0) }
            }
        }
        return allocations
    }

    private func insert(_ fact: UsageFact, replace: Bool = false) throws {
        let sql = """
        INSERT \(replace ? "OR REPLACE " : "")INTO usage_facts (
            id, schema_version, coding_agent_raw, coding_agent_display,
            model_raw, model_display, session_id, turn_id, observed_at,
            output_tokens, measurement_quality, authority, definition_version
            , input_uncached, cache_read, cache_write, output_visible, reasoning,
            normalized_burn_total, model_call_id
            , model_call_capability, source_channel, authority_tier,
            measurement_granularity, measurement_range_start, measurement_range_end
            , source_id, superseded_by
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, fact.id)
        bind(statement, 2, fact.schemaVersion)
        bind(statement, 3, fact.codingAgent.rawValue)
        bind(statement, 4, fact.codingAgent.displayName)
        bind(statement, 5, fact.model.raw)
        bind(statement, 6, fact.model.display)
        bind(statement, 7, fact.sessionID)
        bind(statement, 8, fact.turnID)
        sqlite3_bind_double(statement, 9, fact.observedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 10, Int64(fact.outputTokens))
        bind(statement, 11, fact.measurementQuality.rawValue)
        bind(statement, 12, fact.authority)
        bind(statement, 13, fact.definitionVersion)
        bind(statement, 14, fact.tokenParts?.inputUncached)
        bind(statement, 15, fact.tokenParts?.cacheRead)
        bind(statement, 16, fact.tokenParts?.cacheWrite)
        bind(statement, 17, fact.tokenParts?.outputVisible)
        bind(statement, 18, fact.tokenParts?.reasoning)
        bind(statement, 19, fact.tokenParts?.normalizedBurnTotal)
        bind(statement, 20, fact.modelCallID)
        bind(statement, 21, fact.modelCallCapability.rawValue)
        bind(statement, 22, fact.sourceChannel.rawValue)
        bind(statement, 23, fact.authorityTier.rawValue)
        bind(statement, 24, fact.measurementGranularity.rawValue)
        sqlite3_bind_double(statement, 25, fact.measurementRange.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 26, fact.measurementRange.end.timeIntervalSince1970)
        bind(statement, 27, fact.sourceID)
        bind(statement, 28, fact.supersededBy)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.insertFailed
        }
    }

    private func insertPerformance(_ fact: PerformanceFact) throws {
        if let existing = try existingPerformanceFact(matching: fact), !PerformanceFact.prefers(fact, over: existing) {
            return
        }
        let sql = """
        INSERT OR REPLACE INTO performance_facts (
            stable_request_id, coding_agent_raw, coding_agent_display, model_raw, model_display,
            observed_at, duration_ms, ttft_ms, output_total, is_retry, source_channel,
            authority_tier, measurement_granularity, measurement_range_start, measurement_range_end
            , source_id, measurement_quality
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, fact.stableRequestID)
        bind(statement, 2, fact.codingAgent.rawValue)
        bind(statement, 3, fact.codingAgent.displayName)
        bind(statement, 4, fact.model.raw)
        bind(statement, 5, fact.model.display)
        sqlite3_bind_double(statement, 6, fact.observedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, fact.durationMilliseconds)
        sqlite3_bind_double(statement, 8, fact.ttftMilliseconds)
        sqlite3_bind_int64(statement, 9, Int64(fact.outputTotal))
        sqlite3_bind_int(statement, 10, fact.isRetry ? 1 : 0)
        bind(statement, 11, fact.sourceChannel.rawValue)
        bind(statement, 12, fact.authorityTier.rawValue)
        bind(statement, 13, fact.measurementGranularity.rawValue)
        sqlite3_bind_double(statement, 14, fact.measurementRange.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 15, fact.measurementRange.end.timeIntervalSince1970)
        bind(statement, 16, fact.sourceID)
        bind(statement, 17, fact.measurementQuality.rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    /// Mirrors AuthorityCoalescing's durable model-call identity. When an
    /// enhanced observation arrives, the matching fallback remains queryable
    /// until retention runs but is explicitly eligible for the first eviction
    /// step.
    private func markSupersededAuthorityFacts() throws {
        try exec(
            """
            UPDATE usage_facts AS fallback
            SET superseded_by = (
                SELECT enhanced.id
                FROM usage_facts AS enhanced
                WHERE enhanced.authority_tier = 'enhanced'
                  AND enhanced.model_call_id = fallback.model_call_id
                  AND enhanced.model_call_capability IS fallback.model_call_capability
                  AND enhanced.coding_agent_raw = fallback.coding_agent_raw
                  AND enhanced.measurement_granularity = fallback.measurement_granularity
                  AND enhanced.measurement_range_start IS fallback.measurement_range_start
                  AND enhanced.measurement_range_end IS fallback.measurement_range_end
                ORDER BY enhanced.id ASC
                LIMIT 1
            )
            WHERE fallback.authority_tier = 'fallback'
              AND fallback.model_call_id IS NOT NULL
              AND fallback.model_call_id != ''
              AND EXISTS (
                SELECT 1
                FROM usage_facts AS enhanced
                WHERE enhanced.authority_tier = 'enhanced'
                  AND enhanced.model_call_id = fallback.model_call_id
                  AND enhanced.model_call_capability IS fallback.model_call_capability
                  AND enhanced.coding_agent_raw = fallback.coding_agent_raw
                  AND enhanced.measurement_granularity = fallback.measurement_granularity
                  AND enhanced.measurement_range_start IS fallback.measurement_range_start
                  AND enhanced.measurement_range_end IS fallback.measurement_range_end
              );
            """
        )
    }

    private func existingPerformanceFact(matching fact: PerformanceFact) throws -> PerformanceFact? {
        let sql = """
        SELECT stable_request_id, coding_agent_raw, coding_agent_display, model_raw, model_display,
               observed_at, duration_ms, ttft_ms, output_total, is_retry, source_channel,
               authority_tier, measurement_granularity, measurement_range_start, measurement_range_end,
               source_id, measurement_quality
        FROM performance_facts
        WHERE coding_agent_raw = ? AND stable_request_id = ? AND measurement_granularity = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, fact.codingAgent.rawValue)
        bind(statement, 2, fact.stableRequestID)
        bind(statement, 3, fact.measurementGranularity.rawValue)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try performanceRow(statement)
    }

    private func deleteFacts(in scope: SourceFactScope) throws {
        switch scope {
        case let .schemaVersion(schemaVersion):
            try exec(
                "DELETE FROM usage_facts WHERE schema_version = '\(escapeSQL(schemaVersion))';"
            )
        case let .idPrefix(idPrefix):
            try exec(
                "DELETE FROM usage_facts WHERE id LIKE '\(escapeSQL(idPrefix))%';"
            )
        }
    }

    private func query(_ sql: String, binds: [Double] = []) throws -> [UsageFact] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            sqlite3_bind_double(statement, Int32(index + 1), value)
        }
        var facts: [UsageFact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            facts.append(try row(statement))
        }
        return facts
    }

    private func row(_ statement: OpaquePointer) throws -> UsageFact {
        guard
            let quality = MeasurementQuality(rawValue: text(statement, 10))
        else {
            throw StoreError.invalidRow
        }
        return UsageFact(
            id: text(statement, 0),
            schemaVersion: text(statement, 1),
            sourceID: optionalText(statement, 26) ?? "unknown",
            codingAgent: CodingAgent(rawValue: text(statement, 2), displayName: text(statement, 3)),
            model: ModelIdentity(raw: text(statement, 4), display: text(statement, 5)),
            sessionID: text(statement, 6),
            turnID: text(statement, 7),
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            outputTokens: Int(sqlite3_column_int64(statement, 9)),
            measurementQuality: quality,
            authority: text(statement, 11),
            definitionVersion: text(statement, 12),
            tokenParts: sqlite3_column_type(statement, 18) == SQLITE_NULL ? nil : TokenParts(
                inputUncached: integer(statement, 13),
                cacheRead: integer(statement, 14),
                cacheWrite: integer(statement, 15),
                outputVisible: integer(statement, 16),
                reasoning: integer(statement, 17),
                normalizedBurnTotal: integer(statement, 18)
            ),
            modelCallID: optionalText(statement, 19),
            modelCallCapability: optionalText(statement, 20).flatMap(ModelCallCapability.init(rawValue:)),
            sourceChannel: optionalText(statement, 21).flatMap(SourceChannel.init(rawValue:)),
            authorityTier: optionalText(statement, 22).flatMap(AuthorityTier.init(rawValue:)),
            measurementGranularity: optionalText(statement, 23).flatMap(UsageGranularity.init(rawValue:)),
            measurementRange: range(statement, start: 24, end: 25),
            supersededBy: optionalText(statement, 27)
        )
    }

    private func performanceRow(_ statement: OpaquePointer) throws -> PerformanceFact {
        guard let channel = SourceChannel(rawValue: text(statement, 10)),
              let tier = AuthorityTier(rawValue: text(statement, 11)),
              let granularity = UsageGranularity(rawValue: text(statement, 12)) else {
            throw StoreError.invalidRow
        }
        return PerformanceFact(
            stableRequestID: text(statement, 0),
            sourceID: optionalText(statement, 15) ?? "legacy-performance",
            codingAgent: CodingAgent(rawValue: text(statement, 1), displayName: text(statement, 2)),
            model: ModelIdentity(raw: text(statement, 3), display: text(statement, 4)),
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            durationMilliseconds: sqlite3_column_double(statement, 6),
            ttftMilliseconds: sqlite3_column_double(statement, 7),
            outputTotal: Int(sqlite3_column_int64(statement, 8)),
            isRetry: sqlite3_column_int(statement, 9) != 0,
            sourceChannel: channel,
            authorityTier: tier,
            measurementGranularity: granularity,
            measurementRange: DateInterval(
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
            ),
            measurementQuality: optionalText(statement, 16).flatMap(MeasurementQuality.init(rawValue:)) ?? .measured
        )
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func integer(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }

    private func range(_ statement: OpaquePointer, start: Int32, end: Int32) -> DateInterval? {
        guard sqlite3_column_type(statement, start) != SQLITE_NULL,
              sqlite3_column_type(statement, end) != SQLITE_NULL else { return nil }
        return DateInterval(
            start: Date(timeIntervalSince1970: sqlite3_column_double(statement, start)),
            end: Date(timeIntervalSince1970: sqlite3_column_double(statement, end))
        )
    }

    private func migrateUsageFacts() throws {
        let additions = [
            "input_uncached INTEGER", "cache_read INTEGER", "cache_write INTEGER",
            "output_visible INTEGER", "reasoning INTEGER", "normalized_burn_total INTEGER",
            "model_call_id TEXT",
            "model_call_capability TEXT", "source_channel TEXT", "authority_tier TEXT",
            "measurement_granularity TEXT", "measurement_range_start REAL", "measurement_range_end REAL",
            "source_id TEXT", "superseded_by TEXT",
        ]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(usage_facts);", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(text(statement, 1)) }
        for addition in additions {
            let name = addition.split(separator: " ").first.map(String.init) ?? addition
            if !names.contains(name) { try exec("ALTER TABLE usage_facts ADD COLUMN \(addition);") }
        }
        try exec(
            """
            UPDATE usage_facts
            SET source_id = CASE schema_version
                WHEN 'codex-rollout-v1' THEN 'codex'
                WHEN 'claude-code-transcript-v1' THEN 'claude-code'
                WHEN 'synthetic-codex-token-count-v1' THEN 'synthetic-codex'
                WHEN 'synthetic-stable-call-v1' THEN 'synthetic-codex'
                ELSE 'unknown'
            END
            WHERE source_id IS NULL OR source_id = '';
            """
        )
    }

    private func createPerformanceFactsTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS performance_facts (
                stable_request_id TEXT NOT NULL,
                coding_agent_raw TEXT NOT NULL,
                coding_agent_display TEXT NOT NULL,
                model_raw TEXT NOT NULL,
                model_display TEXT NOT NULL,
                observed_at REAL NOT NULL,
                duration_ms REAL NOT NULL,
                ttft_ms REAL NOT NULL,
                output_total INTEGER NOT NULL,
                is_retry INTEGER NOT NULL,
                source_channel TEXT NOT NULL,
                authority_tier TEXT NOT NULL,
                measurement_granularity TEXT NOT NULL,
                measurement_range_start REAL NOT NULL,
                measurement_range_end REAL NOT NULL,
                source_id TEXT,
                measurement_quality TEXT,
                PRIMARY KEY (coding_agent_raw, stable_request_id, measurement_granularity)
            );
            """
        )
    }

    private func createDailyUsageRollupsTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS daily_usage_rollups (
                id TEXT PRIMARY KEY,
                bucket_start REAL NOT NULL,
                bucket_end REAL NOT NULL,
                source_id TEXT NOT NULL,
                coding_agent_raw TEXT NOT NULL,
                coding_agent_display TEXT NOT NULL,
                model_raw TEXT NOT NULL,
                model_display TEXT NOT NULL,
                source_channel TEXT NOT NULL,
                authority_tier TEXT NOT NULL,
                measurement_granularity TEXT NOT NULL,
                measurement_quality TEXT NOT NULL,
                coverage TEXT NOT NULL,
                source_authority TEXT NOT NULL,
                definition_version TEXT NOT NULL,
                output_tokens INTEGER NOT NULL,
                input_uncached INTEGER,
                cache_read INTEGER,
                cache_write INTEGER,
                output_visible INTEGER,
                reasoning INTEGER,
                normalized_burn_total INTEGER,
                sample_count INTEGER NOT NULL
            );
            """
        )
        try exec(
            "CREATE INDEX IF NOT EXISTS daily_usage_rollups_bucket_start ON daily_usage_rollups(bucket_start);"
        )
    }

    private func createRetentionMetadataTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS retention_metadata (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                retention_pruned_before REAL,
                earliest_retained_at REAL,
                ingestion_paused INTEGER NOT NULL DEFAULT 0,
                diagnostic_code TEXT
            );
            """
        )
    }

    private func createSchemaMetadataTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS schema_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            INSERT OR IGNORE INTO schema_metadata (key, value) VALUES ('schema_version', 'retention-v1');
            """
        )
    }

    private func createManagedArtifactsTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS app_managed_artifacts (
                path TEXT PRIMARY KEY,
                kind TEXT NOT NULL
            );
            """
        )
    }

    private func createTelemetryTableRegistry() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS telemetry_table_registry (
                table_name TEXT PRIMARY KEY
            );
            """
        )
    }

    private func createResetCleanupJournalTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS reset_cleanup_journal (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                path TEXT
            );
            """
        )
    }

    private func createTelemetryResetMetadataTable() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS telemetry_reset_metadata (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                cutoff REAL NOT NULL
            );
            """
        )
    }

    private func writeTelemetryResetCutoff(_ cutoff: Date) throws {
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO telemetry_reset_metadata (singleton, cutoff) VALUES (1, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    private func insertResetCleanupTask(id: String, kind: String, path: String?) throws {
        let sql = "INSERT OR REPLACE INTO reset_cleanup_journal (id, kind, path) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        bind(statement, 2, kind)
        if let path {
            bind(statement, 3, path)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    /// Journal rows are committed with the destructive transaction. Cleanup is
    /// retried on every open and Reset, so a post-COMMIT filesystem or reclaim
    /// failure is reported as pending rather than as a rolled-back Reset.
    private func retryPendingResetCleanup() throws -> Bool {
        let tasks = try resetCleanupTasks()
        let root = databaseURL.deletingLastPathComponent().standardizedFileURL
        for task in tasks {
            do {
                switch task.kind {
                case "staging":
                    guard let path = task.path else { continue }
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard url.deletingLastPathComponent() == root,
                          url.lastPathComponent.hasPrefix(".telemetry-reset-") else {
                        continue
                    }
                    if entryExistsNoFollow(url) {
                        try resetCleanupOperations.removeItem(url)
                    }
                case "space-reclaim":
                    try exec("PRAGMA wal_checkpoint(TRUNCATE);")
                    try exec("VACUUM;")
                default:
                    continue
                }
                try deleteResetCleanupTask(id: task.id)
            } catch {
                continue
            }
        }
        return try resetCleanupTaskCount() > 0
    }

    private func resetCleanupTasks() throws -> [(id: String, kind: String, path: String?)] {
        var statement: OpaquePointer?
        let sql = "SELECT id, kind, path FROM reset_cleanup_journal ORDER BY kind, id;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        var tasks: [(id: String, kind: String, path: String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            tasks.append((
                id: text(statement, 0),
                kind: text(statement, 1),
                path: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : text(statement, 2)
            ))
        }
        return tasks
    }

    private func deleteResetCleanupTask(id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM reset_cleanup_journal WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    private func resetCleanupTaskCount() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM reset_cleanup_journal;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func classifiedTelemetryTables() throws -> [String] {
        let registered = try registeredTelemetryTableNames()
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        var telemetry: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let table = text(statement, 0)
            if Self.preservedResetTableNames.contains(table) {
                continue
            }
            if Self.telemetryTableNames.contains(table) || table.hasPrefix("telemetry_") || registered.contains(table) {
                telemetry.append(table)
            } else {
                throw StoreError.unclassifiedResetTable(table)
            }
        }
        return telemetry
    }

    private func registeredTelemetryTableNames() throws -> Set<String> {
        guard try tableExists("telemetry_table_registry") else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT table_name FROM telemetry_table_registry;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.insert(text(statement, 0))
        }
        return names
    }

    private func tableExists(_ table: String) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, table)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func validatedManagedArtifactURL(_ url: URL, root: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let canonicalAppRoot = canonicalURLResolvingExistingAncestor(root)
        let canonicalArtifact = canonicalURLResolvingExistingAncestor(standardized)
        let managedRoots = [
            root.appendingPathComponent("exports", isDirectory: true),
            root.appendingPathComponent("migration-backups", isDirectory: true),
        ]
        let isManaged = managedRoots.contains { managedRoot in
            let canonicalManagedRoot = canonicalURLResolvingExistingAncestor(managedRoot)
            return isDescendant(standardized, of: managedRoot)
                && isDescendant(canonicalManagedRoot, of: canonicalAppRoot)
                && isDescendant(canonicalArtifact, of: canonicalManagedRoot)
        }
        guard isManaged else {
            throw StoreError.artifactOutsideAppOwnedRoot(standardized.path)
        }
        return standardized
    }

    /// Stages only the two fixed top-level managed entries. `renameat` operates
    /// on the directory entry itself with no symlink traversal, so swapping an
    /// entry to a symlink can only move that symlink, never its target.
    private func stageManagedRootEntries(
        _ managedRoots: [URL],
        root: URL,
        stagingRoot: URL
    ) throws -> [(original: URL, staged: URL)] {
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        let rootFD = try openDirectory(root)
        defer { close(rootFD) }
        let stagingFD = try openDirectory(stagingRoot)
        defer { close(stagingFD) }
        var staged: [(original: URL, staged: URL)] = []
        do {
            try resetCleanupOperations.beforeStagingManagedRoots()
            for (index, original) in managedRoots.enumerated() {
                let name = original.lastPathComponent
                guard try entryExistsNoFollow(directoryFD: rootFD, name: name) else { continue }
                try resetCleanupOperations.beforeManagedRootMove(index)
                let destinationName = String(index)
                try renameEntryNoFollow(
                    fromDirectoryFD: rootFD,
                    name: name,
                    toDirectoryFD: stagingFD,
                    destinationName: destinationName
                )
                staged.append((
                    original: original,
                    staged: stagingRoot.appendingPathComponent(destinationName)
                ))
            }
            if staged.isEmpty {
                try FileManager.default.removeItem(at: stagingRoot)
            }
            return staged
        } catch {
            for item in staged.reversed() {
                try? renameEntryNoFollow(
                    fromDirectoryFD: stagingFD,
                    name: item.staged.lastPathComponent,
                    toDirectoryFD: rootFD,
                    destinationName: item.original.lastPathComponent
                )
            }
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StoreError.posixOperationFailed("open", errno)
        }
        return descriptor
    }

    private func entryExistsNoFollow(directoryFD: Int32, name: String) throws -> Bool {
        var info = stat()
        let result = name.withCString {
            fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw StoreError.posixOperationFailed("fstatat", errno)
    }

    private func entryExistsNoFollow(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func renameEntryNoFollow(from source: URL, to destination: URL) throws {
        let sourceFD = try openDirectory(source.deletingLastPathComponent())
        defer { close(sourceFD) }
        let destinationFD = try openDirectory(destination.deletingLastPathComponent())
        defer { close(destinationFD) }
        try renameEntryNoFollow(
            fromDirectoryFD: sourceFD,
            name: source.lastPathComponent,
            toDirectoryFD: destinationFD,
            destinationName: destination.lastPathComponent
        )
    }

    private func renameEntryNoFollow(
        fromDirectoryFD sourceFD: Int32,
        name: String,
        toDirectoryFD destinationFD: Int32,
        destinationName: String
    ) throws {
        let result = name.withCString { sourceName in
            destinationName.withCString { destinationName in
                renameat(sourceFD, sourceName, destinationFD, destinationName)
            }
        }
        guard result == 0 else {
            throw StoreError.posixOperationFailed("renameat", errno)
        }
    }

    private func canonicalURLResolvingExistingAncestor(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
    }

    private func quotedIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func recordPruning(before date: Date) throws {
        let existing = try retentionMetadata()
        let boundary = max(existing.retentionPrunedBefore ?? date, date)
        try writeRetentionMetadata(RetentionMetadata(
            retentionPrunedBefore: boundary,
            earliestRetainedAt: try earliestRetainedAt(),
            ingestionPaused: existing.ingestionPaused,
            diagnosticCode: existing.diagnosticCode
        ))
    }

    private func earliestRetainedAt() throws -> Date? {
        let sql = """
            SELECT MIN(value) FROM (
                SELECT MIN(observed_at) AS value FROM usage_facts
                UNION ALL SELECT MIN(observed_at) FROM performance_facts
                UNION ALL SELECT MIN(bucket_start) FROM daily_usage_rollups
            ) WHERE value IS NOT NULL;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalDate(statement, 0)
    }

    private func writeRetentionMetadata(_ metadata: RetentionMetadata) throws {
        let sql = """
            INSERT INTO retention_metadata (
                singleton, retention_pruned_before, earliest_retained_at,
                ingestion_paused, diagnostic_code
            ) VALUES (1, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET
                retention_pruned_before = excluded.retention_pruned_before,
                earliest_retained_at = excluded.earliest_retained_at,
                ingestion_paused = excluded.ingestion_paused,
                diagnostic_code = excluded.diagnostic_code;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        if let date = metadata.retentionPrunedBefore {
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        if let date = metadata.earliestRetainedAt {
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int(statement, 3, metadata.ingestionPaused ? 1 : 0)
        bind(statement, 4, metadata.diagnosticCode)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    private func distinctBucketStarts(before cutoff: TimeInterval) throws -> [TimeInterval] {
        let sql = """
            SELECT DISTINCT CAST(observed_at / 86400 AS INTEGER) * 86400
            FROM usage_facts
            WHERE observed_at < ?
            ORDER BY 1 ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var values: [TimeInterval] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_double(statement, 0))
        }
        return values
    }

    private func hasDailyRollup(bucketStart: TimeInterval) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM daily_usage_rollups WHERE bucket_start = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, bucketStart)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func makeDailyRollups(
        facts: [UsageFact],
        bucketStart: Date,
        coverage: Coverage
    ) -> [DailyUsageRollup] {
        Dictionary(grouping: facts) { fact in
            RollupCohort(
                sourceID: fact.sourceID,
                codingAgentRaw: fact.codingAgent.rawValue,
                codingAgentDisplay: fact.codingAgent.displayName,
                modelRaw: fact.model.raw,
                modelDisplay: fact.model.display,
                sourceChannel: fact.sourceChannel.rawValue,
                authorityTier: fact.authorityTier.rawValue,
                measurementGranularity: fact.measurementGranularity.rawValue,
                sourceAuthority: fact.authority,
                definitionVersion: fact.definitionVersion
            )
        }
        .map { cohort, cohortFacts in
            func total(_ value: (UsageFact) -> Int?) -> Int? {
                let values = cohortFacts.map(value)
                guard values.allSatisfy({ $0 != nil }) else { return nil }
                return values.compactMap { $0 }.reduce(0, +)
            }
            let bucketEnd = bucketStart.addingTimeInterval(24 * 60 * 60)
            let tokenParts: TokenParts?
            if cohortFacts.allSatisfy({ $0.tokenParts == nil }) {
                tokenParts = nil
            } else {
                let normalizedBurnTotal = total { $0.tokenParts?.normalizedBurnTotal }
                var aggregate = TokenParts(
                    inputUncached: total { $0.tokenParts?.inputUncached },
                    cacheRead: total { $0.tokenParts?.cacheRead },
                    cacheWrite: total { $0.tokenParts?.cacheWrite },
                    outputVisible: total { $0.tokenParts?.outputVisible },
                    reasoning: total { $0.tokenParts?.reasoning },
                    normalizedBurnTotal: normalizedBurnTotal
                )
                // TokenParts' convenience initializer derives a total when
                // omitted; a rollup must preserve cohort-wide unavailability.
                aggregate.normalizedBurnTotal = normalizedBurnTotal
                tokenParts = aggregate
            }
            let idParts = [
                String(Int64(bucketStart.timeIntervalSince1970)), cohort.sourceID,
                cohort.codingAgentRaw, cohort.modelRaw, cohort.sourceChannel,
                cohort.authorityTier, cohort.measurementGranularity,
                cohort.sourceAuthority, cohort.definitionVersion,
            ]
            return DailyUsageRollup(
                id: idParts.joined(separator: "\u{1F}"),
                bucketStart: bucketStart,
                bucketEnd: bucketEnd,
                sourceID: cohort.sourceID,
                codingAgent: CodingAgent(rawValue: cohort.codingAgentRaw, displayName: cohort.codingAgentDisplay),
                model: ModelIdentity(raw: cohort.modelRaw, display: cohort.modelDisplay),
                sourceChannel: SourceChannel(rawValue: cohort.sourceChannel) ?? .unknown,
                authorityTier: AuthorityTier(rawValue: cohort.authorityTier) ?? .fallback,
                measurementGranularity: UsageGranularity(rawValue: cohort.measurementGranularity) ?? .unknown,
                measurementQuality: MeasurementQuality.combined(
                    cohortFacts.map(\.measurementQuality),
                    derivedResult: true
                ),
                coverage: coverage,
                sourceAuthority: cohort.sourceAuthority,
                definitionVersion: cohort.definitionVersion,
                outputTokens: cohortFacts.reduce(0) { $0 + $1.outputTokens },
                tokenParts: tokenParts,
                sampleCount: cohortFacts.count
            )
        }
        .sorted { $0.id < $1.id }
    }

    private func insert(_ rollup: DailyUsageRollup) throws {
        let sql = """
            INSERT INTO daily_usage_rollups (
                id, bucket_start, bucket_end, source_id,
                coding_agent_raw, coding_agent_display, model_raw, model_display,
                source_channel, authority_tier, measurement_granularity,
                measurement_quality, coverage, source_authority, definition_version,
                output_tokens, input_uncached, cache_read, cache_write, output_visible,
                reasoning, normalized_burn_total, sample_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, rollup.id)
        sqlite3_bind_double(statement, 2, rollup.bucketStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, rollup.bucketEnd.timeIntervalSince1970)
        bind(statement, 4, rollup.sourceID)
        bind(statement, 5, rollup.codingAgent.rawValue)
        bind(statement, 6, rollup.codingAgent.displayName)
        bind(statement, 7, rollup.model.raw)
        bind(statement, 8, rollup.model.display)
        bind(statement, 9, rollup.sourceChannel.rawValue)
        bind(statement, 10, rollup.authorityTier.rawValue)
        bind(statement, 11, rollup.measurementGranularity.rawValue)
        bind(statement, 12, rollup.measurementQuality.rawValue)
        bind(statement, 13, rollup.coverage.rawValue)
        bind(statement, 14, rollup.sourceAuthority)
        bind(statement, 15, rollup.definitionVersion)
        sqlite3_bind_int64(statement, 16, Int64(rollup.outputTokens))
        bind(statement, 17, rollup.tokenParts?.inputUncached)
        bind(statement, 18, rollup.tokenParts?.cacheRead)
        bind(statement, 19, rollup.tokenParts?.cacheWrite)
        bind(statement, 20, rollup.tokenParts?.outputVisible)
        bind(statement, 21, rollup.tokenParts?.reasoning)
        bind(statement, 22, rollup.tokenParts?.normalizedBurnTotal)
        sqlite3_bind_int64(statement, 23, Int64(rollup.sampleCount))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.insertFailed }
    }

    private func dailyRollupRow(_ statement: OpaquePointer) throws -> DailyUsageRollup {
        guard let sourceChannel = SourceChannel(rawValue: text(statement, 8)),
              let authorityTier = AuthorityTier(rawValue: text(statement, 9)),
              let granularity = UsageGranularity(rawValue: text(statement, 10)),
              let quality = MeasurementQuality(rawValue: text(statement, 11)),
              let coverage = Coverage(rawValue: text(statement, 12)) else {
            throw StoreError.invalidRow
        }
        let parts = sqlite3_column_type(statement, 21) == SQLITE_NULL ? nil : TokenParts(
            inputUncached: integer(statement, 16),
            cacheRead: integer(statement, 17),
            cacheWrite: integer(statement, 18),
            outputVisible: integer(statement, 19),
            reasoning: integer(statement, 20),
            normalizedBurnTotal: integer(statement, 21)
        )
        return DailyUsageRollup(
            id: text(statement, 0),
            bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            bucketEnd: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            sourceID: text(statement, 3),
            codingAgent: CodingAgent(rawValue: text(statement, 4), displayName: text(statement, 5)),
            model: ModelIdentity(raw: text(statement, 6), display: text(statement, 7)),
            sourceChannel: sourceChannel,
            authorityTier: authorityTier,
            measurementGranularity: granularity,
            measurementQuality: quality,
            coverage: coverage,
            sourceAuthority: text(statement, 13),
            definitionVersion: text(statement, 14),
            outputTokens: Int(sqlite3_column_int64(statement, 15)),
            tokenParts: parts,
            sampleCount: Int(sqlite3_column_int64(statement, 22))
        )
    }

    private func migratePerformanceFactsIfNeeded() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(performance_facts);", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed
        }
        var primaryKeyColumns: [(Int, String)] = []
        var columnNames = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columnNames.insert(text(statement, 1))
            let ordinal = Int(sqlite3_column_int(statement, 5))
            if ordinal > 0 { primaryKeyColumns.append((ordinal, text(statement, 1))) }
        }
        sqlite3_finalize(statement)
        if !columnNames.contains("source_id") {
            try exec("ALTER TABLE performance_facts ADD COLUMN source_id TEXT;")
        }
        if !columnNames.contains("measurement_quality") {
            try exec("ALTER TABLE performance_facts ADD COLUMN measurement_quality TEXT;")
        }
        try exec(
            "UPDATE performance_facts SET source_id = 'legacy-performance' WHERE source_id IS NULL OR source_id = '';"
        )
        let expected = ["coding_agent_raw", "stable_request_id", "measurement_granularity"]
        guard primaryKeyColumns.sorted(by: { $0.0 < $1.0 }).map(\.1) != expected else { return }

        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("ALTER TABLE performance_facts RENAME TO performance_facts_legacy;")
            try createPerformanceFactsTable()
            let sql = """
            SELECT stable_request_id, coding_agent_raw, coding_agent_display, model_raw, model_display,
                   observed_at, duration_ms, ttft_ms, output_total, is_retry, source_channel,
                   authority_tier, measurement_granularity, measurement_range_start, measurement_range_end,
                   source_id, measurement_quality
            FROM performance_facts_legacy;
            """
            var legacy: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &legacy, nil) == SQLITE_OK, let legacy else {
                throw StoreError.prepareFailed
            }
            defer { sqlite3_finalize(legacy) }
            while sqlite3_step(legacy) == SQLITE_ROW { try insertPerformance(try performanceRow(legacy)) }
            try exec("DROP TABLE performance_facts_legacy;")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(sql)
        }
    }
}

public enum StoreError: Error, Equatable {
    case openFailed(Int32)
    case posixOperationFailed(String, Int32)
    case prepareFailed
    case insertFailed
    case invalidRow
    case execFailed(String)
    case artifactOutsideAppOwnedRoot(String)
    case unclassifiedResetTable(String)
    case invalidResetTableRegistration(String)
}

private func escapeSQL(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

private struct RollupCohort: Hashable {
    var sourceID: String
    var codingAgentRaw: String
    var codingAgentDisplay: String
    var modelRaw: String
    var modelDisplay: String
    var sourceChannel: String
    var authorityTier: String
    var measurementGranularity: String
    var sourceAuthority: String
    var definitionVersion: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
