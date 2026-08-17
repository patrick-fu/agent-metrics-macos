import CryptoKit
import Foundation

enum ReplayCheckpoint {
    private struct Payload: Encodable {
        var facts: [CanonicalFact]
        var deletionScopes: [DeletionScope]
    }

    private struct CanonicalFact: Encodable {
        var id: String
        var schemaVersion: String
        var sourceID: String
        var codingAgentRaw: String
        var codingAgentDisplay: String
        var modelRaw: String
        var modelDisplay: String
        var sessionID: String
        var turnID: String
        var observedAt: Double
        var outputTokens: Int
        var tokenParts: TokenParts?
        var modelCallID: String?
        var modelCallCapability: String
        var sourceChannel: String
        var authorityTier: String
        var measurementGranularity: String
        var measurementRangeStart: Double
        var measurementRangeEnd: Double
        var measurementQuality: String
        var authority: String
        var definitionVersion: String

        init(_ fact: UsageFact) {
            id = fact.id
            schemaVersion = fact.schemaVersion
            sourceID = fact.sourceID
            codingAgentRaw = fact.codingAgent.rawValue
            codingAgentDisplay = fact.codingAgent.displayName
            modelRaw = fact.model.raw
            modelDisplay = fact.model.display
            sessionID = fact.sessionID
            turnID = fact.turnID
            observedAt = fact.observedAt.timeIntervalSince1970
            outputTokens = fact.outputTokens
            tokenParts = fact.tokenParts
            modelCallID = fact.modelCallID
            modelCallCapability = fact.modelCallCapability.rawValue
            sourceChannel = fact.sourceChannel.rawValue
            authorityTier = fact.authorityTier.rawValue
            measurementGranularity = fact.measurementGranularity.rawValue
            measurementRangeStart = fact.measurementRange.start.timeIntervalSince1970
            measurementRangeEnd = fact.measurementRange.end.timeIntervalSince1970
            measurementQuality = fact.measurementQuality.rawValue
            authority = fact.authority
            definitionVersion = fact.definitionVersion
        }
    }

    private struct DeletionScope: Encodable, Comparable {
        var kind: String
        var value: String

        init(_ scope: SourceFactScope) {
            switch scope {
            case let .schemaVersion(value):
                kind = "schema-version"
                self.value = value
            case let .idPrefix(value):
                kind = "id-prefix"
                self.value = value
            }
        }

        static func < (lhs: DeletionScope, rhs: DeletionScope) -> Bool {
            (lhs.kind, lhs.value) < (rhs.kind, rhs.value)
        }
    }

    /// Produces one fixed-size checkpoint from exactly the facts that would be
    /// persisted plus the deletion semantics paired with that replay.
    static func digest(
        observations: ArraySlice<UsageObservation>,
        deletionScopes: [SourceFactScope]
    ) throws -> String {
        let ingestor = CanonicalIngestor()
        let facts = observations.compactMap { observation in
            ingestor.ingest([observation]).first.map(CanonicalFact.init)
        }
        let payload = Payload(
            facts: facts,
            deletionScopes: deletionScopes.map(DeletionScope.init).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(payload)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
