import Foundation
import SQLite3

public final class SQLiteFactStore: @unchecked Sendable {
    private var database: OpaquePointer?

    public init(url: URL) throws {
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
                source_id TEXT
            );
            """
        )
        try migrateUsageFacts()
        try exec("CREATE INDEX IF NOT EXISTS usage_facts_observed_at ON usage_facts(observed_at);")
        try createPerformanceFactsTable()
        try migratePerformanceFactsIfNeeded()
        try exec(
            """
            CREATE TABLE IF NOT EXISTS source_states (
                source_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            );
            """
        )
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
        try exec("BEGIN IMMEDIATE;")
        do {
            for scope in scopes {
                try deleteFacts(in: scope)
            }
            for fact in facts {
                try insert(fact, replace: true)
            }
            try failureInjection?()
            try writeSourceState(state)
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
        var sql = """
            SELECT * FROM usage_facts
            WHERE observed_at >= ? AND observed_at <= ?
            ORDER BY observed_at ASC, id ASC
            """
        if let limit {
            // The caller opts into bounded reads; cap is deterministic and avoids
            // turning an untrusted UI query into a whole-store allocation.
            sql += " LIMIT \(max(1, limit));"
        } else {
            sql += ";"
        }
        return try query(
            sql,
            binds: [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
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
            , source_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            measurementRange: range(statement, start: 24, end: 25)
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
            "source_id TEXT",
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
    case prepareFailed
    case insertFailed
    case invalidRow
    case execFailed(String)
}

private func escapeSQL(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
