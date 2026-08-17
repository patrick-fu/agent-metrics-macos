import Foundation

public struct CanonicalIngestor: Sendable {
    public init() {}

    public func ingest(_ observations: [UsageObservation]) -> [UsageFact] {
        observations.map { observation in
            UsageFact(
                id: [
                    observation.schemaVersion,
                    observation.codingAgent.rawValue,
                    observation.sessionID,
                    observation.turnID,
                    String(Int(observation.observedAt.timeIntervalSince1970)),
                ].joined(separator: ":"),
                schemaVersion: observation.schemaVersion,
                codingAgent: observation.codingAgent,
                model: observation.model,
                sessionID: observation.sessionID,
                turnID: observation.turnID,
                observedAt: observation.observedAt,
                outputTokens: observation.outputTokens,
                measurementQuality: .measured,
                authority: "synthetic-codex-token-count",
                definitionVersion: OutputThroughputDefinition.version
            )
        }
    }
}
