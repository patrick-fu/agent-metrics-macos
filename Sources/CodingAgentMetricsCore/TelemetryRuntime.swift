import Foundation

public final class TelemetryRuntime: @unchecked Sendable {
    private let store: SQLiteFactStore
    private let sourceAdapters: [any SourceAdapter]
    private let clock: any Clock
    private let storeQueue = DispatchQueue(label: "dev.codingagentmetrics.runtime-store")
    private let lifecycleGate = NSLock()
    private var receiver: OTLPHTTPReceiver?
    private var activeReceiverToken: UUID?
    private let beforePersistingPerformance: (@Sendable () -> Void)?

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

    public convenience init(
        storeURL: URL,
        sourceAdapters: [any SourceAdapter],
        clock: any Clock = SystemClock(),
        receiverConfiguration: OTLPReceiverConfiguration = OTLPReceiverConfiguration()
    ) throws {
        try self.init(
            storeURL: storeURL,
            sourceAdapters: sourceAdapters,
            clock: clock,
            receiverConfiguration: receiverConfiguration,
            beforePersistingPerformance: nil
        )
    }

    init(
        storeURL: URL,
        sourceAdapters: [any SourceAdapter],
        clock: any Clock = SystemClock(),
        receiverConfiguration: OTLPReceiverConfiguration = OTLPReceiverConfiguration(),
        beforePersistingPerformance: (@Sendable () -> Void)?
    ) throws {
        self.clock = clock
        let store = try SQLiteFactStore(url: storeURL)
        self.store = store
        self.sourceAdapters = sourceAdapters
        self.receiverConfiguration = receiverConfiguration
        self.beforePersistingPerformance = beforePersistingPerformance
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
            try refresh(filter: filter, performanceRange: performanceRange)
        }
    }

    public func lightSnapshotFromStore(filter: MetricFilter, performanceRange: PerformanceRange = .oneHour) throws -> LightSnapshot {
        try storeQueue.sync {
            try snapshotFromStore(filter: filter, performanceRange: performanceRange)
        }
    }

    /// Detail is intentionally separate from the compact LightSnapshot path.
    /// It reads a bounded, bucket-aligned history only after the user opens Trends.
    public func trendSnapshot(filter: MetricFilter = .all) throws -> TrendSnapshot {
        try storeQueue.sync {
            let bucketSeconds = 30.0
            let closedEnd = floor(clock.now.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
            let interval = DateInterval(
                start: Date(timeIntervalSince1970: closedEnd - TimeInterval(TokenBurnDefinition.windowSeconds)),
                end: clock.now
            )
            var facts = try store.facts(in: interval, limit: Self.maximumTrendFacts)
            let currentSourceIDs = Set(facts.map(\.sourceID))
            for health in sourceHealth where !health.isHealthy && health.impacts.contains(.usage)
                && !currentSourceIDs.contains(health.sourceID) {
                guard let last = try store.latestObservedAt(sourceID: health.sourceID, before: clock.now) else { continue }
                let retained = try store.facts(
                    sourceID: health.sourceID,
                    in: DateInterval(
                        start: last.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)),
                        end: last
                    )
                )
                let existing = Set(facts.map(\.id))
                facts.append(contentsOf: retained.filter { !existing.contains($0.id) })
            }
            return TrendBuilder().build(facts: facts, now: clock.now, filter: filter, sourceHealth: sourceHealth)
        }
    }

    public func ingestPerformance(_ facts: [PerformanceFact]) throws {
        try storeQueue.sync { try store.upsertPerformanceFacts(facts) }
    }

    func storedPerformanceFactCountForTesting() throws -> Int {
        try storeQueue.sync { try store.allPerformanceFacts().count }
    }

    /// Starts or stops only this app-owned loopback listener.  It never alters
    /// a shell, environment variable, or Claude Code configuration.
    public func setEnhancedTelemetryEnabled(_ enabled: Bool) throws {
        lifecycleGate.lock()
        defer { lifecycleGate.unlock() }
        if !enabled {
            let toStop = storeQueue.sync { () -> OTLPHTTPReceiver? in
                let existing = receiver
                receiver = nil
                activeReceiverToken = nil
                startupFailureMessage = nil
                return existing
            }
            toStop?.stop()
            return
        }
        if storeQueue.sync(execute: { receiver != nil }) { return }

        var created: OTLPHTTPReceiver?
        do {
            let configuration = try OTLPReceiverConfiguration(enabled: true)
            let token = UUID()
            let next = OTLPHTTPReceiver(configuration: configuration) { [weak self] facts in
                guard let self else { return }
                self.beforePersistingPerformance?()
                try self.storeQueue.sync {
                    guard self.activeReceiverToken == token else { return }
                    try self.store.upsertPerformanceFacts(facts)
                }
            }
            created = next
            storeQueue.sync {
                receiver = next
                activeReceiverToken = token
                startupFailureMessage = nil
            }
            try next.start()
        } catch {
            storeQueue.sync {
                if let created, receiver === created {
                    receiver = nil
                    activeReceiverToken = nil
                }
                startupFailureMessage = String(describing: error)
            }
            created?.stop()
            throw error
        }
    }

    private func refresh(filter: MetricFilter, performanceRange: PerformanceRange) throws -> LightSnapshot {
        var health: [SourceHealth] = []
        for sourceAdapter in sourceAdapters {
            do {
                try refresh(sourceAdapter: sourceAdapter, health: &health)
            } catch {
                let ownership = sourceOwnership(for: sourceAdapter)
                health.append(ownership.health(isHealthy: false, diagnosticCode: "SOURCE_FAILURE"))
            }
        }
        if let performanceHealth = performanceSourceHealth() {
            health.append(performanceHealth)
        }
        sourceHealth = health
        return try snapshotFromStore(filter: filter, performanceRange: performanceRange)
    }

    private func snapshotFromStore(filter: MetricFilter, performanceRange: PerformanceRange) throws -> LightSnapshot {
        var facts = try store.facts(in: DateInterval(
            start: clock.now.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)),
            end: clock.now
        ))
        let unhealthyUsageSources = sourceHealth.filter {
            !$0.isHealthy && $0.impacts.contains(.usage)
        }
        let currentSourceIDs = Set(facts.map(\.sourceID))
        for health in unhealthyUsageSources where !currentSourceIDs.contains(health.sourceID) {
            guard let last = try store.latestObservedAt(sourceID: health.sourceID, before: clock.now) else { continue }
            let retained = try store.facts(
                sourceID: health.sourceID,
                in: DateInterval(
                    start: last.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)),
                    end: last
                )
            )
            let existing = Set(facts.map(\.id))
            facts.append(contentsOf: retained.filter { !existing.contains($0.id) })
        }
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

    private static let maximumTrendFacts = 20_000

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
            health.append(sourceOwnership(for: sourceAdapter).health(isHealthy: true))
        }
    }

    private func sourceOwnership(for sourceAdapter: any SourceAdapter) -> SourceOwnership {
        (sourceAdapter as? any SourceOwnedAdapter)?.sourceOwnership
            ?? SourceOwnership(sourceID: "unknown", impacts: [.usage], codingAgents: [], channels: [])
    }

    private func performanceSourceHealth() -> SourceHealth? {
        let ownership = SourceOwnership(
            sourceID: "claude-otel-request",
            impacts: [.performance],
            codingAgents: [.claudeCode],
            channels: [.claudeTelemetry]
        )
        if startupFailureMessage != nil {
            return ownership.health(isHealthy: false, diagnosticCode: "SOURCE_FAILURE")
        }
        guard let receiver else { return nil }
        if case .failed = receiver.state {
            return ownership.health(isHealthy: false, diagnosticCode: "SOURCE_FAILURE")
        }
        return ownership.health(isHealthy: receiver.isRunning)
    }
}
