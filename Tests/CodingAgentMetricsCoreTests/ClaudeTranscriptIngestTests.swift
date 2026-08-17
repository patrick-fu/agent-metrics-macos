import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct ClaudeTranscriptIngestTests {
    @Test func versionedClaudeTranscriptFixtureReachesSQLiteAndLightSnapshot() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: FixtureLocator.claudeCodeHomeV1),
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()

        #expect(snapshot.outputThroughput.windowSeconds == 180)
        #expect(snapshot.outputThroughput.selectedOutputTokens == 1800)
        #expect(snapshot.outputThroughput.tokensPerSecond == 10)
        #expect(snapshot.outputThroughput.measurementQuality == .derived)
        #expect(snapshot.outputThroughput.dataState == nil)
        #expect(snapshot.outputThroughput.coverage == .complete)
        #expect(snapshot.outputThroughput.sourceAuthority == "claude-code-transcript-usage")
        #expect(snapshot.outputThroughput.definitionVersion == "output-throughput-v1")
        #expect(snapshot.codingAgents.map(\.rawValue) == ["claude-code"])
        #expect(snapshot.codingAgents.map(\.displayName) == ["Claude Code"])
        #expect(snapshot.modelIdentities.map(\.raw) == ["claude-synthetic-sonnet"])
        #expect(snapshot.modelIdentities.map(\.display) == ["claude-synthetic-sonnet"])
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("Decode"))
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("TPS"))
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("TTFT"))
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("OTel"))
        #expect(!snapshot.outputThroughput.sourceAuthority.localizedCaseInsensitiveContains("Model Call"))

        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.count == 1)
        #expect(facts[0].outputTokens == 1800)
        #expect(facts[0].schemaVersion == "claude-code-transcript-v1")
        #expect(facts[0].authority == "claude-code-transcript-usage")
        #expect(facts[0].sessionID == "01900000-0000-7000-8000-000000000021")
        #expect(facts[0].turnID == "01900000-0000-7000-8000-000000000221")
        #expect(facts[0].model.raw == "claude-synthetic-sonnet")
        #expect(facts[0].codingAgent.rawValue == "claude-code")
        #expect(!facts[0].id.localizedCaseInsensitiveContains("model-call"))
        #expect(!facts[0].id.contains("/Users/"))
        #expect(!facts[0].sessionID.contains("/Users/"))
    }

    @Test func incompleteTailIsIgnoredUntilTheLineCompletes() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let completePrefix = userLine() + "\n"
        let content = "PROMPT_LEAK_DO_NOT_STORE"
        try home.writeTranscript(lines: [
            userLine(),
            String(assistantLine(outputTokens: 1800).dropLast(12)),
        ], terminated: false)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == nil)
        let state = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "claude-code"))
        let encodedState = try String(decoding: JSONEncoder().encode(state), as: UTF8.self)
        #expect(!encodedState.contains("output_tokens"))
        #expect(state.files.values.allSatisfy { $0.offset == Int64(Data(completePrefix.utf8).count) })

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800),
        ], terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        let completedState = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "claude-code"))
        #expect(!(try String(decoding: JSONEncoder().encode(completedState), as: UTF8.self)).contains(content))
    }

    @Test func coldScanMatchesIncrementalAppend() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }

        let first = [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
        ]
        let second = assistantLine(
            uuid: "01900000-0000-7000-8000-000000000221",
            outputTokens: 2700,
            timestamp: "2026-04-15T12:00:12.000Z"
        )

        let incrementalStore = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: incrementalStore) }
        try home.writeTranscript(lines: first, terminated: true)
        let incrementalRuntime = try TelemetryRuntime(
            storeURL: incrementalStore,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try incrementalRuntime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        try home.writeTranscript(lines: first + [second], terminated: true)
        let incrementalSnapshot = try incrementalRuntime.lightSnapshot()
        let incrementalFacts = try SQLiteFactStore(url: incrementalStore).allFacts()

        let coldHome = try TempClaudeHome()
        defer { coldHome.tearDown() }
        try coldHome.writeTranscript(lines: first + [second], terminated: true)
        let coldStore = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: coldStore) }
        let coldRuntime = try TelemetryRuntime(
            storeURL: coldStore,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: coldHome.root),
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

    @Test func replayedMessageTotalsAddZero() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let lines = [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:11.000Z"),
        ]
        try home.writeTranscript(lines: lines, terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800])
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800])
    }

    @Test func sessionTotalsContributeOnlyPositiveGrowth() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeTranscript(lines: [
            userLine(),
            sessionUsageLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
            sessionUsageLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:11.000Z"),
            sessionUsageLine(outputTokens: 2700, timestamp: "2026-04-15T12:00:12.000Z"),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800, 900])
    }

    @Test func rollbackRebuildsSourceAndNeverCreatesNegativeFacts() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
            assistantLine(outputTokens: 2700, timestamp: "2026-04-15T12:00:11.000Z"),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
            assistantLine(outputTokens: 2700, timestamp: "2026-04-15T12:00:11.000Z"),
            assistantLine(outputTokens: 100, timestamp: "2026-04-15T12:00:12.000Z"),
        ], terminated: true)
        let snapshot = try runtime.lightSnapshot()
        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.allSatisfy { $0.outputTokens >= 0 })
        #expect(facts.map(\.outputTokens) == [1800, 900, 100])
        #expect(snapshot.outputThroughput.selectedOutputTokens == 2800)
    }

    @Test func truncateReplaceAndRestartStayConsistent() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
            assistantLine(outputTokens: 2700, timestamp: "2026-04-15T12:00:11.000Z"),
        ], terminated: true)
        var runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
        ], terminated: true)
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)

        try home.writeTranscript(lines: [
            userLine(sessionID: "01900000-0000-7000-8000-000000000099"),
            assistantLine(
                uuid: "01900000-0000-7000-8000-000000000299",
                sessionID: "01900000-0000-7000-8000-000000000099",
                model: "claude-synthetic-opus",
                outputTokens: 360,
                timestamp: "2026-04-15T12:00:10.000Z"
            ),
        ], terminated: true)
        let replaced = try runtime.lightSnapshot()
        #expect(replaced.outputThroughput.selectedOutputTokens == 360)
        #expect(replaced.modelIdentities.map(\.raw) == ["claude-synthetic-opus"])

        runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 360)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [360])
    }

    @Test func unknownSchemaIsUnavailableAndNeverZero() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeTranscript(lines: [
            userLine(),
            """
            {"type":"experimental_usage_v9","sessionId":"01900000-0000-7000-8000-000000000021","timestamp":"2026-04-15T12:00:10.000Z","usage":{"output_tokens":9999},"model":"claude-synthetic-sonnet"}
            """,
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.tokensPerSecond == nil)
        #expect(snapshot.outputThroughput.selectedOutputTokens == nil)
        #expect(snapshot.outputThroughput.measurementQuality == .unavailable)
        #expect(snapshot.outputThroughput.dataState != .zero)
        #expect(runtime.sourceHealth.contains { health in
            health.sourceID == "claude-code" && health.diagnosticCode == "UNKNOWN_SCHEMA" && !health.isHealthy
        })
        #expect(try SQLiteFactStore(url: storeURL).allFacts().isEmpty)
    }

    @Test func parserVersionChangeRebuildsSourceAndClearsWatermarks() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800),
        ], terminated: true)
        let identity = try #require(ClaudeTranscriptParser.fileIdentity(fromFileName: home.transcriptName))
        let store = try SQLiteFactStore(url: storeURL)
        var staleFact = directClaudeFact(id: "claude-code:\(identity):stale", outputTokens: 9_999)
        staleFact.schemaVersion = ClaudeTranscriptParser.schemaVersion
        staleFact.authority = ClaudeTranscriptParser.authority
        try store.upsert([staleFact])
        try store.saveSourceState(SourceState(
            sourceID: "claude-code",
            parserVersion: "previous-semantic-version",
            watermarks: [identity: 0]
        ))
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )

        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        #expect(runtime.sourceHealth == [
            SourceHealth(sourceID: "claude-code", isHealthy: false, diagnosticCode: "PARSER_VERSION_CHANGED"),
        ])
        let state = try #require(try SQLiteFactStore(url: storeURL).sourceState(sourceID: "claude-code"))
        #expect(state.parserVersion == ClaudeTranscriptParser.semanticVersion)
        #expect(state.watermarks.values.contains(1800))
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800])
    }

    @Test func persistedCursorSurvivesRestartWithoutDoubleCounting() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
        ], terminated: true)
        let first = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try first.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        let state = try SQLiteFactStore(url: storeURL).sourceState(sourceID: "claude-code")
        #expect(state?.parserVersion == ClaudeTranscriptParser.semanticVersion)
        #expect(state?.files.isEmpty == false)
        #expect(state?.files.values.contains { cursor in
            cursor.locator.hasPrefix("projects/")
                && !cursor.locator.contains("/Users/")
                && !cursor.locator.contains("synthetic-workspace")
                && cursor.offset > 0
                && cursor.parserVersion == ClaudeTranscriptParser.semanticVersion
        } == true)

        try home.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 1800, timestamp: "2026-04-15T12:00:10.000Z"),
            assistantLine(outputTokens: 2700, timestamp: "2026-04-15T12:00:12.000Z"),
        ], terminated: true)
        let restarted = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try restarted.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.outputTokens) == [1800, 900])
    }

    @Test func contentBearingLinesAndUserPathsAreNotPersisted() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let home = try TempClaudeHome()
        defer { home.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try home.writeTranscript(lines: [
            userLine(content: "PROMPT_LEAK_DO_NOT_STORE"),
            assistantLine(outputTokens: 1800),
        ], terminated: true)
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapter: ClaudeTranscriptSourceAdapter(home: home.root),
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 1800)
        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.count == 1)
        let encoded = try String(contentsOf: storeURL, encoding: .isoLatin1)
        #expect(!encoded.contains("PROMPT_LEAK_DO_NOT_STORE"))
        #expect(!encoded.contains("/Users/"))
        if let state = try SQLiteFactStore(url: storeURL).sourceState(sourceID: "claude-code") {
            #expect(state.files.values.allSatisfy {
                !$0.locator.contains("/Users/") && !$0.fileIdentity.contains("/")
            })
        }
    }

    @Test func bundledFixtureAndSourcesDoNotEmbedUserAbsolutePaths() throws {
        let fixture = try String(contentsOf: FixtureLocator.claudeCodeHomeV1Transcript, encoding: .utf8)
        #expect(!fixture.contains("/Users/"))
        #expect(!fixture.contains("\"cwd\""))
        #expect(!fixture.contains("\"content\""))
        #expect(fixture.contains("\"type\":\"assistant\""))
        #expect(fixture.contains("\"output_tokens\":1800"))
        #expect(fixture.contains("\"schema_version\"") == false)
    }

    @Test func defaultAdapterResolvesSessionRootAtRuntime() {
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-claude-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolated) }
        let resolved = ClaudeHome.resolve(environment: ["CLAUDE_CONFIG_DIR": isolated.path])
        #expect(resolved.standardizedFileURL == isolated.standardizedFileURL)
    }

    @Test func unknownClaudeSchemaDoesNotAffectCodexSnapshot() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let claudeHome = try TempClaudeHome()
        defer { claudeHome.tearDown() }
        let codexHome = try TempCodexHomeForClaude()
        defer { codexHome.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try claudeHome.writeTranscript(lines: [
            userLine(),
            """
            {"type":"experimental_usage_v9","sessionId":"01900000-0000-7000-8000-000000000021","timestamp":"2026-04-15T12:00:11.000Z","usage":{"output_tokens":9999}}
            """,
        ], terminated: true)
        try codexHome.writeActiveRollout(lines: [
            codexSessionMetaLine(),
            codexTurnContextLine(),
            codexTokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)

        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapters: [
                CodexRolloutSourceAdapter(sessionRoot: codexHome.root),
                ClaudeTranscriptSourceAdapter(home: claudeHome.root),
            ],
            clock: clock
        )
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.selectedOutputTokens == 1800)
        #expect(snapshot.outputThroughput.measurementQuality == .derived)
        #expect(snapshot.codingAgents.map(\.rawValue) == ["codex"])
        #expect(runtime.sourceHealth.contains { $0.sourceID == "codex" && $0.isHealthy })
        #expect(runtime.sourceHealth.contains {
            $0.sourceID == "claude-code" && !$0.isHealthy && $0.diagnosticCode == "UNKNOWN_SCHEMA"
        })
        #expect(try SQLiteFactStore(url: storeURL).allFacts().map(\.codingAgent.rawValue) == ["codex"])
    }

    @Test func failingClaudeScanKeepsCodexLastGoodAndDoesNotOverwriteIt() throws {
        let clock = FixedClock(now: isoDate("2026-04-15T12:00:20Z"))
        let claudeHome = try TempClaudeHome()
        defer { claudeHome.tearDown() }
        let codexHome = try TempCodexHomeForClaude()
        defer { codexHome.tearDown() }
        let storeURL = uniqueStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try claudeHome.writeTranscript(lines: [
            userLine(),
            assistantLine(outputTokens: 900, timestamp: "2026-04-15T12:00:11.000Z"),
        ], terminated: true)
        try codexHome.writeActiveRollout(lines: [
            codexSessionMetaLine(),
            codexTurnContextLine(),
            codexTokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
        ], terminated: true)

        let claude = FlakyClaudeAdapter(inner: ClaudeTranscriptSourceAdapter(home: claudeHome.root))
        let runtime = try TelemetryRuntime(
            storeURL: storeURL,
            sourceAdapters: [
                CodexRolloutSourceAdapter(sessionRoot: codexHome.root),
                claude,
            ],
            clock: clock
        )
        #expect(try runtime.lightSnapshot().outputThroughput.selectedOutputTokens == 2700)

        try codexHome.writeActiveRollout(lines: [
            codexSessionMetaLine(),
            codexTurnContextLine(),
            codexTokenCountLine(totalOutput: 1800, lastOutput: 1800, timestamp: "2026-04-15T12:00:10.000Z", ordinal: 3),
            codexTokenCountLine(totalOutput: 2700, lastOutput: 900, timestamp: "2026-04-15T12:00:12.000Z", ordinal: 4),
        ], terminated: true)
        claude.failNext = true
        let snapshot = try runtime.lightSnapshot()
        #expect(snapshot.outputThroughput.selectedOutputTokens == 3600)
        #expect(runtime.sourceHealth.contains { $0.sourceID == "codex" && $0.isHealthy })
        #expect(runtime.sourceHealth.contains {
            $0.sourceID == "claude-code" && !$0.isHealthy && $0.diagnosticCode == "SOURCE_FAILURE"
        })
        let facts = try SQLiteFactStore(url: storeURL).allFacts()
        #expect(facts.contains { $0.codingAgent.rawValue == "claude-code" && $0.outputTokens == 900 })
        #expect(facts.contains { $0.codingAgent.rawValue == "codex" && $0.outputTokens == 1800 })
        #expect(facts.contains { $0.codingAgent.rawValue == "codex" && $0.outputTokens == 900 })
    }
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cam-claude-\(UUID().uuidString).sqlite")
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}

