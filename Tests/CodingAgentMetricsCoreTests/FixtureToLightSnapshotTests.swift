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
        #expect(snapshot.codingAgents.map(\.rawValue) == ["codex"])
        #expect(snapshot.modelIdentities.map(\.raw) == ["gpt-synthetic-orion"])
    }
}
