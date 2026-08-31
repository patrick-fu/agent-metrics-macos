import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct CodexRolloutIngestTests {
    @Test func resetCutoffExcludesExistingAndEqualTimestampRolloutObservations() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1_800, lastOutput: 1_800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1_800)

        _ = try runtime.resetData()
        let resetStore = try SQLiteFactStore(url: storeURL)
        #expect(try resetStore.sourceState(sourceID: "codex") == nil)
        #expect(try resetStore.telemetryResetCutoff() == clock.now)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().isEmpty)

        try home.appendActiveRollout(tokenCountLine(
            totalOutput: 2_200,
            lastOutput: 400,
            timestamp: "2026-04-15T12:00:20.000Z",
            ordinal: 4
        ))
        try home.appendActiveRollout(tokenCountLine(
            totalOutput: 2_700,
            lastOutput: 500,
            timestamp: "2026-04-15T12:00:21.000Z",
            ordinal: 5
        ))
        let restarted = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: FixedClock(now: isoDate("2026-04-15T12:00:30Z"))
        )
        #expect(try restarted.lightSnapshot().outputThroughput.selectedOutputTokens == 500)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [500])
    }

    @Test func resetWhileRolloutIsMissingDoesNotReingestHistoryAfterRecovery() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let initial = [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1_800, lastOutput: 1_800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ]
        try home.writeActiveRollout(lines: initial, terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        _ = try runtime.lightSnapshot()
        try FileManager.default.removeItem(at: home.activeURL)

        _ = try runtime.resetData()
        #expect(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex") == nil)
        try home.writeActiveRollout(lines: initial, terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().isEmpty)

        try home.appendActiveRollout(tokenCountLine(
            totalOutput: 2_700,
            lastOutput: 900,
            timestamp: "2026-04-15T12:00:21.000Z",
            ordinal: 4
        ))
        let laterClock = FixedClock(now: isoDate("2026-04-15T12:00:30Z"))
        let restarted = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: laterClock
        )
        #expect(try restarted.lightSnapshot().outputThroughput.selectedOutputTokens == 900)
    }

    @Test func resetSucceedsWithoutScanningAFailingAdapterAndCutoffFiltersAfterRecovery() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(), turnContextLine(),
            tokenCountLine(totalOutput: 1_800, lastOutput: 1_800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        let adapter = FlakyCodexAdapter(inner: CodexRolloutSourceAdapter(sessionRoot: home.root))
        let runtime = try TelemetryRuntime(storeURL: storeURL, sourceAdapter: adapter, clock: clock)
        _ = try runtime.lightSnapshot()
        adapter.failNext = true

        _ = try runtime.resetData()
        #expect(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex") == nil)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        adapter.failNext = false
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().isEmpty)
    }

    @Test func disappearedRolloutKeepsFactsAndCursorUnavailableUntilRecoveryWithoutDoubleCount() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let initial = [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1_800, lastOutput: 1_800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ]
        try home.writeActiveRollout(lines: initial, terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1_800)
        let stateBefore = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))

        try FileManager.default.removeItem(at: home.activeURL)
        let unavailable = try runtime.lightSnapshot()
        #expect(unavailable.outputThroughput.selectedOutputTokens == 1_800)
        #expect(unavailable.outputThroughput.coverage == .partial)
        #expect(runtime.sourceHealth.contains { $0.sourceID == "codex" && $0.diagnosticCode == "SOURCE_UNAVAILABLE" && !$0.isHealthy })
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1_800])
        #expect(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex")?.files == stateBefore.files)

        try home.writeActiveRollout(lines: initial + [
            tokenCountLine(totalOutput: 2_700, lastOutput: 900, timestamp: "2026-04-15T12:00:15.000Z", ordinal: 4),
        ], terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2_700)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens).reduce(0, +) == 2_700)
    }

    @Test func oversizedContentLineIsSkippedBoundedlyAndFollowingUsageRemainsReachable() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let privateBody = String(repeating: "CONTENT_DO_NOT_PERSIST_", count: 30_000)
        let oversizedContent = """
        {"timestamp":"2026-04-15T12:00:00.000Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(privateBody)"}]}}
        """
        #expect(oversizedContent.utf8.count > CodexRolloutSourceAdapter.maximumAppendBytesPerFile)
        try home.writeActiveRollout(lines: [
            oversizedContent,
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 4),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )

        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        let firstState = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))
        #expect(firstState.files.values.first?.offset == Int64(CodexRolloutSourceAdapter.maximumAppendBytesPerFile))
        #expect(firstState.files.values.first?.discardingOversizedLine == true)

        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(runtime.sourceHealth.contains { $0.diagnosticCode == "SOURCE_LINE_TOO_LONG" })
        let encodedState = try String(decoding: JSONEncoder().encode(
            #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))
        ), as: UTF8.self)
        #expect(!encodedState.contains("CONTENT_DO_NOT_PERSIST"))
    }

    @Test func thirdBoundedBatchRetainsSessionTurnAndModelContext() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let ignored = """
        {"timestamp":"2026-04-15T12:00:02.000Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(String(repeating: "S", count: 1_024))"}]}}
        """
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
        ] + Array(repeating: ignored, count: 1_100) + [
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 1_104),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )

        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()
        _ = try runtime.lightSnapshot()

        let fact = try #require(try SQLiteFactStore(url: storeURL).allFacts().first)
        #expect(fact.sessionID == "01900000-0000-7000-8000-000000000013")
        #expect(fact.turnID == "01900000-0000-7000-8000-000000000113")
        #expect(fact.model.raw == "gpt-synthetic-orion")
        #expect(fact.model.display == "gpt-synthetic-orion")
        let state = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))
        let context = try #require(state.files.values.first?.parserContext)
        #expect(context.sessionID == fact.sessionID)
        #expect(context.turnID == fact.turnID)
        #expect(context.model == fact.model)
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains(String(repeating: "S", count: 64)))
    }

    @Test func legacyFileCursorDecodesWithoutMutationMetadataOrParserContext() throws {
        let payload = Data(#"{"fileIdentity":"file","locator":"relative","generation":"1","prefixFingerprint":"hash","offset":42,"parserVersion":"1"}"#.utf8)

        let cursor = try JSONDecoder().decode(SourceFileCursor.self, from: payload)

        #expect(cursor.lastObservedSize == nil)
        #expect(cursor.lastModifiedAt == nil)
        #expect(cursor.parserContext == nil)
        #expect(cursor.discardingOversizedLine == nil)
    }

    @Test func sameLengthConsumedMiddleRewriteRebuildsInsteadOfSilentlyContinuing() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let padding = Array(repeating: sessionMetaLine(), count: 250)
        let original = padding + [
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ] + padding
        try home.writeActiveRollout(lines: original, terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)

        let replacement = padding + [
            turnContextLine(),
            tokenCountLine(totalOutput: 2700, lastOutput: 2700, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ] + padding
        try rewriteInPlace(
            home.activeURL,
            body: replacement.joined(separator: "\n") + "\n"
        )

        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)
        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.outputTokens == 2700)
    }

    @Test func productionScanReadsAtMostOneBoundedAppendBatchPerFile() throws {
        let home = try TempCodexHome()
        defer { home.tearDown() }
        try home.writeActiveRollout(
            lines: Array(repeating: sessionMetaLine(), count: 10_000),
            terminated: true
        )

        let adapter = CodexRolloutSourceAdapter(sessionRoot: home.root)
        var scan = try adapter.scan(
            clock: FixedClock(now: isoDate("2026-04-15T12:00:20Z")),
            state: nil
        )
        let cursor = try #require(scan.state.files.values.first)

        #expect(cursor.offset <= Int64(CodexRolloutSourceAdapter.maximumAppendBytesPerFile))
        #expect(scan.diagnostics.contains { $0.code == "SOURCE_OVERLOADED" })
        #expect(CodexRolloutSourceAdapter.maximumRolloutFiles == 256)

        for _ in 0..<16 where scan.diagnostics.contains(where: { $0.code == "SOURCE_OVERLOADED" }) {
            scan = try adapter.scan(
                clock: FixedClock(now: isoDate("2026-04-15T12:00:20Z")),
                state: scan.state
            )
        }
        #expect(!scan.diagnostics.contains { $0.code == "SOURCE_OVERLOADED" })
    }

    @Test func scanKeepsNewestRolloutsReachableWhenDiscoveryExceedsFileLimit() throws {
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let base = isoDate("2026-04-15T12:00:00Z")
        var newestURL: URL?

        for index in 0...CodexRolloutSourceAdapter.maximumRolloutFiles {
            let identity = String(format: "01900000-0000-7000-8000-%012d", index)
            let url = home.activeDirectory.appendingPathComponent(
                "rollout-2026-04-15T12-00-00-\(identity).jsonl"
            )
            try [
                sessionMetaLine(),
                turnContextLine(),
                tokenCountLine(
                    totalOutput: index,
                    lastOutput: index,
                    timestamp: "2026-04-15T12:00:10.000Z",
                    ordinal: 3
                ),
            ].joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: url.path
            )
            if index == CodexRolloutSourceAdapter.maximumRolloutFiles {
                newestURL = url
            }
        }

        let adapter = CodexRolloutSourceAdapter(sessionRoot: home.root)
        let first = try adapter.scan(clock: FixedClock(now: base), state: nil)

        #expect(first.state.files.count == CodexRolloutSourceAdapter.maximumRolloutFiles)
        #expect(first.observations.contains { $0.outputTokens == CodexRolloutSourceAdapter.maximumRolloutFiles })
        #expect(first.diagnostics.contains { $0.code == "SOURCE_OVERLOADED" })
        #expect(!first.health.isHealthy)
        #expect(first.health.diagnosticCode == "SOURCE_OVERLOADED")

        let stable = try adapter.scan(clock: FixedClock(now: base), state: first.state)
        #expect(stable.state.files.keys.sorted() == first.state.files.keys.sorted())

        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(-1)],
            ofItemAtPath: try #require(newestURL).path
        )
        let second = try adapter.scan(clock: FixedClock(now: base), state: stable.state)
        #expect(second.health.diagnosticCode == "SOURCE_OVERLOADED")
        #expect(!second.health.isHealthy)
    }

    @Test func scanKeepsActiveRolloutReachableWhenCombinedRootsExceedThePerRootDiscoveryBudget() throws {
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let decoysPerRoot = CodexRolloutSourceAdapter.maximumDirectoryEntries / 2 + 1

        // Each source root remains below the bounded traversal budget, while their
        // combined entry count exceeds it. One noisy archive must not prevent the
        // independently bounded active-session root from being scanned.
        for index in 0..<decoysPerRoot {
            let archivedDecoy = home.archivedDirectory.appendingPathComponent("archived-decoy-\(index).tmp")
            let activeDecoy = home.activeDirectory.appendingPathComponent("active-decoy-\(index).tmp")
            try Data().write(to: archivedDecoy)
            try Data().write(to: activeDecoy)
        }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(
                totalOutput: 314,
                lastOutput: 314,
                timestamp: "2026-04-15T12:00:10.000Z",
                ordinal: 3
            ),
        ], terminated: true)

        let scan = try CodexRolloutSourceAdapter(sessionRoot: home.root).scan(
            clock: FixedClock(now: isoDate("2026-04-15T12:00:20Z")),
            state: nil
        )

        #expect(scan.observations.contains { $0.outputTokens == 314 })
        #expect(scan.state.files.count == 1)
        #expect(scan.health.isHealthy)
    }

    @Test func versionedCodexRolloutWithoutCallIdentityReachesSQLiteAndLightSnapshot() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: FixtureLocator.codexHomeV1),
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()

        #expect(snapshot.outputThroughput.windowSeconds == 180)
        #expect(snapshot.outputThroughput.selectedOutputTokens == 1800)
        #expect(snapshot.outputThroughput.tokensPerSecond == 10)
        #expect(snapshot.outputThroughput.measurementQuality == .derived)
        #expect(snapshot.outputThroughput.dataState == nil)
        #expect(snapshot.outputThroughput.coverage == .complete)
        #expect(snapshot.outputThroughput.sourceAuthority == "codex-rollout-token-count")
        #expect(snapshot.outputThroughput.definitionVersion == "output-throughput-v1")
        #expect(snapshot.codingAgents.map(\.rawValue) == ["codex"])
        #expect(snapshot.modelIdentities.map(\.raw) == ["gpt-synthetic-orion"])
        #expect(snapshot.modelIdentities.map(\.display) == ["gpt-synthetic-orion"])
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("Decode"))
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("TPS"))
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("Calls"))

        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.count == 1)
        #expect(facts[0].outputTokens == 1800)
        #expect(facts[0].schemaVersion == "codex-rollout-v1")
        #expect(facts[0].authority == "codex-rollout-token-count")
        #expect(facts[0].sessionID == "01900000-0000-7000-8000-000000000013")
        #expect(facts[0].turnID == "01900000-0000-7000-8000-000000000113")
        #expect(facts[0].model.raw == "gpt-synthetic-orion")
        #expect(!facts[0].id.contains("/Users/"))
        #expect(!facts[0].sessionID.contains("/Users/"))
    }

    @Test func incompleteTailIsIgnoredUntilTheLineCompletes() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: false)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        #expect(try runtime.lightSnapshot().outputThroughput.dataState == .absent)

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
    }

    @Test func incompleteContentTailIsNeverPersistedAndIsReReadWhenCompleted() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let content = "INCOMPLETE_PROMPT_CODE_TOOL_LEAK_DO_NOT_STORE"
        let contentLine = """
        {"timestamp":"2026-04-15T12:00:03.000Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\(content)"}]}}
        """
        let incomplete = String(contentLine.dropLast(2))
        let completePrefix = "\(sessionMetaLine())\n\(turnContextLine())\n"

        try home.writeActiveRollout(lines: [sessionMetaLine(), turnContextLine(), incomplete], terminated: false)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        let state = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))
        let encodedState = try String(decoding: JSONEncoder().encode(state), as: UTF8.self)
        #expect(!encodedState.contains(content))
        #expect(state.files.values.allSatisfy { $0.offset == Int64(Data(completePrefix.utf8).count) })

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            contentLine,
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 4),
        ], terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        let completedState = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))
        #expect(!(try String(decoding: JSONEncoder().encode(completedState), as: UTF8.self)).contains(content))
    }

    @Test func incrementalFactAndStateMutationRollsBackTogetherOnFailure() throws {
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try SQLiteFactStore(url: storeURL)
        let original = directFact(id: "atomic-original", outputTokens: 100)
        let originalState = SourceState(sourceID: "atomic", parserVersion: "1")
        try store.applyIncremental(facts: [original], deleting: [], state: originalState)

        let replacement = directFact(id: "atomic-replacement", outputTokens: 200)
        let replacementState = SourceState(sourceID: "atomic", parserVersion: "2")
        #expect(throws: InjectedStoreFailure.self) {
            try store.applyIncremental(
                facts: [replacement],
                deleting: [.schemaVersion("atomic-v1")],
                state: replacementState,
                failureInjection: { throw InjectedStoreFailure.planned }
            )
        }
        #expect(try store.allFacts() == [original])
        #expect(try store.sourceState(sourceID: "atomic") == originalState)
    }

    @Test func genericIncrementalAdapterOwnsFactDeletionScopeAndFailureHealthSource() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let adapter = GenericIncrementalAdapter(clock: clock)
        let runtime = try TelemetryRuntime(storeURL: storeURL, sourceAdapter: adapter, clock: clock)

        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 100)
        adapter.shouldRebuild = true
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 240)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.id) == ["other-source-observation-2"])

        adapter.shouldFail = true
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 240)
        #expect(runtime.sourceHealth == [
            SourceHealth(sourceID: "other-source", isHealthy: false, diagnosticCode: "SOURCE_FAILURE"),
        ])
    }

    @Test func coldScanMatchesIncrementalAppend() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }

        let first = [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ]
        let second = tokenCountLine(
            totalOutput: 2700,
            lastOutput: 900,
            timestamp: "2026-04-15T12:00:12.000Z",
            ordinal: 4
        )

        let incrementalStore = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: incrementalStore) }
        try home.writeActiveRollout(lines: first, terminated: true)
        let incrementalRuntime = try TelemetryRuntime(
            storeURL: incrementalStore,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try incrementalRuntime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        try home.writeActiveRollout(lines: first + [second], terminated: true)
        let incrementalSnapshot = try incrementalRuntime.lightSnapshot()
        let incrementalFacts = try SQLiteFactStore(url: incrementalStore).allFacts()

        let coldHome = try TempCodexHome()
        defer { coldHome.tearDown() }
        try coldHome.writeActiveRollout(lines: first + [second], terminated: true)
        let coldStore = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: coldStore) }
        let coldRuntime = try TelemetryRuntime(
            storeURL: coldStore,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: coldHome.root),
            clock: clock
        )
        let coldSnapshot = try coldRuntime.lightSnapshot()
        let coldFacts = try SQLiteFactStore(url: coldStore).allFacts()

        #expect(incrementalSnapshot.outputThroughput.selectedOutputTokens == 2700)
        #expect(coldSnapshot.outputThroughput.selectedOutputTokens == 2700)
        #expect(incrementalFacts.map(\.outputTokens) == [1800, 900])
        #expect(coldFacts.map(\.outputTokens) == incrementalFacts.map(\.outputTokens))
        #expect(Set(coldFacts.map(\.id)) == Set(incrementalFacts.map(\.id)))
    }

    @Test func replayedCumulativeTotalsAddZero() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let lines = [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:11.000Z", ordinal: 4),
        ]
        try home.writeActiveRollout(lines: lines, terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800])
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800])
    }

    @Test func rollbackRebuildsSourceAndNeverCreatesNegativeFacts() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
            tokenCountLine(totalOutput: 2700, lastOutput: 900, timestamp: "2026-04-15T12:00:11.000Z", ordinal: 4),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
            tokenCountLine(totalOutput: 2700, lastOutput: 900, timestamp: "2026-04-15T12:00:11.000Z", ordinal: 4),
            tokenCountLine(totalOutput: 100, lastOutput: 100, timestamp: "2026-04-15T12:00:12.000Z", ordinal: 5),
        ], terminated: true)
        let snapshot = try runtime.lightSnapshot()
        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.allSatisfy { $0.outputTokens >= 0 })
        #expect(facts.map(\.outputTokens) == [100])
        #expect(snapshot.outputThroughput.selectedOutputTokens == 100)
    }

    @Test func truncateReplaceRestartAndArchiveStayConsistent() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let first = [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
            tokenCountLine(totalOutput: 2700, lastOutput: 900, timestamp: "2026-04-15T12:00:11.000Z", ordinal: 4),
        ]
        try home.writeActiveRollout(lines: first, terminated: true)
        var runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)

        try home.writeActiveRollout(lines: [
            sessionMetaLine(sessionID: "01900000-0000-7000-8000-000000000099"),
            turnContextLine(model: "gpt-synthetic-vega"),
            tokenCountLine(totalOutput: 360, lastOutput: 360, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        let replaced = try runtime.lightSnapshot()
        #expect(replaced.outputThroughput.selectedOutputTokens == 360)
        #expect(replaced.modelIdentities.map(\.raw) == ["gpt-synthetic-vega"])

        runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 360)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [360])

        try home.archiveActiveRollout()
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 360)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [360])
    }

    @Test func unknownSchemaIsUnavailableAndNeverZero() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            """
            {"timestamp":"2026-04-15T12:00:10.000Z","ordinal":2,"type":"experimental_usage_v9","payload":{"output_tokens":9999,"model":"gpt-synthetic-orion"}}
            """,
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.tokensPerSecond == nil)
        #expect(snapshot.outputThroughput.selectedOutputTokens == nil)
        #expect(snapshot.outputThroughput.measurementQuality == .unavailable)
        #expect(snapshot.outputThroughput.dataState != .zero)
        #expect(runtime.sourceHealth.contains { health in
            health.sourceID == "codex" && health.diagnosticCode == "UNKNOWN_SCHEMA" && !health.isHealthy
        })
        #expect(try SQLiteFactStore(url: storeURL).allFacts().isEmpty)
    }

    @Test func invalidCumulativeSubsetDoesNotAdvancePartWatermarksBeforeALegalRecovery() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(
                totalOutput: 100, lastOutput: 100, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3,
                inputTotal: 5_000, cachedInput: 6_000, reasoningOutput: 40
            ),
            tokenCountLine(
                totalOutput: 500, lastOutput: 400, timestamp: "2026-04-15T12:00:11.000Z", ordinal: 4,
                inputTotal: 6_000, cachedInput: 3_000, reasoningOutput: 100
            ),
        ], terminated: true)

        let observations = try CodexRolloutSourceAdapter(sessionRoot: home.root).loadObservations(clock: clock)
        #expect(observations.count == 2)
        #expect(observations[0].tokenParts == nil)
        #expect(observations[1].tokenParts == TokenParts(
            inputUncached: 3_000,
            cacheRead: 3_000,
            cacheWrite: nil,
            outputVisible: 400,
            reasoning: 100,
            normalizedBurnTotal: 6_500
        ))
    }

    @Test func unknownEventMessageWithoutUsageFailsClosed() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            """
            {"timestamp":"2026-04-15T12:00:10.000Z","ordinal":2,"type":"event_msg","payload":{"type":"future_event_without_usage","message":"not an allowlisted event"}}
            """,
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )

        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.measurementQuality == .unavailable)
        #expect(runtime.sourceHealth == [
            SourceHealth.usage(sourceID: "codex", codingAgent: .codex, channel: .codexRollout, isHealthy: false, diagnosticCode: "UNKNOWN_SCHEMA"),
        ])
        #expect(try SQLiteFactStore(url: storeURL).allFacts().isEmpty)
    }

    @Test func parserVersionChangeRebuildsSourceAndClearsWatermarks() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        let identity = try #require(CodexRolloutParser.fileIdentity(fromFileName: home.activeURL.lastPathComponent))
        let store = try SQLiteFactStore(url: storeURL)
        var staleFact = directFact(id: "codex-rollout:\(identity):stale", outputTokens: 9_999)
        staleFact.schemaVersion = CodexRolloutParser.schemaVersion
        staleFact.authority = CodexRolloutParser.authority
        try store.upsert([staleFact])
        try store.saveSourceState(SourceState(
            sourceID: "codex",
            parserVersion: "previous-semantic-version",
            files: [identity: SourceFileCursor(
                fileIdentity: identity,
                locator: "sessions/synthetic.jsonl",
                generation: "legacy",
                prefixFingerprint: "legacy",
                offset: 1_500_000,
                parserVersion: "previous-semantic-version"
            )],
            watermarks: [identity: 0]
        ))
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )

        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(runtime.sourceHealth == [
            SourceHealth.usage(sourceID: "codex", codingAgent: .codex, channel: .codexRollout, isHealthy: false, diagnosticCode: "PARSER_VERSION_CHANGED"),
        ])
        let state = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex"))
        #expect(state.parserVersion == CodexRolloutParser.semanticVersion)
        #expect(state.watermarks[identity] == 1800)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800])
    }

    @Test func persistedCursorSurvivesRestartWithoutDoubleCounting() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        let first = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try first.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        let state = try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex")
        #expect(state?.parserVersion == CodexRolloutParser.semanticVersion)
        #expect(state?.files.isEmpty == false)
        #expect(state?.files.values.contains { cursor in
            cursor.locator.hasPrefix("sessions/")
                && !cursor.locator.contains("/Users/")
                && cursor.offset > 0
                && cursor.parserVersion == CodexRolloutParser.semanticVersion
        } == true)

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
            tokenCountLine(totalOutput: 2700, lastOutput: 900, timestamp: "2026-04-15T12:00:12.000Z", ordinal: 4),
        ], terminated: true)
        let restarted = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try restarted.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800, 900])
    }

    @Test func restartPreservesEveryCumulativeTokenWatermarkForAppendDeltas() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        _ = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        ).lightSnapshot()

        try home.appendActiveRollout(
            tokenCountLine(totalOutput: 1900, lastOutput: 100, timestamp: "2026-04-15T12:00:12.000Z", ordinal: 4)
        )
        _ = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        ).lightSnapshot()

        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.map(\.outputTokens) == [1800, 100])
        #expect(facts.map(\.tokenParts?.normalizedBurnTotal) == [6800, 100])
        #expect(facts[1].tokenParts == TokenParts(
            inputUncached: 0, cacheRead: 0, cacheWrite: nil,
            outputVisible: 100, reasoning: 0, normalizedBurnTotal: 100
        ))
    }

    @Test func contentBearingLinesAndUserPathsAreNotPersisted() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            """
            {"timestamp":"2026-04-15T12:00:03.000Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"PROMPT_LEAK_DO_NOT_STORE"}]}}
            """,
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 4),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: CodexRolloutSourceAdapter(sessionRoot: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.count == 1)
        let encoded = try String(contentsOf: storeURL, encoding: .isoLatin1)
        #expect(!encoded.contains("PROMPT_LEAK_DO_NOT_STORE"))
        #expect(!encoded.contains("/Users/"))
        if let state = try SQLiteFactStore(url: storeURL).sourceState(sourceID: "codex") {
            #expect(state.files.values.allSatisfy { !$0.locator.contains("/Users/") && !$0.fileIdentity.contains("/") })
        }
    }

    @Test func bundledFixtureAndSourcesDoNotEmbedUserAbsolutePaths() throws {
        let fixture = try String(contentsOf: FixtureLocator.codexHomeV1Rollout, encoding: .utf8)
        #expect(!fixture.contains("/Users/"))
        #expect(fixture.contains("\"type\":\"token_count\""))
        #expect(fixture.contains("\"schema_version\"") == false)
    }

    @Test func defaultAdapterResolvesSessionRootAtRuntime() {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-codex-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolated) }
        let resolved = CodexHome.resolve(environment: ["CODEX_HOME": isolated.path])
        #expect(resolved.standardizedFileURL == isolated.standardizedFileURL)
    }

    @Test func failingCodexScanKeepsLastGoodSnapshot() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempCodexHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try home.writeActiveRollout(lines: [
            sessionMetaLine(),
            turnContextLine(),
            tokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)
        let adapter = FlakyCodexAdapter(inner: CodexRolloutSourceAdapter(sessionRoot: home.root))
        let runtime = try TelemetryRuntime(storeURL: storeURL, sourceAdapter: adapter, clock: clock)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        adapter.failNext = true
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.selectedOutputTokens == 1800)
        #expect(runtime.sourceHealth.contains { $0.sourceID == "codex" && !$0.isHealthy })
    }
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cam-codex-\(UUID().uuidString).sqlite")
}

