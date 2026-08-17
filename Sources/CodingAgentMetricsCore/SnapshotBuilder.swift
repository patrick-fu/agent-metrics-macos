import Foundation

public struct SnapshotBuilder: Sendable {
    public init() {}

    public func buildLightSnapshot(
        sample: LiveSample,
        allFacts: [UsageFact],
        now: Date,
        sourceHealth: [SourceHealth] = [],
        filter: MetricFilter = .all
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
