import Foundation

public struct UsageObservation: Sendable, Equatable {
    public var observationIdentity: String
    public var schemaVersion: String
    public var codingAgent: CodingAgent
    public var model: ModelIdentity
    public var sessionID: String
    public var turnID: String
    public var observedAt: Date
    public var outputTokens: Int

    public init(
        observationIdentity: String,
        schemaVersion: String,
        codingAgent: CodingAgent,
        model: ModelIdentity,
        sessionID: String,
        turnID: String,
        observedAt: Date,
        outputTokens: Int
    ) {
        self.observationIdentity = observationIdentity
        self.schemaVersion = schemaVersion
        self.codingAgent = codingAgent
        self.model = model
        self.sessionID = sessionID
        self.turnID = turnID
        self.observedAt = observedAt
        self.outputTokens = outputTokens
    }
}

public enum OutputThroughputScope: String, Sendable, Equatable, Codable {
    case all
    case selected
}

public struct UsageFact: Sendable, Equatable, Identifiable {
    public var id: String
    public var schemaVersion: String
    public var codingAgent: CodingAgent
    public var model: ModelIdentity
    public var sessionID: String
    public var turnID: String
    public var observedAt: Date
    public var outputTokens: Int
    public var measurementQuality: MeasurementQuality
    public var authority: String
    public var definitionVersion: String

    public init(
        id: String,
        schemaVersion: String,
        codingAgent: CodingAgent,
        model: ModelIdentity,
        sessionID: String,
        turnID: String,
        observedAt: Date,
        outputTokens: Int,
        measurementQuality: MeasurementQuality,
        authority: String,
        definitionVersion: String
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.codingAgent = codingAgent
        self.model = model
        self.sessionID = sessionID
        self.turnID = turnID
        self.observedAt = observedAt
        self.outputTokens = outputTokens
        self.measurementQuality = measurementQuality
        self.authority = authority
        self.definitionVersion = definitionVersion
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
    public var windowSeconds: Int
    public var measurementQuality: MeasurementQuality
    public var dataState: DataState?
    public var coverage: Coverage
    public var definitionVersion: String
    public var sourceAuthority: String
    public var scope: OutputThroughputScope
}

public struct LightSnapshot: Sendable, Equatable {
    public var outputThroughput: OutputThroughputMetric
    public var codingAgents: [CodingAgent]
    public var modelIdentities: [ModelIdentity]
    public var filter: MetricFilter
    public var generatedAt: Date
    public var sourceHealth: [SourceHealth]
}