private func userLine(
    sessionID: String = "01900000-0000-7000-8000-000000000021",
    content: String = "SYNTHETIC_USER_PLACEHOLDER"
) -> String {
    """
    {"type":"user","uuid":"01900000-0000-7000-8000-000000000121","sessionId":"\(sessionID)","timestamp":"2026-04-15T12:00:00.000Z","cwd":"/tmp/synthetic-claude-workspace","version":"2.1.214","message":{"role":"user","content":"\(content)"}}
    """
}

private func assistantLine(
    uuid: String = "01900000-0000-7000-8000-000000000221",
    sessionID: String = "01900000-0000-7000-8000-000000000021",
    model: String = "claude-synthetic-sonnet",
    outputTokens: Int,
    timestamp: String = "2026-04-15T12:00:10.000Z"
) -> String {
    """
    {"type":"assistant","uuid":"\(uuid)","sessionId":"\(sessionID)","timestamp":"\(timestamp)","cwd":"/tmp/synthetic-claude-workspace","version":"2.1.214","message":{"role":"assistant","model":"\(model)","usage":{"input_tokens":2000,"cache_creation_input_tokens":800,"cache_read_input_tokens":3000,"output_tokens":\(outputTokens)}}}
    """
}

private func sessionUsageLine(
    sessionID: String = "01900000-0000-7000-8000-000000000021",
    outputTokens: Int,
    timestamp: String
) -> String {
    """
    {"type":"system","subtype":"session_usage","uuid":"01900000-0000-7000-8000-000000000321","sessionId":"\(sessionID)","timestamp":"\(timestamp)","usage":{"output_tokens":\(outputTokens)}}
    """
}

