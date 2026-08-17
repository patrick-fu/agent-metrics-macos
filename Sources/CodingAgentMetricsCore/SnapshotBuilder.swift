import Foundation

public struct SnapshotBuilder: Sendable {
    public init() {}

    public func buildLightSnapshot(
        sample: LiveSample,
        allFacts: [UsageFact],
        now: Date,
        sourceHealth: [SourceHealth] = []
    ) -> LightSnapshot {
        LightSnapshot(
            outputThroughput: outputThroughput(
                sample: sample,
                allFacts: allFacts,
                coverage: sourceHealth.contains { !$0.isHealthy } ? .partial : .complete,
                sourceHealth: sourceHealth
            ),
            codingAgents: uniqueAgents(in: allFacts),
            modelIdentities: uniqueModels(in: allFacts),
            generatedAt: now,
            sourceHealth: sourceHealth
        )
    }

    private func outputThroughput(
        sample: LiveSample,
        allFacts: [UsageFact],
        coverage: Coverage,
        sourceHealth: [SourceHealth]
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
                scope: .all
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
                scope: .all
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
            scope: .all
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
    }

    private func uniqueModels(in facts: [UsageFact]) -> [ModelIdentity] {
        var seen = Set<String>()
        return facts.compactMap { fact in
            guard seen.insert(fact.model.raw).inserted else { return nil }
            return fact.model
        }
    }
}
