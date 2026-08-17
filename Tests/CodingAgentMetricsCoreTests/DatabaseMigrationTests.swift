import Foundation
import SQLite3
import Testing
import Darwin
@testable import CodingAgentMetricsCore

struct DatabaseMigrationTests {
    @Test func currentDatabaseLeafSymlinkFailsClosedWithoutTouchingTarget() throws {
        let localURL = migrationTemporaryStoreURL()
        let externalURL = migrationTemporaryStoreURL()
        defer {
            removeMigrationStore(at: localURL)
            removeMigrationStore(at: externalURL)
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try SQLiteFactStore(url: externalURL)
        let externalBytes = try Data(contentsOf: externalURL)
        try FileManager.default.createSymbolicLink(
            at: localURL,
            withDestinationURL: externalURL
        )

        var didFailClosed = false
        do {
            _ = try SQLiteFactStore(url: localURL)
        } catch {
            didFailClosed = true
        }

        #expect(didFailClosed)
        #expect(try Data(contentsOf: externalURL) == externalBytes)
        #expect(try migrationMetadataValue(
            at: externalURL,
            key: "database_schema_version"
        ) == "1")
    }

    @Test func legacyDatabaseLeafSymlinkFailsClosedWithoutMigratingTarget() throws {
        let localURL = migrationTemporaryStoreURL()
        let externalURL = migrationTemporaryStoreURL()
        defer {
            removeMigrationStore(at: localURL)
            removeMigrationStore(at: externalURL)
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createLegacyMigrationFixture(at: externalURL)
        let externalBytes = try Data(contentsOf: externalURL)
        try FileManager.default.createSymbolicLink(
            at: localURL,
            withDestinationURL: externalURL
        )

        var didFailClosed = false
        do {
            _ = try SQLiteFactStore(url: localURL)
        } catch {
            didFailClosed = true
        }

        #expect(didFailClosed)
        #expect(try Data(contentsOf: externalURL) == externalBytes)
        #expect(try migrationScalar(
            at: externalURL,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'schema_metadata';"
        ) == 0)
        #expect(try migrationScalar(at: externalURL, sql: "SELECT COUNT(*) FROM usage_facts;") == 1)
        #expect(!FileManager.default.fileExists(
            atPath: localURL.deletingLastPathComponent()
                .appendingPathComponent(".facts.sqlite.migration.lock").path
        ))
    }

    @Test func databaseParentSymlinkFailsClosedWithoutTouchingExternalDirectory() throws {
        let localParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("database-migration-parent-link-\(UUID().uuidString)")
        let externalURL = migrationTemporaryStoreURL()
        let localURL = localParent.appendingPathComponent("facts.sqlite")
        defer {
            try? FileManager.default.removeItem(at: localParent)
            removeMigrationStore(at: externalURL)
        }
        try createLegacyMigrationFixture(at: externalURL)
        let externalBytes = try Data(contentsOf: externalURL)
        try FileManager.default.createSymbolicLink(
            at: localParent,
            withDestinationURL: externalURL.deletingLastPathComponent()
        )

        var didFailClosed = false
        do {
            _ = try SQLiteFactStore(url: localURL)
        } catch {
            didFailClosed = true
        }

        #expect(didFailClosed)
        #expect(try Data(contentsOf: externalURL) == externalBytes)
        #expect(try migrationScalar(
            at: externalURL,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'schema_metadata';"
        ) == 0)
        #expect(!FileManager.default.fileExists(
            atPath: externalURL.deletingLastPathComponent()
                .appendingPathComponent(".facts.sqlite.migration.lock").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: externalURL.deletingLastPathComponent()
                .appendingPathComponent(MigrationBackupManager.directoryName).path
        ))
    }

    @Test func schemaChangedAfterInitialPreflightStillFailsClosedWithoutMutation() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try SQLiteFactStore(url: url)
        var futureBytes: Data?
        let operations = DatabaseMigrationOperations(checkpoint: { checkpoint in
            guard checkpoint == .initialPreflightCompleted else { return }
            try migrationExecuteSQL(
                at: url,
                sql: """
                    UPDATE schema_metadata
                    SET value = '2'
                    WHERE key = 'database_schema_version';
                    CREATE TABLE future_private_data (payload TEXT NOT NULL);
                    INSERT INTO future_private_data (payload) VALUES ('sentinel');
                    """
            )
            futureBytes = try Data(contentsOf: url)
        })

        #expect(throws: StoreError.incompatibleDatabaseSchema(StoreCompatibilityFailure(
            databaseSchemaVersion: 2,
            supportedSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(
                url: url,
                resetCleanupOperations: .live,
                migrationOperations: operations
            )
        }

        #expect(try Data(contentsOf: url) == futureBytes)
        #expect(try migrationMetadataValue(at: url, key: "database_schema_version") == "2")
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM future_private_data;") == 1)
    }

    @Test func storeCreatedAfterNewPreflightIsRecheckedBeforeBootstrapWrites() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var futureBytes: Data?
        let operations = DatabaseMigrationOperations(checkpoint: { checkpoint in
            guard checkpoint == .initialPreflightCompleted else { return }
            try createFutureMigrationFixture(at: url)
            futureBytes = try Data(contentsOf: url)
        })

        #expect(throws: StoreError.incompatibleDatabaseSchema(StoreCompatibilityFailure(
            databaseSchemaVersion: 2,
            supportedSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(
                url: url,
                resetCleanupOperations: .live,
                migrationOperations: operations
            )
        }

        #expect(try Data(contentsOf: url) == futureBytes)
        #expect(try migrationMetadataValue(at: url, key: "database_schema_version") == "2")
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM future_private_data;") == 1)
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'usage_facts';") == 0)
    }

    @Test func newerStoreFailsClosedBeforeAnyDatabaseMutation() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try migrationExecuteSQL(
            at: url,
            sql: """
                CREATE TABLE schema_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO schema_metadata (key, value) VALUES ('database_schema_version', '2');
                CREATE TABLE future_private_data (payload TEXT NOT NULL);
                INSERT INTO future_private_data (payload) VALUES ('sentinel');
                """
        )
        let before = try Data(contentsOf: url)

        #expect(throws: StoreError.incompatibleDatabaseSchema(StoreCompatibilityFailure(
            databaseSchemaVersion: 2,
            supportedSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(url: url)
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM future_private_data;") == 1)
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'usage_facts';") == 0)
    }

    @Test func incompatibleRuntimeStartupNeverAttemptsToStartOTLP() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createFutureMigrationFixture(at: url)
        var attemptedReceiverStart = false

        #expect(throws: StoreError.incompatibleDatabaseSchema(StoreCompatibilityFailure(
            databaseSchemaVersion: 2,
            supportedSchemaVersion: 1
        ))) {
            _ = try TelemetryRuntime(
                storeURL: url,
                sourceAdapters: [],
                receiverConfiguration: try OTLPReceiverConfiguration(enabled: true),
                beforePersistingPerformance: nil,
                beforeStartingReceiver: { attemptedReceiverStart = true }
            )
        }

        #expect(!attemptedReceiverStart)
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM future_private_data;") == 1)
    }

    @Test func legacyStoreMigratesWithVerifiedBackupAndPreservesFacts() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try migrationExecuteSQL(
            at: url,
            sql: """
                CREATE TABLE usage_facts (
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
                    definition_version TEXT NOT NULL
                );
                INSERT INTO usage_facts VALUES (
                    'legacy-fact', 'synthetic-v1', 'codex', 'Codex', 'model', 'Model',
                    'session', 'turn', 2000000000, 42, 'measured', 'fixture', 'definition-v1'
                );
                CREATE TABLE schema_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO schema_metadata (key, value) VALUES ('schema_version', 'retention-v1');
                """
        )

        let store = try SQLiteFactStore(url: url)

        let fact = try #require(store.allFacts().first)
        #expect(fact.id == "legacy-fact")
        #expect(fact.outputTokens == 42)
        #expect(fact.schemaVersion == "synthetic-v1")
        #expect(try migrationMetadataValue(at: url, key: "database_schema_version") == "1")

        let backupDirectory = migrationBackupDirectory(at: url)
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        let backup = try #require(entries.first { $0.pathExtension == "sqlite" })
        let manifest = try #require(entries.first { $0.pathExtension == "json" })
        #expect(try migrationIntegrityCheck(at: backup) == "ok")
        #expect(try migrationScalar(at: backup, sql: "SELECT COUNT(*) FROM usage_facts;") == 1)
        let manifestObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        #expect(Set(manifestObject.keys) == [
            "applicationVersion", "backupID", "byteSize", "checksumSHA256", "createdAt",
            "formatVersion", "sourceSchemaVersion", "status", "targetSchemaVersion",
        ])
        #expect(manifestObject["sourceSchemaVersion"] as? Int == 0)
        #expect(manifestObject["targetSchemaVersion"] as? Int == 1)
        #expect(manifestObject["status"] as? String == "migrationSucceeded")
        #expect((manifestObject["checksumSHA256"] as? String)?.count == 64)
        #expect((manifestObject["byteSize"] as? Int ?? 0) > 0)
        let manifestText = try String(contentsOf: manifest, encoding: .utf8)
        #expect(!manifestText.contains(url.path))
        #expect(!manifestText.contains("legacy-fact"))
    }

    @Test func writerCannotCommitBetweenVerifiedBackupAndMigrationCommit() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        let writerAttempted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchGroup()
        writerFinished.enter()
        let writerResult = MigrationWriterResult()
        let operations = DatabaseMigrationOperations(checkpoint: { checkpoint in
            guard checkpoint == .backupVerified else { return }
            DispatchQueue.global().async {
                var writer: OpaquePointer?
                let openStatus = sqlite3_open_v2(
                    url.path,
                    &writer,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                    nil
                )
                guard openStatus == SQLITE_OK, let writer else {
                    writerResult.store(openStatus)
                    writerAttempted.signal()
                    writerFinished.leave()
                    return
                }
                defer { sqlite3_close(writer) }
                sqlite3_busy_timeout(writer, 5_000)
                writerAttempted.signal()
                let sql = """
                    INSERT INTO usage_facts (
                        id, schema_version, coding_agent_raw, coding_agent_display,
                        model_raw, model_display, session_id, turn_id, observed_at,
                        output_tokens, measurement_quality, authority, definition_version
                    ) VALUES (
                        'concurrent-fact', 'synthetic-v1', 'codex', 'Codex',
                        'model', 'Model', 'session', 'turn-concurrent', 2000000001,
                        7, 'measured', 'fixture', 'definition-v1'
                    );
                    """
                writerResult.store(sqlite3_exec(writer, sql, nil, nil, nil))
                writerFinished.leave()
            }
            #expect(writerAttempted.wait(timeout: .now() + 2) == .success)
            #expect(writerFinished.wait(timeout: .now() + 0.2) == .timedOut)
        })

        let store = try SQLiteFactStore(
            url: url,
            resetCleanupOperations: .live,
            migrationOperations: operations
        )

        #expect(writerFinished.wait(timeout: .now() + 5) == .success)
        #expect(writerResult.load() == SQLITE_OK)
        #expect(Set(try store.allFacts().map(\.id)) == ["legacy-fact", "concurrent-fact"])
        let backupDirectory = migrationBackupDirectory(at: url)
        let manifest = try #require(try migrationManifests(in: backupDirectory).first)
        let backupID = try #require(manifest["backupID"] as? String)
        let backup = backupDirectory.appendingPathComponent("\(backupID).sqlite")
        #expect(try migrationScalar(at: backup, sql: "SELECT COUNT(*) FROM usage_facts;") == 1)
    }

    @Test func walWriterProcessStaysBlockedFromBackupUntilMigrationCommit() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        var walKeeper: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &walKeeper,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let walKeeper else {
            throw StoreError.openFailed(-1)
        }
        defer { sqlite3_close(walKeeper) }
        let walSQL = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO usage_facts VALUES (
                'wal-fact', 'synthetic-v1', 'codex', 'Codex', 'model', 'Model',
                'session', 'turn-wal', 2000000001, 5, 'measured', 'fixture', 'definition-v1'
            );
            """
        guard sqlite3_exec(walKeeper, walSQL, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(walSQL)
        }
        let writerProcess = Process()
        writerProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let writerAttempted = url.deletingLastPathComponent()
            .appendingPathComponent("writer-process-attempted")
        let processSQL = """
            INSERT INTO usage_facts (
                id, schema_version, coding_agent_raw, coding_agent_display,
                model_raw, model_display, session_id, turn_id, observed_at,
                output_tokens, measurement_quality, authority, definition_version
            ) VALUES (
                'process-fact', 'synthetic-v1', 'codex', 'Codex',
                'model', 'Model', 'session', 'turn-process', 2000000002,
                9, 'measured', 'fixture', 'definition-v1'
            );
            """
        writerProcess.arguments = [
            "-cmd", ".shell /usr/bin/touch \(writerAttempted.path)",
            "-cmd", ".timeout 5000",
            url.path, processSQL,
        ]
        writerProcess.standardOutput = Pipe()
        writerProcess.standardError = Pipe()
        let operations = DatabaseMigrationOperations(checkpoint: { checkpoint in
            guard checkpoint == .backupVerified else { return }
            try writerProcess.run()
            let attemptDeadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: writerAttempted.path),
                  writerProcess.isRunning,
                  Date() < attemptDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(FileManager.default.fileExists(atPath: writerAttempted.path))
            Thread.sleep(forTimeInterval: 0.2)
            #expect(writerProcess.isRunning)
        })

        let store = try SQLiteFactStore(
            url: url,
            resetCleanupOperations: .live,
            migrationOperations: operations
        )

        let deadline = Date().addingTimeInterval(6)
        while writerProcess.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if writerProcess.isRunning { writerProcess.terminate() }
        #expect(!writerProcess.isRunning)
        #expect(writerProcess.terminationStatus == 0)
        #expect(Set(try store.allFacts().map(\.id)) == [
            "legacy-fact", "wal-fact", "process-fact",
        ])
        let backupDirectory = migrationBackupDirectory(at: url)
        let manifest = try #require(try migrationManifests(in: backupDirectory).first)
        let backupID = try #require(manifest["backupID"] as? String)
        let backup = backupDirectory.appendingPathComponent("\(backupID).sqlite")
        #expect(try migrationScalar(at: backup, sql: "SELECT COUNT(*) FROM usage_facts;") == 2)
    }

    @Test func everyFailedMigrationCheckpointRollsBackAndRestartsFromItsIntactBackup() throws {
        let checkpoints: [DatabaseMigrationCheckpoint] = [
            .backupVerified, .schemaChangesApplied, .schemaValidated, .willCommit,
        ]
        for injectedCheckpoint in checkpoints {
            try verifyFailedMigrationCheckpoint(injectedCheckpoint)
        }
    }

    private func verifyFailedMigrationCheckpoint(_ injectedCheckpoint: DatabaseMigrationCheckpoint) throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        let operations = DatabaseMigrationOperations(checkpoint: { checkpoint in
            if checkpoint == injectedCheckpoint { throw InjectedMigrationFailure() }
        })

        #expect(throws: StoreError.databaseMigrationFailed(StoreMigrationFailure(
            sourceSchemaVersion: 0,
            targetSchemaVersion: 1,
            backupAvailable: true
        ))) {
            _ = try SQLiteFactStore(
                url: url,
                resetCleanupOperations: .live,
                migrationOperations: operations
            )
        }

        #expect(!migrationColumnNames(at: url, table: "usage_facts").contains("source_id"))
        #expect(try migrationScalar(
            at: url,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'schema_metadata';"
        ) == 0)
        let backupDirectory = migrationBackupDirectory(at: url)
        let failedManifest = try #require(
            try migrationManifests(in: backupDirectory).first
        )
        #expect(failedManifest["status"] as? String == "migrationFailed")
        let backupID = try #require(failedManifest["backupID"] as? String)
        let failedBackup = backupDirectory.appendingPathComponent("\(backupID).sqlite")
        let failedBackupBytes = try Data(contentsOf: failedBackup)
        #expect(try migrationIntegrityCheck(at: failedBackup) == "ok")

        let restarted = try SQLiteFactStore(url: url)

        #expect(try restarted.allFacts().map(\.id) == ["legacy-fact"])
        #expect(try migrationMetadataValue(at: url, key: "database_schema_version") == "1")
        #expect(try Data(contentsOf: failedBackup) == failedBackupBytes)
    }

    @Test func successfulMigrationCleanupKeepsThreeVerifiedBackupsIncludingLastGood() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)

        for migrationNumber in 0..<5 {
            _ = try SQLiteFactStore(url: url)
            if migrationNumber < 4 {
                try migrationExecuteSQL(
                    at: url,
                    sql: """
                        DELETE FROM schema_metadata WHERE key = 'database_schema_version';
                        INSERT OR REPLACE INTO schema_metadata (key, value)
                        VALUES ('schema_version', 'retention-v1');
                        """
                )
            }
        }

        let backupDirectory = migrationBackupDirectory(at: url)
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(entries.filter { $0.pathExtension == "sqlite" }.count == 3)
        let manifests = try migrationManifests(in: backupDirectory)
        #expect(manifests.count == 3)
        #expect(manifests.allSatisfy { $0["status"] as? String == "migrationSucceeded" })
        for manifest in manifests {
            let backupID = try #require(manifest["backupID"] as? String)
            let backup = backupDirectory.appendingPathComponent("\(backupID).sqlite")
            #expect(try migrationIntegrityCheck(at: backup) == "ok")
        }
        #expect(try SQLiteFactStore(url: url).allFacts().map(\.id) == ["legacy-fact"])
    }

    @Test func resetRemovesRealMigrationStateButPreservesSchemaPreferencesAndSourceLogs() throws {
        let url = migrationTemporaryStoreURL()
        let externalSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-external-source-\(UUID().uuidString).jsonl")
        defer {
            removeMigrationStore(at: url)
            try? FileManager.default.removeItem(at: externalSource)
        }
        try createLegacyMigrationFixture(at: url)
        try Data("source-owned".utf8).write(to: externalSource)
        let store = try SQLiteFactStore(url: url)
        let backupDirectory = migrationBackupDirectory(at: url)
        #expect(FileManager.default.fileExists(atPath: backupDirectory.path))
        try migrationExecuteSQL(
            at: url,
            sql: """
                CREATE TABLE app_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO app_preferences VALUES ('appearance', 'system');
                """
        )

        let result = try store.resetTelemetryData()

        #expect(result.cleanupState == .complete)
        #expect(!FileManager.default.fileExists(atPath: backupDirectory.path))
        #expect(try store.allFacts().isEmpty)
        #expect(try migrationMetadataValue(at: url, key: "database_schema_version") == "1")
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM app_preferences;") == 1)
        #expect(try String(contentsOf: externalSource, encoding: .utf8) == "source-owned")
    }

    @Test func migrationNeverStartsWhenVerifiedBackupCannotBeCreated() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        let blockedBackupDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("migration-backups")
        try Data("not-a-directory".utf8).write(to: blockedBackupDirectory)
        let before = try Data(contentsOf: url)

        #expect(throws: StoreError.migrationBackupFailed(StoreMigrationBackupFailure(
            sourceSchemaVersion: 0,
            targetSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(url: url)
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(!migrationColumnNames(at: url, table: "usage_facts").contains("source_id"))
        #expect(try migrationScalar(
            at: url,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'schema_metadata';"
        ) == 0)
    }

    @Test func manifestWriteFailureRemovesTheUntrackedBackupCopy() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        let backupDirectory = migrationBackupDirectory(at: url)
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: url,
            to: backupDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).sqlite")
        )
        let operations = DatabaseMigrationOperations(
            writeBackupManifest: { _, _ in throw InjectedMigrationFailure() }
        )

        #expect(throws: StoreError.migrationBackupFailed(StoreMigrationBackupFailure(
            sourceSchemaVersion: 0,
            targetSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(
                url: url,
                resetCleanupOperations: .live,
                migrationOperations: operations
            )
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(entries.allSatisfy { $0.pathExtension != "sqlite" })
        #expect(!migrationColumnNames(at: url, table: "usage_facts").contains("source_id"))
    }

    @Test func startupRemovesOrphanBackupsWithoutFollowingLinksOrDeletingLastGood() throws {
        let url = migrationTemporaryStoreURL()
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-orphan-target-\(UUID().uuidString).sqlite")
        defer {
            removeMigrationStore(at: url)
            try? FileManager.default.removeItem(at: external)
        }
        try createLegacyMigrationFixture(at: url)
        _ = try SQLiteFactStore(url: url)
        let directory = migrationBackupDirectory(at: url)
        let manifest = try #require(try migrationManifests(in: directory).first)
        let lastGoodID = try #require(manifest["backupID"] as? String)
        let lastGood = directory.appendingPathComponent("\(lastGoodID).sqlite")
        let lastGoodBytes = try Data(contentsOf: lastGood)
        let orphan = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).sqlite")
        try FileManager.default.copyItem(at: lastGood, to: orphan)
        try Data("external-telemetry-copy".utf8).write(to: external)
        let orphanLink = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).sqlite")
        try FileManager.default.createSymbolicLink(at: orphanLink, withDestinationURL: external)

        _ = try SQLiteFactStore(url: url)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: orphanLink.path))
        #expect(try Data(contentsOf: external) == Data("external-telemetry-copy".utf8))
        #expect(try Data(contentsOf: lastGood) == lastGoodBytes)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(lastGoodID).json").path
        ))
    }

    @Test func backupRootSymlinkCannotRedirectCleanupOrBackupCreationOutsideTheStore() throws {
        let url = migrationTemporaryStoreURL()
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-external-backups-\(UUID().uuidString)", isDirectory: true)
        defer {
            removeMigrationStore(at: url)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try SQLiteFactStore(url: url)
        let externalStoreDirectory = externalRoot.appendingPathComponent(
            migrationBackupDirectory(at: url).lastPathComponent,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalStoreDirectory,
            withIntermediateDirectories: true
        )
        let externalOrphan = externalStoreDirectory
            .appendingPathComponent("\(UUID().uuidString.lowercased()).sqlite")
        let externalBytes = Data("external-private-telemetry".utf8)
        try externalBytes.write(to: externalOrphan)
        let backupRoot = url.deletingLastPathComponent()
            .appendingPathComponent(MigrationBackupManager.directoryName, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: backupRoot, withDestinationURL: externalRoot)
        let staleStaging = url.deletingLastPathComponent().appendingPathComponent(
            ".migration-backup-staging-\(UUID().uuidString.lowercased()).sqlite"
        )
        let staleStagingBytes = Data("unowned-staging-like-file".utf8)
        try staleStagingBytes.write(to: staleStaging)

        _ = try SQLiteFactStore(url: url)

        #expect(try Data(contentsOf: externalOrphan) == externalBytes)
        #expect(try Data(contentsOf: staleStaging) == staleStagingBytes)
        try migrationExecuteSQL(
            at: url,
            sql: """
                DELETE FROM schema_metadata WHERE key = 'database_schema_version';
                INSERT OR REPLACE INTO schema_metadata (key, value)
                VALUES ('schema_version', 'retention-v1');
                """
        )
        #expect(throws: StoreError.migrationBackupFailed(StoreMigrationBackupFailure(
            sourceSchemaVersion: 0,
            targetSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(url: url)
        }
        #expect(try Data(contentsOf: externalOrphan) == externalBytes)
        #expect(try migrationMetadataValue(at: url, key: "database_schema_version") == nil)
    }

    @Test func storesSharingAParentCannotDeleteEachOthersMigrationStaging() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "database-migration-shared-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let firstURL = parent.appendingPathComponent("first.sqlite")
        let secondURL = parent.appendingPathComponent("second.sqlite")
        defer { try? FileManager.default.removeItem(at: parent) }
        try createLegacyMigrationFixture(at: firstURL)
        try createLegacyMigrationFixture(at: secondURL)
        let firstStagingCreated = DispatchSemaphore(value: 0)
        let resumeFirstMigration = DispatchSemaphore(value: 0)
        let firstFinished = DispatchGroup()
        let firstResult = MigrationStoreResult()
        firstFinished.enter()
        DispatchQueue.global().async {
            defer { firstFinished.leave() }
            do {
                let store = try SQLiteFactStore(
                    url: firstURL,
                    resetCleanupOperations: .live,
                    migrationOperations: DatabaseMigrationOperations(checkpoint: { checkpoint in
                        guard checkpoint == .backupStagingCreated else { return }
                        firstStagingCreated.signal()
                        guard resumeFirstMigration.wait(timeout: .now() + 5) == .success else {
                            throw InjectedMigrationFailure()
                        }
                    })
                )
                firstResult.storeSuccess(factIDs: try store.allFacts().map(\.id))
            } catch {
                firstResult.storeFailure()
            }
        }
        guard firstStagingCreated.wait(timeout: .now() + 5) == .success else {
            resumeFirstMigration.signal()
            #expect(Bool(false), "first store never created its VACUUM staging database")
            return
        }

        let secondStore = try SQLiteFactStore(url: secondURL)
        resumeFirstMigration.signal()

        #expect(firstFinished.wait(timeout: .now() + 5) == .success)
        #expect(firstResult.succeeded())
        #expect(firstResult.factIDs() == ["legacy-fact"])
        #expect(try secondStore.allFacts().map(\.id) == ["legacy-fact"])
        #expect(try migrationMetadataValue(
            at: firstURL,
            key: "database_schema_version"
        ) == "1")
        #expect(try migrationMetadataValue(
            at: secondURL,
            key: "database_schema_version"
        ) == "1")
    }

    @Test func replacedDatabaseParentCannotRedirectVacuumStagingOutsidePinnedDirectory() throws {
        let url = migrationTemporaryStoreURL()
        let originalParent = url.deletingLastPathComponent()
        let movedParent = originalParent.deletingLastPathComponent().appendingPathComponent(
            "\(originalParent.lastPathComponent)-moved"
        )
        let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "migration-vacuum-external-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            var info = stat()
            if lstat(originalParent.path, &info) == 0,
               info.st_mode & S_IFMT == S_IFLNK {
                _ = unlink(originalParent.path)
            } else {
                try? FileManager.default.removeItem(at: originalParent)
            }
            try? FileManager.default.removeItem(at: movedParent)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        try createLegacyMigrationFixture(at: url)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        var didReplaceParent = false
        let operations = DatabaseMigrationOperations(checkpoint: { checkpoint in
            guard checkpoint == .backupStagingPathResolved else { return }
            guard rename(originalParent.path, movedParent.path) == 0 else {
                throw StoreError.openFailed(errno)
            }
            guard symlink(externalRoot.path, originalParent.path) == 0 else {
                throw StoreError.openFailed(errno)
            }
            didReplaceParent = true
        })

        #expect(throws: StoreError.migrationBackupFailed(StoreMigrationBackupFailure(
            sourceSchemaVersion: 0,
            targetSchemaVersion: 1
        ))) {
            _ = try SQLiteFactStore(
                url: url,
                resetCleanupOperations: .live,
                migrationOperations: operations
            )
        }

        #expect(didReplaceParent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: externalRoot.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: movedParent.path)
            .allSatisfy { !$0.hasPrefix(".migration-backup-staging-") })
        let movedDatabase = movedParent.appendingPathComponent(url.lastPathComponent)
        #expect(try migrationScalar(at: movedDatabase, sql: "SELECT COUNT(*) FROM usage_facts;") == 1)
        #expect(try migrationScalar(
            at: movedDatabase,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'schema_metadata';"
        ) == 0)
    }

    @Test func unknownSchemaMetadataCannotBeMistakenForLegacyAndDowngraded() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try migrationExecuteSQL(
            at: url,
            sql: """
                CREATE TABLE schema_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO schema_metadata (key, value) VALUES ('future_schema_epoch', '9');
                CREATE TABLE future_private_data (payload TEXT NOT NULL);
                INSERT INTO future_private_data VALUES ('sentinel');
                """
        )
        let before = try Data(contentsOf: url)

        #expect(throws: StoreError.invalidDatabaseSchemaMetadata) {
            _ = try SQLiteFactStore(url: url)
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM future_private_data;") == 1)
        #expect(try migrationScalar(at: url, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'usage_facts';") == 0)
    }

    @Test func legacyPerformancePrimaryKeyMigrationPreservesCanonicalFacts() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        try migrationExecuteSQL(
            at: url,
            sql: """
                CREATE TABLE performance_facts (
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
                    PRIMARY KEY (
                        coding_agent_raw, stable_request_id, measurement_granularity,
                        measurement_range_start, measurement_range_end
                    )
                );
                INSERT INTO performance_facts VALUES (
                    'legacy-request', 'claude-code', 'Claude Code', 'model', 'Model',
                    2000000000, 1200, 150, 50, 0, 'claudeTelemetry', 'enhanced',
                    'modelCall', 1999999999, 2000000000
                );
                """
        )

        let store = try SQLiteFactStore(url: url)

        let fact = try #require(store.allPerformanceFacts().first)
        #expect(fact.stableRequestID == "legacy-request")
        #expect(fact.sourceID == "legacy-performance")
        #expect(fact.outputTotal == 50)
        #expect(fact.measurementQuality == .measured)
        #expect(try store.performanceFactColumnNames().isSuperset(of: [
            "source_id", "measurement_quality",
        ]))
        #expect(try migrationScalar(
            at: url,
            sql: "SELECT COUNT(*) FROM performance_facts WHERE stable_request_id = 'legacy-request';"
        ) == 1)
    }

    @Test func walBackedLegacyStoreProducesAConsistentBackupBeforeMigration() throws {
        let url = migrationTemporaryStoreURL()
        defer { removeMigrationStore(at: url) }
        try createLegacyMigrationFixture(at: url)
        var writer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let writer else {
            throw StoreError.openFailed(-1)
        }
        defer { sqlite3_close(writer) }
        let walSQL = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            INSERT INTO usage_facts VALUES (
                'wal-fact', 'synthetic-v1', 'codex', 'Codex', 'model', 'Model',
                'session', 'turn-2', 2000000001, 7, 'measured', 'fixture', 'definition-v1'
            );
            """
        guard sqlite3_exec(writer, walSQL, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(walSQL)
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

        let store = try SQLiteFactStore(url: url)

        #expect(try store.allFacts().map(\.id) == ["legacy-fact", "wal-fact"])
        let backupDirectory = migrationBackupDirectory(at: url)
        let manifest = try #require(try migrationManifests(in: backupDirectory).first)
        let backupID = try #require(manifest["backupID"] as? String)
        let backup = backupDirectory.appendingPathComponent("\(backupID).sqlite")
        #expect(try migrationIntegrityCheck(at: backup) == "ok")
        #expect(try migrationScalar(at: backup, sql: "SELECT COUNT(*) FROM usage_facts;") == 2)
    }
}