private func directClaudeFact(id: String, outputTokens: Int) -> UsageFact {
    UsageFact(
        id: id,
        schemaVersion: "claude-code-transcript-v1",
        codingAgent: .claudeCode,
        model: ModelIdentity(raw: "claude-synthetic-sonnet", display: "claude-synthetic-sonnet"),
        sessionID: "01900000-0000-7000-8000-000000000021",
        turnID: "01900000-0000-7000-8000-000000000221",
        observedAt: isoDate("2026-04-15T12:00:10Z"),
        outputTokens: outputTokens,
        measurementQuality: .measured,
        authority: "claude-code-transcript-usage",
        definitionVersion: OutputThroughputDefinition.version
    )
}

private func codexSessionMetaLine() -> String {
    """
    {"timestamp":"2026-04-15T12:00:00.000Z","ordinal":1,"type":"session_meta","payload":{"session_id":"01900000-0000-7000-8000-000000000013","id":"01900000-0000-7000-8000-000000000013","timestamp":"2026-04-15T12:00:00.000Z","cwd":"/tmp/synthetic-codex-workspace","originator":"codex-cli","cli_version":"0.145.0","source":"cli","model_provider":"openai"}}
    """
}

private func codexTurnContextLine() -> String {
    """
    {"timestamp":"2026-04-15T12:00:01.000Z","ordinal":2,"type":"turn_context","payload":{"turn_id":"01900000-0000-7000-8000-000000000113","cwd":"/tmp/synthetic-codex-workspace","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"model":"gpt-synthetic-orion","summary":"auto"}}
    """
}

