import Foundation

public enum MeasurementQuality: String, Sendable, Equatable, Hashable, Codable {
    case measured
    case derived
    case estimated
    case unavailable
}

extension MeasurementQuality {
    static func combined(_ qualities: [MeasurementQuality], derivedResult: Bool) -> MeasurementQuality {
        guard !qualities.isEmpty else { return .unavailable }
        if qualities.contains(.estimated) { return .estimated }
        if qualities.contains(.unavailable) { return .unavailable }
        if derivedResult || qualities.contains(.derived) { return .derived }
        return .measured
    }
}

public enum DataState: String, Sendable, Equatable, Codable {
    case zero
    case stale
    case absent
    case unavailable
}

public enum Coverage: String, Sendable, Equatable, Codable {
    case complete
    case partial
}

public struct Freshness: Sendable, Equatable, Codable {
    public var lastUpdatedAt: Date?
    public var ageSeconds: TimeInterval?
    public var isRetained: Bool

    public init(lastUpdatedAt: Date?, ageSeconds: TimeInterval?, isRetained: Bool) {
        self.lastUpdatedAt = lastUpdatedAt
        self.ageSeconds = ageSeconds
        self.isRetained = isRetained
    }

    public static func observed(at date: Date?, now: Date, retained: Bool = false) -> Freshness {
        Freshness(
            lastUpdatedAt: date,
            ageSeconds: date.map { max(0, now.timeIntervalSince($0)) },
            isRetained: retained
        )
    }

    public static let unavailable = Freshness(lastUpdatedAt: nil, ageSeconds: nil, isRetained: false)
}

public enum UnavailableReasonCode: String, Sendable, Equatable, Codable {
    case noObservations = "NO_OBSERVATIONS"
    case filterExcludesObservations = "FILTER_EXCLUDES_OBSERVATIONS"
    case sourceUnavailable = "SOURCE_UNAVAILABLE"
    case sourceFailure = "SOURCE_FAILURE"
    case sourceOverloaded = "SOURCE_OVERLOADED"
    case unsupportedSchema = "UNSUPPORTED_SCHEMA"
    case unsupportedCapability = "UNSUPPORTED_CAPABILITY"
    case stableModelCallIdentityUnavailable = "STABLE_MODEL_CALL_ID_UNAVAILABLE"
    case requestTimingUnavailable = "REQUEST_TIMING_UNAVAILABLE"
    case authorityConflict = "AUTHORITY_CONFLICT"
    case capacityProtectedWindow = "CAPACITY_PROTECTED_WINDOW"
    case capacityHardLimit = "CAPACITY_HARD_LIMIT"
    case retentionPruned = "RETENTION_PRUNED"

    static func sourceDiagnostic(_ code: String?) -> UnavailableReasonCode? {
        guard let code else { return nil }
        return switch code {
        case "SOURCE_FAILURE": .sourceFailure
        case "SOURCE_UNAVAILABLE": .sourceUnavailable
        case "SOURCE_OVERLOADED", "OVERLOADED": .sourceOverloaded
        case "UNKNOWN_SCHEMA", "PARSER_VERSION_CHANGED", "UNSUPPORTED_SCHEMA": .unsupportedSchema
        case "CAPACITY_PROTECTED_WINDOW": .capacityProtectedWindow
        case "CAPACITY_HARD_LIMIT": .capacityHardLimit
        case "RETENTION_PRUNED": .retentionPruned
        default: .sourceUnavailable
        }
    }

    public var message: String {
        switch self {
        case .noObservations: "No observations are available yet."
        case .filterExcludesObservations: "The current filter excludes available observations."
        case .sourceUnavailable: "The metric source is unavailable."
        case .sourceFailure: "The metric source failed."
        case .sourceOverloaded: "The metric source is overloaded."
        case .unsupportedSchema: "The source schema is unsupported."
        case .unsupportedCapability: "This source does not provide the required capability."
        case .stableModelCallIdentityUnavailable: "Stable Model Call ID unavailable for this source"
        case .requestTimingUnavailable: "Enable loopback OTel request traces; local logs do not contain request-level timings."
        case .authorityConflict: "Conflicting source authorities cannot be combined."
        case .capacityProtectedWindow: "Ingestion is paused because the protected seven-day window reached capacity."
        case .capacityHardLimit: "Ingestion is paused because the telemetry store remains at its hard limit."
        case .retentionPruned: "Older telemetry was pruned; this range has partial coverage."
        }
    }
}

