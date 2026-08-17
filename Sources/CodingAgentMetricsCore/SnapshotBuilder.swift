import Foundation

public struct SnapshotBuilder: Sendable {
    public init() {}

    public func buildLightSnapshot(
        sample: LiveSample,
        allFacts: [UsageFact],
        performanceFacts: [PerformanceFact] = [],
        now: Date,
        sourceHealth: [SourceHealth] = [],
        filter: MetricFilter = .all,
        performanceRange: PerformanceRange = .oneHour
    ) -> LightSnapshot {
        let filteredFacts = allFacts.filter(filter.includes)
        let selection = AuthorityCoalescing.select(filteredFacts)
        let selectedFacts = selection.facts
        let selectedSample = LiveSampler(windowSeconds: sample.windowSeconds).sample(facts: selectedFacts, now: now)
        let usageHealth = Self.relevantHealth(from: sourceHealth, impact: .usage, filter: filter, facts: filteredFacts)
        let performanceHealth = Self.relevantHealth(
            from: sourceHealth,
            impact: .performance,
            filter: filter,
            performanceFacts: performanceFacts
        )
        let scope: OutputThroughputScope = filter.agents.isAll && filter.models.isAll ? .all : .selected
        let emptyReason: UnavailableReasonCode = filteredFacts.isEmpty && !allFacts.isEmpty && scope == .selected
            ? .filterExcludesObservations
            : .noObservations

        return LightSnapshot(
            outputThroughput: outputThroughput(
                sample: selectedSample,
                allFacts: selectedFacts,
                now: now,
                sourceHealth: usageHealth,
                scope: scope,
                authorityConflict: selection.hasConflict,
                emptyReason: emptyReason
            ),
            tokenBurn: tokenBurn(
                facts: filteredFacts,
                now: now,
                sourceHealth: usageHealth,
                scope: scope,
                emptyReason: emptyReason
            ),
            calls: calls(
                facts: filteredFacts,
                now: now,
                sourceHealth: usageHealth,
                scope: scope,
                emptyReason: emptyReason
            ),
            performance: PerformanceSnapshotBuilder().build(
                facts: performanceFacts,
                now: now,
                range: performanceRange,
                filter: filter,
                sourceHealth: performanceHealth
            ),
            codingAgents: uniqueAgents(in: allFacts),
            modelIdentities: uniqueModels(in: allFacts),
            filter: filter,
            generatedAt: now,
            sourceHealth: sourceHealth
        )
    }