private enum InjectedStoreFailure: Error {
    case planned
}

private func directFact(id: String, outputTokens: Int) -> UsageFact {
    UsageFact(
        id: id,
        schemaVersion: "atomic-v1",
        codingAgent: .codex,
        model: ModelIdentity(raw: "atomic-model", display: "Atomic Model"),
        sessionID: "atomic-session",
        turnID: "atomic-turn",
        observedAt: Date(timeIntervalSince1970: 1_771_200),
        outputTokens: outputTokens,
        measurementQuality: .measured,
        authority: "atomic",
        definitionVersion: OutputThroughputDefinition.version
    )
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}

private func sessionMetaLine(
    sessionID: String = "01900000-0000-7000-8000-000000000013"
) -> String {
    """
    {"timestamp":"2026-04-15T12:00:00.000Z","ordinal":1,"type":"session_meta","payload":{"session_id":"\(sessionID)","id":"\(sessionID)","timestamp":"2026-04-15T12:00:00.000Z","cwd":"/tmp/synthetic-codex-workspace","originator":"codex-cli","cli_version":"0.145.0","source":"cli","model_provider":"openai"}}
    """
}

private func turnContextLine(model: String = "gpt-synthetic-orion") -> String {
    """
    {"timestamp":"2026-04-15T12:00:01.000Z","ordinal":2,"type":"turn_context","payload":{"turn_id":"01900000-0000-7000-8000-000000000113","cwd":"/tmp/synthetic-codex-workspace","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"model":"\(model)","summary":"auto"}}
    """
}

