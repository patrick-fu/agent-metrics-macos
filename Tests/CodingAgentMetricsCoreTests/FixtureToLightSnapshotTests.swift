import Foundation
import Testing
@testable import CodingAgentMetricsCore

struct FixtureToLightSnapshotTests {
    @Test func syntheticFixtureReachesSQLiteAndLightSnapshot() throws {
        let clock = FixedClock(now: Date(timeIntervalSince1970: 1_771_200))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-slice-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let adapter = SyntheticCodexSourceAdapter(
            fixtureURL: FixtureLocator.syntheticCodexTokenCountV1
        )
        let observations = try adapter.loadObservations(clock: clock)
        #expect(observations.count == 1)
        #expect(observations[0].schemaVersion == "synthetic-codex-token-count-v1")
        #expect(observations[0].observationIdentity == "syn-observation-001")
        #expect(observations[0].codingAgent.rawValue == "codex")
        #expect(observations[0].model.raw == "gpt-synthetic-orion")
        #expect(observations[0].model.display == "Synthetic Orion")
        #expect(observations[0].outputTokens == 1800)

        let facts = CanonicalIngestor().ingest(observations)
        let store = try SQLiteFactStore(url: storeURL)
        try store.replaceAll(facts)

        let reopened = try SQLiteFactStore(url: storeURL)
        let persisted = try reopened.allFacts()
        #expect(persisted.count == 1)
        #expect(persisted[0].outputTokens == 1800)
        #expect(persisted[0].codingAgent.rawValue == "codex")

        let sampled = LiveSampler(windowSeconds: 180).sample(facts: persisted, now: clock.now)
        let snapshot = SnapshotBuilder().buildLightSnapshot(
            sample: sampled,
            allFacts: persisted,
            now: clock.now
        )

        #expect(snapshot.outputThroughput.windowSeconds == 180)
        #expect(snapshot.outputThroughput.selectedOutputTokens == 1800)
        #expect(snapshot.outputThroughput.tokensPerSecond == 10)
        #expect(snapshot.outputThroughput.measurementQuality == .derived)
        #expect(snapshot.outputThroughput.dataState == nil)
        #expect(snapshot.outputThroughput.coverage == .complete)
        #expect(snapshot.outputThroughput.definitionVersion == "output-throughput-v1")
        #expect(snapshot.outputThroughput.scope == .all)
        #expect(snapshot.codingAgents.map(\.rawValue) == ["codex"])
        #expect(snapshot.modelIdentities.map(\.raw) == ["gpt-synthetic-orion"])
    }

    @Test func canonicalIngestorDeduplicatesIdentityWithoutCollidingSameSecondTurns() {
        let observedAt = Date(timeIntervalSince1970: 1_771_200)
        let first = makeObservation(identity: "observation-a", outputTokens: 180, observedAt: observedAt)
        let replay = makeObservation(identity: "observation-a", outputTokens: 180, observedAt: observedAt)
        let distinct = makeObservation(identity: "observation-b", outputTokens: 360, observedAt: observedAt)

        let facts = CanonicalIngestor().ingest([first, replay, distinct])

        #expect(facts.count == 2)
        #expect(facts.map(\.id) == ["observation-a", "observation-b"])
        #expect(facts.map(\.outputTokens) == [180, 360])
    }

    private func makeObservation(
        identity: String,
        outputTokens: Int,
        observedAt: Date
    ) -> UsageObservation {
        UsageObservation(
            observationIdentity: identity,
            schemaVersion: "synthetic-codex-token-count-v1",
            codingAgent: .codex,
            model: ModelIdentity(raw: "gpt-synthetic-orion", display: "Synthetic Orion"),
            sessionID: "syn-session-001",
            turnID: "syn-turn-001",
            observedAt: observedAt,
            outputTokens: outputTokens
        )
    }
}