    private func outputThroughput(
        sample: LiveSample,
        allFacts: [UsageFact],
        now: Date,
        sourceHealth: [SourceHealth],
        scope: OutputThroughputScope,
        authorityConflict: Bool,
        emptyReason: UnavailableReasonCode
    ) -> OutputThroughputMetric {
        let current = sample.contributingFacts.filter { $0.measurementQuality != .unavailable }
        var contributing = current
        var retained = retainMissingUnhealthySources(
            in: &contributing,
            from: allFacts,
            sourceHealth: sourceHealth,
            windowSeconds: sample.windowSeconds
        )
        if contributing.isEmpty && !allFacts.isEmpty {
            contributing = lastGoodFacts(in: allFacts, windowSeconds: sample.windowSeconds)
                .filter { $0.measurementQuality != .unavailable }
            retained = !contributing.isEmpty
        }
        let degraded = sourceHealth.filter { !$0.isHealthy }
        let retainedHealth = unhealthyHealth(degraded, affecting: contributing)
        retained = retained || !retainedHealth.isEmpty

        guard !contributing.isEmpty else {
            let allSourcesUnavailable = !sourceHealth.isEmpty && sourceHealth.allSatisfy { !$0.isHealthy }
            let state: DataState = allSourcesUnavailable ? .unavailable : (allFacts.isEmpty ? .absent : .unavailable)
            let reason = authorityConflict ? UnavailableReasonCode.authorityConflict
                : (firstDegradation(in: sourceHealth)?.0 ?? emptyReason)
            return OutputThroughputMetric(
                tokensPerSecond: nil,
                selectedOutputTokens: nil,
                windowSeconds: sample.windowSeconds,
                measurementQuality: .unavailable,
                dataState: state,
                coverage: authorityConflict || !sourceHealth.filter({ !$0.isHealthy }).isEmpty ? .partial : .complete,
                definitionVersion: OutputThroughputDefinition.version,
                sourceAuthority: authorityConflict ? "mixed" : (authority(in: allFacts) ?? "unavailable"),
                scope: scope,
                freshness: .unavailable,
                sampleCount: 0,
                unavailableReason: reason,
                recommendedAction: MetricAction.recommended(for: reason)
            )
        }

        let tokens = contributing.reduce(0) { $0 + $1.outputTokens }
        let qualities = contributing.map(\.measurementQuality)
        let mixedQuality = Set(qualities).count > 1
        let partial = authorityConflict || !degraded.isEmpty || mixedQuality
            || allFacts.contains { $0.measurementQuality == .unavailable }
        let degradation = firstDegradation(in: degraded)
        return OutputThroughputMetric(
            tokensPerSecond: Double(tokens) / Double(sample.windowSeconds),
            selectedOutputTokens: tokens,
            windowSeconds: sample.windowSeconds,
            measurementQuality: .combined(qualities, derivedResult: true),
            dataState: retained ? .stale : (tokens == 0 ? .zero : nil),
            coverage: partial ? .partial : .complete,
            definitionVersion: OutputThroughputDefinition.version,
            sourceAuthority: authorityConflict ? "mixed" : (authority(in: contributing) ?? "unavailable"),
            scope: scope,
            freshness: freshness(for: contributing, now: now, retained: retained, unhealthy: retainedHealth),
            sampleCount: contributing.count,
            unavailableReason: degradation?.0,
            recommendedAction: degradation?.1
        )
    }

