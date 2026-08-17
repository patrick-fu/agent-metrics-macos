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
                authority: Self.authority(for: observation.schemaVersion),
                definitionVersion: OutputThroughputDefinition.version
            )
        }
    }

    public static func authority(for schemaVersion: String) -> String {
        switch schemaVersion {
        case "synthetic-codex-token-count-v1":
            return "synthetic-codex-token-count"
        case "codex-rollout-v1":
            return CodexRolloutParser.authority
        case "claude-code-transcript-v1":
            return ClaudeTranscriptParser.authority
        default:
            return schemaVersion
        }
    }
}
