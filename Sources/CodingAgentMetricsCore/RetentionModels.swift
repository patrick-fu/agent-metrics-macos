import Foundation

public struct StoreCapacity: Sendable, Equatable {
    public var bytes: Int64
    public var factCount: Int

    public init(bytes: Int64, factCount: Int) {
        self.bytes = bytes
        self.factCount = factCount
    }
}

public enum CapacityLevel: Sendable, Equatable {
    case normal
    case warning
    case hardLimit
}

public struct DailyUsageRollup: Sendable, Equatable, Identifiable {
    public var id: String
    public var bucketStart: Date
    public var bucketEnd: Date
    public var sourceID: String
    public var codingAgent: CodingAgent
    public var model: ModelIdentity
    public var sourceChannel: SourceChannel
    public var authorityTier: AuthorityTier
    public var measurementGranularity: UsageGranularity
    public var measurementQuality: MeasurementQuality
    public var coverage: Coverage
    public var sourceAuthority: String
    public var definitionVersion: String
    public var outputTokens: Int
    public var tokenParts: TokenParts?
    public var sampleCount: Int
}

public struct RetentionMetadata: Sendable, Equatable {
    public var retentionPrunedBefore: Date?
    public var earliestRetainedAt: Date?
    public var ingestionPaused: Bool
    public var diagnosticCode: String?

    public init(
        retentionPrunedBefore: Date? = nil,
        earliestRetainedAt: Date? = nil,
        ingestionPaused: Bool = false,
        diagnosticCode: String? = nil
    ) {
        self.retentionPrunedBefore = retentionPrunedBefore
        self.earliestRetainedAt = earliestRetainedAt
        self.ingestionPaused = ingestionPaused
        self.diagnosticCode = diagnosticCode
    }
}

public struct RetentionResult: Sendable, Equatable {
    public var capacityBefore: StoreCapacity
    public var capacityAfter: StoreCapacity
    public var didPrune: Bool
    public var ingestionPaused: Bool
    public var diagnosticCode: String?
    public var level: CapacityLevel
}

public struct TelemetryResetResult: Equatable, Sendable {
    public enum CleanupState: Equatable, Sendable {
        case complete
        case pending
    }

    public let cleanupState: CleanupState

    public init(cleanupState: CleanupState) {
        self.cleanupState = cleanupState
    }
}

public struct RetentionPolicy: Sendable, Equatable {
    public var warningBytes: Int64
    public var warningFactCount: Int
    public var hardBytes: Int64
    public var hardFactCount: Int
    public var protectedWindow: TimeInterval
    public var rollupAge: TimeInterval

    public init(
        warningBytes: Int64 = 750 * 1_024 * 1_024,
        warningFactCount: Int = 1_500_000,
        hardBytes: Int64 = 1_024 * 1_024 * 1_024,
        hardFactCount: Int = 2_000_000,
        protectedWindow: TimeInterval = 7 * 24 * 60 * 60,
        rollupAge: TimeInterval = 90 * 24 * 60 * 60
    ) {
        precondition(warningBytes <= hardBytes)
        precondition(warningFactCount <= hardFactCount)
        precondition(protectedWindow > 0 && rollupAge > protectedWindow)
        self.warningBytes = warningBytes
        self.warningFactCount = warningFactCount
        self.hardBytes = hardBytes
        self.hardFactCount = hardFactCount
        self.protectedWindow = protectedWindow
        self.rollupAge = rollupAge
    }

    public func level(for capacity: StoreCapacity) -> CapacityLevel {
        if capacity.bytes >= hardBytes || capacity.factCount >= hardFactCount {
            return .hardLimit
        }
        if capacity.bytes >= warningBytes || capacity.factCount >= warningFactCount {
            return .warning
        }
        return .normal
    }
}