private func codexTokenCountLine(
    totalOutput: Int,
    lastOutput: Int,
    timestamp: String,
    ordinal: Int
) -> String {
    """
    {"timestamp":"\(timestamp)","ordinal":\(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":3000,"cache_write_input_tokens":800,"output_tokens":\(totalOutput),"reasoning_output_tokens":400,"total_tokens":6800},"last_token_usage":{"input_tokens":5000,"cached_input_tokens":3000,"cache_write_input_tokens":800,"output_tokens":\(lastOutput),"reasoning_output_tokens":400,"total_tokens":6800},"model_context_window":128000},"rate_limits":null}}
    """
}

private final class TempClaudeHome {
    let root: URL
    let transcriptName = "01900000-0000-7000-8000-000000000021.jsonl"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-claude-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    }

    var projectDirectory: URL {
        root.appendingPathComponent("projects/synthetic-workspace", isDirectory: true)
    }

    var transcriptURL: URL {
        projectDirectory.appendingPathComponent(transcriptName)
    }

    func writeTranscript(lines: [String], terminated: Bool) throws {
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        var body = lines.joined(separator: "\n")
        if terminated {
            body.append("\n")
        }
        try body.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TempCodexHomeForClaude {
    let root: URL
    private let fileName = "rollout-2026-04-15T12-00-00-01900000-0000-7000-8000-000000000013.jsonl"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
    }

    var activeDirectory: URL {
        root.appendingPathComponent("sessions/2026/04/15", isDirectory: true)
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

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FlakyClaudeAdapter: IncrementalSourceAdapter, @unchecked Sendable {
    let inner: ClaudeTranscriptSourceAdapter
    var failNext = false

    init(inner: ClaudeTranscriptSourceAdapter) {
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
            throw AdapterError.unsupportedSchema("claude-isolated-failure")
        }
        return try inner.scan(clock: clock, state: state)
    }
}
