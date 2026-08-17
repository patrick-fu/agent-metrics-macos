import Foundation

public enum MeasurementQuality: String, Sendable, Equatable, Codable {
    case measured
    case derived
    case estimated
    case unavailable
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
    public static let version = "calls-per-minute-v1"
}
