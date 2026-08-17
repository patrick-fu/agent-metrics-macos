import Foundation

public final class TelemetryRuntime: @unchecked Sendable {
    private let store: SQLiteFactStore
    private let sourceAdapter: any SourceAdapter
    private let clock: any Clock
    private var lastGoodSnapshot: LightSnapshot?

    public private(set) var sourceHealth: [SourceHealth] = []

    public init(
        storeURL: URL,
        sourceAdapter: any SourceAdapter,
        clock: any Clock = SystemClock()
    ) throws {
        self.clock = clock
        self.store = try SQLiteFactStore(url: storeURL)
        self.sourceAdapter = sourceAdapter
    }

    public convenience init(
        storeURL: URL,
        fixtureURL: URL,
        clock: any Clock = SystemClock()
    ) throws {
        try self.init(
            storeURL: storeURL,
            sourceAdapter: SyntheticCodexSourceAdapter(fixtureURL: fixtureURL),
            clock: clock
        )
    }

    public func lightSnapshot() throws -> LightSnapshot {
        do {
            let snapshot = try refresh()
            lastGoodSnapshot = snapshot
            return snapshot
        } catch {
            if let lastGoodSnapshot {
                sourceHealth = [
                    SourceHealth(sourceID: "codex", isHealthy: false, diagnosticCode: "SOURCE_FAILURE"),
                ]
                return lastGoodSnapshot
            }
            throw error
        }
    }

    private func refresh() throws -> LightSnapshot {
        if let incremental = sourceAdapter as? any IncrementalSourceAdapter {
            let prior = try store.sourceState(sourceID: incremental.sourceID)
            let scan = try incremental.scan(clock: clock, state: prior)
            if scan.rebuildSource {
                try store.deleteFacts(schemaVersion: CodexRolloutParser.schemaVersion)
            } else {
                for identity in scan.rebuiltFileIdentities {
                    try store.deleteFacts(idPrefix: "codex-rollout:\(identity):")
                }
            }
            try store.upsert(CanonicalIngestor().ingest(scan.observations))
            try store.saveSourceState(scan.state)
            sourceHealth = [scan.health]
        } else {
            let observations = try sourceAdapter.loadObservations(clock: clock)
            try store.replaceAll(CanonicalIngestor().ingest(observations))
        }

        let facts = try store.allFacts()
        let sample = LiveSampler().sample(facts: facts, now: clock.now)
        return SnapshotBuilder().buildLightSnapshot(sample: sample, allFacts: facts, now: clock.now)
    }
}