public enum MetricAction: String, Sendable, Equatable, Codable {
    case enableEnhancedTelemetry = "ENABLE_ENHANCED_TELEMETRY"
    case waitForObservations = "WAIT_FOR_OBSERVATIONS"
    case updateSource = "UPDATE_SOURCE"
    case reduceFilter = "REDUCE_FILTER"
    case resetData = "RESET_DATA"

    static func recommended(for reason: UnavailableReasonCode?) -> MetricAction? {
        switch reason {
        case .noObservations: .waitForObservations
        case .filterExcludesObservations: .reduceFilter
        case .sourceUnavailable, .sourceFailure, .sourceOverloaded, .unsupportedSchema: .updateSource
        case .unsupportedCapability, .stableModelCallIdentityUnavailable, .requestTimingUnavailable: .enableEnhancedTelemetry
        case .authorityConflict, .none: nil
        case .capacityProtectedWindow, .capacityHardLimit: .resetData
        case .retentionPruned: nil
        }
    }

    public var message: String {
        switch self {
        case .enableEnhancedTelemetry: "Enable enhanced telemetry"
        case .waitForObservations: "Wait for new observations"
        case .updateSource: "Update or restore the source"
        case .reduceFilter: "Reduce the active filter"
        case .resetData: "Reset app telemetry data"
        }
    }
}

public enum SourceImpact: String, Sendable, Equatable, Hashable, Codable {
    case usage
    case performance
}

/// Whether a source can report durable model call identities. This is a
/// source capability, not an inference from a placeholder identifier.
public enum ModelCallCapability: String, Sendable, Equatable, Codable {
    case available
    case unavailable
}

public enum SourceChannel: String, Sendable, Equatable, Codable {
    case codexRollout
    case claudeTranscript
    case claudeTelemetry
    case synthetic
    case unknown

    static func inferred(schemaVersion: String) -> SourceChannel {
        switch schemaVersion {
        case "codex-rollout-v1": .codexRollout
        case "claude-code-transcript-v1": .claudeTranscript
        case "synthetic-codex-token-count-v1", "synthetic-stable-call-v1": .synthetic
        default: .unknown
        }
    }
}

public enum AuthorityTier: String, Sendable, Equatable, Codable {
    case fallback
    case enhanced

    static func inferred(authority: String) -> AuthorityTier {
        switch authority {
        case "claude-otel-request": .enhanced
        default: .fallback
        }
    }
}

public enum UsageGranularity: String, Sendable, Equatable, Codable {
    case modelCall
    case turn
    case session
    case unknown
}

public struct CodingAgent: Sendable, Equatable, Hashable, Codable {
    public var rawValue: String
    public var displayName: String

    public init(rawValue: String, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
    }

    public static let codex = CodingAgent(rawValue: "codex", displayName: "Codex")
    public static let claudeCode = CodingAgent(rawValue: "claude-code", displayName: "Claude Code")
}

public struct ModelIdentity: Sendable, Equatable, Hashable, Codable {
    public var raw: String
    public var display: String

    public init(raw: String, display: String) {
        self.raw = raw
        self.display = display
    }
}

public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedClock: Clock {
    public var now: Date
    public init(now: Date) {
        self.now = now
    }
}

public enum AppIdentity {
    public static let bundleIdentifier = "dev.codingagentmetrics.app"
    public static let popoverWidth: Double = 430
}

public enum OutputThroughputDefinition {
    public static let windowSeconds = 180
    public static let version = "output-throughput-v1"
}

public enum TokenBurnDefinition {
    public static let windowSeconds = 600
    public static let version = "token-burn-v1"
}

public enum CallsDefinition {
    public static let windowSeconds = 600
    public static let version = "calls-per-minute-v1"
}
