import Foundation

/// Canonical, mutually exclusive token components.  A nil component is
/// unavailable, rather than a zero token count.
public struct TokenParts: Sendable, Equatable, Codable {
    public var inputUncached: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var outputVisible: Int?
    public var reasoning: Int?
    public var normalizedBurnTotal: Int?

    public init(
        inputUncached: Int?,
        cacheRead: Int?,
        cacheWrite: Int?,
        outputVisible: Int?,
        reasoning: Int?,
        normalizedBurnTotal: Int? = nil
    ) {
        self.inputUncached = inputUncached
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.outputVisible = outputVisible
        self.reasoning = reasoning
        self.normalizedBurnTotal = normalizedBurnTotal ?? [inputUncached, cacheRead, cacheWrite, outputVisible, reasoning]
            .compactMap { $0 }
            .reduce(0, +)
    }

    public var isComplete: Bool {
        inputUncached != nil && cacheRead != nil && cacheWrite != nil && outputVisible != nil && reasoning != nil
    }
}

public struct UsageObservation: Sendable, Equatable {
    public var observationIdentity: String
    public var schemaVersion: String
    public var sourceID: String
    public var codingAgent: CodingAgent
    public var model: ModelIdentity
    public var sessionID: String
    public var turnID: String
    public var observedAt: Date
    public var outputTokens: Int
    public var tokenParts: TokenParts?
    /// Only a source-native, durable model call identity belongs here.
    public var modelCallID: String?

    public init(
        observationIdentity: String,
        schemaVersion: String,
        sourceID: String = "unknown",
        codingAgent: CodingAgent,
        model: ModelIdentity,
        sessionID: String,
        turnID: String,
        observedAt: Date,
        outputTokens: Int,
        tokenParts: TokenParts? = nil,
        modelCallID: String? = nil
    ) {
        self.observationIdentity = observationIdentity
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.codingAgent = codingAgent
        self.model = model
        self.sessionID = sessionID
        self.turnID = turnID
        self.observedAt = observedAt
        self.outputTokens = outputTokens
        self.tokenParts = tokenParts
        self.modelCallID = modelCallID
    }
}
public enum OutputThroughputScope: String, Sendable, Equatable, Codable {
    case all
    case selected
}

public struct UsageFact: Sendable, Equatable, Identifiable {
    public var id: String
    public var schemaVersion: String
    public var sourceID: String
    public var codingAgent: CodingAgent
    public var model: ModelIdentity
    public var sessionID: String
    public var turnID: String
    public var observedAt: Date
    public var outputTokens: Int
    public var tokenParts: TokenParts?
    public var modelCallID: String?
    public var modelCallCapability: ModelCallCapability
    public var sourceChannel: SourceChannel
    public var authorityTier: AuthorityTier
    public var measurementGranularity: UsageGranularity
    public var measurementRange: DateInterval
    public var measurementQuality: MeasurementQuality
    public var authority: String
    public var definitionVersion: String
    /// Durable replacement identity. Retention may remove this Fact without
    /// changing the selected canonical cohort.
    public var supersededBy: String?

    public init(
        id: String,
        schemaVersion: String,
        sourceID: String = "unknown",
        codingAgent: CodingAgent,
        model: ModelIdentity,
        sessionID: String,
        turnID: String,
        observedAt: Date,
        outputTokens: Int,
        measurementQuality: MeasurementQuality,
        authority: String,
        definitionVersion: String,
        tokenParts: TokenParts? = nil,
        modelCallID: String? = nil,
        modelCallCapability: ModelCallCapability? = nil,
        sourceChannel: SourceChannel? = nil,
        authorityTier: AuthorityTier? = nil,
        measurementGranularity: UsageGranularity? = nil,
        measurementRange: DateInterval? = nil,
        supersededBy: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.codingAgent = codingAgent
        self.model = model
        self.sessionID = sessionID
        self.turnID = turnID
        self.observedAt = observedAt
        self.outputTokens = outputTokens
        self.measurementQuality = measurementQuality
        self.authority = authority
        self.definitionVersion = definitionVersion
        self.tokenParts = tokenParts
        self.modelCallID = modelCallID
        self.modelCallCapability = modelCallCapability ?? ((modelCallID?.isEmpty == false) ? .available : .unavailable)
        self.sourceChannel = sourceChannel ?? SourceChannel.inferred(schemaVersion: schemaVersion)
        self.authorityTier = authorityTier ?? AuthorityTier.inferred(authority: authority)
        self.measurementGranularity = measurementGranularity ?? ((modelCallID?.isEmpty == false) ? .modelCall : .unknown)
        self.measurementRange = measurementRange ?? DateInterval(start: .distantPast, end: .distantFuture)
        self.supersededBy = supersededBy
    }
}

public struct LiveSample: Sendable, Equatable {
    public var selectedOutputTokens: Int
    public var windowSeconds: Int
    public var contributingFacts: [UsageFact]
}

public struct OutputThroughputMetric: Sendable, Equatable {
    public var tokensPerSecond: Double?
    public var selectedOutputTokens: Int?
    public var averageTokensPerSecond: Double?
    public var activeSessionCount: Int
    public var windowSeconds: Int
    public var measurementQuality: MeasurementQuality
    public var dataState: DataState?
    public var coverage: Coverage
    public var definitionVersion: String
    public var sourceAuthority: String
    public var scope: OutputThroughputScope
    public var freshness: Freshness
    public var sampleCount: Int
    public var unavailableReason: UnavailableReasonCode?
    public var recommendedAction: MetricAction?
}

