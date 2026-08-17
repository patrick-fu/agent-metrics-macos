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
        let relevantHealth = Self.relevantHealth(from: sourceHealth, filter: filter, allFacts: allFacts)
        return LightSnapshot(
            outputThroughput: outputThroughput(
                sample: sample,
                allFacts: allFacts.filter(filter.includes),
                coverage: relevantHealth.contains { !$0.isHealthy } ? .partial : .complete,
                sourceHealth: relevantHealth,
                scope: filter.agents.isAll && filter.models.isAll ? .all : .selected
            ),
            tokenBurn: tokenBurn(
                facts: allFacts.filter(filter.includes),
                now: now,
                coverage: relevantHealth.contains { !$0.isHealthy } ? .partial : .complete,
                sourceHealth: relevantHealth,
                scope: filter.agents.isAll && filter.models.isAll ? .all : .selected
            ),
            calls: calls(
                facts: allFacts.filter(filter.includes),
                now: now,
                coverage: relevantHealth.contains { !$0.isHealthy } ? .partial : .complete,
                sourceHealth: relevantHealth,
                scope: filter.agents.isAll && filter.models.isAll ? .all : .selected
            ),
            performance: PerformanceSnapshotBuilder().build(
                facts: performanceFacts,
                now: now,
                range: performanceRange,
                filter: filter
            ),
            codingAgents: uniqueAgents(in: allFacts),
            modelIdentities: uniqueModels(in: allFacts),
            filter: filter,
            generatedAt: now,
            sourceHealth: sourceHealth
        )
    }

    private func tokenBurn(
        facts: [UsageFact], now: Date, coverage: Coverage, sourceHealth: [SourceHealth], scope: OutputThroughputScope
    ) -> TokenBurnMetric {
        let contributing = facts.filter { $0.observedAt >= now.addingTimeInterval(-TimeInterval(TokenBurnDefinition.windowSeconds)) && $0.observedAt <= now }
        let selection = selectedAuthorities(in: contributing)
        let authorityScoped = selection.facts
        let capable = authorityScoped.filter { $0.tokenParts?.normalizedBurnTotal != nil }
        guard !capable.isEmpty else {
            let state: DataState = (!sourceHealth.isEmpty && sourceHealth.allSatisfy { !$0.isHealthy }) ? .unavailable : (contributing.isEmpty ? (facts.isEmpty ? .absent : .stale) : .unavailable)
            return unavailableBurn(
                state: state,
                coverage: selection.hasConflict ? .partial : coverage,
                authority: selection.hasConflict ? "mixed" : (authority(in: authorityScoped) ?? authority(in: contributing) ?? authority(in: facts) ?? "unavailable"),
                scope: scope
            )
        }
        let parts = merge(parts: capable.compactMap(\.tokenParts))
        let total = capable.compactMap { $0.tokenParts?.normalizedBurnTotal }.reduce(0, +)
        let hasSupportedSource = authorityScoped.contains { $0.tokenParts != nil }
        let hasUnsupportedSource = authorityScoped.contains { $0.tokenParts == nil }
        let isPartial = coverage == .partial || selection.hasConflict || (hasSupportedSource && hasUnsupportedSource)
        var metric = TokenBurnMetric(
            parts: TokenParts(
                inputUncached: parts.inputUncached,
                cacheRead: parts.cacheRead,
                cacheWrite: parts.cacheWrite,
                outputVisible: parts.outputVisible,
                reasoning: parts.reasoning,
                normalizedBurnTotal: total
            ),
            windowSeconds: TokenBurnDefinition.windowSeconds,
            coverage: isPartial ? .partial : .complete,
            sourceAuthority: selection.hasConflict ? "mixed" : (authority(in: capable) ?? "unavailable")
        )
        metric.scope = scope
        return metric
    }

    private func calls(
        facts: [UsageFact], now: Date, coverage: Coverage, sourceHealth: [SourceHealth], scope: OutputThroughputScope
    ) -> CallsMetric {
        let contributing = facts.filter { $0.observedAt >= now.addingTimeInterval(-TimeInterval(CallsDefinition.windowSeconds)) && $0.observedAt <= now }
        let contributingSelection = selectedAuthorities(in: contributing)
        let capabilityAvailable = facts.contains { $0.modelCallCapability == .available }
        let hasUnavailableSource = facts.contains { $0.modelCallCapability == .unavailable }
        let metricCoverage: Coverage = coverage == .partial || contributingSelection.hasConflict || (capabilityAvailable && hasUnavailableSource) ? .partial : .complete
        guard capabilityAvailable else {
            var metric = CallsMetric(
                modelCallIDs: [],
                capabilityAvailable: false,
                sourceAuthority: contributingSelection.hasConflict ? "mixed" : (authority(in: facts) ?? "unavailable")
            )
            metric.coverage = metricCoverage
            metric.scope = scope
            if !facts.isEmpty && facts.allSatisfy({ $0.observedAt < now.addingTimeInterval(-TimeInterval(CallsDefinition.windowSeconds)) }) {
                metric.dataState = .stale
            }
            return metric
        }
        let supported = contributing.filter { $0.modelCallCapability == .available }
        let identities = supported.compactMap { fact -> String? in
            guard let id = fact.modelCallID, !id.isEmpty else { return nil }
            return "\(fact.codingAgent.rawValue):\(id)"
        }
        var metric = CallsMetric(
            modelCallIDs: identities,
            capabilityAvailable: true,
            sourceAuthority: contributingSelection.hasConflict ? "mixed" : (authority(in: supported) ?? "unavailable")
        )
        metric.coverage = metricCoverage
        metric.scope = scope
        return metric
    }

    private func unavailableBurn(state: DataState, coverage: Coverage, authority: String, scope: OutputThroughputScope) -> TokenBurnMetric {
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
            scope: scope
        )
    }

    private func merge(parts: [TokenParts]) -> TokenParts {
        func sum(_ values: [Int?]) -> Int? { values.allSatisfy { $0 != nil } ? values.compactMap { $0 }.reduce(0, +) : nil }
        return TokenParts(
            inputUncached: sum(parts.map(\.inputUncached)),
            cacheRead: sum(parts.map(\.cacheRead)),
            cacheWrite: sum(parts.map(\.cacheWrite)),
            outputVisible: sum(parts.map(\.outputVisible)),
            reasoning: sum(parts.map(\.reasoning))
        )
    }

    /// Enhanced request observations replace a matching fallback observation as
    /// one whole fact.  Facts without a durable call identity are intentionally
    /// not stitched or guessed at this seam.  The source channel does not
    /// isolate a cohort because fallback transcripts and enhanced telemetry
    /// necessarily arrive from different channels.
    private func selectedAuthorities(in facts: [UsageFact]) -> AuthoritySelection {
        let grouped = Dictionary(grouping: facts) { fact -> String in
            guard let modelCallID = fact.modelCallID, !modelCallID.isEmpty else { return fact.id }
            return [
                fact.modelCallCapability.rawValue,
                fact.codingAgent.rawValue,
                modelCallID,
                fact.measurementGranularity.rawValue,
                String(fact.measurementRange.start.timeIntervalSince1970),
                String(fact.measurementRange.end.timeIntervalSince1970),
            ].joined(separator: ":")
        }
        var selected: [UsageFact] = []
        var hasConflict = false
        for candidates in grouped.values {
            let enhanced = candidates.filter { $0.authorityTier == .enhanced }
            let tierCandidates = enhanced.isEmpty ? candidates : enhanced
            guard Set(tierCandidates.map(\.authority)).count == 1 else {
                hasConflict = true
                continue
            }
            if let representative = tierCandidates.min(by: { $0.id < $1.id }) {
                selected.append(representative)
            }
        }
        return AuthoritySelection(facts: selected, hasConflict: hasConflict)
    }

    private func outputThroughput(
        sample: LiveSample,
        allFacts: [UsageFact],
        coverage: Coverage,
        sourceHealth: [SourceHealth],
        scope: OutputThroughputScope
    ) -> OutputThroughputMetric {
        let window = sample.windowSeconds
        if sample.contributingFacts.isEmpty {
            let allSourcesUnavailable = !sourceHealth.isEmpty && sourceHealth.allSatisfy { !$0.isHealthy }
            let state: DataState = allSourcesUnavailable ? .unavailable : (allFacts.isEmpty ? .absent : .stale)
            return OutputThroughputMetric(
                tokensPerSecond: nil,
                selectedOutputTokens: nil,
                windowSeconds: window,
                measurementQuality: .unavailable,
                dataState: state,
                coverage: coverage,
                definitionVersion: OutputThroughputDefinition.version,
                sourceAuthority: authority(in: sample.contributingFacts) ?? authority(in: allFacts) ?? "unavailable",
                scope: scope
            )
        }

        let tokens = sample.selectedOutputTokens
        if tokens == 0 {
            return OutputThroughputMetric(
                tokensPerSecond: 0,
                selectedOutputTokens: 0,
                windowSeconds: window,
                measurementQuality: .derived,
                dataState: .zero,
                coverage: coverage,
                definitionVersion: OutputThroughputDefinition.version,
                sourceAuthority: authority(in: sample.contributingFacts) ?? authority(in: allFacts) ?? "synthetic-codex-token-count",
                scope: scope
            )
        }

        return OutputThroughputMetric(
            tokensPerSecond: Double(tokens) / Double(window),
            selectedOutputTokens: tokens,
            windowSeconds: window,
            measurementQuality: .derived,
            dataState: nil,
            coverage: coverage,
            definitionVersion: OutputThroughputDefinition.version,
            sourceAuthority: authority(in: sample.contributingFacts) ?? authority(in: allFacts) ?? "synthetic-codex-token-count",
            scope: scope
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

    private static func relevantHealth(
        from sourceHealth: [SourceHealth],
        filter: MetricFilter,
        allFacts: [UsageFact]
    ) -> [SourceHealth] {
        if filter.agents.isAll && filter.models.isAll {
            return sourceHealth
        }
        let mappedSourceIDs = Set(allFacts.filter(filter.includes).map(\.codingAgent.rawValue))
        if !mappedSourceIDs.isEmpty {
            return sourceHealth.filter { mappedSourceIDs.contains($0.sourceID) }
        }
        guard !filter.agents.isAll else { return sourceHealth }
        return sourceHealth.filter { filter.agents.selected.contains($0.sourceID) }
    }
}

private struct AuthoritySelection {
    var facts: [UsageFact]
    var hasConflict: Bool
}
