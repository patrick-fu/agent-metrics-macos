import Foundation

public final class TelemetryRuntime: @unchecked Sendable {
    private let store: SQLiteFactStore
    private let sourceAdapter: any SourceAdapter
    private let clock: any Clock

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
        let observations = try sourceAdapter.loadObservations(clock: clock)
        try store.replaceAll(CanonicalIngestor().ingest(observations))
        let facts = try store.allFacts()
        let sample = LiveSampler().sample(facts: facts, now: clock.now)
        return SnapshotBuilder().buildLightSnapshot(sample: sample, allFacts: facts, now: clock.now)
    }
}