public struct TokenBurnMetric: Sendable, Equatable {
    public var tokensPerMinute: Double?
    public var selectedBurnTokens: Int?
    public var parts: TokenParts?
    public var windowSeconds: Int
    public var measurementQuality: MeasurementQuality
    public var dataState: DataState?
    public var coverage: Coverage
    public var definitionVersion: String
    public var sourceAuthority: String
    public var scope: OutputThroughputScope
    public var freshness: Freshness
    public var sampleCount: Int
    public var unavailableReason: UnavailableReasonCode?
    public var recommendedAction: MetricAction?

    public init(
        tokensPerMinute: Double?, selectedBurnTokens: Int?, parts: TokenParts?, windowSeconds: Int,
        measurementQuality: MeasurementQuality, dataState: DataState?, coverage: Coverage,
        definitionVersion: String, sourceAuthority: String, scope: OutputThroughputScope,
        freshness: Freshness = .unavailable, sampleCount: Int = 0,
        unavailableReason: UnavailableReasonCode? = nil, recommendedAction: MetricAction? = nil
    ) {
        self.tokensPerMinute = tokensPerMinute
        self.selectedBurnTokens = selectedBurnTokens
        self.parts = parts
        self.windowSeconds = windowSeconds
        self.measurementQuality = measurementQuality
        self.dataState = dataState
        self.coverage = coverage
        self.definitionVersion = definitionVersion
        self.sourceAuthority = sourceAuthority
        self.scope = scope
        self.freshness = freshness
        self.sampleCount = sampleCount
        self.unavailableReason = unavailableReason
        self.recommendedAction = recommendedAction
    }

    public init(
        parts: TokenParts,
        windowSeconds: Int = TokenBurnDefinition.windowSeconds,
        measurementQuality: MeasurementQuality = .derived,
        dataState: DataState? = nil,
        coverage: Coverage? = nil,
        sourceAuthority: String = "synthetic"
    ) {
        let total = parts.normalizedBurnTotal
        self.tokensPerMinute = total.map { Double($0) / Double(windowSeconds) * 60 }
        self.selectedBurnTokens = total
        self.parts = parts
        self.windowSeconds = windowSeconds
        self.measurementQuality = measurementQuality
        self.dataState = dataState ?? (total == 0 ? .zero : nil)
        self.coverage = coverage ?? (parts.isComplete ? .complete : .partial)
        self.definitionVersion = TokenBurnDefinition.version
        self.sourceAuthority = sourceAuthority
        self.scope = .all
        self.freshness = .unavailable
        self.sampleCount = 0
        self.unavailableReason = nil
        self.recommendedAction = nil
    }
}

public struct CallsMetric: Sendable, Equatable {
    public var callsPerMinute: Double?
    public var selectedCallCount: Int?
    public var windowSeconds: Int
    public var measurementQuality: MeasurementQuality
    public var dataState: DataState?
    public var coverage: Coverage
    public var definitionVersion: String
    public var sourceAuthority: String
    public var scope: OutputThroughputScope
    public var freshness: Freshness
    public var sampleCount: Int
    public var unavailableReason: UnavailableReasonCode?
    public var recommendedAction: MetricAction?

    public init(
        modelCallIDs: [String],
        capabilityAvailable: Bool,
        windowSeconds: Int = CallsDefinition.windowSeconds,
        sourceAuthority: String = "unavailable"
    ) {
        self.windowSeconds = windowSeconds
        self.definitionVersion = CallsDefinition.version
        self.sourceAuthority = sourceAuthority
        self.scope = .all
        self.freshness = .unavailable
        self.sampleCount = 0
        self.unavailableReason = nil
        self.recommendedAction = nil
        guard capabilityAvailable else {
            callsPerMinute = nil; selectedCallCount = nil; measurementQuality = .unavailable
            dataState = .unavailable; coverage = .partial
            unavailableReason = .stableModelCallIdentityUnavailable
            recommendedAction = .enableEnhancedTelemetry
            return
        }
        let count = Set(modelCallIDs).count
        callsPerMinute = Double(count) / Double(windowSeconds) * 60
        selectedCallCount = count
        measurementQuality = .derived
        dataState = count == 0 ? .zero : nil
        coverage = .complete
        sampleCount = count
    }
}

public struct LightSnapshot: Sendable, Equatable {
    public var outputThroughput: OutputThroughputMetric
    public var tokenBurn: TokenBurnMetric
    public var calls: CallsMetric
    public var performance: PerformanceSnapshot
    public var codingAgents: [CodingAgent]
    public var modelIdentities: [ModelIdentity]
    public var filter: MetricFilter
    public var generatedAt: Date
    public var sourceHealth: [SourceHealth]
    public var retentionStatus: RetentionResult?
}

extension LightSnapshot {
    public static func updated(
        from current: LightSnapshot?,
        applying action: FilterChipAction,
        on axis: FilterAxis,
        load: (MetricFilter) -> LightSnapshot?
    ) -> LightSnapshot? {
        var filter = current?.filter ?? .all
        filter.apply(action, on: axis)
        return load(filter) ?? current
    }
}