    private func tokenBurn(
        facts: [UsageFact],
        now: Date,
        sourceHealth: [SourceHealth],
        scope: OutputThroughputScope,
        emptyReason: UnavailableReasonCode
    ) -> TokenBurnMetric {
        var current = facts.filter {
            $0.observedAt >= now.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)) && $0.observedAt <= now
        }
        let retainedSources = retainMissingUnhealthySources(
            in: &current,
            from: facts,
            sourceHealth: sourceHealth,
            windowSeconds: TokenBurnDefinition.windowSeconds
        )
        var selection = AuthorityCoalescing.select(current)
        var authorityScoped = selection.facts
        var retained = retainedSources
        if current.isEmpty && !facts.isEmpty {
            selection = AuthorityCoalescing.select(lastGoodFacts(in: facts, windowSeconds: TokenBurnDefinition.windowSeconds))
            authorityScoped = selection.facts
            retained = !authorityScoped.isEmpty
        }
        let capable = authorityScoped.filter {
            $0.tokenParts?.normalizedBurnTotal != nil && $0.measurementQuality != .unavailable
        }
        let degraded = sourceHealth.filter { !$0.isHealthy }
        let retainedHealth = unhealthyHealth(degraded, affecting: capable.isEmpty ? authorityScoped : capable)
        retained = retained || !retainedHealth.isEmpty

        guard !capable.isEmpty else {
            let state: DataState
            let reason: UnavailableReasonCode
            if selection.hasConflict {
                state = .unavailable
                reason = .authorityConflict
            } else if current.isEmpty && facts.isEmpty {
                state = sourceHealth.contains(where: { !$0.isHealthy }) ? .unavailable : .absent
                reason = firstDegradation(in: sourceHealth)?.0 ?? emptyReason
            } else {
                state = .unavailable
                reason = firstDegradation(in: sourceHealth)?.0 ?? .unsupportedCapability
            }
            return unavailableBurn(
                state: state,
                coverage: selection.hasConflict || sourceHealth.contains(where: { !$0.isHealthy }) ? .partial : .complete,
                authority: selection.hasConflict ? "mixed" : (authority(in: authorityScoped) ?? authority(in: current) ?? authority(in: facts) ?? "unavailable"),
                scope: scope,
                reason: reason
            )
        }

        let parts = merge(parts: capable.compactMap(\.tokenParts))
        let total = capable.compactMap { $0.tokenParts?.normalizedBurnTotal }.reduce(0, +)
        let qualities = capable.map(\.measurementQuality)
        let mixedQuality = Set(qualities).count > 1
        let isPartial = selection.hasConflict || !degraded.isEmpty || mixedQuality
            || authorityScoped.count != capable.count
            || authorityScoped.contains { $0.tokenParts?.isComplete == false }
        let degradation = firstDegradation(in: degraded)
        return TokenBurnMetric(
            tokensPerMinute: Double(total) / Double(TokenBurnDefinition.windowSeconds) * 60,
            selectedBurnTokens: total,
            parts: TokenParts(
                inputUncached: parts.inputUncached,
                cacheRead: parts.cacheRead,
                cacheWrite: parts.cacheWrite,
                outputVisible: parts.outputVisible,
                reasoning: parts.reasoning,
                normalizedBurnTotal: total
            ),
            windowSeconds: TokenBurnDefinition.windowSeconds,
            measurementQuality: .combined(qualities, derivedResult: true),
            dataState: retained ? .stale : (total == 0 ? .zero : nil),
            coverage: isPartial ? .partial : .complete,
            definitionVersion: TokenBurnDefinition.version,
            sourceAuthority: selection.hasConflict ? "mixed" : (authority(in: capable) ?? "unavailable"),
            scope: scope,
            freshness: freshness(for: capable, now: now, retained: retained, unhealthy: retainedHealth),
            sampleCount: capable.count,
            unavailableReason: degradation?.0,
            recommendedAction: degradation?.1
        )
    }

    private func calls(
        facts: [UsageFact],
        now: Date,
        sourceHealth: [SourceHealth],
        scope: OutputThroughputScope,
        emptyReason: UnavailableReasonCode
    ) -> CallsMetric {
        var current = facts.filter {
            $0.observedAt >= now.addingTimeInterval(-TimeInterval(CallsDefinition.windowSeconds)) && $0.observedAt <= now
        }
        let retainedSources = retainMissingUnhealthySources(
            in: &current,
            from: facts,
            sourceHealth: sourceHealth,
            windowSeconds: CallsDefinition.windowSeconds
        )
        var working = current
        var retained = retainedSources
        if current.isEmpty && !facts.isEmpty {
            working = lastGoodFacts(in: facts, windowSeconds: CallsDefinition.windowSeconds)
            retained = !working.isEmpty
        }
        let selection = AuthorityCoalescing.select(working)
        let capabilityAvailable = working.contains { $0.modelCallCapability == .available }
        let supported = working.filter {
            $0.modelCallCapability == .available && $0.measurementQuality != .unavailable
        }
        let degraded = sourceHealth.filter { !$0.isHealthy }
        let retainedHealth = unhealthyHealth(degraded, affecting: supported.isEmpty ? working : supported)
        retained = retained || !retainedHealth.isEmpty
        let hasUnavailableSource = working.contains {
            $0.modelCallCapability == .unavailable || $0.measurementQuality == .unavailable
        }

        guard capabilityAvailable else {
            var metric = CallsMetric(
                modelCallIDs: [],
                capabilityAvailable: false,
                sourceAuthority: selection.hasConflict ? "mixed" : (authority(in: working) ?? authority(in: facts) ?? "unavailable")
            )
            metric.scope = scope
            metric.coverage = selection.hasConflict || !degraded.isEmpty ? .partial : .complete
            if working.isEmpty {
                metric.dataState = sourceHealth.contains(where: { !$0.isHealthy }) ? .unavailable : .absent
                metric.unavailableReason = firstDegradation(in: sourceHealth)?.0 ?? emptyReason
            } else if retained {
                metric.dataState = .stale
                metric.unavailableReason = firstDegradation(in: degraded)?.0 ?? .stableModelCallIdentityUnavailable
            }
            metric.recommendedAction = MetricAction.recommended(for: metric.unavailableReason)
            metric.freshness = freshness(for: working, now: now, retained: retained, unhealthy: retainedHealth)
            return metric
        }

        let identities = supported.compactMap { fact -> String? in
            guard let id = fact.modelCallID, !id.isEmpty else { return nil }
            return "\(fact.codingAgent.rawValue):\(id)"
        }
        var metric = CallsMetric(
            modelCallIDs: identities,
            capabilityAvailable: true,
            sourceAuthority: selection.hasConflict ? "mixed" : (authority(in: supported) ?? "unavailable")
        )
        let qualities = supported.map(\.measurementQuality)
        let mixedQuality = Set(qualities).count > 1
        metric.measurementQuality = .combined(qualities, derivedResult: true)
        metric.dataState = retained ? .stale : (identities.isEmpty ? .zero : nil)
        metric.coverage = selection.hasConflict || !degraded.isEmpty || hasUnavailableSource || mixedQuality ? .partial : .complete
        metric.scope = scope
        metric.freshness = freshness(
            for: supported.isEmpty ? working : supported,
            now: now,
            retained: retained,
            unhealthy: retainedHealth
        )
        metric.sampleCount = Set(identities).count
        let degradation = firstDegradation(in: degraded)
        metric.unavailableReason = degradation?.0
        metric.recommendedAction = degradation?.1
        return metric
    }

    private func unavailableBurn(
        state: DataState,
        coverage: Coverage,
        authority: String,
        scope: OutputThroughputScope,
        reason: UnavailableReasonCode
    ) -> TokenBurnMetric {
        TokenBurnMetric(
            tokensPerMinute: nil,
            selectedBurnTokens: nil,
            parts: nil,
            windowSeconds: TokenBurnDefinition.windowSeconds,
            measurementQuality: .unavailable,
            dataState: state,
            coverage: coverage,
            definitionVersion: TokenBurnDefinition.version,
            sourceAuthority: authority,
            scope: scope,
            unavailableReason: reason,
            recommendedAction: MetricAction.recommended(for: reason)
        )
    }

    private func lastGoodFacts(in facts: [UsageFact], windowSeconds: Int) -> [UsageFact] {
        guard let last = facts.map(\.observedAt).max() else { return [] }
        let start = last.addingTimeInterval(-TimeInterval(windowSeconds))
        return facts.filter { $0.observedAt >= start && $0.observedAt <= last }
    }

    @discardableResult
    private func retainMissingUnhealthySources(
        in current: inout [UsageFact],
        from allFacts: [UsageFact],
        sourceHealth: [SourceHealth],
        windowSeconds: Int
    ) -> Bool {
        var retained = false
        for health in sourceHealth where !health.isHealthy {
            guard !current.contains(where: { Self.matches(health, fact: $0) }) else { continue }
            let sourceFacts = allFacts.filter { Self.matches(health, fact: $0) }
            let lastGood = lastGoodFacts(in: sourceFacts, windowSeconds: windowSeconds)
            let existing = Set(current.map(\.id))
            current.append(contentsOf: lastGood.filter { !existing.contains($0.id) })
            retained = retained || !lastGood.isEmpty
        }
        return retained
    }

    private func freshness(
        for facts: [UsageFact],
        now: Date,
        retained: Bool,
        unhealthy: [SourceHealth]
    ) -> Freshness {
        let affectedDates = unhealthy.compactMap { health in
            facts.filter { Self.matches(health, fact: $0) }.map(\.observedAt).max()
        }
        let lastUpdated = affectedDates.min() ?? facts.map(\.observedAt).max()
        return .observed(at: lastUpdated, now: now, retained: retained)
    }

    private func unhealthyHealth(_ sourceHealth: [SourceHealth], affecting facts: [UsageFact]) -> [SourceHealth] {
        sourceHealth.filter { health in
            guard !health.isHealthy else { return false }
            return facts.isEmpty || facts.contains { Self.matches(health, fact: $0) }
        }
    }

    private func firstDegradation(in sourceHealth: [SourceHealth]) -> (UnavailableReasonCode, MetricAction?)? {
        sourceHealth.lazy.filter { !$0.isHealthy }.compactMap { health in
            guard let reason = health.reasonCode else { return nil }
            return (reason, health.recommendedAction ?? MetricAction.recommended(for: reason))
        }.first
    }

    private static func matches(_ health: SourceHealth, fact: UsageFact) -> Bool {
        fact.sourceID != "unknown" && health.sourceID == fact.sourceID
    }

    private static func relevantHealth(
        from sourceHealth: [SourceHealth],
        impact: SourceImpact,
        filter: MetricFilter,
        facts: [UsageFact]
    ) -> [SourceHealth] {
        sourceHealth.filter { health in
            guard health.impacts.contains(impact) else { return false }
            if filter.agents.isAll && filter.models.isAll { return true }
            if facts.contains(where: { matches(health, fact: $0) }) { return true }
            if !health.impactedAgents.isEmpty && !filter.agents.isAll {
                return health.impactedAgents.map(\.rawValue).contains { filter.agents.selected.contains($0) }
            }
            if !filter.models.isAll && facts.isEmpty { return true }
            return false
        }
    }

    private static func relevantHealth(
        from sourceHealth: [SourceHealth],
        impact: SourceImpact,
        filter: MetricFilter,
        performanceFacts: [PerformanceFact]
    ) -> [SourceHealth] {
        sourceHealth.filter { health in
            guard health.impacts.contains(impact) else { return false }
            if filter.agents.isAll && filter.models.isAll { return true }
            if performanceFacts.filter(filter.includes).contains(where: { fact in
                if health.sourceID == fact.sourceID { return true }
                guard fact.sourceID == "legacy-performance" else { return false }
                return health.impactedAgents.contains(fact.codingAgent)
                    || health.impactedChannels.contains(fact.sourceChannel)
            }) { return true }
            if !health.impactedAgents.isEmpty && !filter.agents.isAll {
                return health.impactedAgents.map(\.rawValue).contains { filter.agents.selected.contains($0) }
            }
            if !filter.models.isAll && performanceFacts.filter(filter.includes).isEmpty { return true }
            return false
        }
    }

    private func merge(parts: [TokenParts]) -> TokenParts {
        func sum(_ values: [Int?]) -> Int? {
            values.allSatisfy { $0 != nil } ? values.compactMap { $0 }.reduce(0, +) : nil
        }
        return TokenParts(
            inputUncached: sum(parts.map(\.inputUncached)),
            cacheRead: sum(parts.map(\.cacheRead)),
            cacheWrite: sum(parts.map(\.cacheWrite)),
            outputVisible: sum(parts.map(\.outputVisible)),
            reasoning: sum(parts.map(\.reasoning))
        )
    }

    private func authority(in facts: [UsageFact]) -> String? {
        let authorities = Set(facts.map(\.authority))
        if authorities.count > 1 { return "mixed" }
        return authorities.first
    }

    private func uniqueAgents(in facts: [UsageFact]) -> [CodingAgent] {
        var seen = Set<String>()
        return facts.compactMap { fact in
            guard seen.insert(fact.codingAgent.rawValue).inserted else { return nil }
            return fact.codingAgent
        }
        .sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.rawValue < $1.rawValue
        }
    }

    private func uniqueModels(in facts: [UsageFact]) -> [ModelIdentity] {
        var seen = Set<String>()
        return facts.compactMap { fact in
            guard seen.insert(fact.model.raw).inserted else { return nil }
            return fact.model
        }
        .sorted {
            if $0.display != $1.display { return $0.display < $1.display }
            return $0.raw < $1.raw
        }
    }
}
