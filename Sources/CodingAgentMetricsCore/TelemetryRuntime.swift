import Foundation

public final class TelemetryRuntime: @unchecked Sendable {
    private struct PendingIncrementalScan {
        var finalState: SourceState?
        var deletionScopes: [SourceFactScope]
        var health: SourceHealth
        var completionHealth: SourceHealth
        var replayAfterCompletion: IncrementalReplay?
        var checkpointState: SourceState?
    }

    private struct IncrementalReplay {
        var acceptedCount: Int
        var lastAcceptedIdentity: String?
        var acceptedPrefixDigest: String?
        var deletionScopesApplied: Bool
        var hadCommittedSourceState: Bool
    }

    private let store: SQLiteFactStore
    private let sourceAdapters: [any SourceAdapter]
    private let clock: any Clock
    private let storeQueue = DispatchQueue(label: "dev.codingagentmetrics.runtime-store")
    private let lifecycleGate = NSLock()
    private var receiver: OTLPHTTPReceiver?
    private var activeReceiverToken: UUID?
    private let beforePersistingPerformance: (@Sendable () -> Void)?
    private var observationQueue = SourceObservationQueue()
    private var pendingIncrementalScans: [String: PendingIncrementalScan] = [:]
    private var incrementalReplays: [String: IncrementalReplay] = [:]

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
            let unhealthyUsageCount = sourceHealth.filter {
                !$0.isHealthy && $0.impacts.contains(.usage)
            }.count
            let retainedReserve = min(
                Self.maximumQueryFacts - 1,
                unhealthyUsageCount * Self.maximumRetainedFactsPerSource
            )
            let window = try store.factWindow(
                in: interval,
                limit: Self.maximumQueryFacts - retainedReserve
            )
            var facts = window.rows
            var snapshotHealth = sourceHealth
            if window.isTruncated {
                snapshotHealth = Self.applyingOverload(
                    Self.overloadHealth(
                        for: facts,
                        truncatedSourceIDs: window.truncatedSourceIDs,
                        impact: .usage
                    ),
                    to: snapshotHealth
                )
            }
            let currentSourceIDs = Set(facts.map(\.sourceID))
            for health in snapshotHealth where !health.isHealthy && health.impacts.contains(.usage)
                && !currentSourceIDs.contains(health.sourceID) {
                guard let last = try store.latestObservedAt(sourceID: health.sourceID, before: clock.now) else { continue }
                let remaining = Self.maximumQueryFacts - facts.count
                guard remaining > 0 else { continue }
                let retained = try store.factWindow(
                    sourceID: health.sourceID,
                    in: DateInterval(
                        start: last.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)),
                        end: last
                    ),
                    limit: min(Self.maximumRetainedFactsPerSource, remaining)
                ).rows
                let existing = Set(facts.map(\.id))
                facts.append(contentsOf: retained.filter { !existing.contains($0.id) })
            }
            return TrendBuilder().build(facts: facts, now: clock.now, filter: filter, sourceHealth: snapshotHealth)
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
        let unhealthyUsageCount = sourceHealth.filter {
            !$0.isHealthy && $0.impacts.contains(.usage)
        }.count
        let retainedReserve = min(
            Self.maximumQueryFacts - 1,
            unhealthyUsageCount * Self.maximumRetainedFactsPerSource
        )
        let window = try store.factWindow(in: DateInterval(
            start: clock.now.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)),
            end: clock.now
        ), limit: Self.maximumQueryFacts - retainedReserve)
        var facts = window.rows
        var snapshotHealth = sourceHealth
        if window.isTruncated {
            snapshotHealth = Self.applyingOverload(
                Self.overloadHealth(
                    for: facts,
                    truncatedSourceIDs: window.truncatedSourceIDs,
                    impact: .usage
                ),
                to: snapshotHealth
            )
        }
        let unhealthyUsageSources = snapshotHealth.filter {
            !$0.isHealthy && $0.impacts.contains(.usage)
        }
        let currentSourceIDs = Set(facts.map(\.sourceID))
        for health in unhealthyUsageSources where !currentSourceIDs.contains(health.sourceID) {
            guard let last = try store.latestObservedAt(sourceID: health.sourceID, before: clock.now) else { continue }
            let remaining = Self.maximumQueryFacts - facts.count
            guard remaining > 0 else { continue }
            let retained = try store.factWindow(
                sourceID: health.sourceID,
                in: DateInterval(
                    start: last.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)),
                    end: last
                ),
                limit: min(Self.maximumRetainedFactsPerSource, remaining)
            ).rows
            let existing = Set(facts.map(\.id))
            facts.append(contentsOf: retained.filter { !existing.contains($0.id) })
        }
        let performanceWindow = try store.performanceFactWindow(
            in: DateInterval(
                start: clock.now.addingTimeInterval(-performanceRange.seconds),
                end: clock.now
            ),
            limit: Self.maximumQueryFacts
        )
        let performanceFacts = performanceWindow.rows
        if performanceWindow.isTruncated {
            snapshotHealth = Self.applyingOverload(
                Self.overloadHealth(
                    for: performanceFacts,
                    truncatedSourceIDs: performanceWindow.truncatedSourceIDs
                ),
                to: snapshotHealth
            )
        }
        let sample = LiveSampler().sample(facts: facts, filter: filter, now: clock.now)
        return SnapshotBuilder().buildLightSnapshot(
            sample: sample,
            allFacts: facts,
            performanceFacts: performanceFacts,
            now: clock.now,
            sourceHealth: snapshotHealth,
            filter: filter,
            performanceRange: performanceRange
        )
    }

    public static let maximumQueryFacts = 20_000
    public static let maximumRetainedFactsPerSource = 128

    private static func overloadHealth(
        for facts: [UsageFact],
        truncatedSourceIDs: Set<String>,
        impact: SourceImpact
    ) -> [SourceHealth] {
        let factsBySource = Dictionary(grouping: facts, by: \.sourceID)
        return truncatedSourceIDs.sorted().map { sourceID in
            let sourceFacts = factsBySource[sourceID, default: []]
            return SourceHealth(
                sourceID: sourceID,
                isHealthy: false,
                diagnosticCode: "SOURCE_OVERLOADED",
                impacts: [impact],
                impactedAgents: Set(sourceFacts.map(\.codingAgent)),
                impactedChannels: Set(sourceFacts.map(\.sourceChannel)),
                reasonCode: .sourceOverloaded,
                recommendedAction: .updateSource
            )
        }
    }

    private static func overloadHealth(
        for facts: [PerformanceFact],
        truncatedSourceIDs: Set<String>
    ) -> [SourceHealth] {
        let factsBySource = Dictionary(grouping: facts, by: \.sourceID)
        return truncatedSourceIDs.sorted().map { sourceID in
            let sourceFacts = factsBySource[sourceID, default: []]
            return SourceHealth(
                sourceID: sourceID,
                isHealthy: false,
                diagnosticCode: "SOURCE_OVERLOADED",
                impacts: [.performance],
                impactedAgents: Set(sourceFacts.map(\.codingAgent)),
                impactedChannels: Set(sourceFacts.map(\.sourceChannel)),
                reasonCode: .sourceOverloaded,
                recommendedAction: .updateSource
            )
        }
    }

    private static func applyingOverload(_ overloads: [SourceHealth], to health: [SourceHealth]) -> [SourceHealth] {
        let overloadedSources = Set(overloads.map(\.sourceID))
        let overloadedImpacts = Set(overloads.flatMap(\.impacts))
        return health.filter {
            !overloadedSources.contains($0.sourceID) || $0.impacts.isDisjoint(with: overloadedImpacts)
        } + overloads
    }

    private func refresh(
        sourceAdapter: any SourceAdapter,
        health: inout [SourceHealth]
    ) throws {
        if let incremental = sourceAdapter as? any IncrementalSourceAdapter {
            let sourceID = incremental.sourceID
            if pendingIncrementalScans[sourceID] == nil {
                var prior = try store.sourceState(sourceID: sourceID)
                prior?.diagnosticCodes.removeAll { $0 == "SOURCE_OVERLOADED" }
                let persistedReplay = prior?.replayState
                if persistedReplay?.hadCommittedSourceState == false {
                    prior = nil
                } else {
                    prior?.replayState = nil
                }
                let scan = try incremental.scan(clock: clock, state: prior)
                var replay = incrementalReplays[sourceID]
                    ?? persistedReplay.map {
                        IncrementalReplay(
                            acceptedCount: $0.acceptedCount,
                            lastAcceptedIdentity: $0.lastAcceptedIdentity,
                            acceptedPrefixDigest: $0.acceptedPrefixDigest,
                            deletionScopesApplied: $0.deletionScopesApplied,
                            hadCommittedSourceState: $0.hadCommittedSourceState ?? true
                        )
                    }
                    ?? IncrementalReplay(
                        acceptedCount: 0,
                        lastAcceptedIdentity: nil,
                        acceptedPrefixDigest: nil,
                        deletionScopesApplied: false,
                        hadCommittedSourceState: prior != nil
                    )
                if replay.acceptedCount > 0, replay.acceptedPrefixDigest == nil {
                    replay.acceptedCount = 0
                    replay.lastAcceptedIdentity = nil
                    replay.deletionScopesApplied = false
                }

                let ownership = sourceOwnership(for: sourceAdapter)
                if replay.acceptedCount > scan.observations.count,
                   replay.acceptedPrefixDigest != nil,
                   !scan.health.isHealthy {
                    incrementalReplays[sourceID] = replay
                    health.append(SourceHealth(
                        sourceID: sourceID,
                        isHealthy: false,
                        diagnosticCode: "SOURCE_OVERLOADED",
                        impacts: ownership.impacts,
                        impactedAgents: ownership.codingAgents,
                        impactedChannels: ownership.channels,
                        reasonCode: .sourceOverloaded,
                        recommendedAction: .updateSource
                    ))
                    return
                }

                let candidateScopes: [SourceFactScope]
                if scan.rebuildSource {
                    candidateScopes = [incremental.sourceRebuildScope]
                } else {
                    candidateScopes = scan.rebuiltFileIdentities.map { incremental.rebuiltFileScope(for: $0) }
                }
                let acceptedPrefixMatches: Bool
                if replay.acceptedCount == 0 {
                    acceptedPrefixMatches = true
                } else if replay.acceptedCount > scan.observations.count {
                    acceptedPrefixMatches = false
                } else {
                    let candidateDigest = try ReplayCheckpoint.digest(
                        observations: scan.observations.prefix(replay.acceptedCount),
                        deletionScopes: candidateScopes
                    )
                    acceptedPrefixMatches = scan.observations[replay.acceptedCount - 1].observationIdentity
                        == replay.lastAcceptedIdentity
                        && candidateDigest == replay.acceptedPrefixDigest
                }
                if !acceptedPrefixMatches {
                    replay.acceptedCount = 0
                    replay.lastAcceptedIdentity = nil
                    replay.acceptedPrefixDigest = nil
                    replay.deletionScopesApplied = false
                }

                var scopes = candidateScopes
                if replay.deletionScopesApplied { scopes = [] }

                let remaining = scan.observations.dropFirst(replay.acceptedCount)
                let queuedBefore = observationQueue.count(for: sourceID)
                for observation in remaining {
                    observationQueue.enqueue(observation, sourceID: sourceID)
                }
                let acceptedCount = observationQueue.count(for: sourceID) - queuedBefore
                let overloaded = acceptedCount < remaining.count
                let wasReplaying = incrementalReplays[sourceID] != nil || persistedReplay != nil
                var finalState = scan.state
                finalState.diagnosticCodes.removeAll { $0 == "SOURCE_OVERLOADED" }
                finalState.replayState = nil
                let overloadHealth = SourceHealth(
                    sourceID: sourceID,
                    isHealthy: false,
                    diagnosticCode: "SOURCE_OVERLOADED",
                    impacts: ownership.impacts,
                    impactedAgents: ownership.codingAgents,
                    impactedChannels: ownership.channels,
                    reasonCode: .sourceOverloaded,
                    recommendedAction: .updateSource
                )
                let acceptedEnd = replay.acceptedCount + acceptedCount
                if acceptedCount > 0, overloaded {
                    replay.acceptedCount = acceptedEnd
                    replay.lastAcceptedIdentity = scan.observations[acceptedEnd - 1].observationIdentity
                    replay.acceptedPrefixDigest = try ReplayCheckpoint.digest(
                        observations: scan.observations.prefix(acceptedEnd),
                        deletionScopes: candidateScopes
                    )
                }
                pendingIncrementalScans[sourceID] = PendingIncrementalScan(
                    finalState: overloaded ? nil : finalState,
                    deletionScopes: scopes,
                    health: overloaded || wasReplaying ? overloadHealth : scan.health,
                    completionHealth: scan.health,
                    replayAfterCompletion: overloaded ? replay : nil,
                    checkpointState: overloaded
                        ? (prior ?? SourceState(sourceID: sourceID, parserVersion: scan.state.parserVersion))
                        : nil
                )
            }

            guard var pending = pendingIncrementalScans[sourceID] else { return }
            let observations = observationQueue.next(sourceID: sourceID)
            let finishesScan = observationQueue.count(for: sourceID) == observations.count
            if !pending.deletionScopes.isEmpty {
                pending.replayAfterCompletion?.deletionScopesApplied = true
            }
            var stateToPersist = finishesScan ? pending.finalState : nil
            if finishesScan,
               stateToPersist == nil,
               var checkpointState = pending.checkpointState,
               let replay = pending.replayAfterCompletion {
                checkpointState.replayState = SourceReplayState(
                    acceptedCount: replay.acceptedCount,
                    lastAcceptedIdentity: replay.lastAcceptedIdentity,
                    acceptedPrefixDigest: replay.acceptedPrefixDigest,
                    deletionScopesApplied: replay.deletionScopesApplied,
                    hadCommittedSourceState: replay.hadCommittedSourceState
                )
                stateToPersist = checkpointState
            }
            try store.applyIncrementalChunk(
                facts: CanonicalIngestor().ingest(observations),
                deleting: pending.deletionScopes,
                finalState: stateToPersist
            )
            observationQueue.removeFirst(observations.count, sourceID: sourceID)
            pending.deletionScopes = []
            health.append(finishesScan && pending.finalState != nil ? pending.completionHealth : pending.health)
            if finishesScan {
                pendingIncrementalScans[sourceID] = nil
                incrementalReplays[sourceID] = pending.replayAfterCompletion
            } else {
                pendingIncrementalScans[sourceID] = pending
            }
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