private func tokenCountLine(
    totalOutput: Int,
    lastOutput: Int,
    timestamp: String,
    ordinal: Int,
    inputTotal: Int = 5_000,
    cachedInput: Int = 3_000,
    reasoningOutput: Int = 400
) -> String {
    """
    {"timestamp":"\(timestamp)","ordinal":\(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(inputTotal),"cached_input_tokens":\(cachedInput),"cache_write_input_tokens":800,"output_tokens":\(totalOutput),"reasoning_output_tokens":\(reasoningOutput),"total_tokens":6800},"last_token_usage":{"input_tokens":\(inputTotal),"cached_input_tokens":\(cachedInput),"cache_write_input_tokens":800,"output_tokens":\(lastOutput),"reasoning_output_tokens":\(reasoningOutput),"total_tokens":6800},"model_context_window":128000},"rate_limits":null}}
    """
}

private func rewriteInPlace(_ url: URL, body: String) throws {
    let before = try FileManager.default.attributesOfItem(atPath: url.path)
    let beforeSize = (before[.size] as? NSNumber)?.int64Value
    let beforeInode = (before[.systemFileNumber] as? NSNumber)?.uint64Value
    #expect(beforeSize == Int64(body.utf8.count))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(body.utf8))
    try handle.synchronize()
    let previousModified = before[.modificationDate] as? Date ?? Date()
    try FileManager.default.setAttributes(
        [.modificationDate: previousModified.addingTimeInterval(5)],
        ofItemAtPath: url.path
    )
    let after = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((after[.systemFileNumber] as? NSNumber)?.uint64Value == beforeInode)
    #expect((after[.size] as? NSNumber)?.int64Value == beforeSize)
}

