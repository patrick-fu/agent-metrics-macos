import Foundation

public struct SnapshotBuilder: Sendable {
    public init() {}

    public func buildLightSnapshot(
        sample: LiveSample,
        allFacts: [UsageFact],
        now: Date
    ) -> LightSnapshot {
        LightSnapshot(
            outputThroughput: outputThroughput(sample: sample, allFacts: allFacts),
            codingAgents: uniqueAgents(in: allFacts),
            modelIdentities: uniqueModels(in: allFacts),
            generatedAt: now
        )
    }

    private func outputThroughput(sample: LiveSample, allFacts: [UsageFact]) -> OutputThroughputMetric {
        let window = sample.windowSeconds
        if sample.contributingFacts.isEmpty {
            let state: DataState = allFacts.isEmpty ? .absent : .stale
            return OutputThroughputMetric(
                tokensPerSecond: nil,
                selectedOutputTokens: nil,
                windowSeconds: window,
                measurementQuality: .unavailable,
                dataState: state,
                coverage: .complete,
                definitionVersion: OutputThroughputDefinition.version,
                sourceAuthority: authority(in: sample.contributingFacts) ?? authority(in: allFacts) ?? "synthetic-codex-token-count",
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
                coverage: .complete,
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
            coverage: .complete,
            definitionVersion: OutputThroughputDefinition.version,
            sourceAuthority: authority(in: sample.contributingFacts) ?? authority(in: allFacts) ?? "synthetic-codex-token-count",
            scope: .all
        )
    }

    private func authority(in facts: [UsageFact]) -> String? {
        facts.last?.authority
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
