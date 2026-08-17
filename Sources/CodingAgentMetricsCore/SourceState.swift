import Foundation

public struct SourceParserContext: Sendable, Equatable, Codable {
    public var sessionID: String
    public var turnID: String
    public var model: ModelIdentity

    public init(sessionID: String, turnID: String, model: ModelIdentity) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.model = model
    }
}

/// Fixed-size replay metadata. It never contains source records or content.
public struct SourceReplayState: Sendable, Equatable, Codable {
    public var acceptedCount: Int
    public var lastAcceptedIdentity: String?
    public var acceptedPrefixDigest: String?
    public var deletionScopesApplied: Bool
    /// Nil decodes as true for legacy checkpoints, which always overlaid a state.
    public var hadCommittedSourceState: Bool?

    public init(
        acceptedCount: Int,
        lastAcceptedIdentity: String?,
        acceptedPrefixDigest: String?,
        deletionScopesApplied: Bool,
        hadCommittedSourceState: Bool? = nil
    ) {
        self.acceptedCount = acceptedCount
        self.lastAcceptedIdentity = lastAcceptedIdentity
        self.acceptedPrefixDigest = acceptedPrefixDigest
        self.deletionScopesApplied = deletionScopesApplied
        self.hadCommittedSourceState = hadCommittedSourceState
    }
}

public struct SourceFileCursor: Sendable, Equatable, Codable {
    public var fileIdentity: String
    public var locator: String
    public var generation: String
    public var prefixFingerprint: String
    public var offset: Int64
    public var parserVersion: String
    public var lastObservedSize: Int64?
    public var lastModifiedAt: Date?
    public var parserContext: SourceParserContext?
    /// True only while bounded scans are skipping one oversized JSONL record.
    public var discardingOversizedLine: Bool?

    public init(
        fileIdentity: String,
        locator: String,
        generation: String,
        prefixFingerprint: String,
        offset: Int64,
        parserVersion: String,
        lastObservedSize: Int64? = nil,
        lastModifiedAt: Date? = nil,
        parserContext: SourceParserContext? = nil,
        discardingOversizedLine: Bool? = nil
    ) {
        self.fileIdentity = fileIdentity
        self.locator = locator
        self.generation = generation
        self.prefixFingerprint = prefixFingerprint
        self.offset = offset
        self.parserVersion = parserVersion
        self.lastObservedSize = lastObservedSize
        self.lastModifiedAt = lastModifiedAt
        self.parserContext = parserContext
        self.discardingOversizedLine = discardingOversizedLine
    }
}

public enum SourceFactScope: Sendable, Equatable {
    case schemaVersion(String)
    case idPrefix(String)
}

public struct SourceOwnership: Sendable, Equatable, Codable {
    public var sourceID: String
    public var impacts: Set<SourceImpact>
    public var codingAgents: Set<CodingAgent>
    public var channels: Set<SourceChannel>

    public init(
        sourceID: String,
        impacts: Set<SourceImpact>,
        codingAgents: Set<CodingAgent>,
        channels: Set<SourceChannel>
    ) {
        self.sourceID = sourceID
        self.impacts = impacts
        self.codingAgents = codingAgents
        self.channels = channels
    }

    func health(isHealthy: Bool, diagnosticCode: String? = nil) -> SourceHealth {
        SourceHealth(
            sourceID: sourceID,
            isHealthy: isHealthy,
            diagnosticCode: diagnosticCode,
            impacts: impacts,
            impactedAgents: codingAgents,
            impactedChannels: channels
        )
    }
}

public struct SourceState: Sendable, Equatable, Codable {
    public var sourceID: String
    public var parserVersion: String
    public var files: [String: SourceFileCursor]
    public var watermarks: [String: Int]
    /// Persisted parser diagnostics remain visible when no new bytes arrive.
    public var diagnosticCodes: [String]
    /// Claude message totals are authoritative for these sessions.
    public var messageTotalSessions: [String]
    /// Session totals were used only while message totals were absent.
    public var sessionFallbackSessions: [String]
    /// Present only while a bounded accepted prefix still needs replay.
    public var replayState: SourceReplayState?

    public init(
        sourceID: String,
        parserVersion: String,
        files: [String: SourceFileCursor] = [:],
        watermarks: [String: Int] = [:],
        diagnosticCodes: [String] = [],
        messageTotalSessions: [String] = [],
        sessionFallbackSessions: [String] = [],
        replayState: SourceReplayState? = nil
    ) {
        self.sourceID = sourceID
        self.parserVersion = parserVersion
        self.files = files
        self.watermarks = watermarks
        self.diagnosticCodes = diagnosticCodes
        self.messageTotalSessions = messageTotalSessions
        self.sessionFallbackSessions = sessionFallbackSessions
        self.replayState = replayState
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, parserVersion, files, watermarks, diagnosticCodes, messageTotalSessions, sessionFallbackSessions, replayState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        parserVersion = try container.decode(String.self, forKey: .parserVersion)
        files = try container.decodeIfPresent([String: SourceFileCursor].self, forKey: .files) ?? [:]
        watermarks = try container.decodeIfPresent([String: Int].self, forKey: .watermarks) ?? [:]
        diagnosticCodes = try container.decodeIfPresent([String].self, forKey: .diagnosticCodes) ?? []
        messageTotalSessions = try container.decodeIfPresent([String].self, forKey: .messageTotalSessions) ?? []
        sessionFallbackSessions = try container.decodeIfPresent([String].self, forKey: .sessionFallbackSessions) ?? []
        replayState = try container.decodeIfPresent(SourceReplayState.self, forKey: .replayState)
    }
}

