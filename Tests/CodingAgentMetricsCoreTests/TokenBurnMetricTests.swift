import Foundation
import SQLite3
import Testing
@testable import CodingAgentMetricsCore

struct TokenBurnMetricTests {
    @Test func canonicalTokenPartsKeepOpenAISubsetsOutOfTheBurnTotal() {
        let parts = TokenParts(
            inputUncached: 70,
            cacheRead: 30,
            cacheWrite: nil,
            outputVisible: 60,
            reasoning: 40
        )

        let metric = TokenBurnMetric(parts: parts, windowSeconds: 600)

        #expect(metric.tokensPerMinute == 20)
        #expect(metric.coverage == .partial)
    }

    @Test func callsRequireAStableModelCallIdentity() {
        let metric = CallsMetric(
            modelCallIDs: [],
            capabilityAvailable: false,
            windowSeconds: 600
        )

        #expect(metric.callsPerMinute == nil)
        #expect(metric.dataState == .unavailable)
    }

    @Test func fixtureSourcesNormalizeCodexSubsetsAndClaudeAdditiveParts() throws {
        let now = ISO8601DateFormatter().date(from: "2026-04-15T12:00:20Z")!
        let codex: [UsageObservation] = try CodexRolloutSourceAdapter(sessionRoot: FixtureLocator.codexHomeV1)
            .loadObservations(clock: FixedClock(now: now))
        let claude: [UsageObservation] = try ClaudeTranscriptSourceAdapter(home: FixtureLocator.claudeCodeHomeV1)
            .loadObservations(clock: FixedClock(now: now))
        let facts = CanonicalIngestor().ingest(codex + claude)
        let codexParts = try #require(facts.first { $0.codingAgent == .codex }?.tokenParts)
        let claudeParts = try #require(facts.first { $0.codingAgent == .claudeCode }?.tokenParts)

        #expect(facts.allSatisfy { $0.modelCallID == nil })

        #expect(codexParts.inputUncached == 2_000)
        #expect(codexParts.cacheRead == 3_000)
        #expect(codexParts.cacheWrite == nil)
        #expect(codexParts.outputVisible == 1_400)
        #expect(codexParts.reasoning == 400)
        #expect(codexParts.normalizedBurnTotal == 6_800)
        #expect(claudeParts.inputUncached == 2_000)
        #expect(claudeParts.cacheWrite == 800)
        #expect(claudeParts.cacheRead == 3_000)
        #expect(claudeParts.outputVisible == nil)
        #expect(claudeParts.reasoning == nil)
        #expect(claudeParts.normalizedBurnTotal == 7_600)
    }

