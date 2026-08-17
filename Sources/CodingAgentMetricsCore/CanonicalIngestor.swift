import Foundation

public struct CanonicalIngestor: Sendable {
    public init() {}

    public func ingest(_ observations: [UsageObservation]) -> [UsageFact] {
        var seenObservationIdentities = Set<String>()
        return observations.compactMap { observation in
            guard seenObservationIdentities.insert(observation.observationIdentity).inserted else {
                return nil
            }
            return UsageFact(
                id: observation.observationIdentity,
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