public struct SourceDiagnostic: Sendable, Equatable {
    public var code: String
    public var sourceID: String

    public init(code: String, sourceID: String) {
        self.code = code
        self.sourceID = sourceID
    }
}

public struct SourceHealth: Sendable, Equatable, Codable {
    public var sourceID: String
    public var isHealthy: Bool
    public var diagnosticCode: String?
    public var impacts: Set<SourceImpact>
    public var impactedAgents: Set<CodingAgent>
    public var impactedChannels: Set<SourceChannel>
    public var reasonCode: UnavailableReasonCode?
    public var recommendedAction: MetricAction?

    public init(
        sourceID: String,
        isHealthy: Bool,
        diagnosticCode: String? = nil,
        impacts: Set<SourceImpact> = [.usage],
        impactedAgents: Set<CodingAgent> = [],
        impactedChannels: Set<SourceChannel> = [],
        reasonCode: UnavailableReasonCode? = nil,
        recommendedAction: MetricAction? = nil
    ) {
        self.sourceID = sourceID
        self.isHealthy = isHealthy
        self.diagnosticCode = diagnosticCode
        self.impacts = impacts
        self.impactedAgents = impactedAgents
        self.impactedChannels = impactedChannels
        let resolvedReason = reasonCode ?? UnavailableReasonCode.sourceDiagnostic(diagnosticCode)
        self.reasonCode = resolvedReason
        self.recommendedAction = recommendedAction ?? MetricAction.recommended(for: resolvedReason)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, isHealthy, diagnosticCode, impacts, impactedAgents, impactedChannels, reasonCode, recommendedAction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        isHealthy = try container.decode(Bool.self, forKey: .isHealthy)
        diagnosticCode = try container.decodeIfPresent(String.self, forKey: .diagnosticCode)
        impacts = try container.decodeIfPresent(Set<SourceImpact>.self, forKey: .impacts) ?? [.usage]
        impactedAgents = try container.decodeIfPresent(Set<CodingAgent>.self, forKey: .impactedAgents) ?? []
        impactedChannels = try container.decodeIfPresent(Set<SourceChannel>.self, forKey: .impactedChannels) ?? []
        let resolvedReason = try container.decodeIfPresent(UnavailableReasonCode.self, forKey: .reasonCode)
            ?? UnavailableReasonCode.sourceDiagnostic(diagnosticCode)
        reasonCode = resolvedReason
        recommendedAction = try container.decodeIfPresent(MetricAction.self, forKey: .recommendedAction)
            ?? MetricAction.recommended(for: resolvedReason)
    }
}

extension SourceHealth {
    static func usage(
        sourceID: String,
        codingAgent: CodingAgent,
        channel: SourceChannel,
        isHealthy: Bool,
        diagnosticCode: String? = nil
    ) -> SourceHealth {
        SourceHealth(
            sourceID: sourceID,
            isHealthy: isHealthy,
            diagnosticCode: diagnosticCode,
            impacts: [.usage],
            impactedAgents: [codingAgent],
            impactedChannels: [channel]
        )
    }
}

public struct SourceScan: Sendable, Equatable {
    public var observations: [UsageObservation]
    public var state: SourceState
    public var rebuildSource: Bool
    public var rebuiltFileIdentities: [String]
    public var diagnostics: [SourceDiagnostic]
    public var health: SourceHealth

    public init(
        observations: [UsageObservation],
        state: SourceState,
        rebuildSource: Bool,
        rebuiltFileIdentities: [String] = [],
        diagnostics: [SourceDiagnostic] = [],
        health: SourceHealth
    ) {
        self.observations = observations
        self.state = state
        self.rebuildSource = rebuildSource
        self.rebuiltFileIdentities = rebuiltFileIdentities
        self.diagnostics = diagnostics
        self.health = health
    }
}

public protocol SourceOwnedAdapter: SourceAdapter {
    var sourceOwnership: SourceOwnership { get }
}

public protocol IncrementalSourceAdapter: SourceOwnedAdapter {
    var sourceID: String { get }
    var sourceRebuildScope: SourceFactScope { get }
    func rebuiltFileScope(for identity: String) -> SourceFactScope
    func scan(clock: any Clock, state: SourceState?) throws -> SourceScan
}

extension IncrementalSourceAdapter {
    public var sourceOwnership: SourceOwnership {
        SourceOwnership(sourceID: sourceID, impacts: [.usage], codingAgents: [], channels: [])
    }
}
