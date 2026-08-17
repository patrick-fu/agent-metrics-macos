import Foundation
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

    @Test func callsDistinguishUnsupportedFromAStableSourceConfirmedZeroAndRespectFilter() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let unsupported = fact(id: "unsupported", agent: .codex, model: "gpt-a", observedAt: now, parts: nil, call: nil)
        let unavailable = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [unsupported], now: now), allFacts: [unsupported], now: now
        )
        #expect(unavailable.calls.callsPerMinute == nil)
        #expect(unavailable.calls.dataState == .unavailable)

        let zero = fact(id: "zero", agent: .codex, model: "gpt-a", observedAt: now, parts: nil, call: "")
        let confirmedZero = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [zero], now: now), allFacts: [zero], now: now
        )
        #expect(confirmedZero.calls.callsPerMinute == 0)
        #expect(confirmedZero.calls.dataState == .zero)

        var filter = MetricFilter()
        filter.apply(.toggle("gpt-a"), on: .model)
        let other = fact(id: "other", agent: .claudeCode, model: "claude-a", observedAt: now, parts: TokenParts(inputUncached: 600, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0), call: "other")
        let filtered = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [zero, other], filter: filter, now: now), allFacts: [zero, other], now: now, filter: filter
        )
        #expect(filtered.tokenBurn.dataState == .unavailable)
        #expect(filtered.calls.selectedCallCount == 0)
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

    @Test func enhancedAuthorityReplacesMatchingFallbackInsteadOfAddingIt() {
        let now = Date(timeIntervalSince1970: 1_771_200)
        let parts = TokenParts(inputUncached: 100, cacheRead: 0, cacheWrite: 0, outputVisible: 0, reasoning: 0)
        var fallback = fact(id: "fallback", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        fallback.authority = "claude-code-transcript-usage"
        var enhanced = fact(id: "enhanced", agent: .claudeCode, model: "claude-a", observedAt: now, parts: parts, call: "request-1")
        enhanced.authority = "claude-otel-request"
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: LiveSampler().sample(facts: [fallback, enhanced], now: now), allFacts: [fallback, enhanced], now: now
        )
        #expect(snapshot.tokenBurn.selectedBurnTokens == 100)
        #expect(snapshot.calls.selectedCallCount == 1)
        #expect(snapshot.tokenBurn.sourceAuthority == "claude-otel-request")
    }

    private func fact(id: String, agent: CodingAgent, model: String, observedAt: Date, parts: TokenParts?, call: String?) -> UsageFact {
        UsageFact(
            id: id, schemaVersion: "synthetic-stable-call-v1", codingAgent: agent,
            model: ModelIdentity(raw: model, display: model), sessionID: "session", turnID: "turn",
            observedAt: observedAt, outputTokens: parts?.outputVisible ?? 0,
            measurementQuality: .measured, authority: "synthetic-stable-call", definitionVersion: TokenBurnDefinition.version,
            tokenParts: parts, modelCallID: call
        )
    }
}