private final class TempCodexHome {
    let root: URL
    private let fileName = "rollout-2026-04-15T12-00-00-01900000-0000-7000-8000-000000000013.jsonl"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)
    }

    var activeDirectory: URL {
        root.appendingPathComponent("sessions/2026/04/15", isDirectory: true)
    }

    var archivedDirectory: URL {
        root.appendingPathComponent("archived_sessions", isDirectory: true)
    }

    var activeURL: URL {
        activeDirectory.appendingPathComponent(fileName)
    }

    func writeActiveRollout(lines: [String], terminated: Bool) throws {
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        var body = lines.joined(separator: "\n")
        if terminated {
            body.append("\n")
        }
        try body.write(to: activeURL, atomically: true, encoding: .utf8)
    }

    func appendActiveRollout(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: activeURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    func archiveActiveRollout() throws {
        let destination = archivedDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: activeURL, to: destination)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FlakyCodexAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let inner: CodexRolloutSourceAdapter
    var failNext = false

    init(inner: CodexRolloutSourceAdapter) {
        self.inner = inner
    }

    var sourceID: String { inner.sourceID }

    var sourceRebuildScope: SourceFactScope { inner.sourceRebuildScope }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        inner.rebuiltFileScope(for: identity)
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        try scan(clock: clock, state: nil).observations
    }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        if failNext {
            throw AdapterError.unsupportedSchema("codex-isolated-failure")
        }
        return try inner.scan(clock: clock, state: state)
    }
}

