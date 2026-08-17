import Foundation

public final class TelemetryRuntime: @unchecked Sendable {
    private let store: SQLiteFactStore
    private let sourceAdapters: [any SourceAdapter]
    private let clock: any Clock
    private let storeQueue = DispatchQueue(label: "dev.codingagentmetrics.runtime-store")
    private var receiver: OTLPHTTPReceiver?
    private var lastGoodSnapshot: LightSnapshot?

    public private(set) var sourceHealth: [SourceHealth] = []
    public let receiverConfiguration: OTLPReceiverConfiguration
    private var startupFailureMessage: String?

    public var receiverState: OTLPReceiverState {
        storeQueue.sync { receiver?.state ?? .stopped }
    }

    public var receiverEndpoint: URL { receiverConfiguration.endpoint }

    public var receiverFailureMessage: String? {
        storeQueue.sync {
            if case let .failed(message) = receiver?.state { return message }
            return startupFailureMessage
        }
    }

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
        clock: any Clock = SystemClock(),
        receiverConfiguration: OTLPReceiverConfiguration = OTLPReceiverConfiguration()
    ) throws {
        self.clock = clock
        let store = try SQLiteFactStore(url: storeURL)
        self.store = store
        self.sourceAdapters = sourceAdapters
        self.receiverConfiguration = receiverConfiguration
        if receiverConfiguration.isEnabled {
            try setEnhancedTelemetryEnabled(true)
        }
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

    public func lightSnapshot(filter: MetricFilter = .all, performanceRange: PerformanceRange = .oneHour) throws -> LightSnapshot {
        try storeQueue.sync {
            let snapshot = try refresh(filter: filter, performanceRange: performanceRange)
            lastGoodSnapshot = snapshot
            return snapshot
        }
    }

    public func lightSnapshotFromStore(filter: MetricFilter, performanceRange: PerformanceRange = .oneHour) throws -> LightSnapshot {
        try storeQueue.sync {
            let snapshot = try snapshotFromStore(filter: filter, performanceRange: performanceRange)
            lastGoodSnapshot = snapshot
            return snapshot
        }
    }

    public func ingestPerformance(_ facts: [PerformanceFact]) throws {
        try storeQueue.sync { try store.upsertPerformanceFacts(facts) }
    }

    /// Starts or stops only this app-owned loopback listener.  It never alters
    /// a shell, environment variable, or Claude Code configuration.
    public func setEnhancedTelemetryEnabled(_ enabled: Bool) throws {
        try storeQueue.sync {
            if !enabled {
                receiver?.stop()
                receiver = nil
                startupFailureMessage = nil
                return
            }
            if receiver != nil { return }
            do {
                let configuration = try OTLPReceiverConfiguration(enabled: true)
                let next = OTLPHTTPReceiver(configuration: configuration) { [weak self] facts in
                    guard let self else { return }
                    try self.storeQueue.sync { try self.store.upsertPerformanceFacts(facts) }
                }
                try next.start()
                receiver = next
                startupFailureMessage = nil
            } catch {
                receiver?.stop()
                receiver = nil
                startupFailureMessage = String(describing: error)
                throw error
            }
        }
    }

    private func refresh(filter: MetricFilter, performanceRange: PerformanceRange) throws -> LightSnapshot {
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
        return try snapshotFromStore(filter: filter, performanceRange: performanceRange)
    }

    private func snapshotFromStore(filter: MetricFilter, performanceRange: PerformanceRange) throws -> LightSnapshot {
        let facts = try store.allFacts()
        let performanceFacts = try store.allPerformanceFacts()
        let sample = LiveSampler().sample(facts: facts, filter: filter, now: clock.now)
        return SnapshotBuilder().buildLightSnapshot(
            sample: sample,
            allFacts: facts,
            performanceFacts: performanceFacts,
            now: clock.now,
            sourceHealth: sourceHealth,
            filter: filter,
            performanceRange: performanceRange
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