    @Test func tenMinuteBurnAndCallsPoolSelectedRawFactsAndDeduplicatePerSource() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 60, cacheRead: 20, cacheWrite: 10, outputVisible: 10, reasoning: 0)
        let codexOne = fact(id: "a", agent: .codex, model: "gpt-a", observedAt: now.addingTimeInterval(-599), parts: parts, call: "call-1")
        let codexDuplicate = fact(id: "b", agent: .codex, model: "gpt-a", observedAt: now.addingTimeInterval(-10), parts: parts, call: "call-1")
        let claudeSameNativeID = fact(id: "c", agent: .claudeCode, model: "claude-a", observedAt: now.addingTimeInterval(-1), parts: parts, call: "call-1")
        let stale = fact(id: "old", agent: .codex, model: "gpt-a", observedAt: now.addingTimeInterval(-601), parts: parts, call: "old")
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [codexOne, codexDuplicate, claudeSameNativeID, stale], now: now),
            allFacts: [codexOne, codexDuplicate, claudeSameNativeID, stale], now: now
        )

        #expect(snapshot.tokenBurn.selectedBurnTokens == 200)
        #expect(snapshot.tokenBurn.tokensPerMinute == 20)
        #expect(snapshot.calls.selectedCallCount == 2)
        #expect(snapshot.calls.callsPerMinute == 0.2)
    }

    @Test func healthySourcesKeepCoverageCompleteWhenPartsOrCallIdentityAreUnavailable() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let codex = fact(
            id: "codex", agent: .codex, model: "gpt-a", observedAt: now,
            parts: TokenParts(inputUncached: 2_000, cacheRead: 3_000, cacheWrite: nil, outputVisible: 1_400, reasoning: 400), call: nil
        )
        let claude = fact(
            id: "claude", agent: .claudeCode, model: "claude-a", observedAt: now,
            parts: TokenParts(inputUncached: 2_000, cacheRead: 3_000, cacheWrite: 800, outputVisible: nil, reasoning: nil), call: nil
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [codex, claude], now: now), allFacts: [codex, claude], now: now,
            sourceHealth: [SourceHealth(sourceID: "codex", isHealthy: true), SourceHealth(sourceID: "claude-code", isHealthy: true)]
        )
        #expect(snapshot.tokenBurn.coverage == .complete)
        #expect(snapshot.calls.callsPerMinute == nil)
        #expect(snapshot.calls.dataState == .unavailable)
        #expect(snapshot.calls.coverage == .complete)
    }

    @Test func mixedSupportedAndUnsupportedSourcesHavePartialCoverage() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let supported = fact(
            id: "supported", agent: .codex, model: "gpt-a", observedAt: now,
            parts: TokenParts(inputUncached: 1, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0), call: "call-1"
        )
        let unsupported = fact(id: "unsupported", agent: .claudeCode, model: "claude-a", observedAt: now, parts: nil, call: nil)
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [supported, unsupported], now: now), allFacts: [supported, unsupported], now: now,
            sourceHealth: [SourceHealth(sourceID: "codex", isHealthy: true), SourceHealth(sourceID: "claude-code", isHealthy: true)]
        )
        #expect(snapshot.tokenBurn.coverage == .partial)
        #expect(snapshot.calls.coverage == .partial)
    }

    @Test func emptyModelCallIdentityIsUnsupported() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let empty = fact(id: "empty", agent: .codex, model: "gpt-a", observedAt: now, parts: nil, call: "")
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [empty], now: now), allFacts: [empty], now: now
        )
        #expect(snapshot.calls.callsPerMinute == nil)
        #expect(snapshot.calls.dataState == .unavailable)
        #expect(snapshot.calls.coverage == .complete)
    }

    @Test func knownCallCapabilityWithNoCallInTheWindowIsATrueZero() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let knownSource = fact(
            id: "known-source", agent: .codex, model: "gpt-a", observedAt: now.addingTimeInterval(-601),
            parts: nil, call: nil, callCapability: .available
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [knownSource], now: now), allFacts: [knownSource], now: now
        )
        #expect(snapshot.calls.selectedCallCount == 0)
        #expect(snapshot.calls.callsPerMinute == 0)
        #expect(snapshot.calls.dataState == .zero)
        #expect(snapshot.calls.coverage == .complete)
    }

    @Test func staleAuthorityConflictDoesNotMakeCurrentCallsZeroPartial() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var first = fact(id: "first", agent: .claudeCode, model: "claude-a", observedAt: now.addingTimeInterval(-601), parts: parts, call: "request-1")
        first.authority = "claude-code-transcript-usage"
        var second = fact(id: "second", agent: .claudeCode, model: "claude-a", observedAt: now.addingTimeInterval(-602), parts: parts, call: "request-1")
        second.authority = "third-party-otel-mirror"
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [first, second], now: now), allFacts: [first, second], now: now
        )
        #expect(snapshot.calls.selectedCallCount == 0)
        #expect(snapshot.calls.dataState == .zero)
        #expect(snapshot.calls.coverage == .complete)
    }

    @Test func unsupportedCallsDoNotTurnAHealthyScopePartial() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let unsupported = fact(id: "unsupported", agent: .codex, model: "gpt-a", observedAt: now, parts: nil, call: nil)
        let unavailable = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [unsupported], now: now), allFacts: [unsupported], now: now
        )
        #expect(unavailable.calls.coverage == .complete)

        var filter = MetricFilter()
        filter.apply(.toggle("gpt-a"), on: .model)
        let other = fact(id: "other", agent: .claudeCode, model: "claude-a", observedAt: now, parts: TokenParts(inputUncached: 600, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0), call: "other")
        let filtered = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [unsupported, other], filter: filter, now: now), allFacts: [unsupported, other], now: now, filter: filter
        )
        #expect(filtered.tokenBurn.dataState == .unavailable)
        #expect(filtered.calls.callsPerMinute == nil)
    }

    @Test func sqliteRoundTripsCanonicalPartsAndStableCallIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burn-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let stored = fact(
            id: "stored", agent: .codex, model: "gpt-a", observedAt: Date(),
            parts: TokenParts(inputUncached: 1, cacheRead: 2, cacheWrite: nil, outputVisible: 3, reasoning: 4), call: "stable-call"
        )
        let store = try SQLiteFactStore(url: url)
        try store.upsert([stored])
        let loaded = try #require(store.allFacts().first)
        #expect(loaded.tokenParts == stored.tokenParts)
        #expect(loaded.modelCallID == "stable-call")
    }

    @Test func sqliteMigratesLegacyThirteenColumnRowsAndReadsNewPartsAndCallID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-burn-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw SQLiteFixtureError.open }
        try executeLegacySQL(database, """
            CREATE TABLE usage_facts (
                id TEXT PRIMARY KEY, schema_version TEXT NOT NULL, coding_agent_raw TEXT NOT NULL,
                coding_agent_display TEXT NOT NULL, model_raw TEXT NOT NULL, model_display TEXT NOT NULL,
                session_id TEXT NOT NULL, turn_id TEXT NOT NULL, observed_at REAL NOT NULL,
                output_tokens INTEGER NOT NULL, measurement_quality TEXT NOT NULL, authority TEXT NOT NULL,
                definition_version TEXT NOT NULL
            );
            INSERT INTO usage_facts VALUES (
                'legacy', 'legacy-v1', 'codex', 'Codex', 'gpt-a', 'GPT A', 'session', 'turn', 1,
                5, 'measured', 'legacy-source', 'legacy-definition'
            );
        """)
        sqlite3_close(database)
        let store = try SQLiteFactStore(url: url)
        let legacy = try #require(store.allFacts().first { $0.id == "legacy" })
        #expect(legacy.tokenParts == nil)
        #expect(legacy.modelCallID == nil)

        let fresh = fact(
            id: "fresh", agent: .codex, model: "gpt-a", observedAt: Date(timeIntervalSince1970: 2),
            parts: TokenParts(inputUncached: 1, cacheRead: 2, cacheWrite: nil, outputVisible: 3, reasoning: 4), call: "call-1"
        )
        try store.upsert([fresh])
        let reloaded = try #require(store.allFacts().first { $0.id == "fresh" })
        #expect(reloaded.tokenParts == fresh.tokenParts)
        #expect(reloaded.modelCallID == "call-1")
    }

    @Test func enhancedAuthorityReplacesMatchingFallbackInsteadOfAddingIt() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var fallback = fact(id: "fallback", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        fallback.authority = "claude-code-transcript-usage"
        var enhanced = fact(id: "enhanced", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        enhanced.authority = "claude-otel-request"
        enhanced.authorityTier = .enhanced
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fallback, enhanced], now: now), allFacts: [fallback, enhanced], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 100)
        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.tokenBurn.sourceAuthority == "claude-otel-request")
    }

    @Test func replacementCoverageIgnoresSupersededFallbackAvailability() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var fallback = fact(id: "fallback", agent: .claudeCode, model: "claude-a", observedAt: now, parts: nil, call: "request-1")
        fallback.authority = "claude-code-transcript-usage"
        fallback.authorityTier = .fallback
        var enhanced = fact(id: "enhanced", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        enhanced.authority = "claude-otel-request"
        enhanced.authorityTier = .enhanced
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fallback, enhanced], now: now), allFacts: [fallback, enhanced], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 100)
        #expect(snapshot.tokenBurn.coverage == .complete)
    }

    @Test func conflictingFallbackAuthoritiesFailClosedInsteadOfAddingTheirTokenBurn() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var fallback = fact(id: "fallback", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        fallback.authority = "claude-code-transcript-usage"
        fallback.authorityTier = .fallback
        var unknown = fact(id: "unknown", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        unknown.authority = "third-party-otel-mirror"
        unknown.authorityTier = .fallback
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fallback, unknown], now: now), allFacts: [fallback, unknown], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == nil)
        #expect(snapshot.tokenBurn.dataState == .unavailable)
        #expect(snapshot.tokenBurn.sourceAuthority == "mixed")
        #expect(snapshot.tokenBurn.coverage == .partial)
        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.calls.coverage == .partial)
    }

    @Test func conflictingEnhancedAuthoritiesFailClosedInsteadOfAddingTheirTokenBurn() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var one = fact(id: "enhanced-one", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        one.authority = "claude-otel-request"
        one.authorityTier = .enhanced
        var two = fact(id: "enhanced-two", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        two.authority = "third-party-otel-request"
        two.authorityTier = .enhanced
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [one, two], now: now), allFacts: [one, two], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == nil)
        #expect(snapshot.tokenBurn.dataState == .unavailable)
        #expect(snapshot.tokenBurn.sourceAuthority == "mixed")
        #expect(snapshot.tokenBurn.coverage == .partial)
    }

    @Test func duplicateObservationsFromTheSameAuthorityUseAStableRepresentative() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let smaller = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        let larger = TokenParts(inputUncached: 200, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        let first = fact(id: "a", agent: .claudeCode, model: "claude-a", observedAt: now, parts: smaller, call: "request-1")
        let duplicate = fact(id: "b", agent: .claudeCode, model: "claude-a", observedAt: now, parts: larger, call: "request-1")
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [duplicate, first], now: now), allFacts: [duplicate, first], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 100)
        #expect(snapshot.tokenBurn.coverage == .complete)
    }

    @Test func factsWithoutStableIdentityAreNeverStitched() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        let one = fact(id: "one", agent: .codex, model: "gpt-a", observedAt: now, parts: parts, call: nil)
        let two = fact(id: "two", agent: .codex, model: "gpt-a", observedAt: now, parts: parts, call: nil)
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [one, two], now: now), allFacts: [one, two], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 200)
    }

    @Test func enhancedTelemetryReplacesTranscriptFallbackAcrossChannels() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        let range = DateInterval(start: now.addingTimeInterval(-10), end: now)
        var fallback = fact(
            id: "transcript", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1",
            channel: .claudeTranscript, range: range
        )
        fallback.authority = "claude-code-transcript-usage"
        fallback.authorityTier = .fallback
        var enhanced = fact(
            id: "telemetry", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1",
            channel: .claudeTelemetry, range: range
        )
        enhanced.authority = "claude-otel-request"
        enhanced.authorityTier = .enhanced
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fallback, enhanced], now: now), allFacts: [fallback, enhanced], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 100)
        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.tokenBurn.sourceAuthority == "claude-otel-request")
        #expect(snapshot.tokenBurn.coverage == .complete)
    }

    @Test func enhancedDoesNotReplaceAFallbackWithDifferentMeasurementRange() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var fallback = fact(
            id: "transcript", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1",
            channel: .claudeTranscript, range: DateInterval(start: now.addingTimeInterval(-10), end: now)
        )
        fallback.authority = "claude-code-transcript-usage"
        fallback.authorityTier = .fallback
        var enhanced = fact(
            id: "telemetry", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1",
            channel: .claudeTelemetry, range: DateInterval(start: now.addingTimeInterval(-20), end: now)
        )
        enhanced.authority = "claude-otel-request"
        enhanced.authorityTier = .enhanced
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fallback, enhanced], now: now), allFacts: [fallback, enhanced], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 200)
        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.tokenBurn.sourceAuthority == "mixed")
    }

    @Test func callsDeduplicateStableIdentityAcrossChannelsAndMeasurementRanges() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        let first = fact(
            id: "first", agent: .codex, model: "gpt-a", observedAt: now, parts: parts, call: "request-1",
            channel: .claudeTranscript,
            range: DateInterval(start: now.addingTimeInterval(-10), end: now)
        )
        let second = fact(
            id: "second", agent: .codex, model: "gpt-a", observedAt: now, parts: parts, call: "request-1",
            channel: .claudeTelemetry,
            range: DateInterval(start: now.addingTimeInterval(-20), end: now)
        )
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [first, second], now: now), allFacts: [first, second], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 200)
        #expect(snapshot.calls.selectedCallCount == 1)
    }

    @Test func callsPresentationShowsAbsoluteCountAndWindowOrKeepsTheReason() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 10, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        let first = fact(id: "first", agent: .codex, model: "gpt-a", observedAt: now, parts: parts, call: "call-1")
        let second = fact(id: "second", agent: .codex, model: "gpt-a", observedAt: now, parts: parts, call: "call-2")
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [first, second], now: now), allFacts: [first, second], now: now
        )
        let presentation = LightSnapshotPresentation(snapshot: snapshot)
        #expect(presentation.callsDetailText == "2 distinct stable Model Call IDs")
        #expect(presentation.callsWindowLabel == "10m")
        #expect(presentation.callsUnavailableReason == nil)

        let unsupported = fact(id: "unsupported", agent: .claudeCode, model: "claude-a", observedAt: now, parts: nil, call: nil)
        let unavailableSnapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [unsupported], now: now), allFacts: [unsupported], now: now
        )
        let unavailable = LightSnapshotPresentation(snapshot: unavailableSnapshot)
        #expect(unavailable.callsDetailText == "Stable Model Call ID unavailable for this source")
        #expect(unavailable.callsWindowLabel == "10m")
        #expect(unavailable.callsUnavailableReason == "Stable Model Call ID unavailable for this source")
    }

    private func fact(
        id: String, agent: CodingAgent, model: String, observedAt: Date, parts: TokenParts?, call: String?,
        callCapability: ModelCallCapability? = nil, channel: SourceChannel? = nil, range: DateInterval? = nil
    ) -> UsageFact {
        UsageFact(
            id: id, schemaVersion: "synthetic-stable-call-v1", codingAgent: agent,
            model: ModelIdentity(raw: model, display: model), sessionID: "session", turnID: "turn",
            observedAt: observedAt, outputTokens: parts?.outputVisible ?? 0,
            measurementQuality: .measured, authority: "synthetic-stable-call", definitionVersion: TokenBurnDefinition.version,
            tokenParts: parts, modelCallID: call, modelCallCapability: callCapability,
            sourceChannel: channel, measurementRange: range
        )
    }
}

private enum SQLiteFixtureError: Error {
    case open
    case execute
}

private func executeLegacySQL(_ database: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFixtureError.execute }
}
