import Foundation

public final class TelemetryRuntime: @unchecked Sendable {
    private let store: SQLiteFactStore
    private let sourceAdapters: [any SourceAdapter]
    private let clock: any Clock
    private var lastGoodSnapshot: LightSnapshot?

    public private(set) var sourceHealth: [SourceHealth] = []

    public convenience init(
        storeURL: URL,
        sourceAdapter: any SourceAdapter,
        clock: any Clock = SystemClock()
    ) throws {
        try self.init(storeURL: storeURL, sourceAdapters: [sourceAdapter], clock: clock)
    }

    public init(
        storeURL: URL,
        sourceAdapters: [any SourceAdapter],
        clock: any Clock = SystemClock()
    ) throws {
        self.clock = clock
        self.store = try SQLiteFactStore(url: storeURL)
        self.sourceAdapters = sourceAdapters
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

    public func lightSnapshot(filter: MetricFilter = .all) throws -> LightSnapshot {
        let snapshot = try refresh(filter: filter)
        lastGoodSnapshot = snapshot
        return snapshot
    }

    private func refresh(filter: MetricFilter) throws -> LightSnapshot {
        var health: [SourceHealth] = []
        for sourceAdapter in sourceAdapters {
            do {
                try refresh(sourceAdapter: sourceAdapter, health: &health)
            } catch {
                health.append(SourceHealth(
                    sourceID: sourceID(for: sourceAdapter),
                    isHealthy: false,
                    diagnosticCode: "SOURCE_FAILURE"
                ))
            }
        }
        sourceHealth = health

        let facts = try store.allFacts()
        let sample = LiveSampler().sample(facts: facts, filter: filter, now: clock.now)
        return SnapshotBuilder().buildLightSnapshot(
            sample: sample,
            allFacts: facts,
            now: clock.now,
            sourceHealth: health,
            filter: filter
        )
    }

    private func refresh(
        sourceAdapter: any SourceAdapter,
        health: inout [SourceHealth]
    ) throws {
        if let incremental = sourceAdapter as? any IncrementalSourceAdapter {
            let prior = try store.sourceState(sourceID: incremental.sourceID)
            let scan = try incremental.scan(clock: clock, state: prior)
            let scopes: [SourceFactScope]
            if scan.rebuildSource {
                scopes = [incremental.sourceRebuildScope]
            } else {
                scopes = scan.rebuiltFileIdentities.map { incremental.rebuiltFileScope(for: $0) }
            }
            try store.applyIncremental(
                facts: CanonicalIngestor().ingest(scan.observations),
                deleting: scopes,
                state: scan.state
            )
            health.append(scan.health)
        } else {
            guard sourceAdapters.count == 1 else {
                health.append(SourceHealth(
                    sourceID: "non-incremental",
                    isHealthy: false,
                    diagnosticCode: "MULTI_SOURCE_NON_INCREMENTAL_UNSUPPORTED"
                ))
                return
            }
            let observations = try sourceAdapter.loadObservations(clock: clock)
            try store.replaceAll(CanonicalIngestor().ingest(observations))
            health.append(SourceHealth(sourceID: "unknown", isHealthy: true))
        }
    }

    private func sourceID(for sourceAdapter: any SourceAdapter) -> String {
        (sourceAdapter as? any IncrementalSourceAdapter)?.sourceID ?? "unknown"
    }
}