private struct InjectedMigrationFailure: Error {}

private final class MigrationWriterResult: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    func store(_ status: Int32) {
        lock.lock()
        self.status = status
        lock.unlock()
    }

    func load() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

private final class MigrationStoreResult: @unchecked Sendable {
    private let lock = NSLock()
    private var didSucceed = false
    private var storedFactIDs: [String] = []

    func storeSuccess(factIDs: [String]) {
        lock.lock()
        didSucceed = true
        storedFactIDs = factIDs
        lock.unlock()
    }

    func storeFailure() {
        lock.lock()
        didSucceed = false
        storedFactIDs = []
        lock.unlock()
    }

    func succeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didSucceed
    }

    func factIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedFactIDs
    }
}

private func migrationTemporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("database-migration-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("facts.sqlite")
}

private func migrationBackupDirectory(at url: URL) -> URL {
    MigrationBackupManager.directory(for: url)
}

private func removeMigrationStore(at url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func migrationExecuteSQL(at url: URL, sql: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let database else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw StoreError.execFailed(sql)
    }
}

private func createLegacyMigrationFixture(at url: URL) throws {
    try migrationExecuteSQL(
        at: url,
        sql: """
            CREATE TABLE usage_facts (
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
                definition_version TEXT NOT NULL
            );
            INSERT INTO usage_facts VALUES (
                'legacy-fact', 'synthetic-v1', 'codex', 'Codex', 'model', 'Model',
                'session', 'turn', 2000000000, 42, 'measured', 'fixture', 'definition-v1'
            );
            """
    )
}