private final class GenericIncrementalAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let clock: any Clock
    var shouldRebuild = false
    var shouldFail = false

    init(clock: any Clock) {
        self.clock = clock
    }

    var sourceID: String { "other-source" }

    var sourceRebuildScope: SourceFactScope { .schemaVersion("other-source-v1") }

    func rebuiltFileScope(for identity: String) -> SourceFactScope {
        .idPrefix("other-source:\(identity):")
    }

    func loadObservations(clock: any Clock) throws -> [UsageObservation] {
        try scan(clock: clock, state: nil).observations
    }

    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan {
        if shouldFail {
            throw AdapterError.unsupportedSchema("other-source-failure")
        }
        let observation = UsageObservation(
            observationIdentity: shouldRebuild ? "other-source-observation-2" : "other-source-observation-1",
            schemaVersion: "other-source-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: "other-model", display: "Other Model"),
            sessionID: "other-session",
            turnID: "other-turn",
            observedAt: clock.now.addingTimeInterval(-1),
            outputTokens: shouldRebuild ? 240 : 100
        )
        return SourceScan(
            observations: [observation],
            state: SourceState(sourceID: sourceID, parserVersion: "1"),
            rebuildSource: shouldRebuild,
            health: SourceHealth(sourceID: sourceID, isHealthy: true)
        )
    }
}