private func createFutureMigrationFixture(at url: URL) throws {
    try migrationExecuteSQL(
        at: url,
        sql: """
            CREATE TABLE schema_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO schema_metadata (key, value) VALUES ('database_schema_version', '2');
            CREATE TABLE future_private_data (payload TEXT NOT NULL);
            INSERT INTO future_private_data (payload) VALUES ('sentinel');
            """
    )
}

private func migrationColumnNames(at url: URL, table: String) -> Set<String> {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        return []
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        return []
    }
    defer { sqlite3_finalize(statement) }
    var names = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 1) {
        names.insert(String(cString: value))
    }
    return names
}

private func migrationManifests(in directory: URL) throws -> [[String: Any]] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .map { url in
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw StoreError.invalidRow
            }
            return object
        }
}

private func migrationMetadataValue(at url: URL, key: String) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT value FROM schema_metadata WHERE key = ? LIMIT 1;",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw StoreError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
        return nil
    }
    return String(cString: value)
}

private func migrationIntegrityCheck(at url: URL) throws -> String {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw StoreError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let result = sqlite3_column_text(statement, 0) else {
        throw StoreError.invalidRow
    }
    return String(cString: result)
}

private func migrationScalar(at url: URL, sql: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw StoreError.openFailed(-1)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw StoreError.prepareFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.invalidRow }
    return Int(sqlite3_column_int64(statement, 0))
}
